## Encrypted databases (retroui/db with a key, src/retroui/cryptvfs.c): what
## is written is noise without the key (the file, its WAL), a wrong key or
## none does not open it, a byte changed on disk is found, full-text search
## and big rows work as before, two connections share it, an unencrypted
## file is made encrypted (encryptDb) with nothing of it left, and a writer
## killed in the middle of its work (kill -9) leaves a database that opens
## with every transaction it finished.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, osproc, strutils, sysrand, times, streams]
import retroui/db

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc newKey(): string =
  result = newString(32)
  discard urandom(result.toOpenArrayByte(0, 31))

let dir = getTempDir() / "retro-dbcrypt-" & $getCurrentProcessId()
let marker = "ZebraMarkerWord"

# (the writer the crash test kills: it commits rows, saying each one done)
if paramCount() == 3 and paramStr(1) == "--writer":
  let k = readFile(paramStr(3))
  let d = openDb(paramStr(2), key = k)
  d.execScript("CREATE TABLE IF NOT EXISTS w(id INTEGER PRIMARY KEY, body TEXT)")
  var i = 0
  while true:
    inc i
    d.transaction:
      for j in 0 ..< 20:
        d.exec("INSERT INTO w(body) VALUES(?)", marker & " " & $i & " " & repeat("x", 300 + (i * 37) mod 900))
    echo i
    flushFile(stdout)
  quit 0

createDir(dir)

proc holds(path, word: string): bool =
  fileExists(path) and word in readFile(path)

block basics:
  echo "a new encrypted database"
  let key = newKey()
  let p = dir / "a.db"
  var d = openDb(p, key = key)
  d.execScript("""CREATE TABLE notes(id INTEGER PRIMARY KEY, title TEXT, body TEXT, pic BLOB);
    CREATE VIRTUAL TABLE notes_fts USING fts5(title, body)""")
  d.transaction:
    for i in 1 .. 3000:
      let body = marker & " note " & $i & " " & repeat("مرحبا ", i mod 40)
      d.exec("INSERT INTO notes(title, body, pic) VALUES(?, ?, ?)", "title " & $i, body,
             blob(repeat("\x01\x02" & marker, (i mod 7) * 900)))
      d.exec("INSERT INTO notes_fts(rowid, title, body) VALUES(?, ?, ?)", i, "title " & $i, body)
  check d.value("SELECT count(*) FROM notes").num == 3000, "3000 rows written"
  check d.value("SELECT count(*) FROM notes_fts WHERE notes_fts MATCH 'مرحبا'").num > 2000, "searched (FTS5)"
  check not holds(p, marker) and not holds(p & "-wal", marker), "none of it readable in the file or its WAL"
  d.close()
  check not holds(p, marker) and not holds(p, "SQLite format 3"), "nor after closing (not even SQLite's header)"
  d = openDb(p, key = key)
  check d.value("SELECT count(*) FROM notes").num == 3000 and
        d.value("SELECT length(pic) FROM notes WHERE id = 6").num == 6 * 900 * 17,
        "opened again with its key: every row, the big ones too"
  check d.one("PRAGMA integrity_check")[0].str == "ok", "SQLite finds nothing wrong"
  d.exec("DELETE FROM notes WHERE id % 2 = 0")
  d.execScript("VACUUM")
  check d.value("SELECT count(*) FROM notes").num == 1500 and d.one("PRAGMA integrity_check")[0].str == "ok",
        "VACUUM"
  # a second connection, at the same time
  let d2 = openDb(p, key = key)
  d.exec("INSERT INTO notes(title, body) VALUES('new', ?)", marker)
  check d2.value("SELECT count(*) FROM notes").num == 1501, "a second connection sees the first's rows"
  d2.close()
  d.close()
  var wrong = ""
  try: discard openDb(p, key = newKey()).value("SELECT count(*) FROM notes")
  except DbError as e: wrong = e.msg
  check wrong.len > 0, "a wrong key does not open it (" & wrong.split(':')[0] & ")"
  var none = ""
  try: discard openDb(p).value("SELECT count(*) FROM notes")
  except DbError as e: none = e.msg
  check none.len > 0, "nor no key"
  # a byte changed on disk
  var bytes = readFile(p)
  let at = bytes.len div 2 + 100
  bytes[at] = char(ord(bytes[at]) xor 1)
  writeFile(p, bytes)
  var damaged = 0
  try:
    let d3 = openDb(p, key = key)
    for r in d3.rows("SELECT body, pic FROM notes"): discard r
    d3.close()
  except DbError as e: damaged = e.code
  check damaged == 8202, "a byte changed on disk is found (SQLITE_IOERR_DATA: " & $damaged & ")"

block journal:
  echo "a rollback journal instead of the WAL (encrypted too)"
  let key = newKey()
  let p = dir / "j.db"
  var d = openDb(p, key = key)
  d.execScript("PRAGMA journal_mode=DELETE; CREATE TABLE j(x TEXT)")
  d.transaction:
    for i in 1 .. 500: d.exec("INSERT INTO j VALUES(?)", marker & repeat("j", 500))
  var rolled = false
  try:
    d.transaction:
      d.exec("UPDATE j SET x = 'changed'")
      raise newException(ValueError, "undo")
  except ValueError: rolled = true
  check rolled and d.value("SELECT count(*) FROM j WHERE x = 'changed'").num == 0, "a transaction rolled back"
  check d.one("PRAGMA integrity_check")[0].str == "ok" and not holds(p, marker), "nothing wrong, nothing readable"
  d.close()

block migrate:
  echo "an unencrypted database made encrypted"
  let p = dir / "plain.db"
  var d = openDb(p)
  d.execScript("CREATE TABLE m(id INTEGER PRIMARY KEY, body TEXT); CREATE VIRTUAL TABLE mf USING fts5(body)")
  d.transaction:
    for i in 1 .. 2000:
      d.exec("INSERT INTO m(body) VALUES(?)", marker & " " & $i)
      d.exec("INSERT INTO mf(rowid, body) VALUES(?, ?)", i, marker & " " & $i)
  d.close()
  check holds(p, marker) or holds(p & "-wal", marker), "it is readable before"
  let key = newKey()
  var refused = false
  try: discard openDb(p, key = key)
  except DbError: refused = true
  check refused, "opening it with a key is refused (it is not encrypted yet)"
  let t0 = epochTime()
  encryptDb(p, key)
  check isPlainDb(p) == false and not holds(p, marker) and not fileExists(p & ".plain") and
        not fileExists(p & ".sealing"), "encrypted, nothing left behind (" & $int((epochTime() - t0) * 1000) & " ms)"
  d = openDb(p, key = key)
  check d.value("SELECT count(*) FROM m").num == 2000 and
        d.value("SELECT count(*) FROM mf WHERE mf MATCH ?", marker).num == 2000, "every row and the index"
  d.exec("INSERT INTO m(body) VALUES('after')")
  d.close()
  encryptDb(p, key)
  check openDb(p, key = key).value("SELECT count(*) FROM m").num == 2001, "a second encryptDb does nothing"
  decryptDb(p, key)
  check isPlainDb(p) and openDb(p).value("SELECT count(*) FROM m").num == 2001, "and back (decryptDb)"
  encryptDb(p, key)
  check not isPlainDb(p) and openDb(p, key = key).value("SELECT count(*) FROM m").num == 2001, "and again"
  # a crash between its two renames
  let q = dir / "half.db"
  var dq = openDb(q)
  dq.execScript("CREATE TABLE h(x); INSERT INTO h VALUES(1)")
  dq.close()
  let kq = newKey()
  encryptDb(q, kq)
  moveFile(q, q & ".sealing")
  writeFile(q & ".plain", "SQLite format 3\0 pretend old file")
  encryptDb(q, kq)
  check fileExists(q) and not fileExists(q & ".sealing") and not fileExists(q & ".plain") and
        openDb(q, key = kq).value("SELECT x FROM h").num == 1, "a crash between its renames: put right"

block crash:
  echo "a writer killed part way (kill -9), five times"
  let p = dir / "crash.db"
  let key = newKey()
  writeFile(dir / "key", key)
  var lastDone = 0
  for round in 1 .. 5:
    let w = startProcess(getAppFilename(), args = ["--writer", p, dir / "key"], options = {})
    let outp = w.outputStream
    let until = epochTime() + 0.4 + 0.15 * float(round)
    var done = 0
    while epochTime() < until:
      let line = outp.readLine
      done = try: parseInt(line.strip) except ValueError: done
    w.kill()
    discard w.waitForExit()
    w.close()
    let d = openDb(p, key = key)
    let ok = d.one("PRAGMA integrity_check")[0].str == "ok"
    let rows = d.value("SELECT count(*) FROM w").num
    d.close()
    check ok and rows >= int64(lastDone + done) * 20, "round " & $round & ": opens, nothing wrong, " &
          $rows & " rows (at least the " & $((lastDone + done) * 20) & " committed)"
    lastDone = int(rows div 20)
  check not holds(p, marker) and not holds(p & "-wal", marker), "and none of it readable"

block speed:
  echo "speed"
  let key = newKey()
  for (name, k) in [("plain", ""), ("encrypted", key)]:
    let p = dir / ("speed-" & name & ".db")
    let d = openDb(p, key = k)
    d.execScript("CREATE TABLE s(id INTEGER PRIMARY KEY, a TEXT, b TEXT)")
    let t0 = epochTime()
    d.transaction:
      for i in 1 .. 20000:
        d.exec("INSERT INTO s(a, b) VALUES(?, ?)", "subject " & $i, repeat("body text ", 30))
    let t1 = epochTime()
    var n = 0
    for r in d.rows("SELECT a, b FROM s"): inc n
    let t2 = epochTime()
    d.close()
    echo "  ", name, ": 20000 rows written in ", int((t1 - t0) * 1000), " ms, read in ", int((t2 - t1) * 1000), " ms"

removeDir(dir)
if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_dbcrypt: all passed"

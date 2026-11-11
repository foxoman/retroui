## A local SQL database: SQLite, compiled in (nothing to install), with
## FTS5 full-text search -- where an app keeps its records and finds them
## again at once, offline.
##
## .. code-block:: nim
##   let db = openDb(dataDir("Notes") / "notes.db")
##   db.execScript """
##     CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, title TEXT, body TEXT);
##     CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(title, body,
##       content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2');
##     CREATE TRIGGER IF NOT EXISTS notes_ai AFTER INSERT ON notes BEGIN
##       INSERT INTO notes_fts(rowid, title, body)
##         VALUES (new.id, fts_text(new.title), fts_text(new.body));
##     END;"""
##   db.transaction:
##     db.exec("INSERT INTO notes(title, body) VALUES(?, ?)", "فاتورة الكهرباء", "March")
##   for r in db.rows("""SELECT n.id, n.title FROM notes_fts JOIN notes n ON n.id = notes_fts.rowid
##                       WHERE notes_fts MATCH ? ORDER BY rank""", ftsQuery("فاتوره", fold = true)):
##     echo r[0].num, " ", r[1].str
##
## Searching: `ftsQuery` makes what someone typed a MATCH expression. With
## the indexed text put through `fts_text()` (in SQL; `ftsText` in Nim) and
## `ftsQuery(typed, fold = true)`, Arabic words are found as people type
## them (with or without vowel marks, hamza, ة or ى).
##
## A `Db` is one connection: use it from one thread (open another one for
## another thread; in WAL mode readers and the writer do not wait for each
## other). Statements are prepared once and kept (the last 64, by their
## text). Every error raises `DbError` with SQLite's message and the SQL.

import std/[os, strutils, tables]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)

const
  sqliteFlags = "-O2 -DSQLITE_ENABLE_FTS5 -DSQLITE_THREADSAFE=1 " &
    "-DSQLITE_DEFAULT_MEMSTATUS=0 -DSQLITE_DQS=0 -DSQLITE_OMIT_LOAD_EXTENSION " &
    "-DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_SHARED_CACHE " &
    "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1" &
    # (Android has no /tmp: SQLite's temporary tables stay in memory, as in
    # Android's own build of it)
    (when defined(android): " -DSQLITE_TEMP_STORE=3" else: "")

# (-O2 always: in a debug build the C would otherwise be compiled without
# optimization, and SQLite would be several times slower)
{.compile("vendor/sqlite/sqlite3.c", sqliteFlags).}

type
  CDbObj {.incompleteStruct.} = object
  CDb = ptr CDbObj
  CStmtObj {.incompleteStruct.} = object
  CStmt = ptr CStmtObj
  CDestructor = proc (p: pointer) {.cdecl.}

const
  SQLITE_OK = 0
  SQLITE_ROW = 100
  SQLITE_DONE = 101
  SQLITE_OPEN_READONLY = 0x00000001
  SQLITE_OPEN_READWRITE = 0x00000002
  SQLITE_OPEN_CREATE = 0x00000004
  SQLITE_OPEN_NOMUTEX = 0x00008000
  SQLITE_OPEN_EXRESCODE = 0x02000000
  SQLITE_PREPARE_PERSISTENT = 0x01'u32
  SQLITE_UTF8 = 1'u8

proc sqlite3_open_v2(filename: cstring; db: var CDb; flags: cint; vfs: cstring): cint {.importc, cdecl.}
proc sqlite3_close_v2(db: CDb): cint {.importc, cdecl.}
proc sqlite3_errmsg(db: CDb): cstring {.importc, cdecl.}
proc sqlite3_errstr(code: cint): cstring {.importc, cdecl.}
proc sqlite3_extended_errcode(db: CDb): cint {.importc, cdecl.}
proc sqlite3_busy_timeout(db: CDb; ms: cint): cint {.importc, cdecl.}
proc sqlite3_exec(db: CDb; sql: cstring; cb: pointer; arg: pointer; err: var cstring): cint {.importc, cdecl.}
proc sqlite3_free(p: pointer) {.importc, cdecl.}
proc sqlite3_prepare_v3(db: CDb; sql: cstring; nByte: cint; flags: uint32; stmt: var CStmt;
                        tail: var cstring): cint {.importc, cdecl.}
proc sqlite3_step(s: CStmt): cint {.importc, cdecl.}
proc sqlite3_reset(s: CStmt): cint {.importc, cdecl.}
proc sqlite3_clear_bindings(s: CStmt): cint {.importc, cdecl.}
proc sqlite3_finalize(s: CStmt): cint {.importc, cdecl.}
proc sqlite3_bind_parameter_count(s: CStmt): cint {.importc, cdecl.}
proc sqlite3_bind_int64(s: CStmt; i: cint; v: int64): cint {.importc, cdecl.}
proc sqlite3_bind_double(s: CStmt; i: cint; v: cdouble): cint {.importc, cdecl.}
proc sqlite3_bind_null(s: CStmt; i: cint): cint {.importc, cdecl.}
proc sqlite3_bind_text64(s: CStmt; i: cint; p: cstring; n: uint64; d: CDestructor;
                         enc: uint8): cint {.importc, cdecl.}
proc sqlite3_bind_blob64(s: CStmt; i: cint; p: pointer; n: uint64; d: CDestructor): cint {.importc, cdecl.}
proc sqlite3_bind_zeroblob(s: CStmt; i: cint; n: cint): cint {.importc, cdecl.}
proc sqlite3_column_count(s: CStmt): cint {.importc, cdecl.}
proc sqlite3_column_type(s: CStmt; i: cint): cint {.importc, cdecl.}
proc sqlite3_column_int64(s: CStmt; i: cint): int64 {.importc, cdecl.}
proc sqlite3_column_double(s: CStmt; i: cint): cdouble {.importc, cdecl.}
proc sqlite3_column_text(s: CStmt; i: cint): pointer {.importc, cdecl.}
proc sqlite3_column_blob(s: CStmt; i: cint): pointer {.importc, cdecl.}
proc sqlite3_column_bytes(s: CStmt; i: cint): cint {.importc, cdecl.}
proc sqlite3_column_name(s: CStmt; i: cint): cstring {.importc, cdecl.}
proc sqlite3_last_insert_rowid(db: CDb): int64 {.importc, cdecl.}
proc sqlite3_changes64(db: CDb): int64 {.importc, cdecl.}
proc sqlite3_get_autocommit(db: CDb): cint {.importc, cdecl.}
proc sqlite3_libversion(): cstring {.importc, cdecl.}
proc sqlite3_create_function_v2(db: CDb; name: cstring; nArg, flags: cint; app: pointer;
                                fn: proc (ctx: pointer; n: cint; args: ptr UncheckedArray[pointer]) {.cdecl.};
                                step, final, destroy: pointer): cint {.importc, cdecl.}
proc sqlite3_value_type(v: pointer): cint {.importc, cdecl.}
proc sqlite3_value_text(v: pointer): pointer {.importc, cdecl.}
proc sqlite3_value_bytes(v: pointer): cint {.importc, cdecl.}
proc sqlite3_result_value(ctx: pointer; v: pointer) {.importc, cdecl.}
proc sqlite3_result_text64(ctx: pointer; p: cstring; n: uint64; d: CDestructor; enc: uint8) {.importc, cdecl.}

template transient(): CDestructor = cast[CDestructor](-1)   # SQLITE_TRANSIENT: SQLite copies the value

# ---- values ---------------------------------------------------------------------------------

type
  DbError* = object of CatchableError
    ## What went wrong, with SQLite's message and the SQL.
    code*: int               ## SQLite's (extended) result code, e.g. 2067 for a UNIQUE clash
  DbKind* = enum
    ## The kind of a value: SQLite's five.
    dkNull, dkInt, dkFloat, dkText, dkBlob
  DbValue* = object
    ## One value: a parameter or a column of a row.
    case kind*: DbKind       ## which of the fields below holds the value
    of dkInt: i*: int64      ## an integer
    of dkFloat: f*: float    ## a real number
    of dkText, dkBlob: s*: string  ## text (UTF-8) or a blob's bytes
    of dkNull: discard
  DbRow* = seq[DbValue]
    ## A row's columns, in the order of the SELECT.

proc toDbValue*(x: DbValue): DbValue {.inline.} =
  ## A value as it is (so a `DbValue` can be a parameter too).
  x
proc toDbValue*(x: SomeInteger): DbValue {.inline.} =
  ## An integer.
  DbValue(kind: dkInt, i: int64(x))
proc toDbValue*(x: SomeFloat): DbValue {.inline.} =
  ## A real number.
  DbValue(kind: dkFloat, f: float(x))
proc toDbValue*(x: string): DbValue {.inline.} =
  ## Text (UTF-8).
  DbValue(kind: dkText, s: x)
proc toDbValue*(x: bool): DbValue {.inline.} =
  ## 1 or 0.
  DbValue(kind: dkInt, i: int64(ord(x)))

proc dbNull*(): DbValue {.inline.} =
  ## NULL.
  DbValue(kind: dkNull)

proc blob*(s: string): DbValue {.inline.} =
  ## Bytes as a BLOB (kept as they are, never read as text).
  DbValue(kind: dkBlob, s: s)

proc blob*(b: openArray[byte]): DbValue =
  ## Bytes as a BLOB.
  result = DbValue(kind: dkBlob, s: newString(b.len))
  if b.len > 0: copyMem(addr result.s[0], unsafeAddr b[0], b.len)

proc isNull*(v: DbValue): bool {.inline.} =
  ## The value is NULL.
  v.kind == dkNull

proc str*(v: DbValue): string =
  ## Text and blobs as they are, numbers as text, NULL as "".
  case v.kind
  of dkText, dkBlob: v.s
  of dkInt: $v.i
  of dkFloat: $v.f
  of dkNull: ""

proc parseNum(s: string): float =
  ## (NaN when `s` is not a number)
  let t = s.strip
  if t.len == 0: return NaN
  try: result = parseFloat(t)
  except ValueError: result = NaN

proc num*(v: DbValue): int64 =
  ## Integers as they are, reals truncated, numeric text read, anything
  ## else 0.
  case v.kind
  of dkInt: v.i
  of dkFloat, dkText:
    var f: float
    if v.kind == dkText:
      try: return parseBiggestInt(v.s.strip)
      except ValueError: f = parseNum(v.s)
    else: f = v.f
    if f != f: 0'i64                                    # NaN
    elif f >= 9.2233720368547758e18: high(int64)
    elif f <= -9.2233720368547758e18: low(int64)
    else: int64(f)
  else: 0

proc flt*(v: DbValue): float =
  ## Reals and integers as a float, numeric text read, anything else 0.
  case v.kind
  of dkFloat: v.f
  of dkInt: float(v.i)
  of dkText:
    let f = parseNum(v.s)
    if f != f: 0.0 else: f
  else: 0.0

proc `$`*(v: DbValue): string =
  ## For a log: NULL, numbers, text quoted, blobs by size.
  case v.kind
  of dkNull: "NULL"
  of dkInt: $v.i
  of dkFloat: $v.f
  of dkText: escape(v.s)
  of dkBlob: "blob(" & $v.s.len & " bytes)"

proc `==`*(a, b: DbValue): bool =
  ## Same kind and same value.
  if a.kind != b.kind: return false
  case a.kind
  of dkNull: true
  of dkInt: a.i == b.i
  of dkFloat: a.f == b.f
  of dkText, dkBlob: a.s == b.s

# ---- text for the search index -------------------------------------------------------------

proc foldRune(c: int): int {.inline.} =
  ## -1: removed; else the code point it becomes.
  case c
  of 0x064B .. 0x065F, 0x0670, 0x0640, 0x06D6 .. 0x06DC, 0x06DF .. 0x06E8, 0x06EA .. 0x06ED,
     0x061C, 0x00AD, 0x200C .. 0x200F, 0x202A .. 0x202E, 0x2060, 0x2066 .. 0x2069, 0xFEFF: -1
  of 0x200B: 0x20                                # (a zero-width space still parts two words)
  of 0x0622, 0x0623, 0x0625, 0x0671: 0x0627      # أ إ آ ٱ: ا
  of 0x0629: 0x0647                              # ة: ه
  of 0x0649, 0x06CC: 0x064A                      # ى and the Persian ی: ي
  of 0x06A9: 0x0643                              # the Persian ک: ك
  else: c

proc ftsText*(s: string): string =
  ## Text made ready for the full-text index, so Arabic is found the way
  ## people type it: short vowels and the other marks (tashkeel), tatweel
  ## and invisible direction marks removed, أ إ آ made ا, ة made ه and ى
  ## made ي. Anything else is left as it is (the unicode61 tokenizer's
  ## remove_diacritics takes the accents off Latin letters). In SQL --
  ## triggers that fill an FTS table -- it is `fts_text(x)`.
  var maybe = false
  for ch in s:
    if ch in {'\xC2', '\xD8', '\xD9', '\xDA', '\xDB', '\xE2', '\xEF'}:
      maybe = true
      break
  if not maybe: return s
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    let b = ord(s[i])
    var cp = -1
    var n = 1
    if b in 0xC2 .. 0xDF and i + 1 < s.len and (ord(s[i+1]) and 0xC0) == 0x80:
      cp = ((b and 0x1F) shl 6) or (ord(s[i+1]) and 0x3F)
      n = 2
    elif b in 0xE0 .. 0xEF and i + 2 < s.len and (ord(s[i+1]) and 0xC0) == 0x80 and
         (ord(s[i+2]) and 0xC0) == 0x80:
      cp = ((b and 0x0F) shl 12) or ((ord(s[i+1]) and 0x3F) shl 6) or (ord(s[i+2]) and 0x3F)
      n = 3
    if cp < 0:
      result.add s[i]
    else:
      let f = foldRune(cp)
      if f == cp: result.add s[i ..< i + n]
      elif f >= 0: result.add Rune(f).toUTF8
    i += n

proc ftsTextSql(ctx: pointer; n: cint; args: ptr UncheckedArray[pointer]) {.cdecl.} =
  let v = args[0]
  if sqlite3_value_type(v) != 3:                 # (not text: as it is)
    sqlite3_result_value(ctx, v)
    return
  let p = sqlite3_value_text(v)
  var s = newString(int(sqlite3_value_bytes(v)))
  if s.len > 0 and p != nil: copyMem(addr s[0], p, s.len)
  let t = ftsText(s)
  sqlite3_result_text64(ctx, (if t.len > 0: t.cstring else: cstring""), uint64(t.len),
                        transient(), SQLITE_UTF8)

const SQLITE_UTF8_FN = 1 or 0x800 or 0x200000    # UTF-8, deterministic, innocuous

# ---- the connection -------------------------------------------------------------------------

type
  CachedObj = object
    stmt: CStmt
    tick: int
    busy: bool               ## in use (a `rows` loop): a second use prepares its own
  Cached = ref CachedObj
  Conn = object
    p: CDb
  Db* = ref object
    ## One connection: use it from one thread; open another for another
    ## thread.
    c: Conn
    cache: Table[string, Cached]
    path: string
    tick: int
    txDepth: int

const MaxCached = 64

# (a kept statement is finalized when it is dropped; the connection is
# closed with sqlite3_close_v2, which waits for the last one. Only ours:
# FTS5 keeps statements of its own on the connection.)
when defined(gcDestructors):
  proc `=destroy`(x: CachedObj) =
    if x.stmt != nil: discard sqlite3_finalize(x.stmt)
else:      # (--mm:refc, an editor's check among them: its hooks take `var`)
  proc `=destroy`(x: var CachedObj) =
    if x.stmt != nil: discard sqlite3_finalize(x.stmt)
proc `=copy`(a: var CachedObj; b: CachedObj) {.error.}
when defined(gcDestructors):
  proc `=destroy`(c: Conn) =
    if c.p != nil: discard sqlite3_close_v2(c.p)
else:
  proc `=destroy`(c: var Conn) =
    if c.p != nil: discard sqlite3_close_v2(c.p)
proc `=copy`(a: var Conn; b: Conn) {.error.}

proc shortSql(sql: string): string =
  for w in strutils.splitWhitespace(sql):
    if result.len > 0: result.add ' '
    result.add w
    if result.len > 300:
      result.setLen(300)
      result.add "..."
      break

proc fail(msg: string; code: int; sql: string) {.noreturn.} =
  var e = newException(DbError, if sql.len > 0: msg & " (in: " & shortSql(sql) & ")" else: msg)
  e.code = code
  raise e

proc fail(db: Db; sql: string) {.noreturn.} =
  fail($sqlite3_errmsg(db.c.p), int(sqlite3_extended_errcode(db.c.p)), sql)

proc checkOpen(db: Db; sql: string) {.inline.} =
  if db.isNil or db.c.p == nil: fail("the database is closed", 21, sql)

proc sqliteVersion*(): string =
  ## The version of the SQLite compiled in, e.g. "3.54.1".
  $sqlite3_libversion()

proc execScript*(db: Db; sql: string) =
  ## Runs `sql`, which may hold many statements separated by ";" (a schema,
  ## a migration). No parameters; nothing is returned.
  db.checkOpen(sql)
  var err: cstring
  let rc = sqlite3_exec(db.c.p, sql.cstring, nil, nil, err)
  if rc != SQLITE_OK:
    let msg = if err != nil: $err else: $sqlite3_errstr(rc)
    if err != nil: sqlite3_free(err)
    fail(msg, int(sqlite3_extended_errcode(db.c.p)), sql)

proc openDb*(path: string; readOnly = false): Db =
  ## Opens (or makes) the database file at `path`, making its folder too:
  ## WAL journal, foreign keys on, synchronous NORMAL, and waiting up to 5 s
  ## when another connection is writing. ":memory:" is a database in memory.
  let mem = path.len == 0 or path == ":memory:"
  if not mem and not readOnly:
    let dir = path.parentDir
    if dir.len > 0:
      try: createDir(dir)
      except OSError as e: fail("cannot make the folder " & dir & ": " & e.msg, 14, "")
  result = Db(path: path)
  let flags = (if readOnly: SQLITE_OPEN_READONLY else: SQLITE_OPEN_READWRITE or SQLITE_OPEN_CREATE) or
              SQLITE_OPEN_NOMUTEX or SQLITE_OPEN_EXRESCODE
  var p: CDb
  let rc = sqlite3_open_v2(path.cstring, p, cint(flags), nil)
  result.c.p = p
  if rc != SQLITE_OK:
    let msg = if p != nil: $sqlite3_errmsg(p) else: $sqlite3_errstr(rc)
    fail(msg & ": " & path, int(rc), "")
  discard sqlite3_busy_timeout(p, 5000)
  discard sqlite3_create_function_v2(p, "fts_text", 1, SQLITE_UTF8_FN, nil, ftsTextSql, nil, nil, nil)
  if not readOnly and not mem:
    result.execScript("PRAGMA journal_mode=WAL")
  result.execScript("PRAGMA foreign_keys=ON; PRAGMA synchronous=NORMAL")

proc close*(db: Db) =
  ## Closes the connection (its statements are finalized). Closing twice
  ## does nothing; using it after raises `DbError`.
  if db.isNil or db.c.p == nil: return
  db.cache.clear()           # (one a `rows` loop still uses goes when the loop ends)
  let p = db.c.p
  db.c.p = nil
  discard sqlite3_close_v2(p)

proc isOpen*(db: Db): bool =
  ## The connection is open.
  not db.isNil and db.c.p != nil

proc path*(db: Db): string =
  ## The file the connection was opened on.
  db.path

proc prepare(db: Db; sql: string; persistent: bool): CStmt =
  var tail: cstring
  let rc = sqlite3_prepare_v3(db.c.p, sql.cstring, cint(sql.len),
                              (if persistent: SQLITE_PREPARE_PERSISTENT else: 0'u32),
                              result, tail)
  if rc != SQLITE_OK: db.fail(sql)
  # one statement only: what follows may be spaces, ";" or comments
  if tail != nil and tail[0] != '\0':
    var more: CStmt
    var tail2: cstring
    let rest = $tail
    if rest.strip(chars = Whitespace + {';'}).len > 0:
      let rc2 = sqlite3_prepare_v3(db.c.p, rest.cstring, cint(rest.len), 0, more, tail2)
      if more != nil: discard sqlite3_finalize(more)
      if rc2 != SQLITE_OK or more != nil:
        if result != nil: discard sqlite3_finalize(result)
        fail("one statement at a time here (execScript runs many)", 1, sql)

proc acquire(db: Db; sql: string): (CStmt, Cached) =
  db.checkOpen(sql)
  inc db.tick
  var c = db.cache.getOrDefault(sql)
  if c != nil and not c.busy:
    c.busy = true
    c.tick = db.tick
    return (c.stmt, c)
  let s = db.prepare(sql, persistent = c == nil)
  if c != nil or s == nil: return (s, nil)       # (in use already, or nothing to run)
  if db.cache.len >= MaxCached:
    var oldest = ""
    var t = high(int)
    for k, v in db.cache:
      if not v.busy and v.tick < t: (oldest = k; t = v.tick)
    if t == high(int): return (s, nil)            # (all in use: not kept)
    db.cache.del oldest
  c = Cached(stmt: s, tick: db.tick, busy: true)
  db.cache[sql] = c
  (s, c)

proc release(db: Db; s: CStmt; c: Cached) =
  if s == nil: return
  if db.c.p == nil:                               # (closed meanwhile)
    if c == nil: discard sqlite3_finalize(s)
    return
  discard sqlite3_reset(s)
  discard sqlite3_clear_bindings(s)               # (frees the copies of big values)
  if c == nil: discard sqlite3_finalize(s)
  else: c.busy = false

proc bindAll(db: Db; s: CStmt; sql: string; args: openArray[DbValue]) =
  let n = int(sqlite3_bind_parameter_count(s))
  if n != args.len:
    fail("the statement has " & $n & " parameters, " & $args.len & " values were given", 25, sql)
  for k, a in args:
    let i = cint(k + 1)
    let rc = case a.kind
      of dkNull: sqlite3_bind_null(s, i)
      of dkInt: sqlite3_bind_int64(s, i, a.i)
      of dkFloat: sqlite3_bind_double(s, i, a.f)
      of dkText:
        # (an empty string needs a pointer, or it would be NULL)
        sqlite3_bind_text64(s, i, (if a.s.len > 0: a.s.cstring else: cstring""),
                            uint64(a.s.len), transient(), SQLITE_UTF8)
      of dkBlob:
        if a.s.len == 0: sqlite3_bind_zeroblob(s, i, 0)
        else: sqlite3_bind_blob64(s, i, unsafeAddr a.s[0], uint64(a.s.len), transient())
    if rc != SQLITE_OK: db.fail(sql)

proc readRow(s: CStmt): DbRow =
  let n = int(sqlite3_column_count(s))
  result = newSeq[DbValue](n)
  for k in 0 ..< n:
    let i = cint(k)
    case sqlite3_column_type(s, i)
    of 1: result[k] = DbValue(kind: dkInt, i: sqlite3_column_int64(s, i))
    of 2: result[k] = DbValue(kind: dkFloat, f: float(sqlite3_column_double(s, i)))
    of 3, 4:
      let isText = sqlite3_column_type(s, i) == 3
      let p = if isText: sqlite3_column_text(s, i) else: sqlite3_column_blob(s, i)
      let len = int(sqlite3_column_bytes(s, i))
      var str = newString(len)
      if len > 0 and p != nil: copyMem(addr str[0], p, len)
      result[k] = if isText: DbValue(kind: dkText, s: move str) else: DbValue(kind: dkBlob, s: move str)
    else: result[k] = DbValue(kind: dkNull)

proc exec*(db: Db; sql: string; args: varargs[DbValue, toDbValue]) =
  ## Runs one statement with its `?` parameters: `db.exec("UPDATE t SET
  ## a = ? WHERE id = ?", "x", 7)`. (Statements are prepared once, then
  ## kept by their text.)
  let (s, c) = db.acquire(sql)
  if s == nil: return
  try:
    db.bindAll(s, sql, args)
    while true:
      let rc = sqlite3_step(s)
      if rc == SQLITE_DONE: break
      if rc != SQLITE_ROW: db.fail(sql)
  finally:
    db.release(s, c)

iterator rows*(db: Db; sql: string; args: varargs[DbValue, toDbValue]): DbRow =
  ## The rows of a query, one at a time. Leaving the loop early (`break`,
  ## `return`, an exception) is fine.
  let (s, c) = db.acquire(sql)
  if s != nil:
    try:
      db.bindAll(s, sql, args)
      while true:
        let rc = sqlite3_step(s)
        if rc == SQLITE_ROW: yield readRow(s)
        elif rc == SQLITE_DONE: break
        else: db.fail(sql)
    finally:
      db.release(s, c)

proc all*(db: Db; sql: string; args: varargs[DbValue, toDbValue]): seq[DbRow] =
  ## All the rows of a query.
  for r in db.rows(sql, args): result.add r

proc one*(db: Db; sql: string; args: varargs[DbValue, toDbValue]): DbRow =
  ## The first row of a query; `@[]` when there is none.
  for r in db.rows(sql, args): return r

proc value*(db: Db; sql: string; args: varargs[DbValue, toDbValue]): DbValue =
  ## The first column of the first row (`SELECT count(*) ...`); NULL when
  ## there is no row.
  for r in db.rows(sql, args):
    return (if r.len > 0: r[0] else: dbNull())
  dbNull()

proc columns*(db: Db; sql: string): seq[string] =
  ## The names of the columns a query gives (it is not run).
  let (s, c) = db.acquire(sql)
  if s == nil: return
  try:
    for i in 0 ..< int(sqlite3_column_count(s)):
      result.add $sqlite3_column_name(s, cint(i))
  finally:
    db.release(s, c)

proc lastInsertId*(db: Db): int64 =
  ## The rowid of the last row inserted on this connection.
  db.checkOpen("")
  sqlite3_last_insert_rowid(db.c.p)

proc changes*(db: Db): int =
  ## How many rows the last INSERT, UPDATE or DELETE changed.
  db.checkOpen("")
  int(sqlite3_changes64(db.c.p))

proc inTransaction*(db: Db): bool =
  ## A transaction is open on this connection.
  db.isOpen and sqlite3_get_autocommit(db.c.p) == 0

proc userVersion*(db: Db): int =
  ## The schema version the app keeps in the file (PRAGMA user_version; 0
  ## in a new file): for migrations.
  int(db.value("PRAGMA user_version").num)

proc `userVersion=`*(db: Db; v: int) =
  ## Sets the schema version kept in the file.
  db.execScript("PRAGMA user_version=" & $v)

# ---- transactions ---------------------------------------------------------------------------

type TxMark = tuple[level: int, began: bool]

proc txBegin(db: Db): TxMark =
  db.checkOpen("BEGIN")
  result.level = db.txDepth + 1
  result.began = sqlite3_get_autocommit(db.c.p) != 0
  if result.began: db.exec("BEGIN IMMEDIATE")
  else: db.exec("SAVEPOINT retro_tx" & $result.level)
  db.txDepth = result.level

proc txRollback(db: Db; t: TxMark) =
  db.txDepth = t.level - 1
  if not db.isOpen: return
  try:
    if t.began:
      if sqlite3_get_autocommit(db.c.p) == 0: db.exec("ROLLBACK")
    elif sqlite3_get_autocommit(db.c.p) == 0:
      db.exec("ROLLBACK TO retro_tx" & $t.level)
      db.exec("RELEASE retro_tx" & $t.level)
  except DbError: discard          # (SQLite may have rolled back on its own)

proc txCommit(db: Db; t: TxMark) =
  try:
    db.exec(if t.began: "COMMIT" else: "RELEASE retro_tx" & $t.level)
    db.txDepth = t.level - 1
  except DbError:
    db.txRollback(t)
    raise

template transaction*(db: Db; body: untyped) =
  ## Runs `body` in a transaction: BEGIN IMMEDIATE ... COMMIT, or ROLLBACK
  ## when it raises (and the exception goes on). Inside another one it is
  ## a savepoint: only its own changes are undone.
  bind txBegin, txCommit, txRollback
  let txDb = db
  let txMark = txBegin(txDb)
  var txRaised = false
  try:
    body
  except CatchableError, Defect:
    txRaised = true
    txRollback(txDb, txMark)
    raise
  finally:
    if not txRaised: txCommit(txDb, txMark)

# ---- full-text search -----------------------------------------------------------------------

proc isWordRune(r: Rune): bool =
  ## Letters and digits: what FTS5's unicode61 tokenizer keeps in a word.
  let c = int(r)
  if c < 0x80: return chr(c) in {'a'..'z', 'A'..'Z', '0'..'9'}
  r.isAlpha or c in 0x0660..0x0669 or c in 0x06F0..0x06F9 or c in 0x0966..0x096F or
    c in 0xFF10..0xFF19 or c >= 0xE000 and c <= 0xF8FF

proc ftsQuery*(typed: string; fold = false): string =
  ## What someone typed in a search box, as a safe FTS5 MATCH expression:
  ## every word quoted (so AND, OR, NEAR, "-", "*" and quotes are plain
  ## text) and the last one a prefix, so "inv" finds "invoice". No input
  ## can give a syntax error; with nothing searchable typed it is `""`,
  ## which matches nothing. `fold`: the words go through `ftsText` -- for
  ## an index filled through `fts_text()`, where Arabic is found as typed.
  result = ""         # (a value at once: see tools/writecheck.py)
  var words: seq[string]
  for w in unicode.splitWhitespace(if fold: ftsText(typed) else: typed):
    var useful = false
    for r in w.runes:
      if r.isWordRune: (useful = true; break)
    if useful: words.add w
  for k, w in words:
    if k > 0: result.add ' '
    result.add '"'
    for r in w.runes:
      if r == Rune('"'): result.add "\"\""
      elif int(r) < 0x20: result.add ' '
      else: result.add r.toUTF8
    result.add '"'
    if k == words.high: result.add '*'
  if words.len == 0: result = "\"\""

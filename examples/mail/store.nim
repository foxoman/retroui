## Retro Mail's local store: accounts, folders, messages (with a full-text
## index for instant offline search), tags, contacts, calendar events, the
## queue of changes waiting for the server, signatures, notes and tasks.
## One SQLite file; the window and the sync thread each open their own
## connection to it (WAL lets them work at the same time).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, json, times, tables, algorithm, sequtils]
import retroui/db

type
  AccountKind* = enum
    akGraph = "graph"      ## Microsoft 365 / Outlook.com through Microsoft Graph
    akGmail = "gmail"      ## Gmail through the Gmail API
  Account* = object
    id*: int
    kind*: AccountKind
    email*, name*: string
    clientId*, tenant*: string
    syncDays*: int
    state*: string         ## "" fine, "signin" to sign in again, else the last error
    history*: string       ## Gmail's history id / Graph's (unused)
  Folder* = object
    id*, account*: int
    remoteId*, name*, role*, parent*: string
    unread*, total*: int
    delta*: string
  Msg* = object
    id*, account*, folder*: int
    remoteId*, thread*: string
    subject*, fromName*, fromEmail*, toList*, ccList*: string
    date*: float
    size*: int
    snippet*: string
    unread*, flagged*, important*, hasAtt*, focused*, pinned*, mine*, draft*: bool
    tags*: seq[string]
    snooze*: float
    msgId*, inReplyTo*, refs*, labels*: string
    bodyState*: int        ## 0 not fetched, 1 asked for, 2 here, 3 failed
    html*, text*: string
  Att* = object
    id*, message*: int
    remoteId*, name*, mime*, cid*: string
    size*: int
    inline*: bool
    hasData*: bool
  Tag* = object
    id*, account*: int
    name*, color*, remoteId*: string
  Attendee* = tuple[name, email, response: string]   ## response: "accepted", "declined"... ("" not known)
  Event* = object
    id*, account*: int
    remoteId*, title*, location*: string
    start*, finish*: float
    allDay*: bool
    organizer*: string         ## who invited the account ("Name <address>"); "" its own
    mine*: bool                ## the account organizes it (a change goes to everyone)
    attendees*: seq[Attendee]  ## who else is invited
    joinUrl*: string           ## its online meeting (Teams, Google Meet)
    notes*: string             ## its description, as text
    reminder*: int             ## minutes before it starts; -1 none
    series*: string            ## one event of a series: the series' id
    repeat*: string            ## the series': "daily", "weekly", "monthly", "yearly", "custom"
  Action* = object
    id*, account*: int
    kind*: string
    data*: JsonNode
    due*: float
    tries*: int

const schema = """
CREATE TABLE IF NOT EXISTS accounts(id INTEGER PRIMARY KEY, kind TEXT, email TEXT,
  name TEXT, client_id TEXT, tenant TEXT, sync_days INTEGER DEFAULT 90,
  state TEXT DEFAULT '', history TEXT DEFAULT '', added REAL DEFAULT 0);
CREATE TABLE IF NOT EXISTS folders(id INTEGER PRIMARY KEY, account INTEGER, remote_id TEXT,
  name TEXT, role TEXT DEFAULT '', parent TEXT DEFAULT '', unread INTEGER DEFAULT 0,
  total INTEGER DEFAULT 0, delta TEXT DEFAULT '', synced REAL DEFAULT 0,
  UNIQUE(account, remote_id));
CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY, account INTEGER, remote_id TEXT,
  folder INTEGER, thread TEXT, subject TEXT, from_name TEXT, from_email TEXT,
  to_list TEXT DEFAULT '', cc_list TEXT DEFAULT '', date REAL, size INTEGER DEFAULT 0,
  snippet TEXT DEFAULT '', unread INTEGER DEFAULT 0, flagged INTEGER DEFAULT 0,
  important INTEGER DEFAULT 0, has_att INTEGER DEFAULT 0, focused INTEGER DEFAULT 1,
  tags TEXT DEFAULT '', pinned INTEGER DEFAULT 0, snooze REAL DEFAULT 0,
  mine INTEGER DEFAULT 0, draft INTEGER DEFAULT 0, msgid TEXT DEFAULT '',
  in_reply_to TEXT DEFAULT '', refs TEXT DEFAULT '', labels TEXT DEFAULT '',
  body_state INTEGER DEFAULT 0, html TEXT, text TEXT,
  UNIQUE(account, remote_id));
CREATE INDEX IF NOT EXISTS m_folder ON messages(folder, date DESC);
CREATE INDEX IF NOT EXISTS m_thread ON messages(account, thread);
CREATE INDEX IF NOT EXISTS m_date ON messages(date DESC);
CREATE TABLE IF NOT EXISTS atts(id INTEGER PRIMARY KEY, message INTEGER, remote_id TEXT,
  name TEXT, mime TEXT, size INTEGER, cid TEXT DEFAULT '', inline INTEGER DEFAULT 0, data BLOB);
CREATE INDEX IF NOT EXISTS a_msg ON atts(message);
CREATE TABLE IF NOT EXISTS tags(id INTEGER PRIMARY KEY, account INTEGER, name TEXT,
  color TEXT DEFAULT '', remote_id TEXT DEFAULT '', UNIQUE(account, name));
CREATE TABLE IF NOT EXISTS contacts(email TEXT PRIMARY KEY, name TEXT DEFAULT '',
  uses INTEGER DEFAULT 0, last REAL DEFAULT 0, saved INTEGER DEFAULT 0, phone TEXT DEFAULT '',
  company TEXT DEFAULT '', notes TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS actions(id INTEGER PRIMARY KEY, account INTEGER, kind TEXT,
  data TEXT, due REAL DEFAULT 0, tries INTEGER DEFAULT 0, error TEXT DEFAULT '');
CREATE TABLE IF NOT EXISTS signatures(id INTEGER PRIMARY KEY, name TEXT, html TEXT);
CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY, account INTEGER, remote_id TEXT,
  title TEXT, start REAL, finish REAL, all_day INTEGER DEFAULT 0, location TEXT DEFAULT '',
  UNIQUE(account, remote_id));
CREATE TABLE IF NOT EXISTS tasks(id INTEGER PRIMARY KEY, title TEXT, done INTEGER DEFAULT 0,
  due REAL DEFAULT 0, message INTEGER DEFAULT 0, added REAL DEFAULT 0);
CREATE TABLE IF NOT EXISTS notes(id INTEGER PRIMARY KEY, title TEXT, body TEXT, updated REAL);
CREATE TABLE IF NOT EXISTS drafts(id INTEGER PRIMARY KEY, data TEXT, updated REAL);
CREATE VIRTUAL TABLE IF NOT EXISTS mfts USING fts5(subject, people, body,
  tokenize = 'unicode61 remove_diacritics 2');
"""

const msgCols* = "id, account, folder, remote_id, thread, subject, from_name, from_email, " &
  "to_list, cc_list, date, size, snippet, unread, flagged, important, has_att, focused, " &
  "tags, pinned, snooze, mine, draft, msgid, in_reply_to, refs, labels, body_state"

proc mailDir*(): string =
  ## Where Retro Mail keeps its files (RETRO_MAIL_HOME for tests).
  result = getEnv("RETRO_MAIL_HOME")
  if result.len == 0:
    when defined(android):
      result = getEnv("RETRO_DATA_DIR", getHomeDir() / ".retromail")
    elif defined(windows):
      result = getEnv("APPDATA", getHomeDir()) / "Retro Mail"
    else:
      result = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / "retro-mail"
  try: createDir(result) except OSError: discard

proc openStore*(path = ""): Db =
  ## The store (made on first use).
  let p = if path.len > 0: path else: mailDir() / "mail.db"
  result = openDb(p)
  result.execScript(schema)
  # (columns added since 1.0: a store made by an older version gets them)
  var cols: seq[string]
  for r in result.rows("PRAGMA table_info(messages)"): cols.add r[1].str
  if "follow" notin cols:
    result.exec("ALTER TABLE messages ADD COLUMN follow REAL DEFAULT 0")
  cols.setLen(0)
  for r in result.rows("PRAGMA table_info(events)"): cols.add r[1].str
  for (col, decl) in [("organizer", "TEXT DEFAULT ''"), ("mine", "INTEGER DEFAULT 1"),
                      ("attendees", "TEXT DEFAULT ''"), ("join_url", "TEXT DEFAULT ''"),
                      ("notes", "TEXT DEFAULT ''"), ("reminder", "INTEGER DEFAULT 15"),
                      ("series", "TEXT DEFAULT ''"), ("pattern", "TEXT DEFAULT ''")]:
    if col notin cols:
      result.exec("ALTER TABLE events ADD COLUMN " & col & " " & decl)

# ---- tags as stored: "\nA\nB\n" so a tag is found with instr ----------------------------

proc packTags*(tags: openArray[string]): string =
  if tags.len == 0: return ""
  result = "\n"
  for t in tags:
    if t.len > 0:
      result.add t.replace("\n", " ")
      result.add '\n'

proc unpackTags*(s: string): seq[string] =
  for t in s.split('\n'):
    if t.len > 0: result.add t

# ---- rows ------------------------------------------------------------------------------

proc toAccount(r: DbRow): Account =
  Account(id: int r[0].num, kind: (if r[1].str == "gmail": akGmail else: akGraph),
          email: r[2].str, name: r[3].str, clientId: r[4].str, tenant: r[5].str,
          syncDays: int r[6].num, state: r[7].str, history: r[8].str)

proc accounts*(db: Db): seq[Account] =
  for r in db.rows("SELECT id, kind, email, name, client_id, tenant, sync_days, state, history " &
                   "FROM accounts ORDER BY id"):
    result.add toAccount(r)

proc account*(db: Db; id: int): Account =
  let r = db.one("SELECT id, kind, email, name, client_id, tenant, sync_days, state, history " &
                 "FROM accounts WHERE id = ?", id)
  if r.len > 0: result = toAccount(r)

proc addAccount*(db: Db; kind: AccountKind; email, name, clientId, tenant: string;
                 syncDays = 90): int =
  ## A new account (or the same address again: updated), its id.
  let old = db.value("SELECT id FROM accounts WHERE email = ? AND kind = ?", email, $kind)
  if not old.isNull:
    db.exec("UPDATE accounts SET name = ?, client_id = ?, tenant = ?, state = '' WHERE id = ?",
            name, clientId, tenant, old.num)
    return int old.num
  db.exec("INSERT INTO accounts(kind, email, name, client_id, tenant, sync_days, added) " &
          "VALUES(?, ?, ?, ?, ?, ?, ?)", $kind, email, name, clientId, tenant, syncDays, epochTime())
  int db.lastInsertId

proc setAccountState*(db: Db; id: int; state: string) =
  db.exec("UPDATE accounts SET state = ? WHERE id = ?", state, id)

proc setHistory*(db: Db; id: int; h: string) =
  db.exec("UPDATE accounts SET history = ? WHERE id = ?", h, id)

proc removeAccount*(db: Db; id: int) =
  ## The account and everything kept for it.
  db.transaction:
    db.exec("DELETE FROM mfts WHERE rowid IN (SELECT id FROM messages WHERE account = ?)", id)
    db.exec("DELETE FROM atts WHERE message IN (SELECT id FROM messages WHERE account = ?)", id)
    db.exec("DELETE FROM messages WHERE account = ?", id)
    db.exec("DELETE FROM folders WHERE account = ?", id)
    db.exec("DELETE FROM tags WHERE account = ?", id)
    db.exec("DELETE FROM events WHERE account = ?", id)
    db.exec("DELETE FROM actions WHERE account = ?", id)
    db.exec("DELETE FROM accounts WHERE id = ?", id)

proc toFolder(r: DbRow): Folder =
  Folder(id: int r[0].num, account: int r[1].num, remoteId: r[2].str, name: r[3].str,
         role: r[4].str, parent: r[5].str, unread: int r[6].num, total: int r[7].num,
         delta: r[8].str)

const folderCols = "id, account, remote_id, name, role, parent, unread, total, delta"

const roleOrder = ["inbox", "drafts", "sent", "outbox", "scheduled", "archive", "junk", "trash"]

proc folders*(db: Db; account: int): seq[Folder] =
  ## The account's folders: the well-known ones first in Outlook's order,
  ## then the others by name.
  for r in db.rows("SELECT " & folderCols & " FROM folders WHERE account = ?", account):
    result.add toFolder(r)
  result.sort(proc (a, b: Folder): int =
    let ia = roleOrder.find(a.role)
    let ib = roleOrder.find(b.role)
    let ka = if ia < 0: 100 else: ia
    let kb = if ib < 0: 100 else: ib
    if ka != kb: cmp(ka, kb) else: cmp(a.name.toLowerAscii, b.name.toLowerAscii))

proc folder*(db: Db; id: int): Folder =
  let r = db.one("SELECT " & folderCols & " FROM folders WHERE id = ?", id)
  if r.len > 0: result = toFolder(r)

proc folderByRemote*(db: Db; account: int; remoteId: string): Folder =
  let r = db.one("SELECT " & folderCols & " FROM folders WHERE account = ? AND remote_id = ?",
                 account, remoteId)
  if r.len > 0: result = toFolder(r)

proc folderByRole*(db: Db; account: int; role: string): Folder =
  let r = db.one("SELECT " & folderCols & " FROM folders WHERE account = ? AND role = ?",
                 account, role)
  if r.len > 0: result = toFolder(r)

proc upsertFolder*(db: Db; account: int; remoteId, name, role, parent: string;
                   unread = -1; total = -1): int =
  let old = db.value("SELECT id FROM folders WHERE account = ? AND remote_id = ?", account, remoteId)
  if old.isNull:
    db.exec("INSERT INTO folders(account, remote_id, name, role, parent, unread, total) " &
            "VALUES(?, ?, ?, ?, ?, ?, ?)", account, remoteId, name, role, parent,
            max(unread, 0), max(total, 0))
    return int db.lastInsertId
  result = int old.num
  db.exec("UPDATE folders SET name = ?, role = CASE WHEN ? = '' THEN role ELSE ? END, " &
          "parent = ? WHERE id = ?", name, role, role, parent, result)
  if unread >= 0: db.exec("UPDATE folders SET unread = ?, total = ? WHERE id = ?",
                          unread, max(total, 0), result)

proc setFolderDelta*(db: Db; id: int; delta: string) =
  db.exec("UPDATE folders SET delta = ?, synced = ? WHERE id = ?", delta, epochTime(), id)

proc recount*(db: Db; account: int) =
  ## The unread and total counts of the account's folders, from the store.
  db.exec("UPDATE folders SET unread = (SELECT count(*) FROM messages m WHERE m.folder = " &
          "folders.id AND m.unread = 1), total = (SELECT count(*) FROM messages m " &
          "WHERE m.folder = folders.id) WHERE account = ?", account)

# ---- messages --------------------------------------------------------------------------

proc toMsg*(r: DbRow): Msg =
  Msg(id: int r[0].num, account: int r[1].num, folder: int r[2].num, remoteId: r[3].str,
      thread: r[4].str, subject: r[5].str, fromName: r[6].str, fromEmail: r[7].str,
      toList: r[8].str, ccList: r[9].str, date: r[10].flt, size: int r[11].num,
      snippet: r[12].str, unread: r[13].num != 0, flagged: r[14].num != 0,
      important: r[15].num != 0, hasAtt: r[16].num != 0, focused: r[17].num != 0,
      tags: unpackTags(r[18].str), pinned: r[19].num != 0, snooze: r[20].flt,
      mine: r[21].num != 0, draft: r[22].num != 0, msgId: r[23].str,
      inReplyTo: r[24].str, refs: r[25].str, labels: r[26].str, bodyState: int r[27].num)

proc message*(db: Db; id: int): Msg =
  let r = db.one("SELECT " & msgCols & ", html, text FROM messages WHERE id = ?", id)
  if r.len > 0:
    result = toMsg(r)
    result.html = r[28].str
    result.text = r[29].str

proc messageByRemote*(db: Db; account: int; remoteId: string): Msg =
  let r = db.one("SELECT " & msgCols & " FROM messages WHERE account = ? AND remote_id = ?",
                 account, remoteId)
  if r.len > 0: result = toMsg(r)

proc indexMessage*(db: Db; id: int) =
  ## (Re)writes the message's line in the search index.
  let r = db.one("SELECT subject, from_name, from_email, to_list, cc_list, snippet, text " &
                 "FROM messages WHERE id = ?", id)
  if r.len == 0: return
  let body = if r[6].str.len > 0: r[6].str else: r[5].str
  db.exec("DELETE FROM mfts WHERE rowid = ?", id)
  db.exec("INSERT INTO mfts(rowid, subject, people, body) VALUES(?, fts_text(?), fts_text(?), " &
          "fts_text(?))", id, r[0].str,
          r[1].str & " " & r[2].str & " " & r[3].str & " " & r[4].str, body)

proc upsertMessage*(db: Db; m: Msg): int =
  ## Stores what the server says about a message (keeping what only this
  ## app knows: pinned, snoozed, the body); its id.
  let old = db.one("SELECT id, body_state, unread, flagged, tags, folder FROM messages " &
                   "WHERE account = ? AND remote_id = ?", m.account, m.remoteId)
  if old.len == 0:
    db.exec("INSERT INTO messages(account, remote_id, folder, thread, subject, from_name, " &
            "from_email, to_list, cc_list, date, size, snippet, unread, flagged, important, " &
            "has_att, focused, tags, mine, draft, msgid, in_reply_to, refs, labels) " &
            "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            m.account, m.remoteId, m.folder, m.thread, m.subject, m.fromName, m.fromEmail,
            m.toList, m.ccList, m.date, m.size, m.snippet, m.unread, m.flagged, m.important,
            m.hasAtt, m.focused, packTags(m.tags), m.mine, m.draft, m.msgId, m.inReplyTo,
            m.refs, m.labels)
    result = int db.lastInsertId
  else:
    result = int old[0].num
    # a change made here that has not reached the server yet stays (the
    # server's answer may have been read before it went out)
    var m = m
    for r in db.rows("SELECT kind FROM actions WHERE error = '' AND " &
                     "json_extract(data, '$.id') = ?", result):
      case r[0].str
      of "read": m.unread = old[2].num != 0
      of "flag": m.flagged = old[3].num != 0
      of "tags": m.tags = unpackTags(old[4].str)
      of "move": m.folder = int old[5].num
      else: discard
    db.exec("UPDATE messages SET folder = ?, thread = ?, subject = ?, from_name = ?, " &
            "from_email = ?, to_list = CASE WHEN ? = '' THEN to_list ELSE ? END, " &
            "cc_list = CASE WHEN ? = '' THEN cc_list ELSE ? END, date = ?, " &
            "size = CASE WHEN ? = 0 THEN size ELSE ? END, snippet = ?, unread = ?, " &
            "flagged = ?, important = ?, has_att = ?, focused = ?, tags = ?, mine = ?, " &
            "draft = ?, msgid = CASE WHEN ? = '' THEN msgid ELSE ? END, labels = ? WHERE id = ?",
            m.folder, m.thread, m.subject, m.fromName, m.fromEmail, m.toList, m.toList,
            m.ccList, m.ccList, m.date, m.size, m.size, m.snippet, m.unread, m.flagged,
            m.important, m.hasAtt, m.focused, packTags(m.tags), m.mine, m.draft, m.msgId,
            m.msgId, m.labels, result)
  db.indexMessage(result)

proc deleteMessage*(db: Db; id: int) =
  db.exec("DELETE FROM mfts WHERE rowid = ?", id)
  db.exec("DELETE FROM atts WHERE message = ?", id)
  db.exec("DELETE FROM messages WHERE id = ?", id)

proc deleteByRemote*(db: Db; account: int; remoteId: string) =
  let v = db.value("SELECT id FROM messages WHERE account = ? AND remote_id = ?", account, remoteId)
  if not v.isNull: db.deleteMessage(int v.num)

proc setBody*(db: Db; id: int; html, text: string) =
  db.exec("UPDATE messages SET html = ?, text = ?, body_state = 2 WHERE id = ?", html, text, id)
  db.indexMessage(id)

proc setBodyState*(db: Db; id, state: int) =
  db.exec("UPDATE messages SET body_state = ? WHERE id = ?", state, id)

proc setDetails*(db: Db; id: int; toList, ccList, msgId, inReplyTo, refs: string) =
  db.exec("UPDATE messages SET to_list = CASE WHEN ? = '' THEN to_list ELSE ? END, " &
          "cc_list = CASE WHEN ? = '' THEN cc_list ELSE ? END, " &
          "msgid = CASE WHEN ? = '' THEN msgid ELSE ? END, in_reply_to = ?, refs = ? WHERE id = ?",
          toList, toList, ccList, ccList, msgId, msgId, inReplyTo, refs, id)

proc folderMessages*(db: Db; folder: int; limit = 3000): seq[Msg] =
  ## A folder's messages, newest first (snoozed ones only once they wake).
  let now = epochTime()
  for r in db.rows("SELECT " & msgCols & " FROM messages WHERE folder = ? AND snooze <= ? " &
                   "ORDER BY date DESC LIMIT ?", folder, now, limit):
    result.add toMsg(r)

proc threadMessages*(db: Db; account: int; thread: string): seq[Msg] =
  ## Every message of a thread in every folder, newest first, with bodies.
  for r in db.rows("SELECT " & msgCols & ", html, text FROM messages WHERE account = ? AND " &
                   "thread = ? ORDER BY date DESC LIMIT 200", account, thread):
    var m = toMsg(r)
    m.html = r[28].str
    m.text = r[29].str
    result.add m

proc whereMessages*(db: Db; where: string; args: seq[DbValue]; limit = 2000): seq[Msg] =
  ## Messages that match a SQL condition (the search, the tag and flag views).
  var a = args
  a.add toDbValue(limit)
  for r in db.rows("SELECT " & msgCols & " FROM messages WHERE " & where &
                   " ORDER BY date DESC LIMIT ?", a):
    result.add toMsg(r)

proc unreadIn*(db: Db; folder: int): int =
  int db.value("SELECT count(*) FROM messages WHERE folder = ? AND unread = 1", folder).num

proc setFlags*(db: Db; id: int; unread = -1; flagged = -1) =
  if unread >= 0: db.exec("UPDATE messages SET unread = ? WHERE id = ?", unread, id)
  if flagged >= 0: db.exec("UPDATE messages SET flagged = ? WHERE id = ?", flagged, id)

proc setTags*(db: Db; id: int; tags: seq[string]) =
  db.exec("UPDATE messages SET tags = ? WHERE id = ?", packTags(tags), id)

proc setPinned*(db: Db; id: int; on: bool) =
  db.exec("UPDATE messages SET pinned = ? WHERE id = ?", on, id)

proc setSnooze*(db: Db; id: int; until: float) =
  db.exec("UPDATE messages SET snooze = ? WHERE id = ?", until, id)

proc moveLocal*(db: Db; id, folder: int) =
  db.exec("UPDATE messages SET folder = ? WHERE id = ?", folder, id)

# ---- attachments -----------------------------------------------------------------------

proc toAtt(r: DbRow): Att =
  Att(id: int r[0].num, message: int r[1].num, remoteId: r[2].str, name: r[3].str,
      mime: r[4].str, size: int r[5].num, cid: r[6].str, inline: r[7].num != 0,
      hasData: r[8].num != 0)

proc attachments*(db: Db; message: int): seq[Att] =
  for r in db.rows("SELECT id, message, remote_id, name, mime, size, cid, inline, " &
                   "data IS NOT NULL FROM atts WHERE message = ? ORDER BY id", message):
    result.add toAtt(r)

proc addAttachment*(db: Db; message: int; remoteId, name, mime: string; size: int;
                    cid: string; inline: bool; data = ""; hasData = false): int =
  let old = db.value("SELECT id FROM atts WHERE message = ? AND remote_id = ?", message, remoteId)
  if not old.isNull:
    result = int old.num
    if hasData: db.exec("UPDATE atts SET data = ? WHERE id = ?", blob(data), result)
    return
  if hasData:
    db.exec("INSERT INTO atts(message, remote_id, name, mime, size, cid, inline, data) " &
            "VALUES(?, ?, ?, ?, ?, ?, ?, ?)", message, remoteId, name, mime, size, cid, inline,
            blob(data))
  else:
    db.exec("INSERT INTO atts(message, remote_id, name, mime, size, cid, inline) " &
            "VALUES(?, ?, ?, ?, ?, ?, ?)", message, remoteId, name, mime, size, cid, inline)
  int db.lastInsertId

proc attachmentData*(db: Db; id: int): string =
  db.value("SELECT data FROM atts WHERE id = ?", id).str

proc setAttachmentData*(db: Db; id: int; data: string) =
  db.exec("UPDATE atts SET data = ? WHERE id = ?", blob(data), id)

proc cidData*(db: Db; message: int): Table[string, string] =
  ## The inline pictures of a message by Content-ID.
  for r in db.rows("SELECT cid, data FROM atts WHERE message = ? AND cid != '' AND " &
                   "data IS NOT NULL", message):
    result[r[0].str] = r[1].str

# ---- tags ------------------------------------------------------------------------------

proc tags*(db: Db; account = -1): seq[Tag] =
  ## Every account's tags (or one account's), one per name.
  var seen: seq[string]
  let sql = if account < 0: "SELECT id, account, name, color, remote_id FROM tags ORDER BY name"
            else: "SELECT id, account, name, color, remote_id FROM tags WHERE account = " &
                  $account & " ORDER BY name"
  for r in db.rows(sql):
    if account < 0 and r[2].str.toLowerAscii in seen: continue
    seen.add r[2].str.toLowerAscii
    result.add Tag(id: int r[0].num, account: int r[1].num, name: r[2].str, color: r[3].str,
                   remoteId: r[4].str)

proc tagOf*(db: Db; account: int; name: string): Tag =
  let r = db.one("SELECT id, account, name, color, remote_id FROM tags WHERE account = ? AND " &
                 "lower(name) = lower(?)", account, name)
  if r.len > 0:
    result = Tag(id: int r[0].num, account: int r[1].num, name: r[2].str, color: r[3].str,
                 remoteId: r[4].str)

proc tagByRemote*(db: Db; account: int; remoteId: string): Tag =
  let r = db.one("SELECT id, account, name, color, remote_id FROM tags WHERE account = ? AND " &
                 "remote_id = ?", account, remoteId)
  if r.len > 0:
    result = Tag(id: int r[0].num, account: int r[1].num, name: r[2].str, color: r[3].str,
                 remoteId: r[4].str)

proc upsertTag*(db: Db; account: int; name, color, remoteId: string) =
  db.exec("INSERT INTO tags(account, name, color, remote_id) VALUES(?, ?, ?, ?) " &
          "ON CONFLICT(account, name) DO UPDATE SET color = CASE WHEN excluded.color = '' " &
          "THEN color ELSE excluded.color END, remote_id = CASE WHEN excluded.remote_id = '' " &
          "THEN remote_id ELSE excluded.remote_id END", account, name, color, remoteId)

proc renameTag*(db: Db; old, new: string) =
  db.transaction:
    db.exec("UPDATE tags SET name = ? WHERE lower(name) = lower(?)", new, old)
    for r in db.all("SELECT id, tags FROM messages WHERE instr(tags, ?) > 0", "\n" & old & "\n"):
      var ts = unpackTags(r[1].str)
      for t in ts.mitems:
        if t.toLowerAscii == old.toLowerAscii: t = new
      db.exec("UPDATE messages SET tags = ? WHERE id = ?", packTags(ts), r[0].num)

proc setTagColor*(db: Db; name, color: string) =
  db.exec("UPDATE tags SET color = ? WHERE lower(name) = lower(?)", color, name)

proc deleteTag*(db: Db; name: string) =
  db.transaction:
    db.exec("DELETE FROM tags WHERE lower(name) = lower(?)", name)
    for r in db.all("SELECT id, tags FROM messages WHERE instr(tags, ?) > 0", "\n" & name & "\n"):
      var ts = unpackTags(r[1].str)
      ts.keepItIf(it.toLowerAscii != name.toLowerAscii)
      db.exec("UPDATE messages SET tags = ? WHERE id = ?", packTags(ts), r[0].num)

proc tagCount*(db: Db; name: string): int =
  int db.value("SELECT count(*) FROM messages WHERE instr(tags, ?) > 0", "\n" & name & "\n").num

# ---- contacts --------------------------------------------------------------------------

proc noteContact*(db: Db; email, name: string; when0 = 0.0) =
  ## Someone written to or heard from (for the address book and completion).
  if email.len == 0 or '@' notin email: return
  let e = email.toLowerAscii
  db.exec("INSERT INTO contacts(email, name, uses, last) VALUES(?, ?, 1, ?) ON CONFLICT(email) " &
          "DO UPDATE SET uses = uses + 1, last = max(last, excluded.last), name = CASE WHEN " &
          "name = '' THEN excluded.name ELSE name END", e, name, when0)

proc contacts*(db: Db; filter = ""; limit = 500): seq[tuple[email, name: string; uses: int; saved: bool]] =
  let f = "%" & filter.toLowerAscii & "%"
  for r in db.rows("SELECT email, name, uses, saved FROM contacts WHERE email LIKE ? OR " &
                   "lower(name) LIKE ? ORDER BY saved DESC, uses DESC, last DESC LIMIT ?",
                   f, f, limit):
    result.add (r[0].str, r[1].str, int r[2].num, r[3].num != 0)

proc saveContact*(db: Db; email, name, phone, company, notes: string) =
  db.exec("INSERT INTO contacts(email, name, saved, phone, company, notes) VALUES(?, ?, 1, ?, ?, ?) " &
          "ON CONFLICT(email) DO UPDATE SET name = excluded.name, saved = 1, phone = excluded.phone, " &
          "company = excluded.company, notes = excluded.notes", email.toLowerAscii, name, phone,
          company, notes)

proc contactDetails*(db: Db; email: string): tuple[name, phone, company, notes: string] =
  let r = db.one("SELECT name, phone, company, notes FROM contacts WHERE email = ?", email.toLowerAscii)
  if r.len > 0: result = (r[0].str, r[1].str, r[2].str, r[3].str)

proc deleteContact*(db: Db; email: string) =
  db.exec("DELETE FROM contacts WHERE email = ?", email.toLowerAscii)

# ---- actions waiting for the server ------------------------------------------------------

proc queueAction*(db: Db; account: int; kind: string; data: JsonNode; due = 0.0): int =
  db.exec("INSERT INTO actions(account, kind, data, due) VALUES(?, ?, ?, ?)", account, kind,
          $data, due)
  int db.lastInsertId

proc dueActions*(db: Db; account: int): seq[Action] =
  let now = epochTime()
  for r in db.rows("SELECT id, account, kind, data, due, tries FROM actions WHERE account = ? " &
                   "AND due <= ? AND error = '' ORDER BY id", account, now):
    var j: JsonNode
    try: j = parseJson(r[3].str) except CatchableError: j = newJObject()
    result.add Action(id: int r[0].num, account: int r[1].num, kind: r[2].str, data: j,
                      due: r[4].flt, tries: int r[5].num)

proc actionsWaiting*(db: Db): int =
  int db.value("SELECT count(*) FROM actions WHERE error = ''").num

proc failedActions*(db: Db): seq[tuple[id: int; kind, error: string]] =
  for r in db.rows("SELECT id, kind, error FROM actions WHERE error != '' ORDER BY id DESC LIMIT 20"):
    result.add (int r[0].num, r[1].str, r[2].str)

proc doneAction*(db: Db; id: int) = db.exec("DELETE FROM actions WHERE id = ?", id)

proc retryAction*(db: Db; id: int; after: float) =
  db.exec("UPDATE actions SET tries = tries + 1, due = ? WHERE id = ?", epochTime() + after, id)

proc failAction*(db: Db; id: int; error: string) =
  db.exec("UPDATE actions SET error = ? WHERE id = ?", (if error.len > 0: error else: "failed"), id)

proc scheduledSends*(db: Db): seq[tuple[id: int; due: float; subject: string]] =
  for r in db.rows("SELECT id, due, data FROM actions WHERE kind = 'send' AND due > ? ORDER BY due",
                   epochTime()):
    var s = ""
    try: s = parseJson(r[2].str){"subject"}.getStr except CatchableError: discard
    result.add (int r[0].num, r[1].flt, s)

# ---- signatures, events, tasks, notes, drafts ---------------------------------------------

proc signatures*(db: Db): seq[tuple[id: int; name, html: string]] =
  for r in db.rows("SELECT id, name, html FROM signatures ORDER BY id"):
    result.add (int r[0].num, r[1].str, r[2].str)

proc saveSignature*(db: Db; id: int; name, html: string): int =
  if id > 0:
    db.exec("UPDATE signatures SET name = ?, html = ? WHERE id = ?", name, html, id)
    id
  else:
    db.exec("INSERT INTO signatures(name, html) VALUES(?, ?)", name, html)
    int db.lastInsertId

proc deleteSignature*(db: Db; id: int) = db.exec("DELETE FROM signatures WHERE id = ?", id)

proc packAttendees(list: seq[Attendee]): string =
  if list.len == 0: return ""
  var j = newJArray()
  for a in list: j.add %*[a.name, a.email, a.response]
  $j

proc unpackAttendees(s: string): seq[Attendee] =
  if s.len == 0: return
  try:
    for a in parseJson(s):
      result.add (a[0].getStr, a[1].getStr, a[2].getStr)
  except CatchableError: discard

const eventCols = "id, account, remote_id, title, location, start, finish, all_day, organizer, " &
  "mine, attendees, join_url, notes, reminder, series, pattern"

proc toEvent(r: DbRow): Event =
  Event(id: int r[0].num, account: int r[1].num, remoteId: r[2].str, title: r[3].str,
        location: r[4].str, start: r[5].flt, finish: r[6].flt, allDay: r[7].num != 0,
        organizer: r[8].str, mine: r[9].num != 0, attendees: unpackAttendees(r[10].str),
        joinUrl: r[11].str, notes: r[12].str, reminder: int r[13].num, series: r[14].str,
        repeat: r[15].str)

proc upsertEvent*(db: Db; e: Event) =
  db.exec("INSERT INTO events(account, remote_id, title, start, finish, all_day, location, " &
          "organizer, mine, attendees, join_url, notes, reminder, series, pattern) " &
          "VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(account, remote_id) " &
          "DO UPDATE SET title = excluded.title, start = excluded.start, finish = excluded.finish, " &
          "all_day = excluded.all_day, location = excluded.location, organizer = excluded.organizer, " &
          "mine = excluded.mine, attendees = excluded.attendees, join_url = excluded.join_url, " &
          "notes = excluded.notes, reminder = excluded.reminder, series = excluded.series, " &
          "pattern = excluded.pattern",
          e.account, e.remoteId, e.title, e.start, e.finish, e.allDay, e.location, e.organizer,
          e.mine, packAttendees(e.attendees), e.joinUrl, e.notes, e.reminder, e.series, e.repeat)

proc clearEvents*(db: Db; account: int; fromT, toT: float) =
  db.exec("DELETE FROM events WHERE account = ? AND start >= ? AND start < ?", account, fromT, toT)

proc events*(db: Db; fromT, toT: float): seq[Event] =
  for r in db.rows("SELECT " & eventCols & " FROM events WHERE finish >= ? AND start < ? " &
                   "ORDER BY start", fromT, toT):
    result.add toEvent(r)

proc event*(db: Db; id: int): Event =
  let r = db.one("SELECT " & eventCols & " FROM events WHERE id = ?", id)
  if r.len > 0: result = toEvent(r)

proc eventByRemote*(db: Db; account: int; remoteId: string): Event =
  let r = db.one("SELECT " & eventCols & " FROM events WHERE account = ? AND remote_id = ?",
                 account, remoteId)
  if r.len > 0: result = toEvent(r)

proc removeEvent*(db: Db; account: int; remoteId: string) =
  ## An event (or a whole series: its id) taken out here.
  db.exec("DELETE FROM events WHERE account = ? AND (remote_id = ? OR series = ?)", account,
          remoteId, remoteId)

proc tasks*(db: Db): seq[tuple[id: int; title: string; done: bool; due: float; message: int]] =
  for r in db.rows("SELECT id, title, done, due, message FROM tasks ORDER BY done, " &
                   "CASE WHEN due = 0 THEN 1e18 ELSE due END, id DESC"):
    result.add (int r[0].num, r[1].str, r[2].num != 0, r[3].flt, int r[4].num)

proc addTask*(db: Db; title: string; due = 0.0; message = 0): int =
  db.exec("INSERT INTO tasks(title, due, message, added) VALUES(?, ?, ?, ?)", title, due,
          message, epochTime())
  int db.lastInsertId

proc setTaskDone*(db: Db; id: int; done: bool) = db.exec("UPDATE tasks SET done = ? WHERE id = ?", done, id)
proc deleteTask*(db: Db; id: int) = db.exec("DELETE FROM tasks WHERE id = ?", id)

proc notes*(db: Db): seq[tuple[id: int; title, body: string; updated: float]] =
  for r in db.rows("SELECT id, title, body, updated FROM notes ORDER BY updated DESC"):
    result.add (int r[0].num, r[1].str, r[2].str, r[3].flt)

proc saveNote*(db: Db; id: int; title, body: string): int =
  if id > 0:
    db.exec("UPDATE notes SET title = ?, body = ?, updated = ? WHERE id = ?", title, body,
            epochTime(), id)
    id
  else:
    db.exec("INSERT INTO notes(title, body, updated) VALUES(?, ?, ?)", title, body, epochTime())
    int db.lastInsertId

proc deleteNote*(db: Db; id: int) = db.exec("DELETE FROM notes WHERE id = ?", id)

proc saveDraft*(db: Db; id: int; data: JsonNode): int =
  if id > 0:
    db.exec("UPDATE drafts SET data = ?, updated = ? WHERE id = ?", $data, epochTime(), id)
    id
  else:
    db.exec("INSERT INTO drafts(data, updated) VALUES(?, ?)", $data, epochTime())
    int db.lastInsertId

proc drafts*(db: Db): seq[tuple[id: int; data: JsonNode; updated: float]] =
  for r in db.rows("SELECT id, data, updated FROM drafts ORDER BY updated DESC"):
    var j: JsonNode
    try: j = parseJson(r[1].str) except CatchableError: j = newJObject()
    result.add (int r[0].num, j, r[2].flt)

proc deleteDraft*(db: Db; id: int) = db.exec("DELETE FROM drafts WHERE id = ?", id)

proc messageCount*(db: Db): int = int db.value("SELECT count(*) FROM messages").num

# ---- follow up: a flag with a day ------------------------------------------------------------

proc setFollow*(db: Db; id: int; at: float) =
  ## A reminder on a flagged message: `at` (0: none).
  db.exec("UPDATE messages SET follow = ? WHERE id = ?", at, id)

proc followOf*(db: Db; id: int): float =
  ## When the message is to be followed up (0: no day).
  let v = db.value("SELECT follow FROM messages WHERE id = ?", id)
  if v.isNull: 0.0 else: v.flt

proc dueFollowUps*(db: Db; now: float): seq[tuple[id: int; subject: string; at: float]] =
  ## Flagged messages whose day has come, the oldest first.
  for r in db.rows("SELECT id, subject, follow FROM messages WHERE flagged = 1 AND follow > 0 " &
                   "AND follow <= ? ORDER BY follow", now):
    result.add (int r[0].num, r[1].str, r[2].flt)

# ---- message rules: kept as their JSON (examples/mail/rules.nim reads it) -------------------

proc rulesJson*(db: Db): string =
  ## The message rules, as one JSON array ("" none yet).
  db.exec("CREATE TABLE IF NOT EXISTS rules(id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT)")
  let v = db.value("SELECT json FROM rules WHERE id = 1")
  if v.isNull: "" else: v.str

proc saveRulesJson*(db: Db; json: string) =
  db.exec("CREATE TABLE IF NOT EXISTS rules(id INTEGER PRIMARY KEY CHECK (id = 1), json TEXT)")
  db.exec("INSERT INTO rules(id, json) VALUES(1, ?) ON CONFLICT(id) DO UPDATE SET json = excluded.json",
          json)

# ---- newsletters: how to leave them (List-Unsubscribe) --------------------------------------

proc setUnsub*(db: Db; id: int; header, post: string) =
  ## A message's List-Unsubscribe (and -Post) headers, kept with it.
  db.exec("CREATE TABLE IF NOT EXISTS unsub(message INTEGER PRIMARY KEY, header TEXT, post TEXT)")
  db.exec("INSERT INTO unsub(message, header, post) VALUES(?, ?, ?) ON CONFLICT(message) DO " &
          "UPDATE SET header = excluded.header, post = excluded.post", id, header, post)

proc unsubOf*(db: Db; id: int): tuple[header, post: string] =
  ## What a message says about leaving its list ("" when it is not a list's).
  db.exec("CREATE TABLE IF NOT EXISTS unsub(message INTEGER PRIMARY KEY, header TEXT, post TEXT)")
  let r = db.one("SELECT header, post FROM unsub WHERE message = ?", id)
  if r.len > 0: (r[0].str, r[1].str) else: ("", "")

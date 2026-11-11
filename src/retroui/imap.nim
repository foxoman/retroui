## IMAP (RFC 9051, and 3501's IMAP4rev1 that most servers speak): the
## folders and the messages of a mail account on its server -- any
## provider's, or one of your own. A client signs in (a password, or an
## OAuth token: XOAUTH2), lists the folders with what they are for (Sent,
## Drafts, Trash, Junk, Archive), and in a folder searches, fetches the
## headers and the whole messages, sets and clears flags, moves, copies,
## deletes and appends (a sent message into Sent).
##
## .. code-block:: nim
##   import retroui/[imap, netconn]
##   let c = imapConnect("imap.example.com", 993, secTls)
##   c.login("me@example.com", "my password")
##   for f in c.listFolders(): echo f.name, " ", f.role
##   let box = c.select("INBOX")
##   let uids = c.uidSearch("SINCE 1-Nov-2026")
##   for m in c.fetchHeaders(uids): echo m.uid, " ", m.flags
##   echo c.fetchMessage(uids[^1])            # the whole message (RFC 5322)
##   c.addFlags(@[uids[^1]], ["\\Seen"])
##   c.logout()
##
## The connection is `retroui/netconn`'s: the system's own TLS (secTls at
## once, port 993; secStartTls after STARTTLS, port 143). Every call
## blocks: run them on a thread of their own (a mail app's sync does).
## Folder names are UTF-8 here, modified UTF-7 on the wire. `ImapError`
## carries the server's words when it says NO or BAD.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, base64, times, algorithm]
import netconn
export netconn.Security, netconn.NetError

type
  ImapError* = object of IOError
    ## The server said NO or BAD (`msg`: its words), or answered strangely.
  ImapClient* = ref object
    ## A connection to one account's server (`imapConnect`).
    conn: NetConn
    tag: int
    caps*: seq[string]           ## what the server can do, in capitals ("MOVE", "UIDPLUS")
    selected*: string            ## the folder selected ("" none)
    log*: proc (line: string) {.closure, gcsafe.}  ## (sees every line, for tests and debugging)
  ImapFolder* = object
    name*: string                ## the whole name, UTF-8 ("Work/2026")
    raw*: string                 ## as the server writes it (for the commands)
    delimiter*: char             ## between the levels ('/', '.'; '\0' none)
    flags*: seq[string]          ## \HasChildren, \Noselect, \Sent, \Trash...
    role*: string                ## inbox, sent, drafts, trash, junk, archive, all, or ""
  ImapBox* = object
    ## A folder as `select` found it.
    exists*: int                 ## the messages in it
    uidValidity*: int64          ## the UIDs are the same as the last time while this is
    uidNext*: int64              ## the next message's UID
    highestModSeq*: int64        ## CONDSTORE's counter of changes (0: not told)
    readOnly*: bool
  ImapMessage* = object
    uid*: int64
    flags*: seq[string]          ## \Seen, \Flagged, \Answered, \Draft, \Deleted, keywords
    size*: int
    date*: float                 ## when the server got it (INTERNALDATE)
    modSeq*: int64
    header*: string              ## the header fields asked (`fetchHeaders`)
    body*: string                ## the whole message (`fetchMessage`)

  # (an answer, parsed: atoms, strings, NIL, lists)
  IKind = enum ikAtom, ikString, ikNil, ikList
  IVal = object
    kind: IKind
    s: string
    items: seq[IVal]

proc imapFail(msg: string) {.noreturn.} = raise newException(ImapError, msg)

# ---- modified UTF-7 (RFC 3501 5.1.3): folder names --------------------------------------------

const b64m = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+,"

proc decodeFolderName*(s: string): string =
  ## A folder's name as the server writes it ("Entw&APw-rfe"), as UTF-8 ("Entwürfe").
  var i = 0
  while i < s.len:
    if s[i] == '&':
      let e = s.find('-', i + 1)
      if e < 0:
        result.add s[i .. ^1]
        break
      if e == i + 1:
        result.add '&'
      else:
        # base64 (with ',' for '/') of UTF-16 big-endian
        var bits = 0
        var nbits = 0
        var units: seq[uint16]
        for c in s[i + 1 ..< e]:
          let v = b64m.find(c)
          if v < 0: continue
          bits = (bits shl 6) or v
          nbits += 6
          if nbits >= 16:
            nbits -= 16
            units.add uint16((bits shr nbits) and 0xFFFF)
        var k = 0
        while k < units.len:
          var cp = int(units[k])
          if cp >= 0xD800 and cp < 0xDC00 and k + 1 < units.len:
            cp = 0x10000 + ((cp - 0xD800) shl 10) + (int(units[k + 1]) - 0xDC00)
            inc k
          if cp < 0x80: result.add char(cp)
          elif cp < 0x800:
            result.add char(0xC0 or (cp shr 6))
            result.add char(0x80 or (cp and 0x3F))
          elif cp < 0x10000:
            result.add char(0xE0 or (cp shr 12))
            result.add char(0x80 or ((cp shr 6) and 0x3F))
            result.add char(0x80 or (cp and 0x3F))
          else:
            result.add char(0xF0 or (cp shr 18))
            result.add char(0x80 or ((cp shr 12) and 0x3F))
            result.add char(0x80 or ((cp shr 6) and 0x3F))
            result.add char(0x80 or (cp and 0x3F))
          inc k
      i = e + 1
    else:
      result.add s[i]
      inc i

proc encodeFolderName*(s: string): string =
  ## A UTF-8 folder name as the server wants it (modified UTF-7).
  var i = 0
  var units: seq[uint16]
  proc flush(result: var string; units: var seq[uint16]) =
    if units.len == 0: return
    result.add '&'
    var bits = 0
    var nbits = 0
    for u in units:
      bits = (bits shl 16) or int(u)
      nbits += 16
      while nbits >= 6:
        nbits -= 6
        result.add b64m[(bits shr nbits) and 0x3F]
      bits = bits and ((1 shl nbits) - 1)
    if nbits > 0: result.add b64m[(bits shl (6 - nbits)) and 0x3F]
    result.add '-'
    units.setLen(0)
  while i < s.len:
    let c = s[i]
    if ord(c) >= 0x20 and ord(c) < 0x7F:
      flush(result, units)
      if c == '&': result.add "&-" else: result.add c
      inc i
    else:
      # a UTF-8 sequence to its UTF-16 units
      var cp = ord(c)
      var n = 0
      if cp >= 0xF0: (cp = cp and 0x07; n = 3)
      elif cp >= 0xE0: (cp = cp and 0x0F; n = 2)
      elif cp >= 0xC0: (cp = cp and 0x1F; n = 1)
      for k in 1 .. n:
        if i + k < s.len: cp = (cp shl 6) or (ord(s[i + k]) and 0x3F)
      i += n + 1
      if cp >= 0x10000:
        let v = cp - 0x10000
        units.add uint16(0xD800 + (v shr 10))
        units.add uint16(0xDC00 + (v and 0x3FF))
      else: units.add uint16(cp)
  flush(result, units)

# ---- writing commands ---------------------------------------------------------------------------

proc quoted*(s: string): string =
  ## `s` as an IMAP string: quoted, or a literal marker when it cannot be
  ## (a line break, 8-bit text) -- `cmd` sends those as literals.
  var plain = true
  for c in s:
    if c in {'\r', '\n', '\0'} or ord(c) >= 0x80: plain = false
  if plain:
    "\"" & s.multiReplace(("\\", "\\\\"), ("\"", "\\\"")) & "\""
  else:
    "\0LIT" & $s.len & "\0" & s & "\0END\0"

proc nextTag(c: ImapClient): string =
  inc c.tag
  "a" & $c.tag

proc sendLine(c: ImapClient; s: string) =
  if c.log != nil: c.log("> " & (if s.len > 300: s[0 ..< 300] & "..." else: s))
  c.conn.write(s & "\r\n")

proc readLine(c: ImapClient): string =
  result = c.conn.readLine()
  if c.log != nil: c.log("< " & (if result.len > 300: result[0 ..< 300] & "..." else: result))

proc readFull(c: ImapClient): string =
  ## One answer's line, with its literals inline: {n} becomes "\0" n bytes "\0".
  result = c.readLine()
  while result.len > 0 and result[^1] == '}':
    let o = result.rfind('{')
    if o < 0: break
    var nstr = result[o + 1 .. ^2]
    if nstr.endsWith("+"): nstr.setLen(nstr.len - 1)
    let n = try: parseInt(nstr) except ValueError: -1
    if n < 0: break
    var head = result[0 ..< o]
    if head.endsWith("~"): head.setLen(head.len - 1)     # (literal8)
    let data = c.conn.readBytes(n)
    if c.log != nil: c.log("< (" & $n & " bytes)")
    result = head & "\0" & $n & ":" & data & c.readLine()

# ---- reading answers ---------------------------------------------------------------------------

proc parseVals(s: string; i: var int; stopAt = '\0'): seq[IVal] =
  ## (the values of an answer, from `i`: up to the end, or to `stopAt`)
  while i < s.len:
    let c = s[i]
    if c == ' ':
      inc i
    elif c == stopAt:
      inc i
      return
    elif c == '(':
      inc i
      result.add IVal(kind: ikList, items: parseVals(s, i, ')'))
    elif c == '[' and stopAt != '\0':
      # (a section, BODY[HEADER.FIELDS (...)]: kept as one atom with what came before)
      let e = s.find(']', i)
      if e < 0: (result.add IVal(kind: ikAtom, s: s[i .. ^1]); i = s.len)
      else:
        if result.len > 0 and result[^1].kind == ikAtom: result[^1].s.add s[i .. e]
        else: result.add IVal(kind: ikAtom, s: s[i .. e])
        i = e + 1
    elif c == '"':
      var v = ""
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\' and i + 1 < s.len: inc i
        v.add s[i]
        inc i
      inc i
      result.add IVal(kind: ikString, s: v)
    elif c == '\0':
      # a literal: "\0" n ":" bytes
      let colon = s.find(':', i + 1)
      let n = try: parseInt(s[i + 1 ..< colon]) except ValueError: 0
      result.add IVal(kind: ikString, s: s[colon + 1 ..< min(s.len, colon + 1 + n)])
      i = colon + 1 + n
    else:
      var e = i
      while e < s.len and s[e] notin {' ', '(', ')', '\0'} and s[e] != stopAt and
            not (s[e] == '[' and stopAt != '\0'):
        inc e
      if e < s.len and s[e] == '[' and stopAt != '\0':
        let close = s.find(']', e)
        if close > 0:
          e = close + 1
          while e < s.len and s[e] notin {' ', '(', ')'} and s[e] != stopAt: inc e   # (<0.2048>)
      let a = s[i ..< max(i, e)]
      if a.len == 0:
        inc i
        continue
      result.add (if a.toUpperAscii == "NIL": IVal(kind: ikNil) else: IVal(kind: ikAtom, s: a))
      i = e

proc text(v: IVal): string = (if v.kind == ikNil: "" else: v.s)

proc numOf(v: IVal): int64 =
  try: parseBiggestInt(v.s) except ValueError: 0

proc respCode(line: string): string =
  ## "[UIDVALIDITY 3857529045]" of "* OK [UIDVALIDITY 3857529045] UIDs valid"
  let o = line.find('[')
  let e = line.find(']', o + 1)
  if o >= 0 and e > o: line[o + 1 ..< e] else: ""

type Answer = object
  untagged: seq[string]        ## the "* ..." lines (literals inline)
  status, text: string         ## OK / NO / BAD, the words after it

proc cmd(c: ImapClient; command: string): Answer =
  ## Sends a command (literals marked by `quoted` go when the server asks)
  ## and reads its answer; raises `ImapError` on NO or BAD.
  let tag = c.nextTag()
  var line = tag & " " & command
  # literals: each waits for the server's "+" (or not, with LITERAL+)
  let plus = "LITERAL+" in c.caps or "LITERAL-" in c.caps
  while true:
    let k = line.find("\0LIT")
    if k < 0: break
    let colon = line.find('\0', k + 4)
    let n = parseInt(line[k + 4 ..< colon])
    let data = line[colon + 1 ..< colon + 1 + n]
    let rest = line[colon + 1 + n + len("\0END\0") .. ^1]
    c.sendLine(line[0 ..< k] & "{" & $n & (if plus and n <= 4096: "+" else: "") & "}")
    if not (plus and n <= 4096):
      while true:
        let r = c.readLine()
        if r.startsWith("+"): break
        if r.startsWith(tag & " "): imapFail(r[tag.len + 1 .. ^1])
    if c.log != nil: c.log("> (" & $n & " bytes)")
    c.conn.write(data)
    line = rest
  c.sendLine(line)
  while true:
    let r = c.readFull()
    if r.startsWith("* "):
      result.untagged.add r[2 .. ^1]
    elif r.startsWith(tag & " "):
      let rest = r[tag.len + 1 .. ^1]
      let sp = rest.find(' ')
      result.status = (if sp < 0: rest else: rest[0 ..< sp]).toUpperAscii
      result.text = if sp < 0: "" else: rest[sp + 1 .. ^1]
      if result.status != "OK":
        imapFail((if result.text.len > 0: result.text else: "the server said " & result.status))
      return
    elif r.startsWith("+"):
      discard                     # (a continuation nobody asked for)

proc readCaps(c: ImapClient; line: string) =
  let code = respCode(line)
  if code.toUpperAscii.startsWith("CAPABILITY "):
    c.caps = code[11 .. ^1].toUpperAscii.splitWhitespace

proc capability*(c: ImapClient): seq[string] =
  ## Asks the server again what it can do (`caps`).
  let a = c.cmd("CAPABILITY")
  for u in a.untagged:
    if u.toUpperAscii.startsWith("CAPABILITY "): c.caps = u[11 .. ^1].toUpperAscii.splitWhitespace
  c.readCaps(a.text)
  c.caps

proc has*(c: ImapClient; cap: string): bool = cap.toUpperAscii in c.caps
  ## The server can (`"MOVE"`, `"UIDPLUS"`, `"CONDSTORE"`, `"IDLE"`...).

# ---- connecting, signing in --------------------------------------------------------------------

proc imapConnect*(host: string; port = 993; security = secTls; timeoutSec = 60;
                  insecure = false; log: proc (line: string) {.closure, gcsafe.} = nil): ImapClient =
  ## Connects and reads the greeting (STARTTLS first with `secStartTls`).
  ## Raises `NetError` (no connection) or `ImapError` (the server refused).
  result = ImapClient(log: log)
  result.conn = openSecured(host, port, security, timeoutSec, insecure)
  try:
    let g = result.readLine()
    if not g.startsWith("* OK") and not g.startsWith("* PREAUTH"):
      imapFail(if g.startsWith("* BYE"): g[5 .. ^1].strip else: "not an IMAP server: " & g)
    result.readCaps(g)
    if result.caps.len == 0: discard result.capability()
    if security == secStartTls:
      if not result.has("STARTTLS"):
        imapFail(host & " does not offer STARTTLS (try TLS, port 993)")
      discard result.cmd("STARTTLS")
      result.conn.startTls()
      result.caps.setLen(0)
      discard result.capability()
  except CatchableError:
    result.conn.close()           # (no socket or TLS state left behind)
    raise

proc login*(c: ImapClient; user, password: string) =
  ## Signs in with a password (AUTHENTICATE PLAIN where the server has it,
  ## else LOGIN). Raises `ImapError` with the server's words when refused.
  if c.has("AUTH=PLAIN"):
    let ir = encode("\0" & user & "\0" & password)
    if c.has("SASL-IR"):
      let a = c.cmd("AUTHENTICATE PLAIN " & ir)
      c.readCaps(a.text)
    else:
      let tag = c.nextTag()
      c.sendLine(tag & " AUTHENTICATE PLAIN")
      var r = c.readLine()
      if not r.startsWith("+"): imapFail("the server refused PLAIN: " & r)
      c.sendLine(ir)
      while true:
        r = c.readLine()
        if r.startsWith(tag & " "):
          let rest = r[tag.len + 1 .. ^1]
          if not rest.toUpperAscii.startsWith("OK"): imapFail(rest.split(' ', 1)[^1])
          c.readCaps(rest)
          break
  elif c.has("LOGINDISABLED"):
    imapFail("the server takes no password here (it wants TLS, or another way to sign in)")
  else:
    let a = c.cmd("LOGIN " & quoted(user) & " " & quoted(password))
    c.readCaps(a.text)
  if c.caps.len == 0 or "IMAP4REV1" notin c.caps and "IMAP4REV2" notin c.caps:
    discard c.capability()

proc loginOAuth*(c: ImapClient; user, token: string) =
  ## Signs in with an OAuth access token (XOAUTH2: Gmail, Outlook.com).
  let ir = encode("user=" & user & "\x01auth=Bearer " & token & "\x01\x01")
  let tag = c.nextTag()
  c.sendLine(tag & " AUTHENTICATE XOAUTH2 " & ir)
  while true:
    let r = c.readLine()
    if r.startsWith("+"):
      c.sendLine("")                   # (the error's details came: end it)
    elif r.startsWith(tag & " "):
      let rest = r[tag.len + 1 .. ^1]
      if not rest.toUpperAscii.startsWith("OK"): imapFail(rest.split(' ', 1)[^1])
      c.readCaps(rest)
      break
  discard c.capability()

proc enable*(c: ImapClient; what: varargs[string]) =
  ## Turns on extensions the server has (`"CONDSTORE"`, `"UTF8=ACCEPT"`).
  var on: seq[string]
  for w in what:
    if c.has(w): on.add w
  if on.len > 0 and c.has("ENABLE"):
    try: discard c.cmd("ENABLE " & on.join(" "))
    except ImapError: discard

proc logout*(c: ImapClient) =
  ## Signs out and closes the connection.
  if c == nil or c.conn == nil: return
  try: discard c.cmd("LOGOUT")
  except CatchableError: discard
  c.conn.close()

proc close*(c: ImapClient) =
  ## Closes the connection without signing out (it broke).
  if c != nil and c.conn != nil: c.conn.close()

proc noop*(c: ImapClient) =
  ## Keeps the connection open (and lets the server say what changed).
  discard c.cmd("NOOP")

# ---- folders -----------------------------------------------------------------------------------

proc roleOf*(name: string; flags: openArray[string]): string =
  ## What a folder is for, by its special-use flag, else by its usual names.
  for f in flags:
    case f.toLowerAscii
    of "\\sent": return "sent"
    of "\\drafts": return "drafts"
    of "\\trash": return "trash"
    of "\\junk": return "junk"
    of "\\archive": return "archive"
    of "\\all": return "all"
    of "\\flagged": return "flagged"
    else: discard
  let n = name.toLowerAscii
  let last = if '/' in n: n.rsplit('/', 1)[1] elif '.' in n: n.rsplit('.', 1)[1] else: n
  if n == "inbox": return "inbox"
  case last
  of "sent", "sent items", "sent messages", "sent mail", "gesendet", "gesendete objekte",
     "envoyés", "éléments envoyés", "enviados", "elementos enviados", "posta inviata",
     "verzonden", "verzonden items", "отправленные", "المرسلة", "البريد المرسل": "sent"
  of "drafts", "draft", "entwürfe", "brouillons", "borradores", "bozze", "concepten",
     "черновики", "المسودات": "drafts"
  of "trash", "deleted", "deleted items", "deleted messages", "bin", "papierkorb",
     "corbeille", "papelera", "cestino", "prullenbak", "удаленные", "корзина",
     "المحذوفات", "سلة المهملات": "trash"
  of "junk", "spam", "junk e-mail", "junk email", "bulk mail", "spamverdacht", "indésirables",
     "correo no deseado", "posta indesiderata", "ongewenste e-mail", "спам",
     "البريد العشوائي", "غير المرغوب فيه": "junk"
  of "archive", "archives", "archiv", "archivo", "archivio", "архив", "الأرشيف": "archive"
  else: ""

proc listFolders*(c: ImapClient): seq[ImapFolder] =
  ## Every folder of the account (with its special use, where told).
  let special = c.has("SPECIAL-USE")
  let a = c.cmd(if special: "LIST \"\" \"*\" RETURN (SPECIAL-USE)" else: "LIST \"\" \"*\"")
  for u in a.untagged:
    if not u.toUpperAscii.startsWith("LIST "): continue
    var i = 5
    let vs = parseVals(u, i)
    if vs.len < 3: continue
    var f = ImapFolder()
    for fl in vs[0].items: f.flags.add fl.s
    let d = vs[1].text
    f.delimiter = if d.len > 0: d[0] else: '\0'
    f.raw = vs[2].text
    f.name = if "UTF8=ACCEPT" in c.caps: f.raw else: decodeFolderName(f.raw)
    if f.name.toUpperAscii == "INBOX": f.name = "Inbox"
    f.role = if f.raw.toUpperAscii == "INBOX": "inbox" else: roleOf(f.name, f.flags)
    result.add f
  # (Inbox first, the others by name)
  result.sort(proc (x, y: ImapFolder): int =
    if x.role == "inbox": -1 elif y.role == "inbox": 1 else: cmp(x.name.toLowerAscii, y.name.toLowerAscii))

proc folderArg(c: ImapClient; name: string): string =
  ## (a folder for a command: its raw name; quoted, or a literal)
  quoted(name)

proc select*(c: ImapClient; folder: string; readOnly = false): ImapBox =
  ## Opens `folder` (its raw name, `ImapFolder.raw`) for the commands
  ## that work in one: UIDs, flags, fetches.
  let cond = if c.has("CONDSTORE"): " (CONDSTORE)" else: ""
  let a = c.cmd((if readOnly: "EXAMINE " else: "SELECT ") & c.folderArg(folder) & cond)
  c.selected = folder
  result.readOnly = readOnly or a.text.toUpperAscii.startsWith("[READ-ONLY]")
  for u in a.untagged:
    let up = u.toUpperAscii
    if up.endsWith(" EXISTS"):
      result.exists = try: parseInt(u.split(' ')[0]) except ValueError: 0
    let code = respCode(u)
    let w = code.splitWhitespace
    if w.len >= 2:
      case w[0].toUpperAscii
      of "UIDVALIDITY": result.uidValidity = try: parseBiggestInt(w[1]) except ValueError: 0
      of "UIDNEXT": result.uidNext = try: parseBiggestInt(w[1]) except ValueError: 0
      of "HIGHESTMODSEQ": result.highestModSeq = try: parseBiggestInt(w[1]) except ValueError: 0
      else: discard

proc status*(c: ImapClient; folder: string): tuple[messages, unseen: int; uidNext, uidValidity: int64] =
  ## A folder's counts without selecting it.
  let a = c.cmd("STATUS " & c.folderArg(folder) & " (MESSAGES UNSEEN UIDNEXT UIDVALIDITY)")
  for u in a.untagged:
    if not u.toUpperAscii.startsWith("STATUS "): continue
    let o = u.rfind('(')
    if o < 0: continue
    var i = o
    let vs = parseVals(u, i)
    if vs.len == 0: continue
    let items = vs[0].items
    var k = 0
    while k + 1 < items.len:
      case items[k].s.toUpperAscii
      of "MESSAGES": result.messages = int numOf(items[k + 1])
      of "UNSEEN": result.unseen = int numOf(items[k + 1])
      of "UIDNEXT": result.uidNext = numOf(items[k + 1])
      of "UIDVALIDITY": result.uidValidity = numOf(items[k + 1])
      else: discard
      k += 2

proc createFolder*(c: ImapClient; name: string) =
  ## Makes a folder (`name` raw, as `encodeFolderName` gives it).
  discard c.cmd("CREATE " & c.folderArg(name))

proc deleteFolder*(c: ImapClient; name: string) = discard c.cmd("DELETE " & c.folderArg(name))
  ## Deletes a folder (its messages with it).

proc renameFolder*(c: ImapClient; old, new: string) =
  ## Gives a folder another name.
  discard c.cmd("RENAME " & c.folderArg(old) & " " & c.folderArg(new))

# ---- messages ----------------------------------------------------------------------------------

proc uidSet*(uids: openArray[int64]): string =
  ## "1:5,9,12:14" of 1 2 3 4 5 9 12 13 14.
  var s = @uids
  s.sort()
  var i = 0
  while i < s.len:
    var j = i
    while j + 1 < s.len and s[j + 1] <= s[j] + 1: inc j
    if result.len > 0: result.add ','
    result.add $s[i]
    if s[j] != s[i]: result.add ":" & $s[j]
    i = j + 1

proc imapDate*(t: float): string =
  ## An instant as SEARCH wants it: "9-Nov-2026".
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  let d = fromUnixFloat(t).utc
  $d.monthday & "-" & months[ord(d.month) - 1] & "-" & $d.year

proc parseInternalDate*(s: string): float =
  ## "17-Jul-1996 02:44:25 -0700" as seconds since 1970 (0 when not one).
  try:
    let st = s.strip
    let parts = st.splitWhitespace
    if parts.len < 2: return 0
    var t = parse(parts[0] & " " & parts[1], "d-MMM-yyyy HH:mm:ss", utc()).toTime.toUnixFloat
    if parts.len >= 3 and parts[2].len == 5:
      let sign = if parts[2][0] == '-': 1.0 else: -1.0
      t += sign * float(parseInt(parts[2][1 .. 2]) * 3600 + parseInt(parts[2][3 .. 4]) * 60)
    t
  except CatchableError: 0.0

proc uidSearch*(c: ImapClient; criteria: string): seq[int64] =
  ## The UIDs of the messages in the folder selected that match (IMAP's
  ## SEARCH: "ALL", "UNSEEN", "SINCE 1-Nov-2026", "TEXT \"word\""...).
  let a = c.cmd("UID SEARCH " & criteria)
  for u in a.untagged:
    if u.toUpperAscii.startsWith("SEARCH"):
      for w in u.splitWhitespace()[1 .. ^1]:
        if w.startsWith("("): break                    # ((MODSEQ n))
        try: result.add parseBiggestInt(w) except ValueError: discard
  result.sort()

proc parseFetch(u: string): tuple[seqNo: int; m: ImapMessage] =
  ## (a "* n FETCH (...)" answer)
  let sp = u.find(' ')
  result.seqNo = try: parseInt(u[0 ..< sp]) except ValueError: 0
  let o = u.find('(')
  if o < 0: return
  var i = o
  let vs = parseVals(u, i)
  if vs.len == 0: return
  let items = vs[0].items
  var k = 0
  while k + 1 < items.len:
    let key = items[k].s.toUpperAscii
    let v = items[k + 1]
    if key == "UID": result.m.uid = numOf(v)
    elif key == "FLAGS":
      for f in v.items: result.m.flags.add f.s
    elif key == "RFC822.SIZE": result.m.size = int numOf(v)
    elif key == "INTERNALDATE": result.m.date = parseInternalDate(v.text)
    elif key == "MODSEQ":
      if v.items.len > 0: result.m.modSeq = numOf(v.items[0])
    elif key.startsWith("BODY[HEADER") or key.startsWith("RFC822.HEADER"):
      result.m.header = v.text
    elif key == "BODY[]" or key == "RFC822" or key.startsWith("BINARY[]") or
         (key.startsWith("BODY[]<")):
      result.m.body = v.text
    k += 2

const headerFields* = "FROM TO CC SUBJECT DATE MESSAGE-ID IN-REPLY-TO REFERENCES " &
                      "CONTENT-TYPE LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST IMPORTANCE X-PRIORITY"
  ## (what `fetchHeaders` asks of each message)

proc fetchHeaders*(c: ImapClient; uids: openArray[int64]; fields = headerFields): seq[ImapMessage] =
  ## The flags, size, date and header fields of messages in the folder
  ## selected, in pieces of 500.
  var i = 0
  let all = @uids
  while i < all.len:
    let part = all[i ..< min(i + 500, all.len)]
    let a = c.cmd("UID FETCH " & uidSet(part) & " (UID FLAGS RFC822.SIZE INTERNALDATE" &
                  (if c.has("CONDSTORE"): " MODSEQ" else: "") &
                  " BODY.PEEK[HEADER.FIELDS (" & fields & ")])")
    for u in a.untagged:
      if " FETCH " in u.toUpperAscii[0 ..< min(u.len, 24)]:
        let (_, m) = parseFetch(u)
        if m.uid > 0: result.add m
    i += 500

proc fetchFlags*(c: ImapClient; uids: openArray[int64]; changedSince = 0'i64): seq[ImapMessage] =
  ## The flags of messages (only those changed since a CONDSTORE counter,
  ## when the server keeps one and it is given).
  if uids.len == 0: return
  let since = if changedSince > 0 and c.has("CONDSTORE"): " (CHANGEDSINCE " & $changedSince & ")" else: ""
  let a = c.cmd("UID FETCH " & uidSet(uids) & " (UID FLAGS)" & since)
  for u in a.untagged:
    if " FETCH " in u.toUpperAscii[0 ..< min(u.len, 24)]:
      let (_, m) = parseFetch(u)
      if m.uid > 0: result.add m

proc fetchMessage*(c: ImapClient; uid: int64): string =
  ## The whole message (its RFC 5322 bytes), without marking it read.
  let a = c.cmd("UID FETCH " & $uid & " (UID BODY.PEEK[])")
  for u in a.untagged:
    if " FETCH " in u.toUpperAscii[0 ..< min(u.len, 24)]:
      let (_, m) = parseFetch(u)
      if m.uid == uid or (m.uid == 0 and m.body.len > 0): return m.body
  imapFail("the message is no longer there")

proc storeFlags(c: ImapClient; uids: openArray[int64]; op: string; flags: openArray[string]) =
  if uids.len == 0 or flags.len == 0: return
  discard c.cmd("UID STORE " & uidSet(uids) & " " & op & ".SILENT (" & @flags.join(" ") & ")")

proc addFlags*(c: ImapClient; uids: openArray[int64]; flags: openArray[string]) =
  ## Sets flags (`"\\Seen"`, `"\\Flagged"`, a keyword) on messages.
  c.storeFlags(uids, "+FLAGS", flags)

proc removeFlags*(c: ImapClient; uids: openArray[int64]; flags: openArray[string]) =
  ## Clears flags.
  c.storeFlags(uids, "-FLAGS", flags)

proc expunge*(c: ImapClient; uids: openArray[int64] = []) =
  ## Deletes for good the messages marked \Deleted (only `uids`, where the
  ## server has UIDPLUS).
  if uids.len > 0 and c.has("UIDPLUS"): discard c.cmd("UID EXPUNGE " & uidSet(uids))
  else: discard c.cmd("EXPUNGE")

proc copyUidOf(text: string): seq[int64] =
  ## (the new UIDs of COPYUID / APPENDUID: "[COPYUID 38505 304,319:320 3956:3958]")
  let code = respCode(text)
  let w = code.splitWhitespace
  if w.len >= 3 and w[0].toUpperAscii in ["COPYUID", "APPENDUID"]:
    for part in w[^1].split(','):
      if ':' in part:
        let ab = part.split(':')
        try:
          for u in parseBiggestInt(ab[0]) .. parseBiggestInt(ab[1]): result.add u
        except ValueError: discard
      else:
        try: result.add parseBiggestInt(part) except ValueError: discard

proc copy*(c: ImapClient; uids: openArray[int64]; dest: string): seq[int64] =
  ## Copies messages to the folder `dest` (raw): their new UIDs there,
  ## where the server tells them.
  if uids.len == 0: return
  copyUidOf(c.cmd("UID COPY " & uidSet(uids) & " " & c.folderArg(dest)).text)

proc move*(c: ImapClient; uids: openArray[int64]; dest: string): seq[int64] =
  ## Moves messages to `dest` (MOVE where the server has it; else a copy,
  ## then the originals deleted): their new UIDs, where told.
  if uids.len == 0: return
  if c.has("MOVE"):
    let a = c.cmd("UID MOVE " & uidSet(uids) & " " & c.folderArg(dest))
    result = copyUidOf(a.text)
    if result.len == 0:
      for u in a.untagged:
        let r = copyUidOf("* " & u)
        if r.len > 0: result = r
  else:
    result = c.copy(uids, dest)
    c.addFlags(uids, ["\\Deleted"])
    c.expunge(uids)

proc deleteForever*(c: ImapClient; uids: openArray[int64]) =
  ## Deletes messages for good (no Trash).
  if uids.len == 0: return
  c.addFlags(uids, ["\\Deleted"])
  c.expunge(uids)

proc append*(c: ImapClient; folder, message: string; flags: openArray[string] = [];
             date = 0.0): int64 =
  ## Puts a whole message into `folder` (a sent mail into Sent, a draft
  ## into Drafts): its UID there when the server says it (0 else).
  var line = "APPEND " & c.folderArg(folder)
  if flags.len > 0: line.add " (" & @flags.join(" ") & ")"
  # (always a literal: the message has line breaks)
  line.add " \0LIT" & $message.len & "\0" & message & "\0END\0"
  let a = c.cmd(line)
  let u = copyUidOf(a.text)
  if u.len > 0: u[0] else: 0

proc command*(c: ImapClient; line: string): seq[string] =
  ## Any other command (an extension the server has, `"GETQUOTAROOT INBOX"`):
  ## its untagged answers, "* " taken off, a literal's bytes in place of
  ## its {n}. Raises `ImapError` on NO or BAD.
  for u in c.cmd(line).untagged:
    var s = ""
    var i = 0
    while i < u.len:
      if u[i] == '\0':
        let colon = u.find(':', i + 1)
        let n = try: parseInt(u[i + 1 ..< colon]) except ValueError: 0
        s.add u[colon + 1 ..< min(u.len, colon + 1 + n)]
        i = colon + 1 + n
      else:
        s.add u[i]
        inc i
    result.add s

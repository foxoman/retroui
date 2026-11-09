## Bringing old mail in and taking mail out, for Retro Mail -- with the
## nostalgia of Outlook Express. Reads the stores of Outlook Express 5 and 6
## (`.dbx`: Folders.dbx and a file for each folder), the mailboxes of Outlook
## Express 4 (`.mbx`, with or without the `.idx` beside it), mbox files
## (mboxo and mboxrd: Thunderbird, Apple Mail, Gmail's Takeout, Unix mail),
## single `.eml` files, and folders of all of these (Maildir among them);
## writes `.eml` and mbox files.
##
## .. code-block:: nim
##   for m in importMail(r"D:\Old PC\Outlook Express"):
##     let p = parseMime(m.raw)
##     echo m.folder, "  ", p.decodedHeader("Subject"), (if m.read: "" else: "  (new)")
##
##   writeMbox("Inbox.mbox", raws)              # for Thunderbird, Apple Mail...
##   writeEml(emlFileName(raw), raw)            # for Outlook, Windows Mail...
##
## Reading never raises and never trusts the file: every offset and length
## is checked, every index tree and chain of blocks is followed at most once,
## and a damaged store gives the messages that can still be read (an Outlook
## Express folder whose index is broken is searched for its messages' blocks).
## Folder names come out as UTF-8, with "/" between a folder and a folder in it.

import std/[os, strutils, algorithm, sets, tables, times]
from std/unicode import nil
import mime

when defined(windows):
  import std/registry
  proc GetACP(): cuint {.importc, stdcall, dynlib: "kernel32".}

type
  ImportedMail* = object
    ## A message brought in from an old program's store.
    folder*: string          ## the folder it was in ("Inbox", "Sent Items", "Projects/Retro"); "" for a lone .eml
    raw*: string             ## the whole RFC 5322 message
    read*, flagged*, replied*: bool  ## what the old program knew, where it knew it (false where it did not say)
    date*: float             ## epoch seconds: when Outlook Express received it, else the Date header (else an mbox "From " line's date, an .eml file's time); 0 when none is known
  ImportProgress* = proc (done, total: int): bool {.closure.}
    ## Told how far an import has come (`done` of `total` bytes); false stops it.

const
  MaxMessage = 256 * 1024 * 1024   ## bytes kept of one message
  DbxHeaderSize = 0x24BC           ## the file header; objects start after it
  DbxNodeSize = 0x27C              ## an index tree node: 24 bytes and 51 entries of 12
  DbxNodeEntries = 0x33
  DbxBlockData = 0x200             ## the data a message block holds
  DbxMaxInfo = 0x10000             ## the most a message's or a folder's info object can hold
  DbxMessages = 0xC5               ## (the byte that tells the files of a store apart)
  DbxFolders = 0xC6
  MbxHeaderSize = 0x54
  MbxMarker = 0x7F007F00'i64       ## at the start of each message record
  FileTimeEpoch = 116444736000000000'i64   ## 1970-01-01 in 100 ns since 1601
  OeMagic = "\xCF\xAD\x12\xFE\xC5\xFD\x74\x6F\x66\xE3\xD1\x11\x9A\x4E\x00\xC0"
  SpecialFolders = ["Inbox", "Outbox", "Sent Items", "Deleted Items", "Drafts"]
  CodepageGuesses = ["windows-1252", "windows-1251", "windows-1256", "windows-1250", "windows-1253",
                     "windows-1254", "windows-1255", "windows-1257", "windows-1258", "windows-874",
                     "shift-jis", "gbk", "euc-kr", "big5"]
  NotMail = [".msf", ".idx", ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".pdf", ".zip", ".exe",
             ".dll", ".wab", ".pst", ".ost", ".nch", ".dat", ".log", ".sqlite", ".db", ".json",
             ".html", ".htm", ".css", ".js", ".ini", ".lnk", ".plist"]
  StrongFields = ["from", "to", "cc", "date", "subject", "received", "return-path", "message-id",
                  "mime-version", "delivered-to", "reply-to", "sender"]

# ---- a file read piece by piece ----------------------------------------------------------------

type Store = object
  f: File
  size: int64
  isOpen: bool

proc openStore(path: string): Store =
  try:
    if open(result.f, path):
      result.isOpen = true
      result.size = getFileSize(result.f)
  except IOError, OSError:
    if result.isOpen: close(result.f)
    result.isOpen = false

proc close(s: var Store) =
  if s.isOpen:
    s.isOpen = false
    close(s.f)

proc readAt(s: var Store; pos: int64; n: int): string =
  ## Up to `n` bytes at `pos`: fewer where the file ends, "" outside it.
  if not s.isOpen or n <= 0 or pos < 0 or pos >= s.size: return ""
  let m = int(min(int64(n), s.size - pos))
  result = newString(m)
  try:
    s.f.setFilePos(pos)
    result.setLen(max(0, s.f.readBuffer(addr result[0], m)))
  except IOError, OSError:
    result = ""

proc headOf(path: string; n = 4096): string =
  ## The first `n` bytes of the file at `path`.
  var s = openStore(path)
  result = s.readAt(0, n)
  s.close()

proc le16(s: string; i: int): int64 =
  if i < 0 or i + 2 > s.len: 0'i64
  else: int64(ord(s[i])) or (int64(ord(s[i+1])) shl 8)

proc le32(s: string; i: int): int64 =
  if i < 0 or i + 4 > s.len: 0'i64
  else: int64(ord(s[i])) or (int64(ord(s[i+1])) shl 8) or (int64(ord(s[i+2])) shl 16) or
        (int64(ord(s[i+3])) shl 24)

proc le64(s: string; i: int): int64 =
  if i < 0 or i + 8 > s.len: 0'i64 else: le32(s, i) or (le32(s, i + 4) shl 32)

proc addRange(s: var string; src: string; a, b: int) =
  ## Appends src[a ..< b].
  if b <= a: return
  let n = s.len
  s.setLen(n + b - a)
  copyMem(addr s[n], unsafeAddr src[a], b - a)

proc fileTimeToEpoch(ft: int64): float =
  ## A Windows FILETIME as epoch seconds; 0 when it is not a date from 1970 to 2100.
  if ft <= FileTimeEpoch: return 0
  result = float(ft - FileTimeEpoch) / 1e7
  if result > 4102444800.0: result = 0

proc isAscii(s: string): bool =
  for c in s:
    if ord(c) >= 0x80: return false
  true

# ---- the header of a message -------------------------------------------------------------------

proc headerField(raw, name: string): string =
  ## The header field `name` (any case) of the message `raw`, unfolded and
  ## trimmed; "" when it has none.
  let lim = min(raw.len, 1 shl 20)
  var i = 0
  var first = true
  while i < lim:
    var e = raw.find('\n', i, lim - 1)
    if e < 0: e = lim
    var le = e
    if le > i and raw[le - 1] == '\r': dec le
    if le == i: result = ""; return                   # the empty line: the body follows
    if first and raw.continuesWith("From ", i):       # (an mbox "From " line)
      first = false
      i = e + 1
      continue
    first = false
    if raw[i] notin {' ', '\t'} and le - i > name.len:
      var same = true
      for k in 0 ..< name.len:
        if toLowerAscii(raw[i + k]) != toLowerAscii(name[k]): (same = false; break)
      if same:
        var j = i + name.len
        while j < le and raw[j] in {' ', '\t'}: inc j
        if j < le and raw[j] == ':':
          result.addRange(raw, j + 1, le)
          var k = e + 1
          while k < lim and raw[k] in {' ', '\t'}:   # (folded lines)
            var e2 = raw.find('\n', k, lim - 1)
            if e2 < 0: e2 = lim
            var le2 = e2
            if le2 > k and raw[le2 - 1] == '\r': dec le2
            result.add ' '
            result.addRange(raw, k, le2)
            k = e2 + 1
          result = result.strip; return
    i = e + 1

proc looksLikeMail(s: string; start = 0): bool =
  ## Whether `s` from `start` begins as a message does: header fields, two of
  ## them ones that messages have (From, Date, Subject...), before an empty
  ## line or the end of `s`.
  var i = start
  if s.continuesWith("\xEF\xBB\xBF", i): i += 3
  var fields, strong = 0
  while i < s.len:
    var e = s.find('\n', i)
    let complete = e >= 0
    if e < 0: e = s.len
    var le = e
    if le > i and s[le - 1] == '\r': dec le
    if le == i: break
    if s[i] in {' ', '\t'}:
      if fields == 0: return false
    else:
      var c = i
      while c < le and s[c] != ':' and ord(s[c]) in 33 .. 126: inc c
      if c == i or c >= le or s[c] != ':':
        if not complete: break                        # (a line cut where `s` ends)
        return false
      inc fields
      if s[i ..< c].toLowerAscii in StrongFields: inc strong
    i = e + 1
  strong >= 2

proc fromLine(line: string): tuple[ok: bool, date: float] =
  ## Whether `line` is an mbox "From " line ("From sender Mon Nov  3 14:05:09
  ## 2025": a sender, then a time and a year), and the date in it (0 when it
  ## is not one).
  if not line.startsWith("From "): return
  let rest = line[5 .. ^1].strip
  var sp = 0
  while sp < rest.len and rest[sp] notin {' ', '\t'}: inc sp
  if sp == 0 or sp >= rest.len: return
  let d = rest[sp .. ^1].strip
  var time, year = false
  for k in 0 ..< d.len:
    if d[k] == ':' and k > 0 and d[k - 1] in Digits and k + 1 < d.len and d[k + 1] in Digits:
      time = true
    if k + 4 <= d.len and (k == 0 or d[k - 1] notin Digits) and
       (k + 4 == d.len or d[k + 4] notin Digits) and d[k + 2] in Digits and d[k + 3] in Digits and
       ((d[k] == '1' and d[k + 1] == '9') or (d[k] == '2' and d[k + 1] in {'0', '1'})):
      year = true
  if time and year: (true, parseMailDate(d)) else: (false, 0.0)

proc mozillaStatus(raw: string): int =
  ## Thunderbird's X-Mozilla-Status flags; -1 when there are none.
  let v = headerField(raw, "X-Mozilla-Status")
  if v.len == 0: return -1
  try: parseHexInt(v) except ValueError: -1

proc mailOf(raw: string): ImportedMail =
  ## `raw` with the flags its headers keep (Status and X-Status of Unix mail,
  ## Thunderbird's X-Mozilla-Status, Gmail's X-Gmail-Labels) and its date.
  result.raw = raw
  let st = headerField(raw, "Status")
  if 'R' in st: result.read = true
  let xs = headerField(raw, "X-Status")
  if 'F' in xs: result.flagged = true
  if 'A' in xs: result.replied = true
  let moz = mozillaStatus(raw)
  if moz >= 0:
    result.read = (moz and 1) != 0
    result.replied = result.replied or (moz and 2) != 0
    result.flagged = result.flagged or (moz and 4) != 0
  let labels = headerField(raw, "X-Gmail-Labels")
  if labels.len > 0:
    var unread = false
    for l in labels.split(','):
      case l.strip(chars = Whitespace + {'"'}).toLowerAscii
      of "unread": unread = true
      of "starred": result.flagged = true
      else: discard
    result.read = not unread
  result.date = parseMailDate(headerField(raw, "Date"))

proc maildirFlags(name: string; m: var ImportedMail) =
  ## The flags of a Maildir file name ("...:2,FRS"; "!" or ";" for ":" where
  ## the system will not have it).
  for sep in [":2,", "!2,", ";2,"]:
    let k = name.rfind(sep)
    if k >= 0:
      for c in name[k + 3 .. ^1]:
        case c
        of 'S': m.read = true
        of 'F': m.flagged = true
        of 'R': m.replied = true
        else: discard
      return

# ---- Outlook Express 5 and 6 (.dbx) ------------------------------------------------------------

proc dbxType(head: string): int =
  ## The byte that tells the files of an Outlook Express 5/6 store apart
  ## (0xC5 a folder of messages, 0xC6 Folders.dbx); -1 for another file.
  if head.len < 16: return -1
  for i in 0 ..< 16:
    if i != 4 and head[i] != OeMagic[i]: return -1
  ord(head[4])

proc walkDbxTree(s: var Store; node: int64; depth, limit: int; seen: var HashSet[int64];
                 res: var seq[int64]) =
  if node <= 0 or depth > 40 or res.len >= limit or node in seen: return
  seen.incl node
  let b = s.readAt(node, DbxNodeSize)
  if b.len < 24 or le32(b, 0) != node: return       # not a node: left out with what hangs from it
  walkDbxTree(s, le32(b, 8), depth + 1, limit, seen, res)
  let n = min(int((le32(b, 16) shr 8) and 0xFF), DbxNodeEntries)
  for i in 0 ..< n:
    let at = 24 + 12 * i
    if at + 12 > b.len or res.len >= limit: break
    let v = le32(b, at)
    if v > 0: res.add v
    walkDbxTree(s, le32(b, at + 4), depth + 1, limit, seen, res)

proc dbxTree(s: var Store; root: int64): seq[int64] =
  ## The values the index tree at `root` holds, in order (each node read once).
  var seen = initHashSet[int64]()
  walkDbxTree(s, root, 0, int(min(s.size div 12 + 1, 10_000_000)), seen, result)

type DbxInfo = object
  ## A message's or a folder's info object: attribute entries, then their data.
  body: string
  count: int

proc dbxInfo(s: var Store; p: int64): DbxInfo =
  let h = s.readAt(p, 12)
  if h.len < 12 or le32(h, 0) != p: return
  let n = le32(h, 4)
  if n <= 0 or n > DbxMaxInfo: return
  result.body = s.readAt(p + 12, int(n))
  result.count = min(ord(h[10]), result.body.len div 4)

proc attr(info: DbxInfo; id: int): tuple[found, direct: bool, value: int] =
  for i in 0 ..< info.count:
    let e = le32(info.body, 4 * i)
    if int(e and 0x7F) == id: return (true, (e and 0x80) != 0, int(e shr 8))

proc intAttr(info: DbxInfo; id: int): int64 =
  let a = info.attr(id)
  if not a.found: 0'i64
  elif a.direct: int64(a.value)
  else: le32(info.body, 4 * info.count + a.value)

proc timeAttr(info: DbxInfo; id: int): int64 =
  let a = info.attr(id)
  if a.found and not a.direct: le64(info.body, 4 * info.count + a.value) else: 0'i64

proc strAttr(info: DbxInfo; id: int): string =
  let a = info.attr(id)
  if not a.found or a.direct: return
  var i = 4 * info.count + a.value
  while i < info.body.len and info.body[i] != '\0' and result.len < 1024:
    result.add info.body[i]
    inc i

proc dbxMessage(s: var Store; start: int64): string =
  ## The message whose first block is at `start`: the data of each block of
  ## its chain (a header of itself, its size, the length used, the next
  ## block), until the chain ends, loops, leaves the file or meets a block
  ## that is not one.
  var p = start
  var seen = initHashSet[int64]()
  while p > 0 and p notin seen and result.len < MaxMessage:
    seen.incl p
    let b = s.readAt(p, 16 + DbxBlockData)
    if b.len < 16 or le32(b, 0) != p: break
    let n = int(le16(b, 8))
    if n > max(le32(b, 4), DbxBlockData): break
    if n > 0:
      if 16 + n <= b.len:
        result.addRange(b, 16, 16 + n)
      else:
        let d = s.readAt(p + 16, n)
        result.add d
        if d.len < n: break                         # (the file ends)
    p = le32(b, 12)

proc dbxLostChains(s: var Store; known: HashSet[int64]): seq[int64] =
  ## The first blocks of the message chains in the file that no index entry
  ## leads to, in file order (when the index is damaged).
  var blocks = initTable[int64, int64]()            # block -> the next
  var order: seq[int64]
  var pos = int64(DbxHeaderSize)
  const Chunk = 1 shl 20
  while pos + 16 <= s.size:
    let buf = s.readAt(pos, Chunk + 16)
    if buf.len < 16: break
    var i = 0
    while i < Chunk and i + 16 <= buf.len:
      let at = pos + i
      if le32(buf, i) == at and le32(buf, i + 4) == DbxBlockData:
        let n = le16(buf, i + 8)
        let nx = le32(buf, i + 12)
        if n >= 1 and n <= DbxBlockData and nx != at and
           (nx == 0 or ((nx and 3) == 0 and nx >= DbxHeaderSize and nx + 16 <= s.size)):
          blocks[at] = nx
          order.add at
          i += 16 + DbxBlockData
          continue
      i += 4
    pos += i
  var taken = initHashSet[int64]()                  # the blocks of the messages already read
  for a in known:
    var b = a
    while b in blocks and b notin taken:
      taken.incl b
      b = blocks[b]
  var pointed = initHashSet[int64]()
  for b, nx in blocks:
    if nx != 0: pointed.incl nx
  for b in order:
    if b notin taken and b notin pointed: result.add b

type DbxItem = object
  address: int64
  flags: int64
  received: float
  lost: bool          ## found by its blocks, not in the index

proc dbxItems(s: var Store): seq[DbxItem] =
  ## The messages of an Outlook Express 5/6 folder file: those its index
  ## lists, and -- when it lists fewer than the file header counts -- those
  ## found by their blocks.
  let head = s.readAt(0, 0xF0)
  if dbxType(head) != DbxMessages: return
  var infos = 0
  var seenInfo = initHashSet[int64]()
  var used = initHashSet[int64]()
  for v in dbxTree(s, le32(head, 0xE4)):
    if v in seenInfo: continue
    seenInfo.incl v
    let info = s.dbxInfo(v)
    if info.count == 0: continue
    inc infos
    let a = info.intAttr(4)                         # (0: only its headers were fetched)
    if a <= 0 or a in used: continue
    used.incl a
    var t = info.timeAttr(0x12)                     # received, else sent
    if t <= 0: t = info.timeAttr(0x02)
    result.add DbxItem(address: a, flags: info.intAttr(1), received: fileTimeToEpoch(t))
  if infos < le32(head, 0xC4):
    for a in dbxLostChains(s, used): result.add DbxItem(address: a, lost: true)

type DbxFolderInfo = object
  id, parent, special: int64
  name, file, account: string

proc readDbxFolders(path: string): seq[DbxFolderInfo] =
  ## The folders a Folders.dbx lists.
  var s = openStore(path)
  defer: s.close()
  let head = s.readAt(0, 0xF0)
  if dbxType(head) != DbxFolders: return
  var seen = initHashSet[int64]()
  for v in dbxTree(s, le32(head, 0xE4)):
    if v in seen: continue
    seen.incl v
    let info = s.dbxInfo(v)
    if info.count == 0: continue
    result.add DbxFolderInfo(id: info.intAttr(0), parent: info.intAttr(1), name: info.strAttr(2),
                             file: info.strAttr(3), account: info.strAttr(5),
                             special: info.intAttr(9))

proc systemCodepage(): string =
  ## The system's ANSI code page (Windows), "" elsewhere.
  when defined(windows):
    let cp = GetACP()
    if cp == 65001: "utf-8" else: "cp" & $cp
  else: ""

proc lastPart(s: string): string =
  let k = max(s.rfind('/'), s.rfind('\\'))
  if k >= 0: s[k + 1 .. ^1] else: s

proc lowerName(s: string): string = unicode.toLower(s)

proc dirFiles(dir: string): Table[string, string] =
  ## The files in `dir` by their names in lower case.
  try:
    for kind, p in walkDir(dir):
      if kind in {pcFile, pcLinkToFile}: result[lowerName(p.extractFilename)] = p
  except OSError: discard

proc storeCodepage(list: seq[DbxFolderInfo]; files: Table[string, string]; given: string): string =
  ## The code page of a store's names: `given`, else the one under which the
  ## file names Folders.dbx keeps are the names on the disk, else the system's.
  if given.len > 0: return given
  let sys = systemCodepage()
  var cands: seq[string]
  if sys.len > 0: cands.add sys
  cands.add CodepageGuesses
  for f in list:
    if f.file.isAscii: continue
    for cp in cands:
      if lowerName(lastPart(toUtf8(f.file, cp))) in files: return cp
  if sys.len > 0: sys else: "windows-1252"

proc cleanFolderName(s: string): string =
  for c in s:
    if c in {'/', '\\'}: result.add '-'
    elif ord(c) >= 32 and c != '\x7F': result.add c
  result = result.strip

proc stem(name: string): string =
  let dot = name.rfind('.')
  if dot > 0: name[0 ..< dot] else: name

proc dbxFolderPath(list: seq[DbxFolderInfo]; byId: Table[int64, int]; k: int;
                   cp, fileName: string): string =
  ## Folder `k`'s path in its store: "Inbox", "Projects/Retro" under Local
  ## Folders, "Account/Folder" under another account; the special folders by
  ## their English names.
  var parts: seq[string]
  var cur = k
  var visited = initHashSet[int]()
  while cur notin visited and parts.len < 64:
    visited.incl cur
    let f = list[cur]
    if f.account == "LocalStore": break               # "Local Folders"
    let p = byId.getOrDefault(f.parent, -1)
    if p < 0 or p == cur: break                       # the root, "Outlook Express"
    let top = list[p].account == "LocalStore"
    var name = if top and f.special in 1'i64 .. 5'i64: SpecialFolders[int(f.special) - 1]
               else: cleanFolderName(toUtf8(f.name, cp))
    if name.len == 0: name = (if cur == k: stem(fileName) else: "Folder")
    parts.add name
    cur = p
  if parts.len == 0: return stem(fileName)
  parts.reverse
  parts.join("/")

type Source = object
  ## A file to bring in, what it is and the folder its messages go to.
  path, kind, folder: string
  size: int64

proc sizeOf(path: string): int64 =
  try: getFileSize(path) except OSError, IOError: 0'i64

proc storeSources(foldersDbx, codepage: string): seq[Source] =
  ## The folder files of the Outlook Express 5/6 store whose list is `foldersDbx`.
  let dir = foldersDbx.parentDir
  let list = readDbxFolders(foldersDbx)
  let files = dirFiles(dir)
  let cp = storeCodepage(list, files, codepage)
  var byId = initTable[int64, int]()
  for k, f in list:
    if f.id notin byId: byId[f.id] = k
  var seen = initHashSet[string]()
  for k, f in list:
    if f.file.len == 0: continue
    let name = lastPart(toUtf8(f.file, cp))
    let p = files.getOrDefault(lowerName(name))
    if p.len == 0 or p in seen or dbxType(headOf(p, 16)) != DbxMessages: continue
    seen.incl p
    result.add Source(path: p, kind: "dbx", folder: dbxFolderPath(list, byId, k, cp, name),
                      size: sizeOf(p))

proc foldersDbxIn(dir: string): string =
  ## The Folders.dbx in `dir` ("" when there is none).
  for name, p in dirFiles(dir):
    if name == "folders.dbx" and dbxType(headOf(p, 16)) == DbxFolders: return p
  for name, p in dirFiles(dir):
    if name.endsWith(".dbx") and dbxType(headOf(p, 16)) == DbxFolders: return p

# ---- Outlook Express 4 (.mbx) ------------------------------------------------------------------

proc isMbx(head: string): bool =
  head.len >= 8 and head.startsWith("JMF6") and le32(head, 4) == 0x00010003

proc mbxMarker(s: var Store; start: int64): int64 =
  ## Where the next message record starts from `start`; -1 when none does.
  var pos = start
  const Chunk = 1 shl 16
  while pos + 4 <= s.size:
    let buf = s.readAt(pos, Chunk + 3)
    if buf.len < 4: break
    let k = buf.find("\x00\x7F\x00\x7F")
    if k >= 0: return pos + k
    pos += max(1, buf.len - 3)
  -1

type MbxRecord = tuple[pos, len: int64]

proc mbxFromIdx(s: var Store; idxPath: string; ok: var bool): seq[MbxRecord] =
  ## The messages the .idx beside a mailbox lists (those it marks deleted
  ## left out); `ok` false when it is missing or does not agree with the file.
  ok = false
  var x = openStore(idxPath)
  if not x.isOpen: return
  defer: x.close()
  let h = x.readAt(0, 80)
  if h.len < 80 or not h.startsWith("JMF9") or le32(h, 4) != 0x00010004: return
  let count = le32(h, 8)
  if count > x.size div 28: return
  var p = 80'i64
  for _ in 0 ..< int(count):
    let e = x.readAt(p, 28)
    if e.len < 28 or le32(e, 12) != p: return         # (each entry gives where it is)
    let elen = le32(e, 16)
    if elen < 28 or p + elen > x.size: return
    if (le32(e, 0) and 1) == 0:                        # (1: deleted)
      let off = le32(e, 20)
      let r = s.readAt(off, 16)
      if r.len < 16 or le32(r, 0) != MbxMarker: return
      result.add (off + 16, min(min(le32(r, 12), s.size - off - 16), int64(MaxMessage)))
    p += elen
  ok = true

proc mbxScan(s: var Store): seq[MbxRecord] =
  ## Every message record in the file: a marker, a number, the record's size,
  ## the text's length, the text. Where the sizes do not agree the text runs
  ## to the next marker.
  var pos = int64(MbxHeaderSize)
  while pos + 16 <= s.size:
    let h = s.readAt(pos, 16)
    if h.len < 16: break
    if le32(h, 0) != MbxMarker:
      pos = s.mbxMarker(pos + 1)
      if pos < 0: break
      continue
    let rec = le32(h, 8)
    let body = le32(h, 12)
    var stop = pos + 16 + body
    var next = pos + rec
    if rec < 16 + body or rec > 16 + body + 4096 or stop > s.size:
      let m = s.mbxMarker(pos + 16)
      next = if m < 0: s.size else: m
      stop = next
    if stop > pos + 16: result.add (pos + 16, min(stop - pos - 16, int64(MaxMessage)))
    pos = next

proc idxBeside(path: string): string =
  for ext in [".idx", ".IDX", ".Idx"]:
    let p = path.changeFileExt(ext)
    if fileExists(p): return p

proc mbxRecords(s: var Store; path: string): seq[MbxRecord] =
  ## The messages of an Outlook Express 4 mailbox: as its .idx lists them
  ## when it has one that agrees with it, else every record in it.
  if not isMbx(s.readAt(0, 8)): return
  var ok = false
  let idx = idxBeside(path)
  if idx.len > 0: result = mbxFromIdx(s, idx, ok)
  if not ok: result = mbxScan(s)

proc mbxMessage(s: var Store; r: MbxRecord): string =
  result = s.readAt(r.pos, int(r.len))
  var n = result.len
  while n > 0 and result[n - 1] == '\0': dec n
  result.setLen(n)

# ---- mbox --------------------------------------------------------------------------------------

type LineReader = object
  f: File
  buf: string
  pos, fill: int
  done: bool
  offset: int64       ## where the next line starts in the file

proc nextLine(r: var LineReader; line: var string; cap: int): bool =
  ## The next line with its line break; false at the end of the file. What
  ## a line has past `cap` bytes is dropped.
  line.setLen(0)
  var any = false
  while true:
    if r.pos >= r.fill:
      if r.done: return any
      try: r.fill = r.f.readBuffer(addr r.buf[0], r.buf.len)
      except IOError: r.fill = 0
      r.pos = 0
      if r.fill <= 0:
        r.fill = 0
        r.done = true
        return any
    any = true
    let nl = r.buf.find('\n', r.pos, r.fill - 1)
    let stop = if nl >= 0: nl + 1 else: r.fill
    let take = min(stop, r.pos + max(0, cap - line.len))
    line.addRange(r.buf, r.pos, take)
    r.offset += stop - r.pos
    r.pos = stop
    if nl >= 0: return true

proc blank(s: string): bool =
  for c in s:
    if c notin Whitespace: return false
  true

proc finishMbox(s: var string) =
  ## Drops the empty line an mbox puts after each message.
  if s.endsWith("\r\n\r\n") or s.endsWith("\n\r\n"): s.setLen(s.len - 2)
  elif s.endsWith("\n\n"): s.setLen(s.len - 1)

iterator mboxItems(path: string): tuple[raw: string, date: float, pos: int64] =
  ## The messages of the mbox file at `path`, the date of each one's "From "
  ## line, and where it ends in the file.
  var f: File
  var opened = false
  try: opened = open(f, path)
  except IOError, OSError: opened = false
  if opened:
    try:
      var r = LineReader(f: f, buf: newString(1 shl 20))
      var cur = ""
      var date = 0.0
      var line = ""
      var start = true                               # (no line but empty ones yet)
      while r.nextLine(line, MaxMessage):
        var sep = false
        var d = 0.0
        if line.startsWith("From "):
          let fl = fromLine(line)
          if fl.ok or start: (sep = true; d = fl.date)
        if sep:
          if not cur.blank:
            finishMbox(cur)
            yield (cur, date, r.offset - line.len)
          cur = ""
          date = d
        else:
          if line.len > 1 and line[0] == '>':
            var k = 1
            while k < line.len and line[k] == '>': inc k
            if line.continuesWith("From ", k): line.delete(0 .. 0)   # (mboxrd and mboxo quoting)
          if cur.len + line.len <= MaxMessage: cur.add line
        if not line.blank: start = false
      if not cur.blank:
        finishMbox(cur)
        yield (cur, date, r.offset)
    finally:
      close(f)

iterator readMbox*(path: string): string =
  ## The messages of the mbox file at `path` -- mboxrd or mboxo, LF or CRLF
  ## lines -- without their "From " lines, ">From " unquoted. A file that
  ## cannot be read gives none.
  for it in mboxItems(path): yield it.raw

proc asctime(t: float): string =
  ## "Mon Nov  3 14:05:09 2025", in UTC.
  let dt = fromUnix(int64(clamp(t, 0.0, 253402300799.0))).utc
  dt.format("ddd MMM ") & align($dt.monthday, 2) & dt.format(" HH:mm:ss yyyy")

proc envelopeSender(raw: string): string =
  for field in ["Return-Path", "From"]:
    for a in parseAddresses(headerField(raw, field)):
      var ok = a.email.len > 0
      for c in a.email:
        if ord(c) <= 32 or ord(c) >= 127: (ok = false; break)
      if ok: return a.email
  "MAILER-DAEMON"

proc addMboxMessage*(f: File; raw: string) =
  ## Writes the message `raw` to the mbox file `f` (open to write or to
  ## append): a "From " line, its lines ended by LF with those starting
  ## ">...From " given one more ">" (mboxrd), and an empty line.
  var t = parseMailDate(headerField(raw, "Date"))
  if t <= 0: t = epochTime()
  var s = newStringOfCap(raw.len + raw.len div 50 + 100)
  s.add "From " & envelopeSender(raw) & " " & asctime(t) & "\n"
  var i = 0
  while i < raw.len:
    var e = raw.find('\n', i)
    if e < 0: e = raw.len
    var le = e
    if le > i and raw[le - 1] == '\r': dec le
    var k = i
    while k < le and raw[k] == '>': inc k
    if raw.continuesWith("From ", k): s.add '>'
    s.addRange(raw, i, le)
    s.add '\n'
    i = e + 1
  s.add '\n'
  f.write(s)

proc writeMbox*(path: string; raws: openArray[string]) =
  ## Writes the messages `raws` as the mbox file `path` (mboxrd, LF lines),
  ## replacing it. Raises IOError when it cannot be written.
  var f = open(path, fmWrite)
  defer: f.close()
  for r in raws: addMboxMessage(f, r)

# ---- .eml --------------------------------------------------------------------------------------

proc readEml*(path: string): ImportedMail =
  ## The .eml file at `path` (a leading mbox "From " line and byte order
  ## mark dropped): its flags from its Status, X-Mozilla-Status or Gmail
  ## headers or its Maildir name, its date from its Date header, else the
  ## file's time. An empty `raw` when it cannot be read.
  var raw = ""
  var f: File
  try:
    if not open(f, path): return
    try:
      let n = int(min(getFileSize(f), int64(MaxMessage)))
      raw = newString(n)
      if n > 0: raw.setLen(max(0, f.readBuffer(addr raw[0], n)))
    finally:
      close(f)
  except IOError, OSError:
    return
  if raw.startsWith("\xEF\xBB\xBF"): raw.delete(0 .. 2)
  if raw.startsWith("From "):
    let nl = raw.find('\n')
    if nl > 0 and looksLikeMail(raw[nl + 1 ..< min(raw.len, nl + 1 + 4096)]):
      raw.delete(0 .. nl)
  result = mailOf(raw)
  maildirFlags(path.extractFilename, result)
  if result.date == 0:
    try: result.date = getLastModificationTime(path).toUnixFloat
    except OSError: discard

proc writeEml*(path: string; raw: string) =
  ## Writes the message `raw` as the .eml file `path`, its bytes as they are
  ## (its folder made when missing). Raises IOError or OSError when it cannot.
  let dir = path.parentDir
  if dir.len > 0 and not dirExists(dir): createDir(dir)
  writeFile(path, raw)

proc emlFileName*(raw: string): string =
  ## A file name to save the message `raw` as: "2025-11-03 Subject.eml" (the
  ## date from its Date header, when it has one), safe on every system.
  let t = parseMailDate(headerField(raw, "Date"))
  if t > 0: result = fromUnix(int64(t)).utc.format("yyyy-MM-dd") & " "
  var subj = ""
  for c in decodeWords(headerField(raw, "Subject")):
    if ord(c) < 32 or c in {'/', '\\', ':', '*', '?', '"', '<', '>', '|', '\x7F'}: subj.add '_'
    else: subj.add c
  subj = subj.strip(chars = Whitespace + {'.'})
  if subj.len > 100:
    var n = 100
    while n > 0 and (ord(subj[n]) and 0xC0) == 0x80: dec n    # (a whole character)
    subj.setLen(n)
    subj = subj.strip
  result.add(if subj.len > 0: subj else: "(no subject)")
  result.add ".eml"

# ---- what a file is, and the plan of an import -------------------------------------------------

proc kindOfHead(head, path: string): string =
  let t = dbxType(head)
  if t == DbxMessages or t == DbxFolders: return "dbx"
  if isMbx(head): return "mbx"
  let ext = path.splitFile.ext.toLowerAscii
  let i = if head.startsWith("\xEF\xBB\xBF"): 3 else: 0
  if head.continuesWith("From ", i):
    let nl = head.find('\n', i)
    let line = if nl < 0: head[i .. ^1] else: head[i ..< nl]
    if fromLine(line).ok or (nl >= 0 and looksLikeMail(head, nl + 1)):
      return (if ext == ".eml": "eml" else: "mbox")
  if looksLikeMail(head, i):
    return (if ext in [".mbox", ".mbx"]: "mbox" else: "eml")
  ""

proc fileKind(path: string): string =
  if path.splitFile.ext.toLowerAscii in NotMail: return ""
  kindOfHead(headOf(path), path)

proc importKind*(path: string): string =
  ## What `path` holds that can be brought in, told by its content (the name
  ## only tells a one-message mbox from an .eml): "dbx" (an Outlook Express
  ## 5/6 folder, or its Folders.dbx), "mbx" (Outlook Express 4), "mbox",
  ## "eml", "folder" (a folder with any of these in it, at any depth), or ""
  ## when it is none of them.
  try:
    if dirExists(path):
      for f in walkDirRec(path):
        if fileKind(f).len > 0: return "folder"
    elif fileExists(path):
      return kindOfHead(headOf(path), path)
  except OSError, IOError: discard
  ""

proc mailboxName(path: string): string =
  ## A mailbox file's folder name: its name without .mbox, .mbx or .dbx;
  ## Apple Mail's "Inbox.mbox/mbox" is "Inbox".
  let (dir, name, ext) = splitFile(path)
  if name & ext == "mbox" and dir.toLowerAscii.endsWith(".mbox"): return stem(dir.lastPathPart)
  if ext.toLowerAscii in [".mbox", ".mbx", ".dbx", ".mbs"]: name else: name & ext

proc relParts(root, dir: string): seq[string] =
  ## `dir`'s path from `root`, Thunderbird's ".sbd" and Apple Mail's ".mbox"
  ## taken off the folder names.
  if dir == root or not dir.isRelativeTo(root): return
  for p in relativePath(dir, root).split({'/', '\\'}):
    if p.len == 0 or p == ".": continue
    var q = p
    for suf in [".sbd", ".mbox"]:
      if q.len > suf.len and q.toLowerAscii.endsWith(suf): q.setLen(q.len - suf.len)
    result.add q

proc isMaildir(dir: string): bool =
  dirExists(dir / "cur") and dirExists(dir / "new")

proc emlFolder(root, dir: string): string =
  ## The folder the .eml files in `dir` go to: `dir`'s path from `root` (the
  ## name of `root` for those at the top). A Maildir's "cur" and "new" are
  ## its folder, the top Maildir is the Inbox and Maildir++'s ".Work.Retro"
  ## is "Work/Retro".
  var d = dir
  let maildir = d.lastPathPart in ["cur", "new"] and isMaildir(d.parentDir)
  if maildir: d = d.parentDir
  var parts: seq[string]
  for p in relParts(root, d):
    if maildir and p.len > 1 and p[0] == '.':
      for q in p[1 .. ^1].split('.'):
        if q.len > 0: parts.add q
    else: parts.add p
  if parts.len > 0: return parts.join("/")
  if maildir:
    let n = d.lastPathPart
    if n.len > 1 and n[0] == '.': return n[1 .. ^1].replace('.', '/')
    return "Inbox"
  root.lastPathPart

proc joinFolder(parts: seq[string]; name: string): string =
  (parts & @[name]).join("/")

proc importPlan(path, codepage: string): seq[Source] =
  ## The files to read for an import of `path`, in order, with their folders.
  try:
    let path = absolutePath(path).normalizedPath
    if fileExists(path):
      let kind = kindOfHead(headOf(path), path)
      let size = sizeOf(path)
      case kind
      of "dbx":
        if dbxType(headOf(path, 16)) == DbxFolders: return storeSources(path, codepage)
        let fl = foldersDbxIn(path.parentDir)
        if fl.len > 0:
          for s in storeSources(fl, codepage):
            if sameFile(s.path, path): return @[s]
        return @[Source(path: path, kind: kind, folder: mailboxName(path), size: size)]
      of "mbx", "mbox": return @[Source(path: path, kind: kind, folder: mailboxName(path), size: size)]
      of "eml": return @[Source(path: path, kind: kind, size: size)]
      else: return
    if not dirExists(path): return
    let root = absolutePath(path).normalizedPath
    var files: seq[string]
    for f in walkDirRec(root): files.add f
    files.sort(proc (a, b: string): int =                # (a folder's files before its folders')
      cmp((a.parentDir, a.extractFilename), (b.parentDir, b.extractFilename)))
    var dirs: seq[string]
    var byDir = initTable[string, seq[string]]()
    for f in files:
      let d = f.parentDir
      if d notin byDir: dirs.add d
      byDir.mgetOrPut(d, @[]).add f
    for d in dirs:
      if d.lastPathPart == "tmp" and isMaildir(d.parentDir): continue   # (mail still arriving)
      var claimed = initHashSet[string]()
      let fl = foldersDbxIn(d)
      if fl.len > 0:
        claimed.incl fl
        for s in storeSources(fl, codepage):
          claimed.incl s.path
          result.add s
      for f in byDir[d]:
        if f in claimed: continue
        let kind = fileKind(f)
        var folder = ""
        case kind
        of "dbx":
          if dbxType(headOf(f, 16)) != DbxMessages: continue
          folder = joinFolder(relParts(root, d), mailboxName(f))
        of "mbx":
          folder = joinFolder(relParts(root, d), mailboxName(f))
        of "mbox":
          if f.extractFilename == "mbox" and d.toLowerAscii.endsWith(".mbox"):
            folder = joinFolder(relParts(root, d.parentDir), mailboxName(f))
          else:
            folder = joinFolder(relParts(root, d), mailboxName(f))
        of "eml":
          folder = emlFolder(root, d)
        else: continue
        result.add Source(path: f, kind: kind, folder: folder, size: sizeOf(f))
  except OSError, IOError: discard

# ---- bringing mail in --------------------------------------------------------------------------

iterator importMail*(path: string; progress: ImportProgress = nil; codepage = ""): ImportedMail =
  ## Every message in the file or folder `path`: an Outlook Express 5/6 store
  ## (its Folders.dbx gives the folders' names and places; special folders
  ## by their English names), a folder of it, an Outlook Express 4 mailbox
  ## (deleted messages left out when its .idx is there), an mbox file
  ## (Thunderbird's deleted ones left out), an .eml file; in a folder, all of
  ## them at any depth, the folders named after the files and the folders
  ## they are in. `progress` is told how far it has come after each message.
  ## `codepage` is that of the Windows that made an Outlook Express store
  ## ("windows-1256"); by default it is found from the store's file names.
  let plan = importPlan(path, codepage)
  var total = 0'i64
  for s in plan: total += s.size
  let all = int(min(total, int64(high(int))))
  var base, done = 0'i64
  var stop = false
  template tell(at: int64) =
    if progress != nil:
      done = max(done, min(at, total))
      if not progress(int(min(done, int64(all))), all): stop = true
  for src in plan:
    if stop: break
    case src.kind
    of "dbx":
      var st = openStore(src.path)
      try:
        let items = dbxItems(st)
        for k, it in items:
          let raw = dbxMessage(st, it.address)
          if raw.len > 0 and (not it.lost or looksLikeMail(raw)):
            var m = mailOf(raw)
            m.folder = src.folder
            if not it.lost:
              m.read = (it.flags and 0x80) != 0
              m.flagged = (it.flags and 0x20) != 0
              m.replied = (it.flags and 0x80000) != 0
              if it.received > 0: m.date = it.received
            yield m
          tell(base + src.size * (k + 1) div items.len)
          if stop: break
      finally:
        st.close()
    of "mbx":
      var st = openStore(src.path)
      try:
        for r in mbxRecords(st, src.path):
          let raw = mbxMessage(st, r)
          if raw.len > 0:
            var m = mailOf(raw)
            m.folder = src.folder
            yield m
          tell(base + min(r.pos + r.len, src.size))
          if stop: break
      finally:
        st.close()
    of "mbox":
      for it in mboxItems(src.path):
        if (max(mozillaStatus(it.raw), 0) and 8) == 0:     # (8: deleted in Thunderbird)
          var m = mailOf(it.raw)
          if m.date == 0 and it.date > 0: m.date = it.date
          m.folder = src.folder
          yield m
        tell(base + min(it.pos, src.size))
        if stop: break
    of "eml":
      var m = readEml(src.path)
      if m.raw.len > 0:
        m.folder = src.folder
        yield m
      tell(base + src.size)
    else: discard
    base += src.size
  if progress != nil and not stop and plan.len > 0: discard progress(all, all)

# ---- where Outlook Express kept its mail -------------------------------------------------------

when defined(windows):
  proc expandVars(s: string): string =
    ## "%USERPROFILE%\Local Settings" with the variables put in.
    var i = 0
    while i < s.len:
      if s[i] == '%':
        let e = s.find('%', i + 1)
        if e > i + 1:
          let v = getEnv(s[i + 1 ..< e])
          if v.len > 0:
            result.add v
            i = e + 1
            continue
      result.add s[i]
      inc i

  proc holdsMail(dir: string): bool =
    try:
      for kind, p in walkDir(dir):
        if kind in {pcFile, pcLinkToFile} and p.splitFile.ext.toLowerAscii in [".dbx", ".mbx"]:
          return true
    except OSError: discard

proc oeStoreFolders*(): seq[string] =
  ## Where Outlook Express kept its mail on this computer, when it is Windows:
  ## each identity's store (the "Store Root" the registry gives, and the
  ## `Identities\{GUID}\Microsoft\Outlook Express` folders under the local
  ## application data, as Vista and later and as XP keep them) and Outlook
  ## Express 4's Mail folder -- those that are there and hold mail. Empty on
  ## other systems.
  when defined(windows):
    var cands, guids: seq[string]
    let local = getEnv("LOCALAPPDATA")
    let appdata = getEnv("APPDATA")
    let profile = getEnv("USERPROFILE")
    let windir = getEnv("WINDIR")
    var roots: seq[string]
    if local.len > 0: roots.add local / "Identities"
    if profile.len > 0: roots.add profile / "Local Settings" / "Application Data" / "Identities"
    if appdata.len > 0: roots.add appdata / "Identities"
    if windir.len > 0: roots.add windir / "Application Data" / "Identities"
    for r in roots:
      try:
        for kind, d in walkDir(r):
          if kind in {pcDir, pcLinkToDir}:
            guids.add d.lastPathPart
            cands.add d / "Microsoft" / "Outlook Express"
      except OSError: discard
    for v in ["Default User ID", "Last User ID"]:
      try: guids.add getUnicodeValue("Identities", v, HKEY_CURRENT_USER).strip(chars = {'\0', ' '})
      except CatchableError: discard
    for g in guids:
      if g.len == 0: continue
      try:
        cands.add expandVars(getUnicodeValue("Identities\\" & g &
          "\\Software\\Microsoft\\Outlook Express\\5.0", "Store Root",
          HKEY_CURRENT_USER).strip(chars = {'\0', ' '}))
      except CatchableError: discard
    try:
      cands.add expandVars(getUnicodeValue("Software\\Microsoft\\Outlook Express\\Mail",
                                           "Store Root", HKEY_CURRENT_USER).strip(chars = {'\0', ' '}))
    except CatchableError: discard
    if appdata.len > 0: cands.add appdata / "Microsoft" / "Outlook Express" / "Mail"
    if windir.len > 0: cands.add windir / "Application Data" / "Microsoft" / "Outlook Express" / "Mail"
    var seen = initHashSet[string]()
    for c in cands:
      if c.len == 0: continue
      let key = c.normalizedPath.toLowerAscii.strip(leading = false, chars = {'\\', '/'})
      if key in seen: continue
      seen.incl key
      if dirExists(c) and holdsMail(c): result.add c.normalizedPath
  else:
    result = @[]

# Retro Mail: what the list shows (threads, groups, search), and the
# changes made from the window (applied here at once, queued for the
# server). Included by examples/mail.nim.
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

proc placeTitle(): string =
  case place.kind
  of plFolder:
    let f = folderOf(place.folder)
    if f.name.len > 0: f.name else: "Folder"
  of plTag: "Tag"
  of plSearch: (if place.tag.len > 0: place.tag else: "Search")
  of plFlagged: "Flagged"
  of plPinned: "Pinned"
  of plSnoozed: "Snoozed"
  of plUnread: "Unread Mail"
  of plAllInbox: "Inbox"

proc isInboxPlace(): bool =
  place.kind == plAllInbox or (place.kind == plFolder and folderOf(place.folder).role == "inbox")

proc searchWhere(q: string; args: var seq[DbValue]): string =
  ## A search typed in the box as SQL: from: to: has:attachment tag: is:
  ## before: after: in:, the rest words of the full-text index.
  var conds: seq[string]
  var words: seq[string]
  for raw in strutils.splitWhitespace(q):
    let k = raw.find(':')
    let key = if k > 0: raw[0 ..< k].toLowerAscii else: ""
    let val = if k > 0: raw[k + 1 .. ^1] else: raw
    case key
    of "from":
      conds.add "(from_email LIKE ? OR from_name LIKE ?)"
      args.add toDbValue("%" & val & "%")
      args.add toDbValue("%" & val & "%")
    of "to", "cc":
      conds.add "(to_list LIKE ? OR cc_list LIKE ?)"
      args.add toDbValue("%" & val & "%")
      args.add toDbValue("%" & val & "%")
    of "subject":
      conds.add "subject LIKE ?"
      args.add toDbValue("%" & val & "%")
    of "has":
      if val.toLowerAscii.startsWith("att"): conds.add "has_att = 1"
    of "tag":
      conds.add "instr(lower(tags), ?) > 0"
      args.add toDbValue("\n" & val.toLowerAscii & "\n")
    of "is":
      case val.toLowerAscii
      of "unread": conds.add "unread = 1"
      of "read": conds.add "unread = 0"
      of "flagged", "starred": conds.add "flagged = 1"
      of "pinned": conds.add "pinned = 1"
      of "important": conds.add "important = 1"
      else: discard
    of "before", "after":
      try:
        let t = parse(val, "yyyy-MM-dd", local()).toTime.toUnixFloat
        conds.add(if key == "before": "date < ?" else: "date >= ?")
        args.add toDbValue(t)
      except CatchableError: words.add val
    of "in":
      conds.add "folder IN (SELECT id FROM folders WHERE role = ? OR lower(name) = ?)"
      args.add toDbValue(val.toLowerAscii)
      args.add toDbValue(val.toLowerAscii)
    else:
      words.add raw
  if words.len > 0:
    conds.add "id IN (SELECT rowid FROM mfts WHERE mfts MATCH ?)"
    args.add toDbValue(ftsQuery(words.join(" "), fold = true))
  if conds.len == 0: "0" else: conds.join(" AND ")

proc loadMessages(): seq[Msg] =
  let now = epochTime()
  var args: seq[DbValue]
  if query.strip.len > 0:
    let w = searchWhere(query, args)
    result = store0.whereMessages(w, args, 1000)
    var have: HashSet[int]
    for m in result: have.incl m.id
    for id in serverIds:
      if id notin have:
        let m = store0.message(id)
        if m.id > 0: result.add m
    return
  case place.kind
  of plFolder: result = store0.folderMessages(place.folder)
  of plTag:
    args.add toDbValue("\n" & place.tag & "\n")
    result = store0.whereMessages("instr(tags, ?) > 0", args)
  of plFlagged: result = store0.whereMessages("flagged = 1", args)
  of plPinned: result = store0.whereMessages("pinned = 1", args)
  of plUnread:
    args.add toDbValue(now)
    result = store0.whereMessages("unread = 1 AND snooze <= ?", args)
  of plSnoozed:
    args.add toDbValue(now)
    result = store0.whereMessages("snooze > ?", args)
  of plAllInbox:
    args.add toDbValue(now)
    result = store0.whereMessages("folder IN (SELECT id FROM folders WHERE role = 'inbox') " &
                                  "AND snooze <= ?", args)
  of plSearch:
    # a Search Folder: its search run again
    let w = searchWhere(place.tag, args)
    result = store0.whereMessages(w, args, 1000)
  if isInboxPlace() and prefBool("focused", true) and query.len == 0:
    let want = focusTab == 0
    result.keepItIf(it.focused == want or it.pinned)
  if prefBool("hideRead", false) and query.len == 0 and place.kind != plSearch:
    # View > Current View > Hide Read Messages (the conversation open stays)
    var open: HashSet[int]
    for x in openMsgs: open.incl x.id
    result.keepItIf(it.unread or it.flagged or it.pinned or it.id in open)

proc addThreadMates(ms: var seq[Msg]) =
  ## The other messages of the threads shown (your replies in Sent Items),
  ## as Outlook's conversations have them.
  if not prefBool("threads", true) or ms.len == 0 or query.len > 0: return
  var have: HashSet[int]
  var byAcc = initTable[int, seq[string]]()
  var seen: HashSet[string]
  for m in ms:
    have.incl m.id
    let k = $m.account & "\t" & m.thread
    if k notin seen:
      seen.incl k
      byAcc.mgetOrPut(m.account, @[]).add m.thread
  for acc, threads in byAcc:
    var i = 0
    while i < threads.len:
      let chunk = threads[i ..< min(i + 300, threads.len)]
      var args = @[toDbValue(acc)]
      for t in chunk: args.add toDbValue(t)
      let marks = repeat("?, ", chunk.len - 1) & "?"
      for m in store0.whereMessages("account = ? AND thread IN (" & marks & ") AND folder NOT IN " &
                                    "(SELECT id FROM folders WHERE role IN ('trash', 'junk'))", args, 5000):
        if m.id notin have:
          have.incl m.id
          mates.incl m.id
          ms.add m
      i += 300

proc buildConvs(ms0: seq[Msg]) =
  var ms = ms0
  mates.clear()
  addThreadMates(ms)
  ms.sort(proc (a, b: Msg): int = cmp(b.date, a.date))
  convs.setLen(0)
  var at = initTable[string, int]()
  let threads = prefBool("threads", true)
  for m in ms:
    let key = if threads: $m.account & ":" & m.thread else: "m" & $m.id
    var i = at.getOrDefault(key, -1)
    if i < 0:
      i = convs.len
      at[key] = i
      convs.add Conv(key: key, account: m.account, thread: m.thread, subject: m.subject,
                     latest: m.date)
    var c = addr convs[i]
    c.msgs.add m
    if m.unread: inc c.unread
    if m.flagged: c.flagged = true
    if m.important: c.important = true
    if m.pinned: c.pinned = true
    if m.hasAtt: c.hasAtt = true
    c.size += m.size
    for t in m.tags:
      if t notin c.tags: c.tags.add t
  for c in convs.mitems:
    var seen: seq[string]
    for k in countdown(c.msgs.high, 0):
      let n = who(c.msgs[k])
      if n notin seen: seen.add n
    c.people = seen.join("; ")
    if c.msgs.len > 0:
      c.latest = c.msgs[0].date
      c.subject = c.msgs[^1].subject
      if c.subject.len == 0: c.subject = c.msgs[0].subject
  # the order the list is arranged by (View, Arrange By; or a column's header)
  let by = pref("sortBy", "date")
  let asc = prefBool("sortAsc", false)
  convs.sort(proc (a, b: Conv): int =
    if a.pinned != b.pinned: return (if a.pinned: -1 else: 1)
    var r = case by
      of "from": cmpIgnoreCase(a.people, b.people)
      of "subject": cmpIgnoreCase(a.subject.strip(chars = {' '}), b.subject)
      of "size": cmp(a.size, b.size)
      of "flag": cmp(ord(a.flagged), ord(b.flagged))
      of "unread": cmp(ord(a.unread > 0), ord(b.unread > 0))
      else: cmp(a.latest, b.latest)
    if r == 0: r = cmp(a.latest, b.latest)
    if asc: r else: -r)

proc sizeGroup(n: int): string =
  if n > 10_000_000: "Huge (over 10 MB)"
  elif n > 1_000_000: "Large (1 - 10 MB)"
  elif n > 100_000: "Medium (100 KB - 1 MB)"
  else: "Small (under 100 KB)"

proc buildRows() =
  rows.setLen(0)
  var last = ""
  let by = pref("sortBy", "date")
  let grouped = query.len == 0 and by in ["date", "from", "size", "flag"]
  for i, c in convs:
    if grouped:
      let g = if c.pinned: "Pinned"
              else:
                case by
                of "from": (if c.msgs.len > 0: who(c.msgs[^1]) else: "")
                of "size": sizeGroup(c.size)
                of "flag": (if c.flagged: "Flagged" else: "Not flagged")
                else: groupOf(c.latest)
      if g != last:
        rows.add LRow(group: g, conv: i, msg: -1)
        last = g
    rows.add LRow(conv: i, msg: -1)
    if c.msgs.len > 1 and c.key in expanded:
      for k in 0 ..< c.msgs.len: rows.add LRow(conv: i, msg: k)

proc rowKey(i: int): string =
  ## A row's identity across reloads: its conversation, or one message of it.
  if i < 0 or i >= rows.len or rows[i].group.len > 0: return ""
  let r = rows[i]
  if r.msg < 0: "c:" & convs[r.conv].key else: "m:" & $convs[r.conv].msgs[r.msg].id

proc rowMsgs(i: int): seq[Msg] =
  ## The messages a row stands for (a conversation: those in this folder).
  if i < 0 or i >= rows.len: return
  let r = rows[i]
  if r.group.len > 0: return
  if r.msg >= 0: @[convs[r.conv].msgs[r.msg]]
  else: convs[r.conv].msgs.filterIt(it.id notin mates)

proc reload() =
  ## Reads what the window shows from the store again (when it changed).
  if listVer == dataVer: return
  listVer = dataVer
  accountsC = store0.accounts()
  foldersC.clear()
  for a in accountsC: foldersC[a.id] = store0.folders(a.id)
  tagsC = store0.tags()
  buildConvs(loadMessages())
  buildRows()
  # rows selected together that are gone (moved, deleted) are no longer selected
  if multiSel.len > 0:
    var keep: OrderedSet[string]
    for i in 0 ..< rows.len:
      let k = rowKey(i)
      if k in multiSel: keep.incl k
    multiSel = if keep.len > 1: keep else: initOrderedSet[string]()
  # keep the selection on its conversation
  selRow = -1
  for i, r in rows:
    if r.group.len == 0 and r.msg < 0 and convs[r.conv].key == selKey:
      selRow = i
      break
  openVer = -1

proc selectedConv(): ptr Conv =
  if selRow >= 0 and selRow < rows.len and rows[selRow].group.len == 0:
    return addr convs[rows[selRow].conv]
  nil

proc multiSelecting(): bool = multiSel.len > 1
  ## More than one row is selected (Ctrl / Shift + click, Ctrl+A, a long press).

proc selectedMsgs(): seq[Msg] =
  ## What an action acts on: the selected rows' messages, else the selected
  ## message, or the whole conversation.
  if multiSel.len > 0:
    var seen: HashSet[int]
    for i in 0 ..< rows.len:
      if rowKey(i) in multiSel:
        for m in rowMsgs(i):
          if m.id notin seen:
            seen.incl m.id
            result.add m
    if result.len > 0 or multiSel.len > 1: return
  rowMsgs(selRow)

proc clearMulti() =
  multiSel.clear()
  selAnchor = -1

proc loadOpen() =
  ## The selected conversation for the reading pane (every folder, bodies).
  let c = selectedConv()
  if c == nil:
    openMsgs.setLen(0)
    openKey = ""
    return
  if openKey == c.key and openVer == dataVer: return
  let fresh = openKey != c.key
  openKey = c.key
  openVer = dataVer
  if prefBool("threads", true):
    openMsgs = store0.threadMessages(c.account, c.thread)
  else:
    openMsgs = @[store0.message(c.msgs[0].id)]
  if openMsgs.len == 0: openMsgs = @[store0.message(c.msgs[0].id)]
  if fresh:
    openShown = epochTime()
    openExpanded.clear()
    if openMsgs.len > 0: openExpanded.incl openMsgs[0].id
    for m in openMsgs:
      if m.unread: openExpanded.incl m.id
  for m in openMsgs:
    if m.id in openExpanded and m.bodyState == 0:
      store0.setBodyState(m.id, 1)
      link.cmds.send(SyncCmd(kind: scBody, id: m.id))

proc unreadAll(): int =
  for fs in foldersC.values:
    for f in fs:
      if f.role == "inbox": result += f.unread

# ---- pictures --------------------------------------------------------------------------

proc picturePath(key: string): string =
  mailDir() / "pictures" / ($hash(key)).replace("-", "m") & ".img"

proc pictureFromBytes(key, data: string): Bitmap =
  let p = picturePath(key)
  try:
    createDir(p.parentDir)
    if not fileExists(p): writeFile(p, data)
    result = loadPicture(p, 1600, 6000)
  except CatchableError: result = nil

proc readHtml(m: Msg): string =
  ## What the reading pane shows: the message's HTML, or its text alone
  ## (Options: "Read all messages in plain text").
  if not prefBool("plainRead", false): return m.html
  textToHtml(if m.text.len > 0: m.text else: htmlToText(m.html))

proc picturesTrusted(m: Msg): bool =
  ## Pictures from the web are shown: for this message, for everyone, or
  ## for its sender ("Always from ...").
  if m.id in allowPictures or prefInt("pictures", 0) == 1: return true
  let s = m.fromEmail.toLowerAscii
  s.len > 0 and s in pref("picSenders").splitLines

proc imagesFor(m: Msg): HtmlImageSource =
  let mid = m.id
  let allowed = picturesTrusted(m)
  result = proc (src: string): Bitmap =
    if src.startsWith("cid:"):
      let key = "cid:" & $mid & ":" & src[4 .. ^1]
      if pictures.hasKey(key): result = pictures[key]; return
      let cids = store0.cidData(mid)
      let want = src[4 .. ^1]
      if cids.hasKey(want):
        let b = pictureFromBytes(key, cids[want])
        pictures[key] = b
        result = b; return
      result = nil; return
    if (src.startsWith("http://") or src.startsWith("https://")):
      if pictures.hasKey(src): result = pictures[src]; return
      if allowed and src notin picturesAsked:
        picturesAsked.incl src
        fetchLink[].send(src)
    nil


# ---- changes ---------------------------------------------------------------------------

proc queue(m: Msg; kind: string; data: JsonNode; due = 0.0): int {.discardable.} =
  data["id"] = %m.id
  data["remote"] = %m.remoteId
  store0.queueAction(m.account, kind, data, due)

proc markRead(ms: seq[Msg]; unread = false) =
  store0.transaction:
    for m in ms:
      if m.unread != unread:
        store0.setFlags(m.id, unread = int(unread))
        queue(m, "read", %*{"unread": unread})
  for a in accountsC: store0.recount(a.id)
  wake()
  changed()

proc toggleFlag(ms: seq[Msg]) =
  var on = true
  for m in ms:
    if m.flagged: on = false
  store0.transaction:
    for m in ms:
      store0.setFlags(m.id, flagged = int(on))
      queue(m, "flag", %*{"flagged": on})
  wake()
  changed()

proc setMsgTags(ms: seq[Msg]; tag: string; on: bool) =
  store0.transaction:
    for m in ms:
      var ts = m.tags
      let had = ts.anyIt(it.toLowerAscii == tag.toLowerAscii)
      if on and not had: ts.add tag
      elif not on and had: ts.keepItIf(it.toLowerAscii != tag.toLowerAscii)
      else: continue
      store0.setTags(m.id, ts)
      if store0.tagOf(m.account, tag).id == 0:
        store0.upsertTag(m.account, tag, hexOf(tagColor(tag)), "")
      var removed = newJArray()
      if not on: removed.add %tag
      queue(m, "tags", %*{"tags": ts, "removed": removed})
  wake()
  changed()

proc clearTags(ms: seq[Msg]) =
  for m in ms:
    for t in m.tags: setMsgTags(@[m], t, false)

const undoSecs = 8.0   ## how long a move waits here before the server hears of it (Undo)

proc moveMsgs(ms: seq[Msg]; role: string; folderId = 0; undoable = true) =
  ## Messages moved to a folder (by its role, or `folderId`): here at once,
  ## on the server a few seconds later, so that Undo can take it back.
  var moved: seq[UndoMove]
  var gone = 0
  let due = if undoable: epochTime() + undoSecs else: 0.0
  var where = ""
  store0.transaction:
    for m in ms:
      let dest = if folderId > 0: folderOf(folderId) else: roleFolder(m.account, role)
      if dest.id == 0 or dest.account != m.account: continue
      if dest.id == m.folder and role != "trash": continue
      if dest.role == "trash" and folderOf(m.folder).role == "trash":
        if account(m.account).kind == akGmail: continue   # (Gmail empties its Trash itself)
        queue(m, "move", %*{"folder": dest.id})
        store0.deleteMessage(m.id)
        inc gone
      else:
        let aid = queue(m, "move", %*{"folder": dest.id}, due)
        store0.moveLocal(m.id, dest.id)
        moved.add UndoMove(msg: m.id, account: m.account, fromFolder: m.folder,
                           toFolder: dest.id, action: aid)
        where = dest.name
  for a in accountsC: store0.recount(a.id)
  if moved.len > 0 and undoable:
    undoMoves = moved
    undoWhat = "move"
    let n = moved.len
    let what = if n == 1: "1 message" else: $n & " messages"
    showSnackbar(case role
                 of "trash": what & " deleted"
                 of "archive": what & " archived"
                 of "junk": what & " moved to Junk"
                 else: what & " moved to " & where, "Undo", int(undoSecs * 1000) - 500)
  elif gone > 0:
    status = $gone & " deleted for good"
  wake()
  changed()

proc undoLastMove() =
  ## Undo: the messages go back where they were (and the server never hears
  ## of the move while it still waits here).
  var n = 0
  store0.transaction:
    for u in undoMoves:
      let waiting = store0.value("SELECT count(*) FROM actions WHERE id = ? AND error = ''",
                                 u.action).num > 0
      if waiting: store0.doneAction(u.action)
      else:
        let m = store0.message(u.msg)
        if m.id > 0: queue(m, "move", %*{"folder": u.fromFolder})
      store0.moveLocal(u.msg, u.fromFolder)
      inc n
  undoMoves.setLen(0)
  for a in accountsC: store0.recount(a.id)
  status = (if n == 1: "1 message" else: $n & " messages") & " put back"
  wake()
  changed()

proc deleteMsgs(ms: seq[Msg]) = moveMsgs(ms, "trash")
proc archiveMsgs(ms: seq[Msg]) = moveMsgs(ms, "archive")

proc pinMsgs(ms: seq[Msg]) =
  var on = true
  for m in ms:
    if m.pinned: on = false
  for m in ms: store0.setPinned(m.id, on)
  changed()

proc snoozeMsgs(ms: seq[Msg]; until: float) =
  for m in ms: store0.setSnooze(m.id, until)
  status = "Snoozed until " & longDate(until)
  changed()

proc tomorrowAt(h: int): float =
  let n = now()
  dateTime(n.year, n.month, n.monthday, h, 0, 0, 0, local()).toTime.toUnixFloat + 86400

proc laterToday(): float =
  max(epochTime() + 3 * 3600, tomorrowAt(16) - 86400)

proc nextMonday(): float =
  let n = now()
  let days = (7 - ord(n.weekday)) mod 7
  tomorrowAt(8) - 86400 + float(if days == 0: 7 else: days) * 86400

proc addTag(name, color: string) =
  for a in accountsC:
    store0.upsertTag(a.id, name, color, "")
    discard store0.queueAction(a.id, "newtag", %*{"name": name, "color": color})
  wake()
  changed()

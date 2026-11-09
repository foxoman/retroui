# Retro Mail: the window's state and small drawing helpers (included by
# examples/mail.nim).
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

type
  View = enum vStart, vMail, vCalendar, vPeople, vTodo, vNotes
  PlaceKind = enum plFolder, plTag, plSearch, plFlagged, plPinned, plSnoozed, plUnread,
                   plAllInbox
  Place = object
    kind: PlaceKind
    folder: int
    tag: string
  Conv = object
    key: string
    account: int
    thread: string
    msgs: seq[Msg]          ## newest first
    unread: int
    flagged, important, pinned, hasAtt: bool
    tags: seq[string]
    latest: float
    subject, people: string
    size: int
  LRow = object
    group: string           ## a group header ("Pinned", "Today"), else ""
    conv: int
    msg: int                ## -1: the conversation's row, else its message
  Phone = enum phFolders, phList, phRead, phCompose
  UndoMove = object
    msg, account, fromFolder, toFolder, action: int

var
  store0: Db
  link: SyncLink
  syncThread: Thread[ptr SyncLink]
  prefs: Settings
  view = vStart
  place = Place(kind: plAllInbox)
  convs: seq[Conv]
  mates: HashSet[int]       ## messages shown only as part of a thread (from other folders)
  rows: seq[LRow]
  multiSel: OrderedSet[string]   ## the rows selected together (`rowKey`), when more than one
  selAnchor = -1                 ## where a Shift+click range starts
  undoMoves: seq[UndoMove]       ## the last move, while Undo can take it back
  undoWhat = ""                  ## what the snack bar's Undo is for: "move", "send"
  readerOpen = false             ## the message in a window of its own (a double click)
  phoneChoosing = false          ## a phone choosing several messages (after a long press)
  pullFrom = -1                  ## where a pull down from the top of the list began
  pullBy = 0
  pullReady = false
  listIdC: Id                    ## the message list's id (the keys go to it when it has the focus)
  readZoom = 1.0                 ## the size mail is read at (Ctrl+wheel, Ctrl +/-, a pinch)
  readSwipeX = -1                ## (a phone: where a swipe over the message began)
  readSwipeY = 0
  readSwipeT = 0.0
  expanded: HashSet[string]
  dataVer = 1
  listVer = 0
  selKey = ""               ## the selected conversation
  selRow = -1
  openMsgs: seq[Msg]        ## the selected conversation, every folder, newest first
  openKey = ""
  openVer = -1
  openShown = 0.0           ## when it was shown (to mark it read)
  openExpanded: HashSet[int]
  openJump = -1             ## the message picked inside a thread (the pane goes to it); -1 the top
  openJumpUntil = 0.0       ## until when the pane keeps it in view (bodies above it still load)
  openJumpFrom = 0.0
  openFocus = 0             ## the message of the thread picked last (marked in the pane)
  readMarked = ""           ## the conversation already marked read by opening it
  syncText = ""
  lastError = ""
  query = ""
  searching = ""
  serverIds: seq[int]
  accountsC: seq[Account]
  foldersC: Table[int, seq[Folder]]
  tagsC: seq[Tag]
  focusTab = 0
  listScroll = 0
  phone = phList
  # pictures: decoded once, by address (http, cid:<message>:<id>)
  pictures: Table[string, Bitmap]
  picturesAsked: HashSet[string]
  allowPictures: HashSet[int]
  fetchLink: ptr Channel[string]
  fetchDone: ptr Channel[string]
  fetchThread: Thread[(ptr Channel[string], ptr Channel[string])]
  # dialogs
  optOpen = false
  optTab = 0
  aboutOpen = false
  moveOpen = false
  moveSel = 0
  tagMenuAt: Rect
  tagMenuOpen = false
  snoozeOpen = false
  newTagOpen = false
  newTagName = ""
  newTagColor = 0
  confirmDelete = false
  status = ""
  # the panes' sizes
  barW = 86
  treeW = 230
  leftH = 460
  listH = 300
  mainW = 900
  paneW = 520
  # swipe
  swipeRow = -1
  swipeX0, swipeY0 = 0
  swipeDx = 0
  swiping = false

const
  appName = "Retro Mail"
  appVersion = "1.1"
  credit = "Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net"
  tagPalette = [("Blue", "#0063b1"), ("Green", "#00a300"), ("Red", "#e81123"),
                ("Orange", "#ff8c00"), ("Purple", "#7a3ba0"), ("Teal", "#008080"),
                ("Yellow", "#ffd700"), ("Brown", "#8b4513"), ("Gray", "#808080"),
                ("Cranberry", "#c30052")]
  swipeChoices = ["Archive", "Delete", "Mark as read", "Flag", "Pin", "Snooze", "Move to...",
                  "Tag..."]

proc rgb(r, g, b: int): Color =
  color(uint8 clamp(r, 0, 255), uint8 clamp(g, 0, 255), uint8 clamp(b, 0, 255))

proc isPixelIcon(s: string): bool =
  ## A pixel icon (`pxMail`: plane 16) rather than a glyph of the icon font.
  s.len == 4 and s[0] == '\xF4'

proc hexColor(s: string): Color =
  if s.len >= 7 and s[0] == '#':
    try:
      return rgb(fromHex[int](s[1 .. 2]), fromHex[int](s[3 .. 4]), fromHex[int](s[5 .. 6]))
    except ValueError: discard
  rgb(96, 96, 96)

proc hexOf(c: Color): string =
  "#" & toHex(int c.r, 2).toLowerAscii & toHex(int c.g, 2).toLowerAscii & toHex(int c.b, 2).toLowerAscii

proc tagColor(name: string): Color =
  for t in tagsC:
    if t.name.toLowerAscii == name.toLowerAscii and t.color.len > 0: return hexColor(t.color)
  var h = 0
  for c in name: h = (h * 31 + ord(c)) and 0xFFFF
  hexColor(tagPalette[h mod tagPalette.len][1])

proc pillW(s: string): int = textWidth(s, style(size = 0.85, bold = true)) + dp(10)

proc pillAt(x, y: int; s: string; c: Color): int =
  ## A tag drawn at x, y; its width.
  let st = style(size = 0.85, bold = true)
  let w = pillW(s)
  let h = lineHeight(st) + dp(2)
  roundRect(rect(x, y, w, h), float(dp(3)), c)
  text(x + dp(5), y + dp(1), s, contrastInk(c, rgb(255, 255, 255), rgb(0, 0, 0)), st)
  w

proc tagsAt(x, y, maxW: int; tags: seq[string]): int =
  var cx = x
  for t in tags:
    if cx + pillW(t) > x + maxW: break
    cx += pillAt(cx, y, t, tagColor(t)) + dp(4)
  cx - x

proc fit(s: string; w: int; st = TextStyle()): string =
  ## `s` cut to `w` pixels, with "..." when it is longer.
  if w <= 0: return ""
  if textWidth(s, st) <= w: return s
  var lo = 0
  var hi = s.runeLen
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if textWidth(s.runeSubStr(0, mid) & "...", st) <= w: lo = mid else: hi = mid - 1
  s.runeSubStr(0, lo) & "..."

proc initials(x, y, d: int; name: string) =
  ## A round badge with someone's initials.
  var ini = ""
  for p in name.split({' ', '.', '_'}):
    if p.len > 0 and ini.runeLen < 2: ini.add p.runeSubStr(0, 1).toUpper
  if ini.len == 0: ini = "?"
  var h = 0
  for ch in name: h = (h * 31 + ord(ch)) and 0xFFFF
  let pal = [rgb(0, 90, 200), rgb(0, 130, 90), rgb(170, 60, 0), rgb(120, 40, 160),
             rgb(0, 120, 140), rgb(180, 0, 70)]
  let r = float(d) / 2
  disc(float(x) + r, float(y) + r, r, pal[h mod pal.len])
  let st = style(bold = true, size = if d < dp(20): 0.65 elif d < dp(30): 0.8 else: 1.0)
  text(x + (d - textWidth(ini, st)) div 2, y + (d - lineHeight(st)) div 2, ini,
       rgb(255, 255, 255), st)

proc shortDate(t: float): string =
  ## "10:42" today, "Mon 18:02" this week, "12/10/2026" before.
  if t <= 0: return ""
  let d = fromUnixFloat(t).local
  let now = now()
  if d.year == now.year and d.yearday == now.yearday: return d.format("HH:mm")
  if t > epochTime() - 6 * 86400: return d.format("ddd HH:mm")
  d.format("dd/MM/yyyy")

proc longDate(t: float): string =
  if t <= 0: return ""
  fromUnixFloat(t).local.format("dddd, d MMMM yyyy HH:mm")

proc groupOf(t: float): string =
  let d = fromUnixFloat(t).local
  let n = now()
  let today0 = dateTime(n.year, n.month, n.monthday, 0, 0, 0, 0, local()).toTime.toUnixFloat
  if t >= today0: "Today"
  elif t >= today0 - 86400: "Yesterday"
  elif t >= today0 - float(ord(n.weekday)) * 86400: "Earlier this week"
  elif t >= today0 - float(ord(n.weekday) + 7) * 86400: "Last week"
  elif d.year == n.year and d.month == n.month: "Earlier this month"
  elif d.year == n.year: $d.month
  else: "Older"

proc sizeText(n: int): string =
  if n <= 0: ""
  elif n < 1024: $n & " B"
  elif n < 1024 * 1024: $(n div 1024) & " KB"
  else: formatFloat(n / (1024 * 1024), ffDecimal, 1) & " MB"

proc who(m: Msg): string =
  if m.mine: "Me"
  elif m.fromName.len > 0: m.fromName
  else: m.fromEmail

proc account(id: int): Account =
  for a in accountsC:
    if a.id == id: return a

proc folderOf(id: int): Folder =
  for fs in foldersC.values:
    for f in fs:
      if f.id == id: return f

proc roleFolder(account: int; role: string): Folder =
  for f in foldersC.getOrDefault(account):
    if f.role == role: return f

proc wake() =
  link.cmds.send(SyncCmd(kind: scWake))

proc changed() =
  inc dataVer
  ui.redraw = true

proc pref(key: string; default = ""): string = prefs.get(key, default)
proc prefInt(key: string; default = 0): int = prefs.getInt(key, default)
proc prefBool(key: string; default = false): bool = prefs.getBool(key, default)

proc savePrefs() =
  try: discard saveSettings("retro-mail", prefs) except CatchableError: discard

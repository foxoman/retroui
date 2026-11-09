## Retro Mail: Outlook Express 4 to look at and to use, with what the new
## Outlook does -- Microsoft 365, Outlook.com and Gmail, signed in in the
## browser (the services' own pages: no password is ever typed here).
##
## - threads, Focused and Other, tags (Outlook categories, Gmail labels),
##   pin, snooze, flags, rules of thumb in the start page
## - instant offline search of everything kept (from: to: tag: is: has:)
## - rich text writing, signatures for new mail and replies, send later
## - swipe a message right or left on touch screens
## - the calendar, people, to do and notes beside the mail
##
## Adding an account is one click: Microsoft or Google, the browser opens
## its sign-in page, done. The app registrations it signs in with are made
## once by whoever builds it (examples/mail/appids.nim, docs/retromail.md).
##
##   nim c -r -d:release examples/mail.nim
##   retroapk examples/mail.nim --permission:INTERNET     (Android)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, json, times, tables, sets, algorithm, sequtils, unicode, hashes, math]
import retroui, retroui/[db, http, oauth, secrets, mime, richedit, spell, pdfview, mailimport, notify,
                     bgcheck]
import retroui/[mailsetup, netconn]
import mail/[store, api, sync, graph, gmail, appids, rules, forward, importer, calendar, imapsync]

include mail/ui_state
include mail/ui_data
include mail/ui_compose
include mail/ui_mail
include mail/ui_more
include mail/ui_extra
include mail/ui_classic
include mail/ui_wizard
include mail/ui_start
include mail/ui_options
include mail/ui_others
include mail/ui_phone
include mail/ui_tools

# ---- pictures from the web: a thread of their own ------------------------------------------

proc fetchMain(chans: (ptr Channel[string], ptr Channel[string])) {.thread.} =
  {.gcsafe.}:
    let (inbox, outbox) = chans
    while true:
      let url = inbox[].recv()
      if url.len == 0: break
      let p = mailDir() / "pictures" / ($hash(url)).replace("-", "m") & ".img"
      if not fileExists(p):
        let r = httpRequest("GET", url, [("User-Agent", "Mozilla/5.0 (Retro Mail)")],
                            timeoutSec = 30)
        if r.ok and r.body.len > 0 and r.body.len < 12_000_000:
          try:
            createDir(p.parentDir)
            writeFile(p, r.body)
          except CatchableError: discard
      outbox[].send(url & "\t" & p)

# ---- what the threads say ----------------------------------------------------------------

proc handleEvents() =
  while true:
    let (ok, ev) = link.events.tryRecv()
    if not ok: break
    case ev.kind
    of seInvite, seAutoReply, seAssist, seRaw, seUnsub: extraEvent(ev)
    of seEvent: eventAnswer(ev)
    of seChanged: changed()
    of seStatus: syncText = ev.text
    of seError:
      lastError = ev.text
      status = (if ev.id > 0: account(ev.id).email & ": " else: "") & ev.text
    of seSignIn:
      status = account(ev.id).email & " must sign in again: Tools, Accounts, Sign In Again"
      changed()
    of seBody:
      openVer = -1
      if ev.text.len > 0: status = ev.text
      changed()
    of seAttachment:
      if ev.text.len > 0: status = "The attachment: " & ev.text
      elif ev.id == openAttAfter:
        openAttAfter = 0
        openAttachment(ev.id)
        status = ""
      else: status = "Downloaded the attachment"
    of seNewMail:
      # told once: what came since it was last told (a background check may
      # have told it already, while the window slept)
      let (n, latest) = takeUnannounced()
      if n > 0 and prefBool("notify", true):
        let title = if n == 1: "New mail" else: $n & " new messages"
        # the system's notification (outside the window); a balloon where there is none
        let told = notify(title, latest, appName, tag = "inbox")
        if not told: toast(latest, title = title, glyph = pxMail)
        # the sound, as Outlook Express played it (a phone's notification has its own)
        if prefBool("newMailSound", true) and (not defined(android) or not told): newMailSound()
      elif n > 0 and prefBool("newMailSound", true): newMailSound()
      status = $ev.count & " new: " & ev.text
    of seSearch:
      if ev.text == searching:
        serverIds = ev.ids
        changed()
    of seSent:
      status = "Sent \"" & ev.text & "\""
      toast("Sent: " & ev.text, glyph = pxMail)
    of seSignature: keepWebSignature(ev.id, ev.text)
  var got = false
  while true:
    let (ok, s) = fetchDone[].tryRecv()
    if not ok: break
    let k = s.find('\t')
    if k < 0: continue
    let url = s[0 ..< k]
    let path = s[k + 1 .. ^1]
    pictures[url] = (if fileExists(path): loadPicture(path, 1600, 6000) else: nil)
    got = true
  if got:
    htmlImagesChanged()
    ui.redraw = true
  wakeIn(if syncText.len > 0 or wizFlow != nil: 250 else: 1500)

# ---- the window ----------------------------------------------------------------------------

proc mailArea() =
  if query.len > 0:
    let n = convs.len
    let a = banner($n & (if n == 1: " thread" else: " threads") & " found in the mail kept here." &
                   (if searching == query: " The server was asked too." else: ""),
                   bkInfo, ["Save as Search Folder", "Search the server"], closable = false)
    if a == 1: saveSearch(query)
    elif a == 2:
      searching = query
      link.cmds.send(SyncCmd(kind: scSearch, text: query))
      status = "Asking the server..."
  elif isInboxPlace() and prefBool("focused", true):
    var t = focusTab
    row:
      discard tabStrip(["Focused", "Other"], t, closable = false, addButton = false)
    if t != focusTab:
      focusTab = t
      selRow = -1
      selKey = ""
      listScroll = 0
      changed()
  case pref("pane", "bottom")
  of "right":
    split(paneW, -1):
      mailList()
    do:
      readingPane()
  of "off": mailList()
  else:
    vsplit(listH, -1):
      mailList()
    do:
      readingPane()

proc leftPane() =
  if prefBool("contactspane", true):
    vsplit(leftH, -1):
      folderTree()
    do:
      contactsPane()
  else:
    folderTree()

proc mainWindow() =
  menus()
  case view
  of vMail, vStart: mailToolbar()
  of vCalendar:
    setToolbarLook(blTextBelow)
    toolbar:
      if barButton(pxNew, "New Event", "A new event or meeting", enabled = calAccounts().len > 0): newEventNow()
      toolSeparator()
      if barButton(pxBack, "Back"): calDay = calDay.addDays(if calMode == amMonth: -30 elif calMode == amWeek: -7 else: -1)
      if barButton(pxHome, "Today"): calDay = today()
      if barButton(pxForward, "Next"): calDay = calDay.addDays(if calMode == amMonth: 30 elif calMode == amWeek: 7 else: 1)
      toolSeparator()
      for m in AgendaMode:
        if barButton(pxCalendar, $m, down = calMode == m): calMode = m
      toolSeparator()
      if barButton(pxRefresh, "Refresh"): link.cmds.send(SyncCmd(kind: scSyncNow))
  else:
    setToolbarLook(blTextBelow)
    toolbar:
      if barButton(pxMail, "New Mail", enabled = accountsC.len > 0): openCompose("new")
      if barButton(pxRefresh, "Send/Recv", enabled = accountsC.len > 0):
        link.cmds.send(SyncCmd(kind: scSyncNow))
  let waiting = store0.actionsWaiting()
  statusbar(
    (if status.len > 0: status
     elif view == vMail: $convs.len & " thread(s), " & $unreadAll() & " unread" else: ""),
    (if syncText.len > 0: syncText
     elif waiting > 0: $waiting & " waiting to be sent"
     elif accountsC.len == 0: "No account yet"
     else: "Working Online"),
    $store0.messageCount() & " messages offline")
  split(barW, -1):
    outlookBar()
  do:
    case view
    of vStart:
      folderBar(appName, (if accountsC.len == 0: "no account yet" elif accountsC.len == 1: "1 account" else: $accountsC.len & " accounts"))
      split(treeW, -1):
        leftPane()
      do:
        startPage()
    of vMail:
      let sub = if place.kind == plFolder: account(folderOf(place.folder).account).email
                elif place.kind == plTag: "in every folder"
                else: (if accountsC.len == 1: accountsC[0].email else: "every account")
      folderBar((if query.len > 0: "Search" else: placeTitle()), sub,
                if place.kind == plTag and query.len == 0: place.tag else: "")
      for a in accountsC:
        if a.state == "signin":
          if banner(a.email & " must sign in again.", bkWarning, ["Sign In"], closable = false) == 1:
            signInAgain(a)
      split(treeW, -1):
        leftPane()
      do:
        if prefBool("myday", true) and available() > dp(1000):
          split(mainW, -1):
            mailArea()
          do:
            myDayPane()
        else:
          mailArea()
    of vCalendar:
      folderBar("Calendar", calDay.year.`$`)
      calendarView()
    of vPeople:
      folderBar("People", "the address book")
      peopleView()
    of vTodo:
      folderBar("To Do", "")
      todoView()
    of vNotes:
      folderBar("Notes", "kept on this device")
      notesView()
  mailKeys()

# ---- start -------------------------------------------------------------------------------

var started = false
var fetchIn, fetchOut: Channel[string]

var panesMoved = false

proc startup() =
  ## (on the first frame: on Android the app's folder is known only then)
  started = true
  if getEnv("RETRO_MAIL_HOME").len == 0:
    when defined(android): putEnv("RETRO_MAIL_HOME", dataDir("RetroMail"))
    else: discard
  prefs = loadSettings("retro-mail")
  # new mail checked while the app is closed (Android: the system's job)
  scheduleBackgroundCheck(if prefBool("bgCheck", true): 15 else: 0)
  restoreAppearance(prefs)
  restoreWriting()
  readZoom = clamp(prefInt("zoom", 100) / 100, 0.5, 3.0)
  # the panes as they were left
  barW = prefInt("barW", barW)
  treeW = prefInt("treeW", treeW)
  leftH = prefInt("leftH", leftH)
  listH = prefInt("listH", listH)
  mainW = prefInt("mainW", mainW)
  paneW = prefInt("paneW", paneW)
  store0 = openStore()
  link.cmds.open()
  link.events.open()
  link.dbPath = mailDir() / "mail.db"
  createThread(syncThread, syncMain, addr link)
  link.cmds.send(SyncCmd(kind: scSettings, count: prefInt("interval", 1)))
  fetchIn.open()
  fetchOut.open()
  fetchLink = addr fetchIn
  fetchDone = addr fetchOut
  createThread(fetchThread, fetchMain, (addr fetchIn, addr fetchOut))
  if store0.signatures().len == 0:
    discard store0.saveSignature(0, "Simple", "<p>--<br>Sent with Retro Mail</p>")
  reload()
  # the signatures the accounts have on the web, once
  for a in accountsC:
    if not prefBool("sigWeb" & $a.id, false) and not isLocal(a):
      link.cmds.send(SyncCmd(kind: scSignatures, id: a.id))
  if accountsC.len == 0:
    view = vStart
    openWizard()
  elif prefBool("startInbox", false):
    view = vMail
    treeSel = "fav:inbox"
    lastTreeSel = treeSel
    place = Place(kind: plAllInbox)

# ---- new mail while Retro Mail is closed (retroui/bgcheck) ---------------------------------

proc checkMail() {.nimcall, gcsafe.} =
  ## The background check, with no window (on Android also in a process
  ## started only for it): the changes waiting sent, new mail fetched and
  ## told, the unread count on the icon -- as the window does.
  {.cast(gcsafe).}:
    when defined(android):
      if getEnv("RETRO_MAIL_HOME").len == 0: putEnv("RETRO_MAIL_HOME", dataDir("RetroMail"))
    let settings = loadSettings("retro-mail")
    if not settings.getBool("bgCheck", true): return
    let dbPath = mailDir() / "mail.db"
    let (count, latest) = syncOnce(dbPath)
    if count > 0 and settings.getBool("notify", true):
      notify((if count == 1: "New mail" else: $count & " new messages"), latest, appName,
             tag = "inbox")
    if settings.getBool("badge", true):
      try:
        let db = openStore(dbPath)
        let unread = db.value("SELECT coalesce(sum(unread), 0) FROM folders WHERE role = 'inbox'")
        db.close()
        setBadge(int(unread.num))
      except CatchableError: discard

onBackgroundCheck(checkMail)     # (before the window: a check's process stops here)

reportedVersion = appVersion     # (what a fault's report says)
app appName, 1280, 800:
  if not started: startup()
  handleEvents()
  reload()
  if prefBool("badge", true): setBadge(unreadAll())   # (the unread count on the app's icon)
  if isCompact():
    phoneUi()
  elif composing:
    composeWindow()
  else:
    mainWindow()
  tagMenu()
  smallDialogs()
  customizeDialog()
  readerWindow()
  goFolderDialog()
  commandBox()
  quickStepsDialog()
  sweepDialog()
  previewDialog()
  shortcutsDialog()
  autoReplyDialog()
  rulesDialog()
  eventDialog()
  emlDialogs()
  classicDialogs()
  importDialog()
  exportDialog()
  followReminders()
  optionsDialog()
  # the panes' sizes are kept (once the mouse lets go of a splitter)
  if not ui.mouseDown and not isCompact():
    for (k, v) in [("barW", barW), ("treeW", treeW), ("leftH", leftH), ("listH", listH),
                   ("mainW", mainW), ("paneW", paneW)]:
      if prefInt(k, -1) != v:
        prefs.put(k, v)
        panesMoved = true
    if panesMoved:
      panesMoved = false
      savePrefs()
  # Undo (the last move, a message being sent)
  if snackbar():
    case undoWhat
    of "send": undoSend()
    of "move": undoLastMove()
    else:
      if undoWhat.startsWith("sweep:"):
        sweepFromMessage(try: parseInt(undoWhat[6 .. ^1]) except ValueError: 0)
    undoWhat = ""
  elif undoWhat.len > 0 and not snackbarShown():
    undoWhat = ""
    undoMoves.setLen(0)
    sentAction = 0
  aboutDialog()
  wizardDialog()

if started:
  link.cmds.send(SyncCmd(kind: scQuit))
  fetchIn.send("")
  savePrefs()
  store0.close()

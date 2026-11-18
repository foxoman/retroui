# Retro Mail: the mail window -- Outlook bar, folder bar, folder tree,
# contacts pane, tool bar, menus, the message list with threads and tags,
# the reading pane with the whole conversation. Included by examples/mail.nim.
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

proc openWizard()
proc multiPane()
proc openPreview(a: Att)
proc attachmentPicture(id: int): Bitmap
proc followMenu(ms: seq[Msg])
proc quickStepsMenu()
proc openSweep()
proc runCommand(name: string)
proc arrangeMenu()
proc moveRow(delta: int)
proc inviteBanner(m: Msg)
proc aiReady(): bool
proc askAssistant(kind: string; m: Msg)
proc assistBox(ids: seq[int])
proc forwardAsAttachment()
proc unsubscribeBar(m: Msg)
proc safetyBanners(m: Msg)
proc safeOf(m: Msg): MailSafety
proc openLinkSafely(m: Msg; url: string)
proc blockSender(ms: seq[Msg])
proc printMessage()
proc showProperties(source = false)
proc saveSearch(q: string)
proc searchFolders()
proc searchFolderMenu()
proc openSearchFolder(i: int)
proc ignoreConversation(ms: seq[Msg])
proc openFind()
proc messagesDragFiles(ids: seq[int]): seq[string]

var treeOpen = initTable[string, bool]()
var treeSel = "start"
var lastTreeSel = ""
var contactSel = -1
var contactNames: seq[string]
var contactMails: seq[string]
var attMenuId = 0
var saveAttOpen = false
var saveAttPath = ""
var saveAttId = 0
var openAttAfter = 0
var attAsked: HashSet[int]
var saveAllOpen = false
var saveAllMsg = 0
var saveAllDir = ""

proc goPlace(p: Place) =
  place = p
  view = vMail
  query = ""
  serverIds.setLen(0)
  selKey = ""
  selRow = -1
  listScroll = 0
  if isCompact(): phone = phList
  changed()

proc allMsgsOf(rowsSel: seq[Msg]): seq[Msg] = rowsSel

# ---- the Outlook bar ---------------------------------------------------------------------

proc outlookBar() =
  let r = place(available(), remainingH(), fill = true)
  fill(r, ui.theme.shadow)
  var y = r.y + dp(10)
  let unread = block:
    var n = 0
    for fs in foldersC.values:
      for f in fs:
        if f.role == "inbox": n += f.unread
    n
  for (v, px, name) in [(vMail, pxMail, "Mail"), (vCalendar, pxCalendar, "Calendar"),
                        (vPeople, pxUser, "People"), (vTodo, pxCheck, "To Do"),
                        (vNotes, pxNote, "Notes")]:
    let cell = rect(r.x + dp(4), y, r.w - dp(8), dp(62))
    let hit = interact(idOf("obar" & name), cell, focusable = false)
    let on = view == v or (v == vMail and view == vStart)
    if hit.clicked:
      view = v
      if v == vMail and accountsC.len > 0 and treeSel == "start":
        goPlace(Place(kind: plAllInbox))
        treeSel = "fav:inbox"
    if on:
      fill(cell, ui.theme.face)
      sunken(cell)
    elif hit.hover:
      raised(cell, 1)
    let ic = pixelIcon(px, big = true)
    image(cell.x + (cell.w - ic.w) div 2, cell.y + dp(6), ic)
    text(cell.x + (cell.w - textWidth(name)) div 2, cell.y + dp(42), name,
         if on: ui.theme.text else: rgb(255, 255, 255))
    if v == vMail and unread > 0:
      let s = $unread
      let bw = textWidth(s, style(bold = true, size = 0.8)) + dp(8)
      roundRect(rect(cell.x + cell.w - bw - dp(4), cell.y + dp(4), bw, dp(16)), float(dp(7)),
                rgb(200, 0, 0))
      text(cell.x + cell.w - bw, cell.y + dp(5), s, rgb(255, 255, 255), style(bold = true, size = 0.8))
    y += dp(70)

# ---- the folder bar ----------------------------------------------------------------------

proc folderBar(title, sub: string; tag = "") =
  let r = place(available(), dp(36), fill = true)
  fill(r, ui.theme.shadow)
  let st = style(size = 1.5, bold = true)
  var x = r.x + dp(12)
  text(x, r.y + (r.h - lineHeight(st)) div 2, fit(title, r.w div 3, st), rgb(255, 255, 255), st)
  x += min(textWidth(title, st), r.w div 3) + dp(10)
  if tag.len > 0:
    x += pillAt(x, r.y + dp(10), tag, tagColor(tag)) + dp(8)
  let sw = min(dp(340), r.x + r.w - x - dp(16))
  if r.w > dp(700):
    text(x, r.y + (r.h - lineHeight()) div 2, fit(sub, r.x + r.w - sw - x - dp(24)),
         rgb(220, 220, 220))
  if sw > dp(160) and query.strip.len > 0:
    # the search kept as a Search Folder (one click)
    pushFrame(rect(r.x + r.w - sw - dp(16) - CtrlH, r.y + (r.h - CtrlH) div 2, CtrlH + 1, 0))
    if toolButton(pixelIcon(pxFolderStar), "Save this search as a Search Folder"): saveSearch(query)
    discard popFrame()
  if sw > dp(120):
    pushFrame(rect(r.x + r.w - sw - dp(10), r.y + (r.h - EditH) div 2, sw, 0))
    if searchBox(query, "Search: from: to: has: tag: is: before:"):
      serverIds.setLen(0)
      searching = ""
      if query.len > 0: view = vMail
      selRow = -1
      selKey = ""
      listScroll = 0
      changed()
    discard popFrame()

# ---- the folder tree ---------------------------------------------------------------------

proc branchOpen(key: string): bool = treeOpen.getOrDefault(key, true)

proc folderPic(f: Folder): Icon =
  case f.role
  of "inbox": pixelIcon(pxInbox)
  of "drafts": pixelIcon(pxDocument)
  of "sent": pixelIcon(pxMail)
  of "outbox": pixelIcon(pxForward)
  of "archive": pixelIcon(pxArchive)
  of "junk": pixelIcon(pxWarning)
  of "trash": pixelIcon(if f.total > 0: pxTrashFull else: pxTrash)
  else: pixelIcon(pxFolder)

proc draggedMsgs(): seq[Msg] =
  ## The messages a drag from the list carries.
  for it in ui.drag.items:
    let m = store0.message(try: parseInt(it) except ValueError: 0)
    if m.id > 0: result.add m

proc dropOnFolder(r: Rect; f: Folder) =
  ## A folder of the tree takes messages dragged from the list (moved).
  if r.w == 0 or f.role in ["outbox", "drafts"]: return
  case dropTarget(r, "mail")
  of dsOver: dropHighlight(r)
  of dsDropped:
    let ms = draggedMsgs().filterIt(it.account == f.account and it.folder != f.id)
    if ms.len == 0: status = "Messages move only between folders of the same account"
    else:
      moveMsgs(ms, f.role, f.id)
      clearMulti()
  else: discard

proc dropOnTag(r: Rect; tag: string) =
  ## A tag of the tree takes messages dragged from the list (tagged).
  if r.w == 0: return
  case dropTarget(r, "mail")
  of dsOver: dropHighlight(r)
  of dsDropped:
    let ms = draggedMsgs()
    setMsgTags(ms, tag, true)
    status = "Tagged " & tag
  else: discard

proc dropOnMark(r: Rect; what: string) =
  ## Flagged and Pinned take dragged messages too (flagged, pinned).
  if r.w == 0: return
  case dropTarget(r, "mail")
  of dsOver: dropHighlight(r)
  of dsDropped:
    let ms = draggedMsgs()
    if what == "flag": toggleFlag(ms.filterIt(not it.flagged))
    else: pinMsgs(ms.filterIt(not it.pinned))
  else: discard

proc folderNode(f: Folder; fs: seq[Folder]) =
  ## A folder in the tree, its sub-folders under it.
  let name = if f.unread > 0 and f.role notin ["sent", "drafts", "trash", "junk"]:
               f.name & " (" & $f.unread & ")" else: f.name
  var kids: seq[Folder]
  for k in fs:
    if k.parent == f.remoteId and k.id != f.id: kids.add k
  if kids.len == 0:
    leaf(name, pic = folderPic(f), id = "f:" & $f.id)
    dropOnFolder(nodeRect(), f)
  else:
    var o = branchOpen("f" & $f.id)
    let shown = beginNode(name, o, false, true, folderPic(f), "f:" & $f.id, true)
    dropOnFolder(nodeRect(), f)
    if shown:
      for k in kids: folderNode(k, fs)
    endNode()
    treeOpen["f" & $f.id] = o

proc folderTree() =
  tree(treeSel, -1):
    var rootOpen = branchOpen("root")
    branch(appName, rootOpen, pixelIcon(pxHome), "start", true):
      if accountsC.len > 1:
        var favOpen = branchOpen("fav")
        branch("Favorites", favOpen, pixelIcon(pxFolderStar), "fav", true):
          var ib = 0
          for fs in foldersC.values:
            for f in fs:
              if f.role == "inbox": ib += f.unread
          leaf((if ib > 0: "All Inboxes (" & $ib & ")" else: "All Inboxes"),
               pic = pixelIcon(pxInbox), id = "fav:inbox")
          leaf("Unread Mail", pic = pixelIcon(pxMail), id = "fav:unread")
          leaf("Flagged", pic = pixelIcon(pxStar), id = "fav:flagged")
          dropOnMark(nodeRect(), "flag")
          leaf("Pinned", pic = pixelIcon(pxPin), id = "fav:pinned")
          dropOnMark(nodeRect(), "pin")
          leaf("Snoozed", pic = pixelIcon(pxClock), id = "fav:snoozed")
        treeOpen["fav"] = favOpen
      for a in accountsC:
        var o = branchOpen("a" & $a.id)
        let label = if a.state == "signin": a.email & " (sign in)" else: a.email
        branch(label, o, pixelIcon(if isLocal(a): pxComputer else: pxGlobe), "acct:" & $a.id, true):
          let fs = foldersC.getOrDefault(a.id)
          var ids: HashSet[string]
          for f in fs: ids.incl f.remoteId
          for f in fs:
            if f.parent notin ids: folderNode(f, fs)
        treeOpen["a" & $a.id] = o
      if accountsC.len == 1:
        leaf("Unread Mail", pic = pixelIcon(pxMail), id = "fav:unread")
        leaf("Flagged", pic = pixelIcon(pxStar), id = "fav:flagged")
        dropOnMark(nodeRect(), "flag")
        leaf("Pinned", pic = pixelIcon(pxPin), id = "fav:pinned")
        dropOnMark(nodeRect(), "pin")
        leaf("Snoozed", pic = pixelIcon(pxClock), id = "fav:snoozed")
      if tagsC.len > 0:
        var tOpen = branchOpen("tags")
        branch("Tags", tOpen, glyphIcon(nfTags, rgb(0, 0, 128)), "tags", true):
          for t in tagsC:
            leaf(t.name, pic = glyphIcon(nfSquare, tagColor(t.name)), id = "tag:" & t.name)
            dropOnTag(nodeRect(), t.name)
        treeOpen["tags"] = tOpen
      searchFolders()
    treeOpen["root"] = rootOpen
  searchFolderMenu()
  if treeSel != lastTreeSel:
    lastTreeSel = treeSel
    if treeSel == "start": view = vStart
    elif treeSel.startsWith("f:"):
      goPlace(Place(kind: plFolder, folder: (try: parseInt(treeSel[2 .. ^1]) except ValueError: 0)))
    elif treeSel.startsWith("tag:"): goPlace(Place(kind: plTag, tag: treeSel[4 .. ^1]))
    elif treeSel == "fav:inbox": goPlace(Place(kind: plAllInbox))
    elif treeSel == "fav:unread": goPlace(Place(kind: plUnread))
    elif treeSel == "fav:flagged": goPlace(Place(kind: plFlagged))
    elif treeSel == "fav:pinned": goPlace(Place(kind: plPinned))
    elif treeSel == "fav:snoozed": goPlace(Place(kind: plSnoozed))
    elif treeSel.startsWith("search:"):
      openSearchFolder(try: parseInt(treeSel[7 .. ^1]) except ValueError: -1)

proc contactsPane() =
  let r = place(available(), lineHeight() + dp(8), fill = true)
  fill(r, ui.theme.face)
  raised(r, 1)
  text(r.x + dp(6), r.y + dp(4), "Contacts", ui.theme.text, style(bold = true))
  if contactNames.len == 0 or listVer mod 7 == 0:
    contactNames.setLen(0)
    contactMails.setLen(0)
    for c in store0.contacts(limit = 200):
      contactNames.add(if c.name.len > 0: c.name else: c.email)
      contactMails.add c.email
  if contactNames.len == 0:
    paragraph "There are no contacts to display. People you write to and hear from show here."
  else:
    let before = contactSel
    listbox(contactNames, contactSel, rows = -1)
    if ui.doubleClick and contactSel >= 0 and contactSel == before:
      openCompose("new", to = contactNames[contactSel] & " <" & contactMails[contactSel] & ">")

# ---- tool bar and menus ------------------------------------------------------------------

proc doReply(mode: string) =
  ## Replies to the message picked in the thread, else the newest selected.
  let ms = selectedMsgs()
  if ms.len == 0: return
  if openFocus > 0 and openMsgs.anyIt(it.id == openFocus):
    openCompose(mode, store0.message(openFocus))
  else: openCompose(mode, store0.message(ms[0].id))

const mailTools = [
  ToolChoice(key: "compose", label: "Compose", glyph: pxMail),
  ToolChoice(key: "reply", label: "Reply", glyph: pxBack),
  ToolChoice(key: "replyAll", label: "Reply All", glyph: pxUndo),
  ToolChoice(key: "forward", label: "Forward", glyph: pxForward),
  ToolChoice(key: "sendrecv", label: "Send/Recv", glyph: pxRefresh),
  ToolChoice(key: "delete", label: "Delete", glyph: pxDelete),
  ToolChoice(key: "archive", label: "Archive", glyph: pxArchive),
  ToolChoice(key: "move", label: "Move To", glyph: pxFolder),
  ToolChoice(key: "junk", label: "Junk", glyph: pxStop),
  ToolChoice(key: "read", label: "Mark Read", glyph: nfEnvelope),
  ToolChoice(key: "unread", label: "Unread", glyph: pxMail),
  ToolChoice(key: "flag", label: "Flag", glyph: nfFlag),
  ToolChoice(key: "pin", label: "Pin", glyph: pxPin),
  ToolChoice(key: "snooze", label: "Snooze", glyph: pxClock),
  ToolChoice(key: "tags", label: "Tags", glyph: nfTags),
  ToolChoice(key: "threads", label: "Threads", glyph: nfComments),
  ToolChoice(key: "addresses", label: "Addresses", glyph: pxUser),
  ToolChoice(key: "calendar", label: "Calendar", glyph: pxCalendar),
  ToolChoice(key: "find", label: "Find", glyph: pxSearch),
  ToolChoice(key: "options", label: "Options", glyph: pxSettings)]

const mailToolDefaults = ["compose", "reply", "replyAll", "forward", "-", "sendrecv", "delete",
                          "archive", "-", "flag", "pin", "snooze", "tags", "-", "threads",
                          "addresses", "find"]

var customizing = false

proc toolbarLookPref(): ButtonLook =
  case pref("toolbarLook", "below")
  of "beside": blTextBeside
  of "icons": blIconOnly
  else: blTextBelow

proc mailToolbar() =
  setToolbarLook(if isCompact(): blIconOnly else: toolbarLookPref())
  let has = selRow >= 0 and selectedMsgs().len > 0
  let ms = if has: selectedMsgs() else: @[]
  let y0 = ui.barY
  toolbar:
    for k in toolKeys(pref("toolbar", ""), mailToolDefaults, mailTools):
      case k
      of "-": toolSeparator()
      of "compose":
        if barButton(pxMail, "Compose", "Compose a message (Ctrl+N)", enabled = accountsC.len > 0):
          openCompose("new")
      of "reply":
        if barButton(pxBack, "Reply", "Reply to the author (Ctrl+R)", enabled = has): doReply("reply")
      of "replyAll":
        if barButton(pxUndo, "Reply All", "Reply to all (Ctrl+Shift+R)", enabled = has): doReply("replyAll")
      of "forward":
        if barButton(pxForward, "Forward", "Forward (Ctrl+F)", enabled = has): doReply("forward")
      of "sendrecv":
        if barButton(pxRefresh, "Send/Recv", "Send and receive (F5)", enabled = accountsC.len > 0):
          link.cmds.send(SyncCmd(kind: scSyncNow))
          syncText = "Checking for new mail..."
      of "delete":
        if barButton(pxDelete, "Delete", "Delete (Del)", enabled = has): deleteMsgs(ms)
      of "archive":
        if barButton(pxArchive, "Archive", "Archive (Backspace)", enabled = has): archiveMsgs(ms)
      of "move":
        if barButton(pxFolder, "Move To", "Move to a folder (Ctrl+Shift+V)", enabled = has): moveOpen = true
      of "junk":
        if barButton(pxStop, "Junk", "Mark as junk", enabled = has): moveMsgs(ms, "junk")
      of "read":
        if barButton(nfEnvelope, "Mark Read", "Mark as read (Ctrl+Q)", enabled = has): markRead(ms)
      of "unread":
        if barButton(pxMail, "Unread", "Mark as unread (Ctrl+U)", enabled = has):
          markRead(ms, true)
          readMarked = selKey
      of "flag":
        if barButton(nfFlag, "Flag", "Flag (Insert)", enabled = has): toggleFlag(ms)
      of "pin":
        if barButton(pxPin, "Pin", "Pin to the top", enabled = has): pinMsgs(ms)
      of "snooze":
        if barButton(pxClock, "Snooze", "Snooze until later", enabled = has): snoozeOpen = true
      of "tags":
        if barButton(nfTags, "Tags", "Tag the message (Ctrl+T)", down = tagMenuOpen, enabled = has):
          tagMenuOpen = not tagMenuOpen
        tagMenuAt = ui.lastRect
      of "threads":
        if barButton(nfComments, "Threads", "Show messages as threads",
                     down = prefBool("threads", true)):
          prefs.put("threads", not prefBool("threads", true))
          savePrefs()
          changed()
      of "addresses":
        if barButton(pxUser, "Addresses", "The address book (Ctrl+Shift+B)"): view = vPeople
      of "calendar":
        if barButton(pxCalendar, "Calendar", "The calendar (Ctrl+2)"): view = vCalendar
      of "find":
        if barButton(pxSearch, "Find", "Search (Ctrl+E)"): ui.textFocusWanted = true
      of "options":
        if barButton(pxSettings, "Options", "Tools, Options"): optOpen = true
      else: discard
  # the right button on the bar: how it looks, and Customize
  let barR = rect(0, y0, ui.w, ui.barY - y0)
  if canInput() and ui.rpressed and mouseIn(barR):
    openPopupMenu("toolbarmenu", ui.mx, ui.my)
  popupMenu("toolbarmenu"):
    let lk = toolbarLookPref()
    if menuItem("Text &Below the Icons", checked = lk == blTextBelow):
      prefs.put("toolbarLook", "below")
      savePrefs()
    if menuItem("Text &Beside the Icons", checked = lk == blTextBeside):
      prefs.put("toolbarLook", "beside")
      savePrefs()
    if menuItem("&Icons Only", checked = lk == blIconOnly):
      prefs.put("toolbarLook", "icons")
      savePrefs()
    menuSeparator()
    if menuItem("&Customize..."): customizing = true

proc customizeDialog() =
  ## View, Customize Toolbar.
  var keys = toolKeys(pref("toolbar", ""), mailToolDefaults, mailTools)
  var look = toolbarLookPref()
  if customizeToolbar(customizing, keys, mailTools, mailToolDefaults, look):
    prefs.put("toolbar", toolKeysText(keys))
    prefs.put("toolbarLook", case look
                             of blTextBeside: "beside"
                             of blIconOnly: "icons"
                             else: "below")
    savePrefs()

proc menus() =
  let ms = selectedMsgs()
  let has = ms.len > 0
  menubar:
    menu "&File":
      if menuItem("&New Message", "Ctrl+N", enabled = accountsC.len > 0): openCompose("new")
      if menuItem("&Add Account..."): openWizard()
      if menuItem("&Open a Saved Message..."): runCommand("Open a saved message")
      if menuItem("Save &As...", enabled = has): runCommand("Save message as")
      if menuItem("&Import Messages..."): runCommand("Import messages")
      if menuItem("E&xport Messages...", enabled = convs.len > 0): runCommand("Export messages")
      menuSeparator()
      if menuItem("&Print...", "Ctrl+P", enabled = has): printMessage()
      if menuItem("P&roperties", "Alt+Enter", enabled = has): showProperties()
      menuSeparator()
      if menuItem("&Send and Receive", "F5"): link.cmds.send(SyncCmd(kind: scSyncNow))
      menuSeparator()
      if menuItem("E&xit", "Alt+F4"): quitApp()
    menu "&Edit":
      if menuItem("&Delete", "Del", enabled = has): deleteMsgs(ms)
      if menuItem("&Archive", "Backspace", enabled = has): archiveMsgs(ms)
      menuSeparator()
      if menuItem("Mark as &Read", "Ctrl+Q", enabled = has): markRead(ms)
      if menuItem("Mark as &Unread", "Ctrl+U", enabled = has): markRead(ms, true)
      if menuItem("Mark All as R&ead", enabled = convs.len > 0):
        var all: seq[Msg]
        for c in convs: all.add c.msgs
        markRead(all)
      menuSeparator()
      if menuItem("&Search", "Ctrl+E"): ui.textFocusWanted = true
      if menuItem("&Find Message...", "Ctrl+Shift+F"): openFind()
      if menuItem("Save Search as a Search F&older", enabled = query.strip.len > 0): saveSearch(query)
      if menuItem("Select A&ll", "Ctrl+A", enabled = rows.len > 0): runCommand("Select all")
      menuSeparator()
      if menuItem("&Undo", "Ctrl+Z", enabled = undoWhat.len > 0 and snackbarShown()):
        runCommand("Undo")
    menu "&View":
      submenu "&Current View":
        if menuItem("Show &All Messages", checked = not prefBool("hideRead", false)):
          prefs.put("hideRead", false)
          savePrefs()
          changed()
        if menuItem("Hide &Read Messages", checked = prefBool("hideRead", false)):
          prefs.put("hideRead", true)
          savePrefs()
          changed()
      if menuItem("&Threads", checked = prefBool("threads", true)):
        prefs.put("threads", not prefBool("threads", true))
        savePrefs()
        changed()
      if menuItem("&Focused Inbox", checked = prefBool("focused", true)):
        prefs.put("focused", not prefBool("focused", true))
        savePrefs()
        changed()
      submenu "&Arrange By": arrangeMenu()
      submenu "&Reading Pane":
        for (k, label) in [("bottom", "&Below the List"), ("right", "&Beside the List"),
                           ("off", "&Off")]:
          if menuItem(label, checked = pref("pane", "bottom") == k):
            prefs.put("pane", k)
            savePrefs()
      if menuItem("&My Day", checked = prefBool("myday", true)):
        prefs.put("myday", not prefBool("myday", true))
        savePrefs()
      if menuItem("&Contacts Pane", checked = prefBool("contactspane", true)):
        prefs.put("contactspane", not prefBool("contactspane", true))
        savePrefs()
      menuSeparator()
      if menuItem("C&ustomize Toolbar..."): customizing = true
      menuSeparator()
      if menuItem("Message &Source", "Ctrl+F3", enabled = has): showProperties(source = true)
    menu "&Go":
      if menuItem("&Inbox", "Ctrl+1"): goPlace(Place(kind: plAllInbox))
      if menuItem("&Calendar", "Ctrl+2"): view = vCalendar
      if menuItem("&People", "Ctrl+3"): view = vPeople
      if menuItem("&To Do", "Ctrl+4"): view = vTodo
      if menuItem("&Notes", "Ctrl+5"): view = vNotes
      menuSeparator()
      if menuItem("Go to &Folder...", "Ctrl+Y"): runCommand("Go to folder")
      if menuItem("&Next Message", "Ctrl+."): clearMulti(); moveRow(1)
      if menuItem("&Previous Message", "Ctrl+,"): clearMulti(); moveRow(-1)
      menuSeparator()
      if menuItem("&Start Page"): view = vStart
    menu "&Message":
      if menuItem("&New Message", "Ctrl+N", enabled = accountsC.len > 0): openCompose("new")
      if menuItem("&Reply to Sender", "Ctrl+R", enabled = has): doReply("reply")
      if menuItem("Reply to &All", "Ctrl+Shift+R", enabled = has): doReply("replyAll")
      if menuItem("&Forward", "Ctrl+F", enabled = has): doReply("forward")
      if menuItem("Forward as Attach&ment", enabled = has): forwardAsAttachment()
      if menuItem("New M&eeting...", enabled = has): runCommand("New meeting")
      menuSeparator()
      if menuItem("F&lag", "Insert", enabled = has): toggleFlag(ms)
      submenu "Follow &Up": followMenu(ms)
      if menuItem("&Pin", enabled = has): pinMsgs(ms)
      if menuItem("S&nooze...", enabled = has): snoozeOpen = true
      if menuItem("&Tags...", "Ctrl+T", enabled = has): tagMenuOpen = true
      menuSeparator()
      submenu "&Quick Steps": quickStepsMenu()
      if menuItem("S&weep...", enabled = has): openSweep()
      if menuItem("&Move to Folder...", "Ctrl+Shift+V", enabled = has): moveOpen = true
      if menuItem("Mark as &Junk", enabled = has): moveMsgs(ms, "junk")
      if menuItem("&Block Sender", enabled = has): blockSender(ms)
      if menuItem("&Ignore Conversation", enabled = has): ignoreConversation(ms)
    menu "&Tools":
      if menuItem("&Send and Receive", "F5"): link.cmds.send(SyncCmd(kind: scSyncNow))
      if menuItem("&Address Book...", "Ctrl+Shift+B"): view = vPeople
      if menuItem("Message &Rules..."): runCommand("Message rules")
      if menuItem("Automatic Re&plies (Out of Office)..."): runCommand("Automatic replies")
      menuSeparator()
      if menuItem("&Accounts..."):
        optTab = 1
        optOpen = true
      if menuItem("&Options..."): optOpen = true
    menu "&Help":
      if menuItem("&Tell Me What You Want to Do...", "Alt+Q"): runCommand("Tell me")
      if menuItem("&Keyboard Shortcuts"): runCommand("Keyboard shortcuts")
      if menuItem("&About Retro Mail..."): aboutOpen = true

# ---- the message list --------------------------------------------------------------------

proc plusBox(x, y: int; open: bool) =
  let s = dp(9)
  fill(rect(x, y, s, s), ui.theme.field)
  box(rect(x, y, s, s), ui.theme.shadow)
  hline(x + 2, y + s div 2, s - 4, ui.theme.text)
  if not open: vline(x + s div 2, y + 2, s - 4, ui.theme.text)

proc swipeAction(right: bool; ms: seq[Msg]) =
  let choice = swipeChoices[prefInt(if right: "swipeRight" else: "swipeLeft", if right: 0 else: 1)]
  case choice
  of "Archive": archiveMsgs(ms)
  of "Delete": deleteMsgs(ms)
  of "Mark as read": markRead(ms, ms.allIt(not it.unread))
  of "Flag": toggleFlag(ms)
  of "Pin": pinMsgs(ms)
  of "Snooze": snoozeMsgs(ms, laterToday())
  of "Move to...": moveOpen = true
  of "Tag...": tagMenuOpen = true
  else: discard

proc swipeLook(right: bool): tuple[c: Color; label, px: string] =
  let choice = swipeChoices[prefInt(if right: "swipeRight" else: "swipeLeft", if right: 0 else: 1)]
  case choice
  of "Archive": (rgb(0, 140, 60), "Archive", pxArchive)
  of "Delete": (rgb(200, 0, 0), "Delete", pxTrash)
  of "Mark as read": (rgb(0, 90, 200), "Read", pxMail)
  of "Flag": (rgb(220, 120, 0), "Flag", pxStar)
  of "Pin": (rgb(120, 40, 160), "Pin", pxPin)
  of "Snooze": (rgb(0, 120, 140), "Snooze", pxClock)
  of "Move to...": (rgb(90, 90, 90), "Move", pxFolder)
  else: (rgb(0, 90, 200), "Tag", pxStar)

proc swipeUnder(full: Rect; dx: int) =
  ## What a swipe does, under the row being swiped.
  let (c, label, px) = swipeLook(dx > 0)
  fill(full, c)
  let ic = pixelIcon(px)
  let st = style(bold = true)
  let tw = textWidth(label, st)
  if dx > 0:
    image(full.x + dp(12), full.y + (full.h - ic.h) div 2, ic)
    text(full.x + dp(34), full.y + (full.h - lineHeight(st)) div 2, label, rgb(255, 255, 255), st)
  else:
    image(full.x + full.w - dp(28), full.y + (full.h - ic.h) div 2, ic)
    text(full.x + full.w - tw - dp(36), full.y + (full.h - lineHeight(st)) div 2, label,
         rgb(255, 255, 255), st)

proc swipeInput(i: int; rr: Rect): int =
  ## Follows a finger swiping row `i` sideways; how far it is now.
  if not canInput(): return 0
  if ui.pressed and mouseIn(rr) and (fingers() or prefBool("mouseSwipe", false)):
    swipeRow = i
    swipeX0 = ui.mx
    swipeY0 = ui.my
    swiping = false
    swipeDx = 0
  if swipeRow != i: return 0
  if ui.mouseDown:
    let dx = ui.mx - swipeX0
    let dy = ui.my - swipeY0
    if not swiping and abs(dx) > dp(14) and abs(dx) > 2 * abs(dy):
      swiping = true
      ui.dragsActive = true
    if swiping:
      # a tap of the phone's motor as the swipe passes the point where it acts
      let past = abs(dx) > rr.w * 35 div 100
      if past != (abs(swipeDx) > rr.w * 35 div 100): discard vibrate(12)
      swipeDx = dx
      ui.redraw = true
      return dx
    if abs(dy) > dp(14): swipeRow = -1
    return 0
  # let go
  let dx = swipeDx
  let was = swiping
  swipeRow = -1
  swiping = false
  swipeDx = 0
  if was and abs(dx) > rr.w * 35 div 100:
    let r = rows[i]
    let ms = if r.msg >= 0: @[convs[r.conv].msgs[r.msg]]
             else: convs[r.conv].msgs.filterIt(it.id notin mates)
    swipeAction(dx > 0, ms)
  ui.pressUsed = true
  0

proc selectRow(i: int) =
  if i < 0 or i >= rows.len or rows[i].group.len > 0: return
  selRow = i
  selKey = convs[rows[i].conv].key
  openVer = -1
  # a message inside a thread: the reading pane goes to it
  openJump = if rows[i].msg >= 0: convs[rows[i].conv].msgs[rows[i].msg].id else: -1
  openFocus = max(openJump, 0)
  openJumpFrom = epochTime()
  openJumpUntil = openJumpFrom + 2.0

proc moveRow(delta: int) =
  var i = selRow
  for k in 0 ..< rows.len:
    i += delta
    if i < 0 or i >= rows.len: return
    if rows[i].group.len == 0:
      selectRow(i)
      return

const listCols = [18, 22, 18, 18, 18, 190, 0, 150, 92, 64]   ## 0: the rest

proc stackedList(w: int): bool =
  ## The list beside the reading pane (or narrow): each message in two or
  ## three lines, as Outlook shows it there, instead of columns.
  w < dp(660)

proc rowHeight(row: LRow; stacked: bool): int =
  let lh = lineHeight()
  if row.group.len > 0 or not stacked: lh + dp(8)
  elif row.msg >= 0: 2 * lh + dp(12)
  else: 3 * lh + dp(16)

proc rowMarks(c: Conv; m: Msg; row: LRow): tuple[att, flag, important, pinned: bool] =
  if row.msg < 0: (c.hasAtt, c.flagged, c.important, c.pinned)
  else: (m.hasAtt, m.flagged, m.important, false)

proc stackedRow(c: Conv; m: Msg; row: LRow; rr: Rect; selected, unread: bool) =
  ## A message in lines: who and when; the subject and its marks; the start
  ## of the text with the tags.
  let lh = lineHeight()
  let fg = if selected: ui.theme.selectText else: ui.theme.fieldText
  let dim = if selected: ui.theme.selectText else: ui.theme.gray
  let st = style(bold = unread)
  let child = row.msg >= 0
  var x = rr.x + dp(6)
  if child:
    # a message of an open thread: under its thread, joined by a line
    let tx = rr.x + dp(9)
    vline(tx, rr.y, (if row.msg == c.msgs.high: rr.h div 2 else: rr.h), ui.theme.gray)
    hline(tx, rr.y + rr.h div 2, dp(10), ui.theme.gray)
    x = rr.x + dp(24)
  elif c.msgs.len > 1:
    plusBox(rr.x + dp(5), rr.y + dp(6) + (lh - dp(9)) div 2, c.key in expanded)
  if unread and not selected: fill(rect(rr.x + 1, rr.y + 2, dp(3), rr.h - 4), rgb(0, 0, 200))
  let env = if m.mine and child: pixelIcon(pxBack)
            elif unread: pixelIcon(pxMail)
            else: glyphIcon(nfEnvelope, dim)
  let ix = (if child: x else: rr.x + dp(18))
  image(ix, rr.y + dp(5) + (lh - env.h) div 2, env)
  let tx = ix + env.w + dp(6)
  let right = rr.x + rr.w - dp(8)
  let y1 = rr.y + dp(5)
  # line 1: who, and when
  let date = shortDate(m.date)
  let dw = textWidth(date, st)
  text(right - dw, y1, date, if unread and not selected: rgb(0, 0, 160) else: fg, st)
  let who0 = if not child and c.msgs.len > 1: c.people else: who(m)
  text(tx, y1, fit(who0, right - dw - tx - dp(10), st), fg, st)
  let marks = rowMarks(c, m, row)
  if child:
    # line 2: where it is, and its start
    let f = folderOf(m.folder)
    let s = (if f.role in ["sent", "drafts", "trash"]: "[" & f.name & "]  " else: "") & m.snippet
    var mx = right
    if marks.flag:
      mx -= textWidth(nfFlag) + dp(4)
      text(mx, y1 + lh + dp(2), nfFlag, if selected: fg else: rgb(200, 0, 0))
    if marks.att:
      mx -= textWidth(nfPaperclip) + dp(4)
      text(mx, y1 + lh + dp(2), nfPaperclip, dim)
    text(tx, y1 + lh + dp(2), fit(s, mx - tx - dp(6)), dim)
    return
  # line 2: the subject, the thread's size; the marks at the right
  let y2 = y1 + lh + dp(3)
  var mx = right
  if marks.flag:
    mx -= textWidth(nfFlag) + dp(4)
    text(mx, y2, nfFlag, if selected: fg else: rgb(200, 0, 0))
  if marks.att:
    mx -= textWidth(nfPaperclip) + dp(4)
    text(mx, y2, nfPaperclip, fg)
  if marks.important:
    mx -= textWidth(nfExclamation) + dp(4)
    text(mx, y2, nfExclamation, if selected: fg else: rgb(200, 0, 0))
  if marks.pinned:
    mx -= 16 + dp(4)
    image(mx, y2 + (lh - 16) div 2, pixelIcon(pxPin))
  let count = if c.msgs.len > 1: " (" & $c.msgs.len & ")" else: ""
  let cw = if count.len > 0: textWidth(count, st) else: 0
  let subj = fit(if c.subject.len > 0: c.subject else: "(no subject)", mx - tx - cw - dp(8), st)
  text(tx, y2, subj, if unread and not selected: rgb(0, 0, 160) else: fg, st)
  if count.len > 0:
    text(tx + textWidth(subj, st), y2, count, if selected: fg else: rgb(0, 0, 200), st)
  # line 3: the tags, then the start of the text
  let y3 = y2 + lh + dp(3)
  let pw = tagsAt(tx, y3 + dp(1), max(0, (right - tx) div 2), c.tags)
  text(tx + pw + (if pw > 0: dp(4) else: 0), y3, fit(m.snippet, right - tx - pw - dp(6)), dim)

proc columnsRow(c: Conv; m: Msg; row: LRow; rr: Rect; ws: seq[int]; area: Rect;
                selected, unread: bool) =
  ## A message in the columns of Outlook Express.
  let lh = lineHeight()
  let rh = rr.h
  let y = rr.y
  let fg = if selected: ui.theme.selectText else: ui.theme.fieldText
  let dim = if selected: ui.theme.selectText else: ui.theme.gray
  let st = style(bold = unread)
  let ty = y + (rh - lh) div 2
  var x = rr.x
  if row.msg < 0 and c.msgs.len > 1: plusBox(x + dp(5), y + (rh - dp(9)) div 2, c.key in expanded)
  x += ws[0]
  let env = if m.mine and row.msg >= 0: pixelIcon(pxBack)
            elif unread: pixelIcon(pxMail)
            else: glyphIcon(nfEnvelope, dim)
  image(x + (ws[1] - env.w) div 2, y + (rh - env.h) div 2, env)
  x += ws[1]
  if row.msg < 0:
    if c.important: text(x + dp(6), ty, nfExclamation, rgb(200, 0, 0))
    elif c.pinned: image(x + 1, y + (rh - 16) div 2, pixelIcon(pxPin))
  x += ws[2]
  if (row.msg < 0 and c.hasAtt) or m.hasAtt: text(x + dp(4), ty, nfPaperclip, fg)
  x += ws[3]
  if (row.msg < 0 and c.flagged) or (row.msg >= 0 and m.flagged):
    text(x + dp(4), ty, nfFlag, rgb(200, 0, 0))
  x += ws[4]
  if row.msg < 0:
    let w = if c.msgs.len > 1: c.people else: who(m)
    text(x + dp(4), ty, fit(w, ws[5] - dp(8), st), fg, st)
  else:
    let tx = area.x + dp(9)
    vline(tx, y, (if row.msg == c.msgs.high: rh div 2 else: rh), ui.theme.gray)
    hline(tx, y + rh div 2, dp(10), ui.theme.gray)
    text(x + dp(18), ty, fit(who(m), ws[5] - dp(22), st), fg, st)
  x += ws[5]
  if row.msg < 0:
    let s = fit(c.subject, ws[6] - dp(44), st)
    text(x + dp(4), ty, s, fg, st)
    if c.msgs.len > 1:
      text(x + dp(8) + textWidth(s, st), ty, "(" & $c.msgs.len & ")",
           if selected: fg else: rgb(0, 0, 200), st)
  else:
    let f = folderOf(m.folder)
    let s = (if f.role in ["sent", "drafts", "trash"]: "[" & f.name & "]  " else: "") & m.snippet
    text(x + dp(4), ty, fit(s, ws[6] - dp(8)), dim)
  x += ws[6]
  if ws[7] > 0 and row.msg < 0: discard tagsAt(x + dp(3), ty, ws[7] - dp(6), c.tags)
  x += ws[7]
  text(x + dp(4), ty, shortDate(m.date), fg, st)
  x += ws[8]
  if ws[9] > 0:
    let sz = sizeText(if row.msg < 0: c.size else: m.size)
    text(x + ws[9] - textWidth(sz, st) - dp(6), ty, sz, fg, st)

var
  dragRow = -1                ## the row the mouse went down on (a drag may start from it)
  dragX0, dragY0 = 0
  colDrag = -1                ## the column whose width is being dragged
  colDragX0, colDragW0 = 0
  typedAhead = ""             ## letters typed on the list (it jumps to a sender)
  typedAt = 0.0

const sortKeys = [(1, "unread"), (4, "flag"), (5, "from"), (6, "subject"), (8, "date"), (9, "size")]

proc sortBy(key: string) =
  ## The list arranged by `key`; again: the other way round.
  if pref("sortBy", "date") == key: prefs.put("sortAsc", not prefBool("sortAsc", false))
  else:
    prefs.put("sortBy", key)
    prefs.put("sortAsc", key in ["from", "subject"])
  savePrefs()
  changed()

proc arrangeMenu() =
  ## View, Arrange By (and the list's header beside the reading pane).
  let by = pref("sortBy", "date")
  for (k, label) in [("date", "&Date"), ("from", "&From"), ("subject", "&Subject"),
                     ("size", "Si&ze"), ("flag", "F&lag"), ("unread", "&Unread")]:
    if menuItem(label, checked = by == k):
      prefs.put("sortBy", k)
      prefs.put("sortAsc", k in ["from", "subject"])
      savePrefs()
      changed()
  menuSeparator()
  let asc = prefBool("sortAsc", false)
  if menuItem(if by == "date": "&Newest on Top" else: "&Descending", checked = not asc):
    prefs.put("sortAsc", false)
    savePrefs()
    changed()
  if menuItem(if by == "date": "&Oldest on Top" else: "&Ascending", checked = asc):
    prefs.put("sortAsc", true)
    savePrefs()
    changed()

proc rowSelect(i: int; listId: Id) =
  ## A click on row `i`: alone, or with Ctrl (one more) or Shift (a range).
  let ctrl = CtrlPressed in ui.mods
  let shift = ShiftPressed in ui.mods
  if shift and selAnchor >= 0:
    multiSel.clear()
    for k in min(selAnchor, i) .. max(selAnchor, i):
      let key = rowKey(k)
      if key.len > 0: multiSel.incl key
    selRow = i
    selKey = convs[rows[i].conv].key
  elif ctrl:
    if multiSel.len == 0 and selRow >= 0: multiSel.incl rowKey(selRow)
    let key = rowKey(i)
    if key in multiSel: multiSel.excl key else: multiSel.incl key
    selAnchor = i
    selRow = i
    selKey = convs[rows[i].conv].key
  else:
    clearMulti()
    selAnchor = i
    selectRow(i)
  ui.focus = listId

proc hoverRects(rr: Rect; stacked: bool): array[3, Rect] =
  ## Where the buttons over a row under the mouse go (flag, pin, delete).
  let s = dp(20)
  let y = if stacked: rr.y + dp(3) else: rr.y + (rr.h - s) div 2
  let x = rr.x + rr.w - 3 * (s + dp(2)) - dp(6)
  for k in 0 .. 2: result[k] = rect(x + k * (s + dp(2)), y, s, s)

proc hoverActions(i: int; rr: Rect; stacked: bool; hits: array[3, Hit]) =
  ## Over a row (with a mouse): flag, pin and delete it at once, as the new
  ## Outlook offers. (Their clicks were taken before the row's: `hits`.)
  let rs = hoverRects(rr, stacked)
  let ms = rowMsgs(i)
  let s = rs[0].w
  fill(rect(rs[0].x - dp(4), rs[0].y - 1, rs[2].x + s - rs[0].x + dp(8), s + 2),
       if i == selRow: ui.theme.select else: rgb(232, 238, 248))
  for k, (glyph, tip) in [(nfFlag, "Flag"), (pxPin, "Pin"), (pxDelete, "Delete")]:
    let br = rs[k]
    let hit = hits[k]
    if hit.hover:
      fill(br, ui.theme.face)
      box(br, ui.theme.shadow)
    let on = (k == 0 and ms.anyIt(it.flagged)) or (k == 1 and ms.anyIt(it.pinned))
    let ink = if k == 0 and on: rgb(200, 0, 0) elif hit.hover: ui.theme.text else: ui.theme.gray
    if isPixelIcon(glyph):
      image(br.x + (s - 16) div 2, br.y + (s - 16) div 2, pixelIcon(glyph))
    else:
      text(br.x + (s - textWidth(glyph)) div 2, br.y + (s - lineHeight()) div 2, glyph, ink)
    if hit.hover: tooltip(tip)
    if hit.clicked:
      case k
      of 0: toggleFlag(ms)
      of 1: pinMsgs(ms)
      else: deleteMsgs(ms)

proc listKeys(listId: Id; tops: seq[int]; areaH, hi: int) =
  ## The list's keys: arrows (Shift: a range), Ctrl+A, Ctrl+. and Ctrl+,,
  ## Left/Right for threads, and letters jump to the next sender.
  if not canInput() or ui.keyUsed or not (ui.focus == listId or ui.focus == 0): return
  let shift = ShiftPressed in ui.mods
  let ctrl = CtrlPressed in ui.mods
  let before = selRow
  if ui.key in {KeyDown, KeyUp}:
    let d = if ui.key == KeyDown: 1 else: -1
    if shift:
      if selAnchor < 0: selAnchor = max(0, selRow)
      var i = selRow
      while true:
        i += d
        if i < 0 or i >= rows.len: break
        if rows[i].group.len == 0:
          multiSel.clear()
          for k in min(selAnchor, i) .. max(selAnchor, i):
            let key = rowKey(k)
            if key.len > 0: multiSel.incl key
          selRow = i
          break
    else:
      clearMulti()
      moveRow(d)
      selAnchor = selRow
    ui.keyUsed = true
  elif ctrl and ui.key == KeyA:
    multiSel.clear()
    for i in 0 ..< rows.len:
      if rows[i].group.len == 0 and rows[i].msg < 0: multiSel.incl rowKey(i)
    ui.keyUsed = true
    status = $multiSel.len & " selected"
  elif ui.key in {KeyRight, KeyLeft} and selRow >= 0 and not ctrl:
    let c = selectedConv()
    if c != nil and c.msgs.len > 1:
      if ui.key == KeyRight: expanded.incl c.key else: expanded.excl c.key
      changed()
    ui.keyUsed = true
  elif ui.key in {KeyHome, KeyEnd}:
    clearMulti()
    if ui.key == KeyHome:
      selRow = -1
      moveRow(1)
    else:
      selRow = rows.len
      moveRow(-1)
    ui.keyUsed = true
  elif ui.typed.len > 0 and not ctrl:
    # type-ahead: the next message whose sender (or subject) starts so
    if epochTime() - typedAt > 1.0: typedAhead = ""
    typedAt = epochTime()
    typedAhead.add ui.typed.toLowerAscii
    ui.typed.setLen(0)
    for k in 0 ..< rows.len:
      let i = (max(selRow, 0) + (if typedAhead.runeLen == 1: 1 else: 0) + k) mod rows.len
      let r = rows[i]
      if r.group.len > 0 or r.msg >= 0: continue
      let c = convs[r.conv]
      if c.people.toLowerAscii.startsWith(typedAhead) or
         c.subject.toLowerAscii.startsWith(typedAhead) or
         (c.msgs.len > 0 and who(c.msgs[0]).toLowerAscii.startsWith(typedAhead)):
        clearMulti()
        selectRow(i)
        selAnchor = i
        break
  if selRow != before and selRow in 0 ..< rows.len:
    scrollShow(listId, listScroll, tops[selRow], tops[selRow + 1], areaH, hi)

proc mailList() =
  let r = place(available(), remainingH(), fill = true)
  fill(r, ui.theme.field)
  sunken(r)
  let inner = inset(r, 1)
  let lh = lineHeight()
  let hh = lh + dp(6)
  let sbw = dp(17)
  let listId = idOf("maillist")
  listIdC = listId
  let area = rect(inner.x, inner.y + hh, inner.w - sbw, inner.h - hh)
  tabStop(listId, r)       # (the list keeps the keyboard: typing does not go to the search box)
  let stacked = stackedList(area.w)
  # where each row starts (rows of threads are taller in lines)
  var tops = newSeq[int](rows.len + 1)
  for i, row in rows: tops[i + 1] = tops[i] + rowHeight(row, stacked)
  let step = lh + dp(8)
  let total = tops[^1]
  let hi = max(0, total - area.h)
  scrollWheel(listId, listScroll, hi, area, step * 3)
  if not swiping: scrollPan(listId, listScroll, hi, area)
  scrollTick(listId, listScroll, hi)
  scrollBarFor(idOf("maillistbar"), listId, rect(inner.x + inner.w - sbw, inner.y + hh, sbw,
               area.h), true, listScroll, hi, area.h, step)
  # widths: the tags column only when there are tags; the user's own widths
  var ws: seq[int]
  let showTags = tagsC.len > 0
  for k, w in listCols:
    var ww = if k == 7 and not showTags: 0 else: dp(w)
    if k in [5, 7, 8, 9] and ww > 0: ww = max(dp(40), prefInt("colW" & $k, ww))
    ws.add ww
  if area.w < dp(760) and not stacked and prefInt("colW5", 0) == 0:
    ws[5] = dp(130)
    ws[9] = 0
  var fixed = 0
  for k, w in ws:
    if k != 6: fixed += w
  ws[6] = max(dp(80), area.w - fixed)
  # the header: a click arranges by the column, its edge changes its width
  pushClip(rect(inner.x, inner.y, inner.w, hh))
  let by = pref("sortBy", "date")
  let asc = prefBool("sortAsc", false)
  if stacked:
    let c = rect(inner.x, inner.y, inner.w, hh)
    fill(c, ui.theme.face)
    raised(c, 1)
    let names = {"date": "Date", "from": "From", "subject": "Subject", "size": "Size",
                 "flag": "Flag", "unread": "Unread"}.toTable
    let t1 = "Arranged by: " & names.getOrDefault(by, "Date")
    let r1 = rect(inner.x, inner.y, textWidth(t1, style(bold = true)) + dp(16), hh)
    if interact(idOf("arrangeby"), r1, focusable = false).clicked:
      openPopupMenu("arrangemenu", r1.x, r1.y + r1.h)
    text(inner.x + dp(6), inner.y + dp(3), t1, ui.theme.text, style(bold = true))
    let t2 = if by == "date": (if asc: "Oldest on top" else: "Newest on top")
             else: (if asc: "A on top" else: "Z on top")
    let r2 = rect(inner.x + inner.w - sbw - textWidth(t2) - dp(16), inner.y, textWidth(t2) + dp(16), hh)
    if interact(idOf("arrangeorder"), r2, focusable = false).clicked:
      prefs.put("sortAsc", not asc)
      savePrefs()
      changed()
    text(r2.x + dp(8), inner.y + dp(3), t2, ui.theme.text)
  else:
    var x = inner.x
    let titles = ["", "", "!", nfPaperclip, nfFlag, "From", "Subject", "Tags", "Received", "Size"]
    for k, w in ws:
      if w == 0: continue
      let c = rect(x, inner.y, w, hh)
      var key = ""
      for (kk, name) in sortKeys:
        if kk == k: key = name
      let hit = interact(idOf("colhead" & $k), rect(c.x + dp(3), c.y, c.w - dp(6), c.h), focusable = false)
      fill(c, ui.theme.face)
      if hit.down: sunken(c) else: raised(c, 1)
      if titles[k].len > 0:
        let tx = if k in 2 .. 4: x + (w - textWidth(titles[k])) div 2 else: x + dp(5)
        text(tx, inner.y + dp(3), titles[k], ui.theme.text)
      if key.len > 0 and key == by and w > dp(30):
        let arrow = if asc: nfCaretUp else: nfCaretDown
        text(c.x + c.w - textWidth(arrow) - dp(5), inner.y + dp(3), arrow, ui.theme.gray)
      if hit.clicked and key.len > 0: sortBy(key)
      # the edge that changes the width: From's right one, the others' left one
      if k in [5, 7, 8, 9]:
        let ex = if k == 5: c.x + c.w else: c.x
        let er = rect(ex - dp(3), inner.y, dp(6), hh)
        let eh = interact(idOf("coledge" & $k), er, focusable = false)
        if eh.hover or colDrag == k: ui.cursor = curSizeWE
        if ui.pressed and mouseIn(er) and canInput():
          colDrag = k
          colDragX0 = ui.mx
          colDragW0 = w
        if colDrag == k:
          if ui.mouseDown:
            let d = ui.mx - colDragX0
            prefs.put("colW" & $k, max(dp(40), (if k == 5: colDragW0 + d else: colDragW0 - d)))
            ui.redraw = true
          else:
            colDrag = -1
            savePrefs()
      x += w
    fill(rect(x, inner.y, inner.x + inner.w - x, hh), ui.theme.face)
  popClip()
  popupMenu("arrangemenu"): arrangeMenu()
  if rows.len == 0:
    let msg = if query.len > 0: "Nothing found here. Press Enter in the search box to ask the server too."
              elif accountsC.len == 0: "No account yet: File, Add Account."
              else: "There are no messages here."
    text(area.x + dp(12), area.y + dp(12), fit(msg, area.w - dp(20)), ui.theme.gray)
    return
  pushClip(area)
  let first = max(0, upperBound(tops, listScroll) - 1)
  let multi = multiSelecting()
  for i in first .. rows.high:
    let row = rows[i]
    let y = area.y + tops[i] - listScroll
    if y >= area.y + area.h: break
    let rh = tops[i + 1] - tops[i]
    let full = rect(area.x, y, area.w, rh)
    if row.group.len > 0:
      fill(full, ui.theme.face)
      text(area.x + dp(26), y + dp(3), row.group, rgb(0, 0, 128), style(bold = true))
      hline(area.x, y + rh - 1, area.w, ui.theme.line)
      continue
    let c = convs[row.conv]
    let m = if row.msg < 0: c.msgs[0] else: c.msgs[row.msg]
    let dx = swipeInput(i, full)
    var rr = full
    if dx != 0:
      swipeUnder(full, dx)
      rr.x += dx
    let selected = i == selRow or (multi and rowKey(i) in multiSel)
    # the buttons that come over a row under the mouse take their clicks first
    let hovering = not fingers() and mouseIn(rr) and canInput() and not swiping and not dragging()
    var hits: array[3, Hit]
    var usedHover = false
    if hovering:
      let hr = hoverRects(rr, stacked)
      for k in 0 .. 2:
        hits[k] = interact(idOf("hover" & $i & ":" & $k), hr[k], focusable = false)
        if mouseIn(hr[k]): usedHover = true
    let rhit = interact(idOf("row" & $i & ":" & c.key), rr, focusable = false)
    if ui.pressed and mouseIn(rr) and canInput() and not fingers() and not usedHover:
      dragRow = i
      dragX0 = ui.mx
      dragY0 = ui.my
    if dragRow == i and ui.mouseDown and not swiping and not dragging() and not fingers() and
       not prefBool("mouseSwipe", false) and abs(ui.my - dragY0) + abs(ui.mx - dragX0) > dp(8):
      # dragged away: the messages go where they are dropped (a folder, a tag)
      if not selected: rowSelect(i, listId)
      let ms = selectedMsgs()
      if ms.len > 0:
        let ids = ms.mapIt(it.id)
        # (out of the window -- to a folder, the desktop -- each a saved message)
        startDrag("mail", ms.mapIt($it.id),
                  if ms.len == 1: (if ms[0].subject.len > 0: ms[0].subject else: "1 message")
                  else: $ms.len & " messages", pxMail,
                  files = proc (): seq[string] = messagesDragFiles(ids))
      dragRow = -1
    if not ui.mouseDown and dragRow == i: dragRow = -1
    if rhit.clicked and not usedHover:
      let boxW = if stacked: dp(18) else: ws[0]
      if row.msg < 0 and ui.mx < area.x + boxW and c.msgs.len > 1 and
         not (CtrlPressed in ui.mods or ShiftPressed in ui.mods):
        if c.key in expanded: expanded.excl c.key else: expanded.incl c.key
        changed()
      rowSelect(i, listId)
      if ui.clicks >= 2 and not multiSelecting():
        readerOpen = true         # a double click: the message in a window of its own
      elif isCompact(): phone = phRead
    if ui.rpressed and mouseIn(rr) and canInput():
      if not selected:
        clearMulti()
        selectRow(i)
      openPopupMenu("rowmenu", ui.mx, ui.my)
    let unread = if row.msg < 0: c.unread > 0 else: m.unread
    let bg = if selected: ui.theme.select
             elif c.pinned: rgb(255, 255, 225)
             elif row.msg >= 0: rgb(246, 246, 246)
             else: ui.theme.field
    fill(rr, bg)
    if stacked: stackedRow(c, m, row, rr, selected, unread)
    else: columnsRow(c, m, row, rr, ws, area, selected, unread)
    if hovering: hoverActions(i, rr, stacked, hits)
    hline(rr.x, y + rh - 1, rr.w, if stacked: rgb(220, 220, 220) else: rgb(232, 232, 232))
  popClip()
  listKeys(listId, tops, area.h, hi)
  popupMenu("rowmenu"):
    let ms = selectedMsgs()
    if menuItem("&Reply", "Ctrl+R"): doReply("reply")
    if menuItem("Reply &All", "Ctrl+Shift+R"): doReply("replyAll")
    if menuItem("&Forward", "Ctrl+F"): doReply("forward")
    if menuItem("Forward as Attach&ment"): forwardAsAttachment()
    menuSeparator()
    if menuItem("Mark as &Read"): markRead(ms)
    if menuItem("Mark as &Unread"): markRead(ms, true)
    if menuItem("F&lag", checked = ms.anyIt(it.flagged)): toggleFlag(ms)
    submenu "Follow &Up": followMenu(ms)
    if menuItem("&Pin", checked = ms.anyIt(it.pinned)): pinMsgs(ms)
    if menuItem("S&nooze..."): snoozeOpen = true
    if menuItem("&Tags..."): tagMenuOpen = true
    menuSeparator()
    if menuItem("&Move to Folder..."): moveOpen = true
    if menuItem("&Archive"): archiveMsgs(ms)
    if menuItem("&Delete"): deleteMsgs(ms)
    if menuItem("Mark as &Junk"): moveMsgs(ms, "junk")
    if menuItem("&Block Sender"): blockSender(ms)
    if menuItem("&Ignore Conversation"): ignoreConversation(ms)
    menuSeparator()
    submenu "&Quick Steps": quickStepsMenu()
    if menuItem("S&weep..."): openSweep()
    menuSeparator()
    if menuItem("&Print...", "Ctrl+P"): printMessage()
    if menuItem("P&roperties", "Alt+Enter"): showProperties()

# ---- the reading pane ------------------------------------------------------------------

proc remoteImages(html: string): int =
  ## How many pictures from the web a message has (shown only when allowed).
  var i = 0
  while true:
    let k = html.find("<img", i)
    if k < 0: break
    let e = html.find('>', k)
    if e < 0: break
    let tag = html[k .. e].toLowerAscii
    if "src=\"http" in tag or "src='http" in tag or "src=http" in tag: inc result
    i = e

proc openAttachment(id: int) =
  ## The attachment in the program the system has for its kind of file.
  let data = store0.attachmentData(id)
  if data.len == 0: return
  let r = store0.one("SELECT name FROM atts WHERE id = ?", id)
  let name = if r.len > 0 and r[0].str.len > 0: r[0].str else: "attachment"
  let dir = when defined(android) or defined(ios): mailDir() / "opened"
            else: getTempDir() / "retro-mail"
  let p = dir / $id & "-" & name.multiReplace(("/", "_"), ("\\", "_"), (":", "_"))
  try:
    createDir(dir)
    writeFile(p, data)
    if openFile(p): status = "Opened " & name
    else: status = "No program here opens " & name & ": Save As keeps it"
  except CatchableError as e: status = e.msg

proc openAttachmentSoon(id: int) =
  ## Opens it now, or once it has come down.
  if store0.attachmentData(id).len > 0:
    openAttachment(id)
  else:
    openAttAfter = id
    link.cmds.send(SyncCmd(kind: scAttachment, id: id))
    status = "Downloading the attachment..."

proc saveAttachmentAs(id: int) =
  saveAttId = id
  let r = store0.one("SELECT name FROM atts WHERE id = ?", id)
  saveAttPath = downloadsDir() / (if r.len > 0 and r[0].str.len > 0: r[0].str else: "attachment")
  saveAttOpen = true
  if store0.attachmentData(id).len == 0:
    link.cmds.send(SyncCmd(kind: scAttachment, id: id))

proc dragName(name: string): string =
  result = name.multiReplace(("/", "_"), ("\\", "_"), (":", "_"), ("*", "_"), ("?", "_"),
                             ("\"", "_"), ("<", "_"), (">", "_"), ("|", "_")).strip
  if result.len == 0: result = "attachment"

proc attachmentDragFile(a: Att): seq[string] =
  ## Attachment `a` as a file, for a drag out of the window (to a folder, the
  ## desktop, another program): written in a temporary folder. Not here yet:
  ## nothing to drag, and it is asked for.
  let data = store0.attachmentData(a.id)
  if data.len == 0:
    if a.id notin attAsked:
      attAsked.incl a.id
      link.cmds.send(SyncCmd(kind: scAttachment, id: a.id))
    status = "Downloading the attachment first: drag it again in a moment"
    return
  let dir = getTempDir() / "retro-mail" / "drag" / $a.id
  let p = dir / dragName(a.name)
  try:
    createDir(dir)
    writeFile(p, data)
    result = @[p]
  except CatchableError as e: status = e.msg

proc messagesDragFiles(ids: seq[int]): seq[string] =
  ## Messages dragged out of the window: each a saved message (.eml).
  let dir = getTempDir() / "retro-mail" / "drag" / ("m" & $int(epochTime() * 1000))
  try: createDir(dir) except CatchableError: return
  var used: HashSet[string]
  for id in ids:
    let m = store0.message(id)
    if m.id == 0: continue
    let acc = accountsC.filterIt(it.id == m.account)
    let me = MailAddress(name: (if acc.len > 0: acc[0].name else: ""),
                         email: (if acc.len > 0: acc[0].email else: ""))
    var name = dragName(attachmentName(m.subject))
    if name in used: name = name.changeFileExt("") & " (" & $id & ").eml"
    used.incl name
    try:
      writeFile(dir / name, rawOf(store0, m, me))
      result.add dir / name
    except CatchableError: discard

proc attachmentsRow(m: Msg) =
  ## The files sent with it: a click opens one in its program, the right
  ## button (or a long press) offers Open and Save As; dragged out of the
  ## window, a file goes where it is let go (a folder, another program).
  let atts = store0.attachments(m.id)
  var files: seq[Att]
  for a in atts:
    # (an invitation's calendar part shows as the meeting, not as a file)
    if a.mime.startsWith("text/calendar") and (a.name.len == 0 or a.name == "attachment"): continue
    if not a.inline: files.add a
  if files.len == 0: return
  row:
    for a in files:
      let px = if a.mime.startsWith("image/"): pxImage
               elif a.mime.contains("pdf"): pxPdf
               elif a.mime.contains("zip") or a.mime.contains("compressed"): pxArchive
               elif a.name.endsWith(".apk") or a.name.endsWith(".exe"): pxApp
               else: pxFile
      if button(fit(a.name, dp(220)) & (if a.size > 0: "  (" & sizeText(a.size) & ")" else: ""), px):
        openAttachmentSoon(a.id)
      let att = a
      fileDragSource(ui.lastRect, proc (): seq[string] = attachmentDragFile(att))
      if canInput() and mouseIn(ui.lastRect) and (ui.rpressed or longPressed()):
        attMenuId = a.id
        openPopupMenu("attmenu", ui.mx, ui.my)
  # the pictures among them, small, to look at before opening
  var pics: seq[Att]
  for a in files:
    if a.mime.startsWith("image/") and a.size < 20_000_000: pics.add a
  if pics.len > 0:
    row:
      for a in pics[0 ..< min(4, pics.len)]:
        let b = attachmentPicture(a.id)
        let th = dp(84)
        let w = if b != nil and b.h > 0: clamp(b.w * th div b.h, dp(40), dp(200)) else: th
        let r = place(w, th)
        let hit = interact(idOf("attpic" & $a.id), r, focusable = false)
        let att = a
        fileDragSource(r, proc (): seq[string] = attachmentDragFile(att))
        fill(r, ui.theme.face)
        if b != nil: drawBitmap(r, b) else:
          if store0.attachmentData(a.id).len == 0 and a.id notin attAsked:
            attAsked.incl a.id
            link.cmds.send(SyncCmd(kind: scAttachment, id: a.id))
          text(r.x + dp(6), r.y + dp(6), "...", ui.theme.gray)
        box(r, if hit.hover: ui.theme.select else: ui.theme.shadow)
        if hit.clicked: openPreview(a)
  popupMenu("attmenu"):
    if menuItem("&Open"): openAttachmentSoon(attMenuId)
    if menuItem("&Preview"):
      for a in files:
        if a.id == attMenuId: openPreview(a)
    if menuItem("&Save As..."): saveAttachmentAs(attMenuId)
    if files.len > 1 and menuItem("Save &All..."):
      saveAllOpen = true
      saveAllMsg = m.id
      saveAllDir = downloadsDir()
      for f in files:
        if store0.attachmentData(f.id).len == 0:
          link.cmds.send(SyncCmd(kind: scAttachment, id: f.id))

var headerRect: Rect     ## (the last message header drawn)

proc mailHeader(m: Msg; collapsed: bool; focused = false): bool =
  ## A message's header in the conversation; true when clicked. `focused`:
  ## the message picked in the list (a blue bar at its side).
  let lh = lineHeight()
  let h = if collapsed: lh + dp(12) else: 2 * lh + dp(14)
  let r = place(available(), h, fill = true)
  headerRect = r
  let hit = interact(idOf("mh" & $m.id), r, focusable = false)
  fill(r, if collapsed: (if hit.hover: rgb(236, 236, 244) else: rgb(244, 244, 244)) else: ui.theme.field)
  box(r, if focused: rgb(0, 90, 200) else: rgb(210, 210, 210))
  if focused: fill(rect(r.x, r.y, dp(4), r.h), rgb(0, 90, 200))
  let d = if collapsed: lh + dp(4) else: 2 * lh
  initials(r.x + dp(8), r.y + (h - d) div 2, d, (if m.mine and m.fromName.len > 0: m.fromName else: who(m)))
  let x = r.x + d + dp(18)
  let tw = textWidth(shortDate(m.date))
  text(r.x + r.w - tw - dp(10), r.y + dp(6), shortDate(m.date), ui.theme.gray)
  let st = style(bold = true)
  if collapsed:
    let nameW = textWidth(who(m), st)
    text(x, r.y + dp(6), who(m), ui.theme.text, style(bold = m.unread))
    text(x + nameW + dp(12), r.y + dp(6), fit(m.snippet, r.w - nameW - tw - d - dp(60)), ui.theme.gray)
  else:
    let from0 = if m.fromName.len > 0: m.fromName & " <" & m.fromEmail & ">" else: m.fromEmail
    text(x, r.y + dp(6), fit(from0, r.w - d - tw - dp(50), st), ui.theme.text, st)
    var line = "To: " & m.toList
    if m.ccList.len > 0: line.add ";  Cc: " & m.ccList
    text(x, r.y + dp(8) + lh, fit(line, r.w - d - dp(40)), ui.theme.gray)
  hit.clicked

proc messageBody(m: Msg; fill: bool) =
  case m.bodyState
  of 2:
    inviteBanner(m)
    safetyBanners(m)
    unsubscribeBar(m)
    let html = safeOf(m).html
    let pics = remoteImages(html)
    if pics > 0 and not picturesTrusted(m):
      let sender = m.fromEmail.toLowerAscii
      case banner("Pictures from the web are hidden in this message (" & $pics &
                  "), so the sender cannot see when you read it.", bkInfo,
                  ["Show pictures", "Trust this sender", "Show always"],
                  closable = false)
      of 1: allowPictures.incl m.id
      of 2:
        if sender.len > 0:
          prefs.put("picSenders", (pref("picSenders").splitLines & @[sender]).filterIt(it.len > 0).join("\n"))
          savePrefs()
        allowPictures.incl m.id
      of 3:
        prefs.put("pictures", 1)
        savePrefs()
      else: discard
    attachmentsRow(m)
    let z0 = readZoom
    let ev = if fill: htmlView(html, readZoom, height = remainingH() - CtrlH - dp(12),
                               key = "msg" & $m.id, images = imagesFor(m))
             else: htmlBlock(html, images = imagesFor(m), zoom = readZoom)
    if readZoom != z0:
      prefs.put("zoom", int(round(readZoom * 100)))
      savePrefs()
      status = "Text size " & $int(round(readZoom * 100)) & " %"
    if ev.link.len > 0:
      if ev.link.startsWith("mailto:"):
        openCompose("new", to = ev.link[7 .. ^1].split('?')[0])
      else: openLinkSafely(m, ev.link)
  of 3:
    paragraph "This message could not be downloaded. It may have been deleted or moved."
  else:
    row:
      spinner()
      label "Downloading the message...", color = ui.theme.gray
    paragraph m.snippet

proc quickReplies(c: Conv): seq[string] =
  let s = (c.subject & " " & (if c.msgs.len > 0: c.msgs[0].snippet else: "")).toLowerAscii
  if "?" in s: @["Yes, that works", "No, sorry", "Let me check"]
  elif "thank" in s: @["You're welcome!", "Any time", "Glad to help"]
  elif "invoice" in s or "payment" in s: @["Received, thank you", "I'll check it now"]
  else: @["Thanks!", "Got it", "Sounds good"]

proc quickReply(text: string) =
  let ms = selectedMsgs()
  if ms.len == 0: return
  openCompose("reply", store0.message(ms[0].id))
  richInsert(composeDoc, text)

proc readingPane() =
  if multiSelecting():
    multiPane()
    return
  loadOpen()
  let c = selectedConv()
  if c == nil or openMsgs.len == 0:
    let r = place(available(), remainingH(), fill = true)
    fill(r, ui.theme.field)
    sunken(r)
    let msg = if convs.len == 0: "" else: "Select a message to read it here."
    text(r.x + (r.w - textWidth(msg)) div 2, r.y + r.h div 3, msg, ui.theme.gray)
    return
  let lh = lineHeight()
  # OE4's gray header: the subject and the thread's tags, with the helpers
  let r = place(available(), 2 * lh + dp(14), fill = true)
  fill(r, ui.theme.face)
  hline(r.x, r.y + r.h - 1, r.w, ui.theme.shadow)
  let bold = style(bold = true)
  let compact = r.w < dp(620)
  # (the values start after the wider label, whatever the font)
  let lx = r.x + dp(16) + max(textWidth("Subject:", bold), textWidth("Thread:", bold))
  text(r.x + dp(8), r.y + dp(5), "Subject:", ui.theme.text, bold)
  text(lx, r.y + dp(5), fit(c.subject, r.x + r.w - lx - dp(10) - (if compact: 0 else: dp(330))),
       ui.theme.text)
  text(r.x + dp(8), r.y + dp(7) + lh, "Thread:", ui.theme.text, bold)
  let info = $openMsgs.len & (if openMsgs.len == 1: " message" else: " messages") & "  |  " &
             fit(c.people, dp(260))
  text(lx, r.y + dp(7) + lh, info, ui.theme.text)
  discard tagsAt(lx + dp(14) + textWidth(info), r.y + dp(7) + lh, dp(240), c.tags)
  if not compact:
    let ai = aiReady()
    let bw = if ai: dp(520) else: dp(318)
    pushFrame(rect(r.x + r.w - bw - dp(8), r.y + (r.h - CtrlH) div 2, bw, 0))
    row:
      if ai:
        let focus = block:
          var f = openMsgs[0]
          for x in openMsgs:
            if x.id == openFocus: f = x
          f
        if button("Summarize", nfComments): askAssistant("summary", openMsgs[0])
        if button("Translate", nfGlobe): askAssistant("translate", focus)
      if button("Tags", nfTags):
        tagMenuAt = ui.lastRect
        tagMenuOpen = true
      if button("Snooze", pxClock): snoozeOpen = true
      if button(if c.flagged: "Unflag" else: "Flag", nfFlag): toggleFlag(selectedMsgs())
    discard popFrame()
  elif aiReady() and openMsgs.len > 0:
    # (a narrow pane: the assistant's buttons under the header)
    row:
      if button("Summarize", nfComments): askAssistant("summary", openMsgs[0])
      var focus = openMsgs[0]
      for x in openMsgs:
        if x.id == openFocus: focus = x
      if button("Translate", nfGlobe): askAssistant("translate", focus)
  assistBox(openMsgs.mapIt(it.id))
  # read once it is opened (or after the moment Options say); marked so
  # once only, so that "Mark as Unread" stays
  let delay = float(prefInt("readDelay", 0))
  if c.unread > 0 and readMarked != c.key and delay < 9999:
    if epochTime() - openShown >= delay:
      markRead(c.msgs)
      readMarked = c.key
    else: wakeIn(250)
  let single = openMsgs.len == 1
  if single:
    let m = openMsgs[0]
    discard mailHeader(m, false)
    messageBody(m, true)
  else:
    # a message picked in the list: opened and brought to the top, while
    # the bodies above it come (until the reader scrolls or clicks)
    let paneR = rect(r.x, r.y + r.h, r.w, remainingH())
    if openJump != 0 and (epochTime() > openJumpUntil or
                          (canInput() and mouseIn(paneR) and (ui.wheel != 0 or ui.pressed))):
      openJump = 0
    if openJump > 0 and openJump notin openExpanded:
      for m in openMsgs:
        if m.id == openJump:
          openExpanded.incl m.id
          if m.bodyState == 0:
            store0.setBodyState(m.id, 1)
            link.cmds.send(SyncCmd(kind: scBody, id: m.id))
    let target = if openJump > 0: openJump elif openJump < 0: openMsgs[0].id else: 0
    panel(remainingH() - CtrlH - dp(12)):
      var loading = false
      for m in openMsgs:
        let open = m.id in openExpanded
        if open and m.bodyState < 2: loading = true
        if mailHeader(m, not open, focused = m.id == openFocus and openMsgs.len > 1):
          openFocus = m.id
          if open: openExpanded.excl m.id
          else:
            openExpanded.incl m.id
            if m.bodyState == 0:
              store0.setBodyState(m.id, 1)
              link.cmds.send(SyncCmd(kind: scBody, id: m.id))
        if m.id == target:
          revealInPanel(headerRect, glide = openJump > 0)
          if openJump < 0: openJump = 0
          elif loading:
            openJumpUntil = min(openJumpFrom + 8, max(openJumpUntil, epochTime() + 0.5))
            wakeIn(100)
        if open:
          messageBody(m, false)
          space()
  row:
    if r.w > dp(560):
      for s in quickReplies(c[]):
        if button(s): quickReply(s)
      space available() - 3 * (dp(90) + Gap) + Gap
    if button("Reply", pxBack, w = dp(90)): doReply("reply")
    if button("Reply all", pxUndo, w = dp(90)): doReply("replyAll")
    if button("Forward", pxForward, w = dp(90)): doReply("forward")

# ---- tags, snooze and move -------------------------------------------------------------

var tagFilter = ""
var tagScroll = 0
var tagHi = 0
var tagWasOpen = false

proc tagMenu() =
  ## Tags for the selected mail, as Outlook's Categorize menu: a box to find
  ## (or make) one, the tags with their colors and checks, a few commands.
  if not tagMenuOpen:
    tagWasOpen = false
    return
  let ms = selectedMsgs()
  if ms.len == 0:
    tagMenuOpen = false
    return
  let opening = not tagWasOpen
  if opening:
    tagWasOpen = true
    tagFilter = ""
    tagScroll = 0
    tagHi = 0
  let lh = lineHeight()
  let ih = lh + dp(10)
  let w = dp(260)
  # the tags of the selected mail's accounts, those that match what is typed
  var accts: seq[int]
  for m in ms:
    if m.account notin accts: accts.add m.account
  var shown: seq[Tag]
  let f = tagFilter.strip.toLowerAscii
  for t in tagsC:
    if f.len == 0 or f in t.name.toLowerAscii: shown.add t
  let exact = shown.anyIt(it.name.toLowerAscii == f)
  let canMake = f.len > 0 and not exact
  let rowsN = shown.len + ord(canMake)
  let maxRows = max(3, min(12, (ui.h - dp(160)) div ih))
  let visRows = min(rowsN, maxRows)
  let listH = max(1, visRows) * ih
  var r = rect(tagMenuAt.x, tagMenuAt.y + tagMenuAt.h, w, CtrlH + dp(14) + listH + 3 * ih + dp(18))
  if r.x + r.w > ui.w: r.x = ui.w - r.w - dp(4)
  if r.y + r.h > ui.h: r.y = max(0, ui.h - r.h - dp(4))
  ui.overlayNow = r
  fill(r, ui.theme.face)
  box(r, ui.theme.frame)
  raised(inset(r, 1), 1)
  # the box to find or make a tag
  pushFrame(rect(r.x + dp(6), r.y + dp(6), w - dp(12), CtrlH))
  row:
    if opening: ui.textFocusWanted = true      # (typing goes to it at once)
    edit(tagFilter, w = w - dp(12))
  discard popFrame()
  if tagFilter.len == 0:
    text(r.x + dp(12), r.y + dp(6) + (CtrlH - lh) div 2, "Find or make a tag", ui.theme.gray)
  var y = r.y + CtrlH + dp(12)
  var cur: seq[string]
  for m in ms:
    for t in m.tags:
      if t notin cur: cur.add t
  # keys: up and down through the tags, Enter picks, Esc closes
  if canInput() and not ui.keyUsed:
    if ui.key == KeyDown: tagHi = min(rowsN - 1, tagHi + 1); ui.keyUsed = true
    elif ui.key == KeyUp: tagHi = max(0, tagHi - 1); ui.keyUsed = true
    elif ui.key == KeyEsc: tagMenuOpen = false; ui.keyUsed = true
  tagHi = clamp(tagHi, 0, max(0, rowsN - 1))
  if tagHi < tagScroll: tagScroll = tagHi
  if tagHi >= tagScroll + visRows: tagScroll = tagHi - visRows + 1
  let listR = rect(r.x + dp(3), y, w - dp(6), listH)
  if canInput() and ui.wheel != 0 and mouseIn(listR) and rowsN > visRows:
    tagScroll = clamp(tagScroll - ui.wheel, 0, rowsN - visRows)
    ui.wheelUsed = true
  let enter = canInput() and not ui.keyUsed and ui.key == KeyEnter
  if enter: ui.keyUsed = true
  pushClip(listR)
  if rowsN == 0:
    text(r.x + dp(12), y + dp(5), "No tags yet: type a name", ui.theme.gray)
  for k in tagScroll ..< min(rowsN, tagScroll + visRows):
    let it = rect(r.x + dp(3), y, w - dp(6), ih)
    if k < shown.len:
      let t = shown[k]
      let hit = interact(idOf("tagitem" & t.name), it, focusable = false)
      if hit.hover and ui.mouseMoved: tagHi = k
      let lit = k == tagHi
      if lit: fill(it, ui.theme.select)
      let fg = if lit: ui.theme.selectText else: ui.theme.text
      let on = cur.anyIt(it.toLowerAscii == t.name.toLowerAscii)
      if on: text(it.x + dp(6), y + dp(5), nfCheck, fg)
      fill(rect(it.x + dp(26), y + dp(5), dp(14), dp(14)), tagColor(t.name))
      box(rect(it.x + dp(26), y + dp(5), dp(14), dp(14)), ui.theme.frame)
      text(it.x + dp(48), y + dp(5), fit(t.name, it.w - dp(110)), fg)
      var idx = -1
      for q, tt in tagsC:
        if tt.name == t.name: idx = q
      if f.len == 0 and idx in 0 .. 9:
        let sc = "Ctrl+" & $((idx + 1) mod 10)
        text(it.x + it.w - textWidth(sc) - dp(8), y + dp(5), sc, fg)
      if hit.clicked or (enter and lit):
        setMsgTags(ms, t.name, not on)
        status = (if on: "Took off the tag " else: "Tagged ") & t.name
        tagMenuOpen = false
    else:
      let name = tagFilter.strip
      let hit = interact(idOf("tagmake"), it, focusable = false)
      if hit.hover and ui.mouseMoved: tagHi = k
      let lit = k == tagHi
      if lit: fill(it, ui.theme.select)
      let fg = if lit: ui.theme.selectText else: ui.theme.text
      text(it.x + dp(6), y + dp(5), "+", fg, style(bold = true))
      text(it.x + dp(26), y + dp(5), fit("New tag \"" & name & "\"", it.w - dp(32)), fg)
      if hit.clicked or (enter and lit):
        addTag(name, tagPalette[tagsC.len mod tagPalette.len][1])
        setMsgTags(ms, name, true)
        status = "Tagged " & name
        tagMenuOpen = false
    y += ih
  popClip()
  y = listR.y + listR.h
  hline(r.x + dp(4), y + dp(3), w - dp(8), ui.theme.shadow)
  hline(r.x + dp(4), y + dp(4), w - dp(8), ui.theme.light)
  y += dp(8)
  for (label, what) in [("New tag...", 1), ("Clear all tags", 2), ("All tags (Options)...", 3)]:
    let it = rect(r.x + dp(3), y, w - dp(6), ih)
    let hit = interact(idOf("tagcmd" & label), it, focusable = false)
    if hit.hover: fill(it, ui.theme.select)
    text(r.x + dp(51), y + dp(5), label, if hit.hover: ui.theme.selectText else: ui.theme.text)
    if hit.clicked:
      tagMenuOpen = false
      case what
      of 1: newTagOpen = true
      of 2: clearTags(ms)
      else:
        optTab = 5
        optOpen = true
    y += ih
  if canInput() and ui.pressed and not mouseIn(r) and not mouseIn(tagMenuAt):
    tagMenuOpen = false
  if keyHit(KeyEsc): tagMenuOpen = false

proc smallDialogs() =
  let ms = selectedMsgs()
  dialog snoozeOpen, "Snooze", dp(300):
    label "Hide it until:"
    for (label, t) in [("Later today", laterToday()), ("Tomorrow morning", tomorrowAt(8)),
                       ("This weekend", nextMonday() - 2 * 86400), ("Next week", nextMonday())]:
      if button(label & "    " & fromUnixFloat(t).local.format("ddd HH:mm"), w = dp(270)):
        snoozeMsgs(ms, t)
        snoozeOpen = false
    if button("Cancel", w = dp(270)): snoozeOpen = false
  dialog moveOpen, "Move to Folder", dp(360):
    if ms.len == 0:
      moveOpen = false
    else:
      let fs = foldersC.getOrDefault(ms[0].account)
      var names: seq[string]
      for f in fs: names.add f.name
      label "Move the selected messages to:"
      listbox(names, moveSel, rows = 10)
      row:
        space available() - 2 * (dp(80) + Gap) + Gap
        if button("OK", isDefault = true, w = dp(80), enabled = moveSel in 0 ..< fs.len):
          moveMsgs(ms, "", fs[moveSel].id)
          moveOpen = false
        if button("Cancel", w = dp(80)): moveOpen = false
  dialog newTagOpen, "New Tag", dp(340):
    form dp(60):
      field "&Name:": edit newTagName
      field "&Color:":
        var names: seq[string]
        for (n, _) in tagPalette: names.add n
        combo(names, newTagColor)
    row:
      space available() - 2 * (dp(80) + Gap) + Gap
      if button("OK", isDefault = true, w = dp(80), enabled = newTagName.strip.len > 0):
        let name = newTagName.strip
        addTag(name, tagPalette[newTagColor][1])
        if ms.len > 0: setMsgTags(ms, name, true)
        newTagName = ""
        newTagOpen = false
      if button("Cancel", w = dp(80)): newTagOpen = false
  if fileDialog(saveAttOpen, saveAttPath, fmSave, ["All Files (*.*)"]):
    let data = store0.attachmentData(saveAttId)
    if data.len == 0: status = "The attachment is still downloading: try again in a moment"
    else:
      try:
        writeFile(saveAttPath, data)
        status = "Saved " & saveAttPath
      except CatchableError as e: status = e.msg
  if fileDialog(saveAllOpen, saveAllDir, fmFolder, title = "Save All Attachments"):
    var n = 0
    var waiting = 0
    for a in store0.attachments(saveAllMsg):
      if a.inline: continue
      let data = store0.attachmentData(a.id)
      if data.len == 0:
        inc waiting
        continue
      try:
        writeFile(saveAllDir / a.name.multiReplace(("/", "_"), ("\\", "_"), (":", "_")), data)
        inc n
      except CatchableError as e: status = e.msg
    status = "Saved " & $n & " file(s) in " & saveAllDir &
             (if waiting > 0: "; " & $waiting & " still downloading" else: "")

proc mailKeys() =
  if not canInput() or ui.keyUsed: return
  let ctrl = CtrlPressed in ui.mods
  let shift = ShiftPressed in ui.mods
  let ms = selectedMsgs()
  if ctrl and ui.key == KeyN: openCompose("new"); ui.keyUsed = true
  elif ctrl and shift and ui.key == KeyR: doReply("replyAll"); ui.keyUsed = true
  elif ctrl and ui.key == KeyR: doReply("reply"); ui.keyUsed = true
  elif ctrl and shift and ui.key == KeyF: openFind(); ui.keyUsed = true
  elif ctrl and ui.key == KeyF: doReply("forward"); ui.keyUsed = true
  elif ctrl and ui.key == KeyQ: markRead(ms); ui.keyUsed = true
  elif ctrl and ui.key == KeyU: markRead(ms, true); ui.keyUsed = true
  elif ctrl and ui.key == KeyT: tagMenuOpen = true; ui.keyUsed = true
  elif ctrl and ui.key == KeyE: ui.textFocusWanted = true; ui.keyUsed = true
  elif ctrl and ui.key in {Key1, Key2, Key3, Key4, Key5}:
    view = [vMail, vCalendar, vPeople, vTodo, vNotes][ord(ui.key) - ord(Key1)]
    ui.keyUsed = true
  elif ui.key == KeyF5: link.cmds.send(SyncCmd(kind: scSyncNow)); ui.keyUsed = true
  elif ctrl and shift and ui.key == KeyV and ms.len > 0: moveOpen = true; ui.keyUsed = true
  elif ctrl and ui.key == KeyY: runCommand("Go to folder"); ui.keyUsed = true
  elif ctrl and ui.key == KeyPeriod: clearMulti(); moveRow(1); ui.keyUsed = true
  elif ctrl and ui.key == KeyComma: clearMulti(); moveRow(-1); ui.keyUsed = true
  elif AltPressed in ui.mods and ui.key == KeyQ: runCommand("Tell me"); ui.keyUsed = true
  elif ctrl and ui.key == KeyP and ms.len > 0: printMessage(); ui.keyUsed = true
  elif ctrl and ui.key == KeyF3 and ms.len > 0: showProperties(source = true); ui.keyUsed = true
  elif AltPressed in ui.mods and ui.key == KeyEnter and ms.len > 0: showProperties(); ui.keyUsed = true
  elif ui.key == KeyF6:
    # F6: the next pane (folders, list, search box), as Outlook goes round
    runCommand("Next pane")
    ui.keyUsed = true
  elif ui.key == KeyEsc and multiSelecting(): clearMulti(); ui.keyUsed = true
  elif ui.focus == 0 or ui.focus == listIdC:
    if ui.key == KeyDelete and ms.len > 0: deleteMsgs(ms); ui.keyUsed = true
    elif ui.key == KeyBackspace and ms.len > 0: archiveMsgs(ms); ui.keyUsed = true
    elif ui.key == KeyInsert and ms.len > 0: toggleFlag(ms); ui.keyUsed = true
    elif ui.key == KeyEnter and isCompact(): phone = phRead; ui.keyUsed = true
    elif ui.key == KeyEnter and ms.len > 0: readerOpen = true; ui.keyUsed = true

# Retro Mail on a phone or a tablet in the newer looks (Glass, Matte, Gloss -- Gloss drawn as phones
# had their mail in 2012): Mailboxes -- the inboxes, all of them together, flagged and unread mail,
# your accounts --, an account's folders, a folder's messages (a blue dot on the unread ones, Edit
# to choose several), one message ("3 of 9" and its arrows to the next, its sender and who it went
# to as names in capsules), writing; action sheets for what is done to a message. On a tablet the
# mailboxes and the list stay down the left, the message beside them. Included by
# examples/mail.nim.
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

type TPage = enum tpBoxes, tpAccount, tpList, tpMessage, tpMore, tpSettings, tpLook

var
  tStack = @[tpBoxes]
  tAccount = 0               ## the account whose folders are open (its id)
  tMore = vCalendar          ## the view More opened (Calendar, People, To Do, Notes)
  tFlagOpen = false          ## the message's sheet: Flag, Mark as Unread
  tReplyOpen = false         ## Reply, Reply All, Forward
  tEditing = false           ## the list's Edit: several chosen
  tSigOpen = false           ## writing: which signature
  tFromOpen = false          ## ... from which account
  tInsertOpen = false        ## ... Insert Photo or Video
  tInsertAt: Rect
  touchLayout = 0            ## (0: the screen's; 1 a phone's, 2 a tablet's: tests)
  tUpdated = 0.0             ## (when the mail was last checked, as the toolbar says)

proc touchUi(): bool =
  ## This shell, not the 3.1 one: the newer looks on a phone or a tablet.
  touchLayout > 0 or (glassLook() and (isCompact() or ui.touch))

proc tabletMail(): bool = touchLayout == 2 or (touchLayout == 0 and not isCompact())

proc tPage(): TPage = tStack[^1]
proc tPush(p: TPage) = tStack.add p
proc tPop() =
  if tStack.len > 1: tStack.setLen(tStack.len - 1)

proc onDarkMail(): bool = lumaOfColor(ui.theme.window) < 128

proc toolInk(): Color =
  ## (a toolbar's glyphs: white on Gloss's steel, the highlight on the others' glass)
  if glossLook(): rgb(255, 255, 255)
  elif onDarkMail(): mixColor(accentColor(), rgb(255, 255, 255), 0.35)
  else: accentColor()

proc toolsBar(r: Rect; items: openArray[(string, string)]; status = ""; below = 0;
              enabled: openArray[bool] = []): int =
  ## A bar of glyph buttons along `r` (a phone's toolbar at its foot): Gloss's glossy steel,
  ## its glyphs white; the others' bar of glass, its glyphs in the highlight. `status`: small words
  ## in its middle (between its first button and the others). Returns the one tapped, -1 none.
  result = -1
  let face = rect(r.x, r.y, r.w, r.h + below)
  if glossLook(): glossBarFill(face)
  elif glassLook():
    titleBar(face, true)
    hline(r.x, r.y, r.w, glassHair())
  else:
    fill(face, ui.theme.face)
    hline(r.x, r.y, r.w, ui.theme.shadow)
  let gs = style(size = 1.25)
  let n = items.len
  let bw = if fingers(): dp(48) else: dp(40)
  # (the first at the start, the others spread from the end; the words between)
  let firstX = r.x + dp(6)
  let restW = (n - 1) * bw
  let restX = r.x + r.w - dp(6) - restW
  for k, (glyph, name) in items:
    let x = if k == 0: firstX elif status.len > 0: restX + (k - 1) * bw
            else: r.x + dp(6) + k * (r.w - dp(12) - bw) div max(1, n - 1)
    let b = rect(x, r.y, bw, r.h)
    let on = k >= enabled.len or enabled[k]
    let hit = interact(idOf("tools:" & name), b, focusable = false, enabled = on)
    if hit.down: roundRect(inset(b, dp(4)), float(dp(8)), withAlpha(rgb(255, 255, 255), 50))
    let ink = if on: toolInk() else: mixColor(toolInk(), ui.theme.window, 0.6)
    let gx = b.x + (b.w - textWidth(glyph, gs)) div 2
    let gy = b.y + (b.h - lineHeight(gs)) div 2
    if glossLook(): text(gx, gy - 1, glyph, withAlpha(rgb(0, 0, 0), 100), gs)
    text(gx, gy, glyph, ink, gs)
    if accessOn: accessNode(arButton, name, id = idOf("tools:" & name), r = b)
    if hit.clicked: result = k
  if status.len > 0:
    let st = style(size = 0.82, bold = glossLook())
    let room = restX - (firstX + bw) - dp(8)
    let s = fit(status, room, st)
    let sx = firstX + bw + (room - textWidth(s, st)) div 2
    let sy = r.y + (r.h - lineHeight(st)) div 2
    if glossLook(): text(sx, sy - 1, s, withAlpha(rgb(0, 0, 0), 90), st)
    text(sx, sy, s, if glossLook(): rgb(255, 255, 255) else: ui.theme.gray, st)

proc checkForMail() =
  link.cmds.send(SyncCmd(kind: scSyncNow))
  syncText = "Checking for Mail..."
  tUpdated = epochTime()

proc mailStatus(): string =
  if syncText.len > 0: syncText
  elif tUpdated > 0:
    let ago = epochTime() - tUpdated
    if ago < 60: "Updated Just Now" else: "Updated " & fromUnixFloat(tUpdated).local.format("HH:mm")
  elif status.len > 0: status
  else: ""

proc listTools(r: Rect; below: int) =
  ## (the mailboxes' and a list's toolbar: check for mail, how it is, write a new one; while
  ## choosing several: Mark, Move, Trash)
  if tEditing and multiSel.len > 0:
    let ms = selectedMsgs()
    case toolsBar(r, [(nfEnvelope, "Mark"), (nfFolder, "Move"), (nfTrash, "Trash")], below = below)
    of 0:
      markRead(ms, ms.allIt(not it.unread))
      tEditing = false
      clearMulti()
    of 1: moveOpen = true
    of 2:
      deleteMsgs(ms)
      tEditing = false
      clearMulti()
    else: discard
    return
  case toolsBar(r, [(nfRefresh, "Check for Mail"), (nfEdit, "New Message")], mailStatus(), below,
                [true, accountsC.len > 0])
  of 0: checkForMail()
  of 1: openCompose("new")
  else: discard

# ---- mailboxes --------------------------------------------------------------------------------------

proc folderGlyph(f: Folder): string =
  case f.role
  of "inbox": nfInbox
  of "sent": nfSend
  of "drafts": nfFileText
  of "trash": nfTrash
  of "archive": nfArchive
  of "junk": nfExclamation
  else: nfFolder

proc openPlace(p: Place) =
  goPlace(p)
  tEditing = false
  clearMulti()
  if tabletMail():
    # (a tablet: the list in the left column, the message beside it)
    while tStack.len > 1 and tPage() != tpBoxes and tPage() != tpAccount: tPop()
  tPush(tpList)

proc countText(n: int): string = (if n > 0: $n else: "")

proc mailboxesPage() =
  tableGroup("Inboxes"):
    if tableRow("All Inboxes", "", taChevron, glyph = nfInbox, tint = rgb(38, 110, 220),
                count = countText(unreadAll()), key = "all").clicked:
      openPlace(Place(kind: plAllInbox))
    for a in accountsC:
      let ib = roleFolder(a.id, "inbox")
      if ib.id == 0: continue
      if tableRow(if a.name.len > 0: a.name else: a.email, "", taChevron, glyph = nfInbox,
                  tint = rgb(38, 110, 220), count = countText(ib.unread), key = "inbox" & $a.id).clicked:
        openPlace(Place(kind: plFolder, folder: ib.id))
    if tableRow("Flagged", "", taChevron, glyph = nfFlag, tint = rgb(236, 136, 24), key = "flagged").clicked:
      openPlace(Place(kind: plFlagged))
    if tableRow("Unread", "", taChevron, glyph = nfEnvelope, tint = rgb(46, 130, 230), key = "unread").clicked:
      openPlace(Place(kind: plUnread))
  tableGroup("Accounts"):
    for a in accountsC:
      let sub = if a.state == "signin": "Sign in again" elif a.state.len > 0: a.state else: a.email
      if tableRow(if a.name.len > 0: a.name else: a.email, "", taChevron, glyph = nfAt,
                  tint = rgb(120, 128, 142), subtitle = sub, key = "acct" & $a.id).clicked:
        tAccount = a.id
        tPush(tpAccount)
    if tableRow("Add Account", "", taChevron, glyph = nfUser, tint = rgb(46, 160, 90), key = "addacct").clicked:
      openWizard()
  tableGroup("More"):
    for (v, g, name, tint) in [(vCalendar, nfCalendar, "Calendar", rgb(220, 60, 50)),
                               (vPeople, nfUsers, "People", rgb(120, 128, 142)),
                               (vTodo, nfCheck, "To Do", rgb(46, 130, 230)),
                               (vNotes, nfFileText, "Notes", rgb(232, 170, 30))]:
      if tableRow(name, "", taChevron, glyph = g, tint = tint, key = "more" & name).clicked:
        tMore = v
        view = v
        tPush(tpMore)
    if tableRow("Settings", "", taChevron, glyph = nfCog, tint = rgb(128, 128, 136), key = "settings").clicked:
      tPush(tpSettings)

proc prefToggle(title, key: string; default: bool; detail = ""): bool =
  ## (a setting of yes or no, kept at once)
  var b = prefBool(key, default)
  if settingToggle(title, b, detail):
    prefs.put(key, b)
    savePrefs()
    result = true

proc prefChoice(title, key: string; values: openArray[int]; names: openArray[string];
                default: int; detail = ""): bool =
  ## (a setting of one of a few, kept at once)
  var i = max(0, values.find(prefInt(key, default)))
  if settingCombo(title, names, i, detail):
    prefs.put(key, values[i])
    savePrefs()
    result = true

proc settingsPage() =
  ## Settings as a phone's: the accounts, when mail comes, reading, writing, what is kept safe, the
  ## look -- each row kept as it is changed; the rest (signatures, spelling, swipes, tags, the
  ## assistant) in the Options of before.
  tableGroup("Accounts"):
    for a in accountsC:
      let sub = if a.state == "signin": "Sign in again" elif a.state.len > 0: a.state else: a.email
      if tableRow(if a.name.len > 0: a.name else: a.email, "", taChevron, glyph = nfAt,
                  tint = rgb(120, 128, 142), subtitle = sub, key = "sacct" & $a.id).clicked:
        tAccount = a.id
        tPush(tpAccount)
    if tableRow("Add Account", "", taChevron, glyph = nfUser, tint = rgb(46, 160, 90), key = "saddacct").clicked:
      openWizard()
  tableGroup("New Mail"):
    var names: seq[string]
    for m in intervals: names.add $m & (if m == 1: " minute" else: " minutes")
    if prefChoice("Check every", "interval", intervals, names, 1):
      link.cmds.send(SyncCmd(kind: scSettings, count: prefInt("interval", 1)))
    var ds: seq[int]
    var dayNames: seq[string]
    for (d, n) in keepDays:
      ds.add d
      dayNames.add n
    if prefChoice("Keep to read offline", "syncDays", ds, dayNames, 90):
      store0.exec("UPDATE accounts SET sync_days = ?", prefInt("syncDays", 90))
    when defined(android):
      if javaAvailable():
        if prefToggle("Check while closed", "bgCheck", true):
          scheduleBackgroundCheck(if prefBool("bgCheck", true): 15 else: 0)
    discard prefToggle("Tell Me", "notify", true)
    discard prefToggle("Sound", "newMailSound", true)
  tableGroup("Reading"):
    if prefToggle("Organize by Thread", "threads", true): changed()
    if prefToggle("Focused Inbox", "focused", true, "What matters first, the rest under Other"): changed()
    discard prefChoice("Mark as read", "readDelay", [0, 1, 2, 5, 9999],
                       ["At once", "1 second", "2 seconds", "5 seconds", "Never by itself"], 0)
    discard prefChoice("Pictures from the web", "pictures", [0, 1], ["Ask each time", "Always show them"], 0)
    discard prefToggle("Plain Text Only", "plainRead", false)
  tableGroup("Writing"):
    discard prefToggle("Replies in Blue", "replyBlue", true)
    discard prefChoice("Undo Send", "undoSend", [0, 5, 10, 20, 30],
                       ["Not at all", "5 seconds", "10 seconds", "20 seconds", "30 seconds"], 10)
  tableGroup("Kept Safe", "Encrypting or decrypting the mail kept here takes effect when Retro Mail starts again."):
    discard prefToggle("Encrypt the mail here", "encryptStore", true)
    discard prefToggle("Warn about look-alikes", "phishWarn", true)
    discard prefToggle("Take out trackers", "noTrackers", true)
  tableGroup(""):
    if tableRow("Appearance", "", taChevron, glyph = nfPalette, tint = rgb(150, 90, 210), key = "slook").clicked:
      tPush(tpLook)
    if tableRow("More Options", "", taChevron, glyph = nfCog, tint = rgb(128, 128, 136), key = "smore").clicked:
      optOpen = true
    if tableRow("About Retro Mail", "", taChevron, glyph = nfInfo, tint = rgb(38, 110, 220),
                key = "sabout").clicked:
      aboutOpen = true

proc lookPage() =
  if appearanceSettings():
    storeAppearance(prefs)
    savePrefs()

proc accountPage() =
  let a = account(tAccount)
  var fs = foldersC.getOrDefault(tAccount)
  # (the inbox, drafts, sent, junk, trash, archive first, as phones list them; then the others)
  const order = ["inbox", "drafts", "sent", "junk", "trash", "archive"]
  proc rank(f: Folder): int =
    let k = order.find(f.role)
    if k < 0: order.len else: k
  fs.sort(proc (x, y: Folder): int =
    if rank(x) != rank(y): cmp(rank(x), rank(y)) else: cmpIgnoreCase(x.name, y.name))
  if fs.len == 0:
    emptyState(nfFolder, "No folders yet", detail = if a.state.len > 0: a.state else: "They come with its mail.")
    return
  tableGroup(""):
    for f in fs:
      if tableRow(f.name, "", taChevron, glyph = folderGlyph(f), tint = rgb(38, 110, 220),
                  count = countText(if f.role in ["inbox", "junk"]: f.unread else: 0), key = "f" & $f.id).clicked:
        openPlace(Place(kind: plFolder, folder: f.id))

# ---- the list -------------------------------------------------------------------------------------------

proc unreadDot(cx, cy: int) =
  ## (an unread message's dot: Gloss's glossy blue bead, the others' the highlight)
  let r = float(max(dp(5), 4))
  if glossLook():
    discShaded(float(cx), float(cy), r, rgb(120, 180, 250), rgb(20, 90, 210))
    disc(float(cx), float(cy) - r * 0.35, r * 0.45, withAlpha(rgb(255, 255, 255), 150))
  else: disc(float(cx), float(cy), r, accentColor())

proc convRowH(): int = 3 * FontH + dp(if fingers(): 26 else: 18)

proc convRow(i: int; c: Conv; r: Rect) =
  ## One message (or conversation) in the list: its sender bold, the day blue at the end, the
  ## subject, two gray lines of it; a blue dot while unread; chosen with a check while editing.
  let m = c.msgs[0]
  let key = rowKey(i)
  let id = idOf("trow" & c.key)
  let hit = interact(id, r, focusable = false)
  if ui.rpressed and mouseIn(r) and canInput():
    # (a finger held, a right click: choosing several, this one first)
    if not tEditing:
      tEditing = true
      clearMulti()
    multiSel.incl key
  elif hit.clicked:
    if tEditing:
      if key in multiSel: multiSel.excl key else: multiSel.incl key
    else:
      selectRow(i)
      if not tabletMail(): tPush(tpMessage)
  let selected = tabletMail() and i == selRow and not tEditing
  let chosen = tEditing and key in multiSel
  let dark = onDarkMail()
  if selected or hit.down:
    if glossLook(): glossBlue(r)
    elif modernGlass(): glassBlue(rect(r.x + dp(4), r.y + dp(2), r.w - dp(8), r.h - dp(4)), float(dp(12)), glow = false)
    else: fill(r, ui.theme.select)
  let lit = selected or hit.down
  let ink = if lit: rgb(255, 255, 255) else: ui.theme.fieldText
  let dim = if lit: withAlpha(rgb(255, 255, 255), 210) else: ui.theme.gray
  let blue = if lit: rgb(255, 255, 255) elif glossLook(): glossDetail() else: accentColor()
  let pad = dp(12)
  let gutter = if tEditing: dp(40) else: dp(24)
  if tEditing:
    let d = dp(22)
    let cx = r.x + dp(10) + d div 2
    let cy = r.y + r.h div 2
    if chosen:
      if glossLook(): discShaded(float(cx), float(cy), float(d) / 2, rgb(230, 70, 60), rgb(180, 20, 20))
      else: disc(float(cx), float(cy), float(d) / 2, accentColor())
      text(cx - textWidth(nfCheck) div 2, cy - FontH div 2, nfCheck, rgb(255, 255, 255))
    else: ring(float(cx), float(cy), float(d) / 2 - 1, 1.4, mixColor(ui.theme.field, ui.theme.fieldText, 0.35))
  elif c.unread > 0: unreadDot(r.x + dp(12), r.y + dp(8) + FontH div 2)
  let x = r.x + gutter
  let day = shortDate(m.date)
  let dw = textWidth(day)
  let bold = style(bold = true)
  let who0 = if c.msgs.len > 1: c.people else: who(m)
  var top = fit(who0, r.x + r.w - pad - dw - dp(10) - x, bold)
  text(x, r.y + dp(6), top, ink, bold)
  if c.msgs.len > 1:
    let n = $c.msgs.len
    let nx = x + textWidth(top, bold) + dp(6)
    let nw = textWidth(n, style(size = 0.8)) + dp(10)
    if nx + nw < r.x + r.w - pad - dw - dp(10):
      roundRect(rect(nx, r.y + dp(8), nw, FontH - dp(2)), float(FontH - dp(2)) / 2,
                if lit: withAlpha(rgb(255, 255, 255), 60) else: mixColor(ui.theme.field, ui.theme.fieldText, 0.18))
      text(nx + dp(5), r.y + dp(8), n, ink, style(size = 0.8))
  text(r.x + r.w - pad - dw, r.y + dp(6), day, blue)
  var marks = ""
  if c.hasAtt: marks.add nfPaperclip
  if c.flagged: marks.add (if marks.len > 0: " " else: "") & nfFlag
  let mw = if marks.len > 0: textWidth(marks) + dp(8) else: 0
  text(x, r.y + dp(8) + FontH, fit(if c.subject.len > 0: c.subject else: "(no subject)", r.x + r.w - pad - x - mw),
       ink)
  if marks.len > 0:
    text(r.x + r.w - pad - textWidth(marks), r.y + dp(8) + FontH, marks,
         if lit: ink elif c.flagged: rgb(236, 136, 24) else: dim)
  var lines = wrapLines(m.snippet, r.x + r.w - pad - x)
  if lines.len > 2: lines.setLen(2)
  for k, ln in lines:
    if k == 1 and r.h < 4 * FontH + dp(14):
      text(x, r.y + dp(10) + 2 * FontH, fit(lines[0] & " " & ln, r.x + r.w - pad - x), dim)
      break
    if k == 0 and r.h < 4 * FontH + dp(14) and lines.len > 1: continue
    text(x, r.y + dp(10) + (2 + k) * FontH, ln, dim)
  if not lit:
    hline(x, r.y + r.h - 1, r.x + r.w - x,
          if glossLook(): (if dark: mixColor(ui.theme.field, rgb(255, 255, 255), 0.08) else: rgb(217, 217, 217))
          elif modernGlass(): glassHair() else: mixColor(ui.theme.field, ui.theme.fieldText, 0.12))
  if accessOn:
    accessNode(arListItem, who0 & ", " & c.subject, id = id, r = r,
               states = (if chosen or selected: {asSelected} else: {}))

proc listPage() =
  ## (a folder's messages, the newest first; the search over them; pulled down: checked)
  if pullRefresh(syncText.len > 0): checkForMail()
  if isInboxPlace() and prefBool("focused", true) and query.len == 0:
    # (Focused and Other: the mail that matters first, the rest beside it)
    let r = place(0, CtrlH + dp(14), fill = true)
    pushFrame(rect(r.x + dp(10), r.y + dp(7), r.w - dp(20), 0))
    var t = focusTab
    if segmented(["Focused", "Other"], t, w = r.w - dp(20)):
      focusTab = t
      selRow = -1
      selKey = ""
      changed()
    discard popFrame()
  let rh = convRowH()
  var n = 0
  for i, row in rows:
    if row.msg >= 0: continue
    if row.group.len > 0:
      let st = style(bold = true, size = 0.85)
      let g = place(0, lineHeight(st) + dp(8), fill = true)
      fill(g, if glossLook(): (if onDarkMail(): rgb(40, 42, 46) else: rgb(218, 223, 232))
              else: mixColor(ui.theme.window, ui.theme.text, 0.06))
      text(g.x + dp(12), g.y + dp(4), row.group, if glossLook() and not onDarkMail(): rgb(76, 86, 108) else: ui.theme.gray, st)
      continue
    let r = place(0, rh, fill = true)
    let seen = clipRect()
    if r.y + r.h >= seen.y and r.y <= seen.y + seen.h: convRow(i, convs[row.conv], r)
    else: discard interact(idOf("trow" & convs[row.conv].key), r, focusable = false)
    inc n
  if n == 0:
    emptyState(nfInbox, if accountsC.len == 0: "No account yet" elif query.len > 0: "Nothing found"
                        else: "No Mail", detail = if accountsC.len == 0: "Mailboxes, Add Account." else: "")

# ---- one message ---------------------------------------------------------------------------------------

proc nameChip(x, y: int; name: string; maxW: int): int =
  ## (a name in a capsule, as a phone's mail showed who wrote and who it went to; its width)
  let st = style(size = 0.95)
  let t = fit(name, maxW - dp(16), st)
  let w = textWidth(t, st) + dp(16)
  let h = FontH + dp(6)
  let r = rect(x, y, w, h)
  if glossLook():
    roundRectShaded(r, float(h) / 2, rgb(206, 222, 246), rgb(176, 198, 236))
    roundFrame(r, float(h) / 2, 1, rgb(140, 166, 214))
  else: roundRect(r, float(h) / 2, mixColor(ui.theme.field, accentColor(), if onDarkMail(): 0.3 else: 0.14))
  text(x + dp(8), y + (h - lineHeight(st)) div 2, t, if glossLook(): rgb(20, 40, 80) else: ui.theme.fieldText, st)
  w

proc namesOf(list: string): seq[string] =
  ## ("Ali <ali@x.om>, sara@y.om" -> Ali, sara@y.om)
  for part in list.split(','):
    let p = part.strip
    if p.len == 0: continue
    let lt = p.find('<')
    let n = if lt > 0: p[0 ..< lt].strip.strip(chars = {'"'}) else: p
    result.add(if n.len > 0: n else: p)

proc convPos(): tuple[at, total: int] =
  ## (the message open among the list's: "3 of 9")
  for i, row in rows:
    if row.group.len > 0 or row.msg >= 0: continue
    inc result.total
    if i == selRow: result.at = result.total

proc messageHeader(m: Msg; c: Conv) =
  let lh = FontH + dp(8)
  let w = available()
  let lst = style()
  let lw = textWidth("From:", lst) + dp(8)
  # From
  var r = place(0, lh + dp(4), fill = true)
  text(r.x, r.y + dp(6), "From:", ui.theme.gray, lst)
  discard nameChip(r.x + lw, r.y + dp(2), (if m.fromName.len > 0: m.fromName else: m.fromEmail), w - lw)
  # To (and Cc), as many as fit, then "and n more"
  r = place(0, lh + dp(4), fill = true)
  text(r.x, r.y + dp(6), "To:", ui.theme.gray, lst)
  var x = r.x + lw
  let names = namesOf(m.toList) & namesOf(m.ccList)
  for k, n in names:
    let left = r.x + r.w - x
    if left < dp(90) and k < names.len:
      text(x, r.y + dp(6), "& " & $(names.len - k) & " more", ui.theme.gray)
      break
    x += nameChip(x, r.y + dp(2), n, min(left, dp(200))) + dp(6)
  let sep = place(0, 1, fill = true)
  fill(sep, mixColor(ui.theme.window, ui.theme.text, 0.15))
  # the subject, the day, its flag
  let st = style(bold = true, size = 1.15)
  # (wrapped as bold text of the usual size, its room smaller by as much as it is larger)
  for ln in wrapLines(if c.subject.len > 0: c.subject else: "(no subject)",
                      int(float(w - (if c.flagged: dp(28) else: 0)) / 1.15), true):
    let lr = place(0, lineHeight(st), fill = true)
    text(lr.x, lr.y, ln, ui.theme.text, st)
  let dr = place(0, FontH + dp(2), fill = true)
  text(dr.x, dr.y, fromUnixFloat(m.date).local.format("d MMMM yyyy  HH:mm"), ui.theme.gray)
  if c.flagged: text(dr.x + dr.w - textWidth(nfFlag), dr.y, nfFlag, rgb(236, 136, 24))
  let sep2 = place(0, 1, fill = true)
  fill(sep2, mixColor(ui.theme.window, ui.theme.text, 0.15))

proc messagePage() =
  loadOpen()
  let c = selectedConv()
  if c == nil or openMsgs.len == 0:
    emptyState(nfEnvelope, "No Message Selected")
    return
  # read once it is open (unless Options say never)
  if c.unread > 0 and readMarked != c.key and prefInt("readDelay", 0) < 9999:
    markRead(c.msgs)
    readMarked = c.key
  var m = openMsgs[0]
  for x in openMsgs:
    if x.id == openFocus: m = x
  messageHeader(m, c[])
  messageBody(m, false)
  # the other messages of its thread, under it, older ones after
  if openMsgs.len > 1:
    space(dp(8))
    tableGroup("In This Conversation"):
      for x in openMsgs:
        if x.id == m.id: continue
        if tableRow(who(x), shortDate(x.date), taChevron, subtitle = x.snippet, key = "th" & $x.id).clicked:
          openFocus = x.id

proc messageTools(r: Rect; below: int) =
  let c = selectedConv()
  let has = c != nil
  case toolsBar(r, [(nfFlag, "Flag or Mark"), (nfFolder, "Move"), (nfTrash, "Trash"),
                    (nfUndo, "Reply"), (nfEdit, "New Message")], below = below,
                enabled = [has, has, has, has, accountsC.len > 0])
  of 0: tFlagOpen = true
  of 1: moveOpen = true
  of 2:
    deleteMsgs(selectedMsgs())
    if not tabletMail(): tPop()
  of 3: tReplyOpen = true
  of 4: openCompose("new")
  else: discard

proc messageSheets() =
  let c = selectedConv()
  let flagged = c != nil and c.flagged
  case actionSheet(tFlagOpen, "", [if flagged: "Unflag" else: "Flag", "Mark as Unread"])
  of 0: toggleFlag(selectedMsgs())
  of 1:
    markRead(selectedMsgs(), unread = true)
    if c != nil: readMarked = c.key        # (kept unread: not read again at once)
  else: discard
  case actionSheet(tReplyOpen, "", ["Reply", "Reply All", "Forward"])
  of 0: doReply("reply")
  of 1: doReply("replyAll")
  of 2: doReply("forward")
  else: discard

# ---- writing ---------------------------------------------------------------------------------------------

proc fieldLine(label: string; s: var string; key: string; kb = kbEmail): bool =
  ## (a row of the message being written: its label gray, the text after it, a line under it)
  let h = if fingers(): dp(44) else: EditH + dp(10)
  let r = place(0, h, fill = true)
  let lst = style()
  text(r.x + dp(10), r.y + (h - FontH) div 2, label, ui.theme.gray, lst)
  let lx = r.x + dp(16) + textWidth(label, lst)
  textKeyboard(kb, keNext)
  result = editAt(idOf("tf:" & key), s, rect(lx, r.y + (h - EditH) div 2, r.x + r.w - lx - dp(8), EditH),
                  false, false, true, frameless = true)
  hline(r.x, r.y + h - 1, r.w, mixColor(ui.theme.field, ui.theme.fieldText, 0.14))

proc composePage(area: Rect) =
  ## Writing, as a phone's: Cancel and Send on the bar, To, Cc and Bcc, Subject, the text; a
  ## picture or a file put in from the bar's paper clip.
  pushFrame(area)
  let title = if cSubject.strip.len > 0: cSubject else: "New Message"
  case navBar(title, back = "Cancel", action = "Send", done = true, enabled = true)
  of npBack: cAskClose = true
  of npAction: send()
  of npNone: discard
  beginPanel(-1, "touch:compose", plain = true)
  fill(rect(area.x, layoutY(), area.w, area.y + area.h - layoutY()), ui.theme.field)
  let g = ui.m.gap
  ui.m.gap = 0
  if cFocus == 1:
    ui.textFocusWanted = true
    cFocus = 0
  if fieldLine("To:", cTo, "to"):
    cDirty = true
    cField = 0
  if cField == 0: suggestions(cTo)
  if cShowCc:
    if fieldLine("Cc:", cCc, "cc"):
      cDirty = true
      cField = 1
    if cField == 1: suggestions(cCc)
    if fieldLine("Bcc:", cBcc, "bcc"):
      cDirty = true
      cField = 2
    if cField == 2: suggestions(cBcc)
  else:
    let r = place(0, if fingers(): dp(44) else: EditH + dp(10), fill = true)
    let acc = if accountsC.len > 0: accountsC[clamp(cAccount, 0, accountsC.high)] else: Account()
    let t = "Cc/Bcc, From: " & acc.email
    if interact(idOf("tf:ccfrom"), r, focusable = false).clicked:
      cShowCc = true
      if accountsC.len > 1: tFromOpen = true
    text(r.x + dp(10), r.y + (r.h - FontH) div 2, fit(t, r.w - dp(20)), ui.theme.gray)
    hline(r.x, r.y + r.h - 1, r.w, mixColor(ui.theme.field, ui.theme.fieldText, 0.14))
  if fieldLine("Subject:", cSubject, "subject", kbText): cDirty = true
  # (the attachments, then the bar's own: a picture or a file, the signature)
  let ar = place(0, if fingers(): dp(40) else: CtrlH + dp(6), fill = true)
  var bx = ar.x + dp(8)
  let bst = style(size = 0.95)
  for (glyph, label) in [(nfImage, "Insert Photo or Video"), (nfPaperclip, "Attach"), (nfEdit, "Signature")]:
    let t = glyph & " " & label
    let bw = textWidth(t, bst) + dp(16)
    let br = rect(bx, ar.y + dp(4), bw, ar.h - dp(8))
    let h = interact(idOf("tf:" & label), br, focusable = false)
    roundRect(br, float(br.h) / 2, if h.down: mixColor(ui.theme.field, accentColor(), 0.3)
                                   else: mixColor(ui.theme.field, ui.theme.fieldText, 0.07))
    text(br.x + dp(8), br.y + (br.h - lineHeight(bst)) div 2, t, accentColor(), bst)
    if accessOn: accessNode(arButton, label, id = idOf("tf:" & label), r = br)
    if h.clicked:
      case label
      of "Signature": tSigOpen = true
      of "Attach": cAttachOpen = true
      else:
        tInsertAt = br
        tInsertOpen = true
    bx += bw + dp(6)
  for i, a in cAtts:
    let rr = place(0, FontH + dp(10), fill = true)
    text(rr.x + dp(12), rr.y + dp(5), nfPaperclip & " " & fit(a.name, rr.w - dp(80)) & "  " & sizeText(a.size),
         ui.theme.fieldText)
    if interact(idOf("tf:drop" & $i), rect(rr.x + rr.w - dp(36), rr.y, dp(36), rr.h), focusable = false).clicked:
      cAtts.delete(i)
      cDirty = true
      break
    text(rr.x + rr.w - dp(28), rr.y + dp(5), nfTimesCircle, ui.theme.gray)
  ui.m.gap = g
  if cFocus == 2:
    ui.textFocusWanted = true
    cFocus = 0
  if richEdit(composeDoc, height = max(dp(160), area.y + area.h - layoutY() - dp(8)), key = "compose",
              placeholder = "Write your message here"):
    cDirty = true
  if cQuote.len > 0:
    if link(if cShowQuote: "Hide the original message" else: "Show the original message"):
      cShowQuote = not cShowQuote
    if cShowQuote: htmlBlock(cQuote, images = imagesFor(cBase))
  endPanel()
  discard popFrame()
  if cDirty and epochTime() - cSavedAt > 15: saveDraftNow()
  # Insert Photo or Video: as a phone's callout, over the button
  popover(tInsertOpen, tInsertAt, 260):
    tableGroup(""):
      if tableRow("Photo or Video", "", taChevron, glyph = nfImage, tint = rgb(46, 130, 230)).clicked:
        tInsertOpen = false
        cAttachOpen = true
      if tableRow("Take a Photo", "", taChevron, glyph = nfCamera, tint = rgb(120, 128, 142)).clicked:
        tInsertOpen = false
        cAttachOpen = true
  var sigNames = @["No Signature"]
  for s in sigsC: sigNames.add s.name
  let k = actionSheet(tSigOpen, "Signature", sigNames)
  if k >= 0: putSignature(k - 1)
  var accNames: seq[string]
  for a in accountsC: accNames.add a.email
  let f = actionSheet(tFromOpen, "From", accNames)
  if f >= 0:
    cAccount = f
    cDirty = true
  # (the file dialog, Send Later, Keep as a draft: the 3.1 compose's own)
  if fileDialog(cAttachOpen, cAttachPath, fmOpen, ["All Files (*.*)"], "Attach a File"):
    try:
      cAtts.add (cAttachPath, extractFilename(cAttachPath), int getFileSize(cAttachPath))
      cDirty = true
    except OSError as e: cError = e.msg
  case actionSheet(cAskClose, "", ["Save Draft", "Delete Draft"], destructive = 1)
  of 0:
    saveDraftNow()
    composing = false
  of 1:
    if cDraftId > 0: store0.deleteDraft(cDraftId)
    composing = false
  else: discard

# ---- the window ---------------------------------------------------------------------------------------------

proc pageTitleOf(p: TPage): string =
  case p
  of tpBoxes: "Mailboxes"
  of tpAccount:
    let a = account(tAccount)
    if a.name.len > 0: a.name else: a.email
  of tpList:
    let n = if place.kind == plAllInbox: unreadAll()
            elif place.kind == plFolder: folderOf(place.folder).unread else: 0
    (if place.kind == plAllInbox: "All Inboxes" else: placeTitle()) & (if n > 0: " (" & $n & ")" else: "")
  of tpMessage:
    let (at, total) = convPos()
    if total > 0: $at & " of " & $total else: ""
  of tpMore: ($tMore)[1 .. ^1].replace("Todo", "To Do")
  of tpSettings: "Settings"
  of tpLook: "Appearance"

proc backOf(i: int): string =
  ## (the Back of the page `i` of the stack: the title of the one under it, short)
  if i == 0: return ""
  let p = tStack[i - 1]
  case p
  of tpList: (if place.kind == plAllInbox: "Inbox" else: placeTitle())
  else: pageTitleOf(p)

proc arrows(bar: Rect) =
  ## (the message's arrows on its bar, up and down the list: "3 of 9")
  let (at, total) = convPos()
  let bh = if glossLook(): min(bar.h - dp(10), if fingers(): dp(29) else: CtrlH) else: bar.h - dp(12)
  let bw = if fingers(): dp(40) else: dp(32)
  for k, (glyph, name, d) in [(nfChevronUp, "The message before", -1), (nfChevronDown, "The next message", 1)]:
    let r = rect(bar.x + bar.w - dp(6) - (2 - k) * bw, bar.y + (bar.h - bh) div 2, bw, bh)
    let on = (d < 0 and at > 1) or (d > 0 and at < total)
    let h = interact(idOf("tarrow" & $k), r, focusable = false, enabled = on)
    if glossLook():
      glossBarButton(r, h.down)
    elif h.down: roundRect(r, float(r.h) / 2, withAlpha(ui.theme.text, 30))
    let ink = if glossLook(): rgb(255, 255, 255) else: accentColor()
    text(r.x + (r.w - textWidth(glyph)) div 2, r.y + (r.h - FontH) div 2, glyph,
         if on: ink else: mixColor(ink, ui.theme.window, 0.6))
    if accessOn: accessNode(arButton, name, id = idOf("tarrow" & $k), r = r)
    if h.clicked:
      moveRow(d)
      openFocus = 0

proc stackColumn(area: Rect; bottomBelow: int; withMessage: bool) =
  ## (a column of pages: the top of the stack under its navigation bar, its toolbar at its foot)
  let tbH = if fingers(): dp(44) else: dp(36)
  let top = tPage()
  pushFrame(rect(area.x, area.y, area.w, area.h - tbH))
  let action = case top
               of tpList: (if tEditing: "Done" else: "Edit")
               else: ""
  let nb = navBar(pageTitleOf(top), back = backOf(tStack.high), action = action, done = tEditing)
  let bar = ui.lastRect
  case nb
  of npBack:
    if top == tpList:
      tEditing = false
      clearMulti()
    if top == tpMore: view = vMail
    tPop()
  of npAction:
    tEditing = not tEditing
    if not tEditing: clearMulti()
  of npNone: discard
  if top == tpMessage: arrows(bar)
  let searchOn = top == tpList
  if searchOn:
    let g = ui.m.gap
    ui.m.gap = 0
    if searchBar(query, "Search"):
      serverIds.setLen(0)
      searching = ""
      selRow = -1
      selKey = ""
      changed()
    ui.m.gap = g
  # (a list and a message on white, as a phone's mail; the mailboxes' groups on the window)
  let paper = top in [tpList, tpMessage]
  if paper: fill(rect(area.x, layoutY(), area.w, area.y + area.h - tbH - layoutY()), ui.theme.field)
  beginPanel(-1, "touch:" & $top & ":" & $tStack.len, plain = paper)
  case top
  of tpBoxes: mailboxesPage()
  of tpAccount: accountPage()
  of tpList: listPage()
  of tpMessage:
    let (fx, _) = layoutOrigin()
    pushFrame(rect(fx + dp(12), layoutY() + dp(8), layoutWidth() - dp(24), 0))
    messagePage()
    discard place(0, popFrame() + dp(12))
  of tpMore:
    case tMore
    of vCalendar: calendarView()
    of vPeople: peopleView()
    of vTodo: todoView()
    else: notesView()
  of tpSettings: settingsPage()
  of tpLook: lookPage()
  endPanel()
  discard popFrame()
  let tb = rect(area.x, area.y + area.h - tbH, area.w, tbH)
  if top == tpMessage and withMessage: messageTools(tb, bottomBelow)
  else: listTools(tb, bottomBelow)

proc touchMail() =
  ## Retro Mail in the newer looks on a phone or a tablet.
  if composing:
    composePage(rect(ui.winX, ui.barY, ui.w, ui.bottom - ui.barY))
    messageSheets()
    return
  # (Back, Esc: a page back)
  if tStack.len > 1 and canInput() and ui.popup == 0 and (keyHit(KeyEsc) or backPressed()):
    if tPage() == tpMore: view = vMail
    tPop()
  # (a tablet's message beside the list, not over it)
  if tabletMail() and tPage() == tpMessage: tPop()
  let below = if ui.bottom >= ui.h - ui.safe.bottom: ui.h - ui.bottom else: 0
  let full = rect(ui.winX + ui.safe.left, ui.barY, ui.w - ui.safe.left - ui.safe.right, ui.bottom - ui.barY)
  if not tabletMail():
    stackColumn(full, below, true)
  else:
    let mw = min(dp(340), full.w * 2 div 5)
    stackColumn(rect(full.x, full.y, mw, full.h), below, false)
    vline(full.x + mw, full.y, full.h, if glossLook() or onDarkMail(): rgb(0, 0, 0)
                                       else: mixColor(ui.theme.window, ui.theme.text, 0.2))
    # the message beside: its bar, its page, its toolbar
    let right = rect(full.x + mw + 1, full.y, full.w - mw - 1, full.h)
    let tbH = if fingers(): dp(44) else: dp(36)
    pushFrame(rect(right.x, right.y, right.w, right.h - tbH))
    discard navBar(pageTitleOf(tpMessage))
    arrows(ui.lastRect)
    fill(rect(right.x, layoutY(), right.w, right.y + right.h - tbH - layoutY()), ui.theme.field)
    beginPanel(-1, "touch:message", plain = true)
    let (fx, _) = layoutOrigin()
    pushFrame(rect(fx + dp(16), layoutY() + dp(6), layoutWidth() - dp(32), 0))
    messagePage()
    discard place(0, popFrame() + dp(12))
    endPanel()
    discard popFrame()
    messageTools(rect(right.x, right.y + right.h - tbH, right.w, tbH), below)
  messageSheets()

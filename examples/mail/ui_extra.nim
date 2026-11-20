# Retro Mail: what asks the servers for more than mail -- meeting
# invitations answered in the message, automatic replies (out of office),
# the message rules, the assistant (summarize, translate), a message
# forwarded as an attachment, saved as .eml and opened again. Included by
# examples/mail.nim.
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

proc gotSource(id: int; data: string)
proc gotUnsub(id: int; data: string)

# ---- meeting invitations ---------------------------------------------------------------------

var
  invitesC: Table[int, JsonNode]     ## message id -> what its invitation is
  invitesAsked: HashSet[int]

proc looksLikeInvite(m: Msg): bool =
  ## Worth asking the server: Graph marks its meeting messages; Gmail's come
  ## with a calendar part (Google's subjects say "Invitation:").
  if m.labels == "meeting": return true
  let s = m.subject.toLowerAscii
  if s.startsWith("invitation:") or s.startsWith("updated invitation") or
     s.startsWith("canceled event") or s.startsWith("cancelled event"): return true
  if m.hasAtt:
    for a in store0.attachments(m.id):
      if a.mime.startsWith("text/calendar") or a.name.toLowerAscii.endsWith(".ics"): return true

proc inviteWhen(j: JsonNode): string =
  let a = fromUnixFloat(j{"start"}.getFloat).local
  let b = fromUnixFloat(j{"finish"}.getFloat).local
  if j{"allDay"}.getBool:
    result = a.format("dddd d MMMM yyyy")
    if b.toTime.toUnixFloat - a.toTime.toUnixFloat > 86400 * 1.5:
      result.add " - " & (b - initDuration(days = 1)).format("dddd d MMMM")
  else:
    result = a.format("dddd d MMMM yyyy, HH:mm") & " - " &
             (if a.yearday == b.yearday: b.format("HH:mm") else: b.format("ddd d MMM HH:mm"))

proc inviteBanner(m: Msg) =
  ## Over a message that is an invitation: when, where, and Accept,
  ## Tentative, Decline (as Outlook shows it).
  if not looksLikeInvite(m): return
  if m.id notin invitesAsked:
    invitesAsked.incl m.id
    link.cmds.send(SyncCmd(kind: scInvite, id: m.id))
  let j = invitesC.getOrDefault(m.id)
  if j == nil: return
  if j.hasKey("error"):
    label "The meeting could not be read: " & j{"error"}.getStr, color = ui.theme.gray
    return
  let kind = j{"kind"}.getStr
  if kind == "ikNone": return
  group (case kind
         of "ikCancel": "Meeting called off"
         of "ikReply": "An answer to your meeting"
         else: "Meeting"):
    row:
      image(pixelIcon(pxCalendar, big = true))
      col:
        label j{"title"}.getStr, bold = true
        label inviteWhen(j)
        if j{"location"}.getStr.len > 0: label j{"location"}.getStr, color = ui.theme.gray
        if kind == "ikReply":
          label j{"replyName"}.getStr & ": " & j{"replyAnswer"}.getStr
        elif j{"organizer"}.getStr.len > 0:
          label "Organizer: " & j{"organizer"}.getStr, color = ui.theme.gray
    if kind == "ikRequest":
      let answer = j{"answer"}.getStr
      if answer != "none":
        label "You " & (case answer
                        of "accepted": "accepted"
                        of "tentative": "said tentative to"
                        else: "declined") & " this meeting.", color = rgb(0, 110, 0)
      row:
        for (label, a, px) in [("Accept", "accepted", pxCheck), ("Tentative", "tentative", pxHelp),
                               ("Decline", "declined", pxStop)]:
          if button(label, px, enabled = answer != a):
            link.cmds.send(SyncCmd(kind: scRespond, id: m.id,
                                   text: $(%*{"answer": a, "comment": "", "send": true})))
            status = "Sending your answer..."

# ---- automatic replies (out of office) -------------------------------------------------------

var
  oofOpen = false
  oofAcct = 0
  oofLoaded = -1
  oofWaiting = false
  oofError = ""
  oofOn = false
  oofScheduled = false
  oofFrom, oofTo: Date
  oofFromH = 9
  oofToH = 17
  oofSubject = ""
  oofInside = ""
  oofOutside = ""
  oofAudience = 2

proc htmlToPlain(html: string): string = htmlToText(html).strip

proc plainToHtml(t: string): string =
  "<p>" & t.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;")).replace("\n", "<br>") & "</p>"

proc atHour(d: Date; h: int): float =
  dateTime(d.year, Month(d.month), d.day, h, 0, 0, 0, local()).toTime.toUnixFloat

proc gotAutoReply(id: int; data: string) =
  oofWaiting = false
  let j = try: parseJson(data) except CatchableError: newJObject()
  if j.hasKey("error"):
    oofError = j{"error"}.getStr
    return
  oofError = ""
  oofOn = j{"enabled"}.getBool
  oofScheduled = j{"scheduled"}.getBool
  let s = j{"start"}.getFloat
  let f = j{"finish"}.getFloat
  if s > 0:
    let d = fromUnixFloat(s).local
    oofFrom = Date(year: d.year, month: ord(d.month), day: d.monthday)
    oofFromH = d.hour
  if f > 0:
    let d = fromUnixFloat(f).local
    oofTo = Date(year: d.year, month: ord(d.month), day: d.monthday)
    oofToH = d.hour
  oofSubject = j{"subject"}.getStr
  oofInside = htmlToPlain(j{"internalHtml"}.getStr)
  oofOutside = htmlToPlain(j{"externalHtml"}.getStr)
  oofAudience = max(0, ["none", "contactsOnly", "all"].find(j{"externalAudience"}.getStr("all")))

proc autoReplyDialog() =
  ## Tools, Automatic Replies: the out-of-office replies the service sends.
  if not oofOpen:
    oofLoaded = -1
    return
  if accountsC.len == 0:
    oofOpen = false
    return
  oofAcct = clamp(oofAcct, 0, accountsC.high)
  let acc = accountsC[oofAcct]
  if oofLoaded != acc.id:
    oofLoaded = acc.id
    oofWaiting = true
    oofError = ""
    if oofFrom.year == 0:
      oofFrom = today()
      oofTo = today().addDays(7)
    link.cmds.send(SyncCmd(kind: scGetAutoReply, id: acc.id))
  dialog oofOpen, "Automatic Replies", dp(520):
    form dp(110):
      field "&Account:":
        block:
          var i = oofAcct
          if combo(accountsC.mapIt(it.email), i): oofAcct = i
    if oofWaiting:
      row:
        spinner()
        label "Asking " & acc.email & "...", color = ui.theme.gray
    if oofError.len > 0: label oofError, color = rgb(200, 0, 0)
    checkbox("&Send automatic replies (I am away)", oofOn)
    checkbox("&Only during this time:", oofScheduled, enabled = oofOn)
    row:
      label "From"
      datePicker(oofFrom, enabled = oofOn and oofScheduled)
      combo((0 .. 23).toSeq.mapIt(align($it, 2, '0') & ":00"), oofFromH, w = dp(80))
      label "to"
      datePicker(oofTo, enabled = oofOn and oofScheduled)
      combo((0 .. 23).toSeq.mapIt(align($it, 2, '0') & ":00"), oofToH, w = dp(80))
    if acc.kind == akGmail:
      form dp(110):
        field "S&ubject:": edit oofSubject
      label "&Reply with:"
      editArea(oofInside, lines = 5)
    else:
      label "&Inside my organization:"
      editArea(oofInside, lines = 4)
      label "Out&side it:"
      editArea(oofOutside, lines = 4)
      form dp(110):
        field "Who outside:":
          combo(["No one", "My contacts only", "Everyone"], oofAudience, w = dp(200))
    row:
      space available() - 2 * (dp(80) + Gap) + Gap
      if button("OK", isDefault = true, w = dp(80), enabled = not oofWaiting):
        let data = %*{"enabled": oofOn, "scheduled": oofScheduled,
                      "start": atHour(oofFrom, oofFromH), "finish": atHour(oofTo, oofToH),
                      "subject": oofSubject, "internalHtml": plainToHtml(oofInside),
                      "externalHtml": plainToHtml(if acc.kind == akGmail: oofInside else: oofOutside),
                      "externalAudience": ["none", "contactsOnly", "all"][oofAudience]}
        link.cmds.send(SyncCmd(kind: scSetAutoReply, id: acc.id, text: $data))
        status = "Saving the automatic replies of " & acc.email & "..."
        oofOpen = false
      if button("Cancel", w = dp(80)): oofOpen = false

# ---- message rules ---------------------------------------------------------------------------

var
  rulesOpen = false
  rulesC: seq[Rule]
  ruleSel = 0
  ruleEditing = false
  ruleEdit: Rule
  ruleTags = ""
  ruleMove = 0

const ruleFields = [(rfFrom, "From contains"), (rfToCc, "To or Cc contains"),
                    (rfSubject, "Subject contains"), (rfBody, "The text contains"),
                    (rfAttachment, "It has an attachment")]
const ruleMoves = [("", "(stays where it is)"), ("archive", "Archive"), ("junk", "Junk"),
                   ("trash", "Deleted Items")]

proc loadRules() =
  rulesC = try: rulesFromJson(parseJson(store0.rulesJson())) except CatchableError: @[]

proc saveRules() =
  store0.saveRulesJson($toJson(rulesC))

proc addSenderRule(sender, action: string) =
  ## A rule: mail from `sender` is deleted or archived as it comes (Sweep).
  loadRules()
  var r = Rule(id: rulesC.len + 1, name: (if action == "delete": "Delete " else: "Archive ") & sender,
               enabled: true, matchAll: true,
               conditions: @[Condition(field: rfFrom, text: sender)])
  if action == "delete": r.delete = true else: r.moveTo = "archive"
  rulesC.add r
  saveRules()

proc rulesDialog() =
  ## Tools, Message Rules (as Outlook Express had them): applied to mail
  ## as it comes, here, for every account.
  if not rulesOpen:
    ruleEditing = false
    return
  if rulesC.len == 0: loadRules()
  dialog rulesOpen, (if ruleEditing: "Edit Mail Rule" else: "Message Rules"), dp(560):
    if not ruleEditing:
      label "These rules are applied to new mail as it comes, in this order:"
      var names: seq[string]
      for r in rulesC: names.add (if r.enabled: "[x] " else: "[  ] ") & r.name
      row([-1, dp(120)]):
        listbox(names, ruleSel, rows = 9)
        col:
          if button("&New...", w = dp(120)):
            ruleEdit = Rule(id: rulesC.len + 1, name: "New Mail Rule #" & $(rulesC.len + 1),
                            enabled: true, matchAll: true,
                            conditions: @[Condition(field: rfFrom)])
            ruleSel = rulesC.len
            ruleTags = ""
            ruleMove = 0
            ruleEditing = true
          let has = ruleSel in 0 ..< rulesC.len
          if button("&Modify...", w = dp(120), enabled = has):
            ruleEdit = rulesC[ruleSel]
            ruleTags = ruleEdit.tags.join(", ")
            ruleMove = max(0, ruleMoves.mapIt(it[0]).find(ruleEdit.moveTo))
            ruleEditing = true
          if button("On / O&ff", w = dp(120), enabled = has):
            rulesC[ruleSel].enabled = not rulesC[ruleSel].enabled
            saveRules()
          if button("&Remove", w = dp(120), enabled = has):
            rulesC.delete(ruleSel)
            ruleSel = max(0, ruleSel - 1)
            saveRules()
          if button("Move &Up", w = dp(120), enabled = has and ruleSel > 0):
            swap(rulesC[ruleSel], rulesC[ruleSel - 1])
            dec ruleSel
            saveRules()
          if button("Move &Down", w = dp(120), enabled = has and ruleSel < rulesC.high):
            swap(rulesC[ruleSel], rulesC[ruleSel + 1])
            inc ruleSel
            saveRules()
      row:
        space available() - dp(84)
        if button("Close", isDefault = true, w = dp(84)): rulesOpen = false
    else:
      form dp(90):
        field "&Name:": edit ruleEdit.name
      label "1. When a message:", bold = true
      var all = if ruleEdit.matchAll: 0 else: 1
      if combo(["matches every condition", "matches any condition"], all, w = dp(240)):
        ruleEdit.matchAll = all == 0
      while ruleEdit.conditions.len < 3: ruleEdit.conditions.add Condition(field: rfFrom)
      for k in 0 ..< 3:
        withId("rulecond" & $k):
          if ruleEdit.conditions[k].field == rfThread:
            label "It is in a conversation you ignore"
          else:
            row:
              var i = 0
              for q, (f, _) in ruleFields:
                if f == ruleEdit.conditions[k].field: i = q
              if combo(ruleFields.mapIt(it[1]), i, w = dp(200)):
                ruleEdit.conditions[k].field = ruleFields[i][0]
              if ruleEdit.conditions[k].field != rfAttachment:
                edit(ruleEdit.conditions[k].text)
      paragraph "(Several words in one box: separate them with ; -- any of them matches.)"
      label "2. Do this:", bold = true
      checkbox("Mark it as &read", ruleEdit.markRead)
      checkbox("&Flag it", ruleEdit.flag)
      checkbox("&Pin it", ruleEdit.pin)
      form dp(120):
        field "&Tag it with:": edit ruleTags
        field "&Move it to:":
          combo(ruleMoves.mapIt(it[1]), ruleMove, w = dp(200))
      checkbox("&Delete it", ruleEdit.delete)
      checkbox("&Stop here (no rule after this one)", ruleEdit.stop)
      row:
        space available() - 2 * (dp(80) + Gap) + Gap
        if button("OK", isDefault = true, w = dp(80), enabled = ruleEdit.name.strip.len > 0):
          var r = ruleEdit
          r.conditions.keepItIf(it.field == rfAttachment or it.text.strip.len > 0)
          r.tags = ruleTags.split({',', ';'}).mapIt(it.strip).filterIt(it.len > 0)
          r.moveTo = ruleMoves[ruleMove][0]
          if ruleSel in 0 ..< rulesC.len: rulesC[ruleSel] = r else: rulesC.add r
          saveRules()
          ruleEditing = false
        if button("Cancel", w = dp(80)): ruleEditing = false

# ---- the assistant: summarize, translate ----------------------------------------------------

var
  assistFor = 0                ## the message the answer is about
  assistText = ""
  assistKind = ""
  assistWaiting = false

proc aiReady(): bool = prefBool("aiOn", false)

proc askViaService(kind: string; m: Msg; lang: string): bool
  ## (ui_assist: the Assistant's service takes it -- this device's own model too)

proc askAssistant(kind: string; m: Msg) =
  assistFor = m.id
  assistKind = kind
  assistText = ""
  assistWaiting = true
  let lang = if kind == "summary": pref("aiSummaryLang", "") else: pref("aiTranslateTo", "English")
  if askViaService(kind, m, lang): return
  link.cmds.send(SyncCmd(kind: scAssist, text: $(%*{"kind": kind, "id": m.id, "to": lang,
                                                    "model": pref("aiModel", "claude-haiku-5-5")})))

proc assistBox(ids: seq[int]) =
  ## The assistant's answer over the conversation it is about.
  if assistFor == 0 or assistFor notin ids: return
  group (if assistKind == "summary": "Summary" else: "Translation"):
    if assistWaiting:
      row:
        spinner()
        label (if assistKind == "summary": "Reading the thread..." else: "Translating..."),
              color = ui.theme.gray
    else:
      paragraph assistText
    row:
      if link("Close"):
        assistFor = 0
        assistText = ""

proc gotAssist(data: string) =
  let j = try: parseJson(data) except CatchableError: newJObject()
  if j{"id"}.getInt != assistFor: return
  assistWaiting = false
  assistText = if j.hasKey("error"): "It did not work: " & j{"error"}.getStr else: j{"text"}.getStr

# ---- a message's source: forward it attached, save it, open a saved one ---------------------

var
  fwdAttFor = 0
  saveEmlOpen = false
  saveEmlPath = ""
  saveEmlFor = 0
  openEmlOpen = false
  openEmlPath = ""
  emlShown = false
  emlTitle = ""
  emlHeader = ""
  emlHtml = ""
  emlAtts: seq[MailAttachment]

proc forwardAsAttachment() =
  let ms = selectedMsgs()
  if ms.len == 0: return
  fwdAttFor = ms[0].id
  link.cmds.send(SyncCmd(kind: scRaw, id: ms[0].id, count: 0))
  status = "Getting the message to attach..."

proc saveMessageAs() =
  let ms = selectedMsgs()
  if ms.len == 0: return
  saveEmlFor = ms[0].id
  saveEmlPath = downloadsDir() / attachmentName(ms[0].subject)
  saveEmlOpen = true

proc gotRaw(id, count: int; data: string) =
  if count == 2:
    gotSource(id, data)
    return
  if data.startsWith("{"):
    let j = try: parseJson(data) except CatchableError: newJObject()
    status = "The message could not be read: " & j{"error"}.getStr
    return
  if count == 1:
    status = "Saved " & data
    return
  if id != fwdAttFor: return
  let m = store0.message(id)
  openCompose("forward", m)
  cQuote = ""
  cQuoteText = ""
  cFwdAtts.setLen(0)
  cAtts.add (data, attachmentName(m.subject), int(try: getFileSize(data) except OSError: 0))
  status = ""

proc showEml(path: string) =
  ## A saved message (.eml) opened: read here, as it was.
  try:
    let root = parseMailFile(path)
    let (html, text) = bodies(root)
    emlTitle = root.decodedHeader("Subject")
    emlHeader = "From: " & root.decodedHeader("From") & "\nTo: " & root.decodedHeader("To") &
                (if root.header("Cc").len > 0: "\nCc: " & root.decodedHeader("Cc") else: "") &
                "\nDate: " & root.header("Date")
    emlHtml = if html.len > 0: html else: textToHtml(text)
    emlAtts = attachments(root)
    emlShown = true
  except CatchableError as e:
    status = path.extractFilename & ": not a message we read (" & e.msg & ")"

proc emlDialogs() =
  if fileDialog(saveEmlOpen, saveEmlPath, fmSave, ["Mail Messages (*.eml)", "All Files (*.*)"],
                "Save Message As"):
    link.cmds.send(SyncCmd(kind: scRaw, id: saveEmlFor, count: 1, text: saveEmlPath))
    status = "Saving the message..."
  if fileDialog(openEmlOpen, openEmlPath, fmOpen, ["Mail Messages (*.eml)", "All Files (*.*)"],
                "Open a Saved Message"):
    showEml(openEmlPath)
  let w = min(ui.w - dp(24), dp(900))
  dialog emlShown, (if emlTitle.len > 0: emlTitle else: "(no subject)") & " - Message", w:
    for l in emlHeader.splitLines: label l
    if emlAtts.len > 0:
      row:
        for a in emlAtts:
          if a.inline: continue
          if button(fit(a.filename, dp(200)) & "  (" & sizeText(a.data.len) & ")", pxFile):
            let p = downloadsDir() / a.filename.multiReplace(("/", "_"), ("\\", "_"), (":", "_"))
            try:
              writeFile(p, a.data)
              status = "Saved " & p
            except CatchableError as e: status = e.msg
    discard htmlView(emlHtml, height = max(dp(220), ui.h - dp(300)), key = "eml")
    row:
      space available() - dp(84)
      if button("Close", isDefault = true, w = dp(84)): emlShown = false

# ---- what the sync thread answered ----------------------------------------------------------

proc extraEvent(ev: SyncEvent) =
  case ev.kind
  of seInvite:
    let j = try: parseJson(ev.text) except CatchableError: newJObject()
    let had = invitesC.getOrDefault(ev.id)
    invitesC[ev.id] = j
    if had != nil and had{"answer"}.getStr != j{"answer"}.getStr:
      status = "Your answer went to " & had{"organizer"}.getStr
  of seAutoReply:
    if ev.count == 1:
      let j = try: parseJson(ev.text) except CatchableError: newJObject()
      status = if j.hasKey("error"): "Automatic replies: " & j{"error"}.getStr
               elif j{"enabled"}.getBool: "Automatic replies are on"
               else: "Automatic replies are off"
    elif ev.id == oofLoaded: gotAutoReply(ev.id, ev.text)
  of seAssist: gotAssist(ev.text)
  of seRaw: gotRaw(ev.id, ev.count, ev.text)
  of seUnsub: gotUnsub(ev.id, ev.text)
  else: discard

# ---- Local Folders: import, export ----------------------------------------------------------

var
  importOpen = false
  importFrom = 0               ## 0: Outlook Express here, 1: a file, 2: a folder
  importPath = ""
  importPickFile = false
  importPickDir = false
  importLink: ImportLink
  importThread: Thread[ptr ImportLink]
  importRunning = false
  importDone, importTotal, importCount = 0
  importResult = ""
  exportOpen = false
  exportPath = ""

proc startImport(path: string) =
  importLink.path = path
  importLink.dbPath = mailDir() / "mail.db"
  importLink.stop = false
  importLink.progress.open()
  importRunning = true
  importDone = 0
  importTotal = 0
  importCount = 0
  importResult = ""
  createThread(importThread, importMain, addr importLink)

proc importProgress() =
  ## (each frame while an import runs: how far it is)
  if not importRunning: return
  while true:
    let (ok, s) = importLink.progress.tryRecv()
    if not ok: break
    let j = try: parseJson(s) except CatchableError: newJObject()
    if j.hasKey("end"):
      joinThread(importThread)
      importLink.progress.close()
      importRunning = false
      importCount = j{"end"}.getInt
      importResult = (if j.hasKey("error"): "Stopped: " & j{"error"}.getStr & ". " else: "") &
                     $importCount & " messages are in Local Folders now."
      status = importResult
      changed()
    else:
      importDone = j{"done"}.getInt
      importTotal = j{"total"}.getInt
      importCount = j{"count"}.getInt
  wakeIn(200)

proc importDialog() =
  ## File, Import, Messages: Outlook Express's Import wizard, into Local Folders.
  importProgress()
  if not importOpen: return
  let stores = oeStoreFolders()
  dialog importOpen, "Import Messages", dp(520):
    if importRunning:
      label "Importing into Local Folders...", bold = true
      label $importCount & " messages so far", color = ui.theme.gray
      progress(if importTotal > 0: importDone / importTotal else: 0.0)
      row:
        space available() - dp(84)
        if button("Stop", w = dp(84)): importLink.stop = true
    elif importResult.len > 0:
      paragraph importResult
      row:
        space available() - dp(84)
        if button("Close", isDefault = true, w = dp(84)):
          importOpen = false
          importResult = ""
    else:
      paragraph "Mail is brought into Local Folders, on this computer: from Outlook Express " &
                "(versions 4 to 6), from Thunderbird, Apple Mail or a Gmail Takeout (mbox), " &
                "or saved messages (.eml)."
      radio("Outlook &Express on this computer" & (if stores.len == 0: " (none found)" else: ""),
            importFrom, 0, enabled = stores.len > 0)
      radio("A &file: .dbx, .mbx, .mbox, .eml", importFrom, 1)
      radio("A f&older of them (an Outlook Express store folder, a Thunderbird profile...)", importFrom, 2)
      case importFrom
      of 0:
        if stores.len > 0 and importPath notin stores: importPath = stores[0]
        var i = max(0, stores.find(importPath))
        if stores.len > 0 and combo(stores, i): importPath = stores[i]
      else:
        row([-1, dp(100)]):
          edit importPath
          if button("&Browse...", w = dp(100)):
            if importPath.len == 0: importPath = getHomeDir()
            if importFrom == 1: importPickFile = true else: importPickDir = true
      let kind = if importPath.len > 0: importKind(importPath) else: ""
      if importPath.len > 0:
        label (if kind.len > 0: "Found: " & (case kind
                                             of "dbx": "an Outlook Express 5/6 store"
                                             of "mbx": "an Outlook Express 4 store"
                                             of "mbox": "an mbox file"
                                             of "eml": "a saved message"
                                             else: "a folder of mail")
               else: "No mail found there."), color = ui.theme.gray
      row:
        space available() - 2 * (dp(84) + Gap) + Gap
        if button("&Import", isDefault = true, w = dp(84), enabled = kind.len > 0):
          startImport(importPath)
        if button("Cancel", w = dp(84)): importOpen = false
  if fileDialog(importPickFile, importPath, fmOpen,
                ["Mail (*.dbx;*.mbx;*.mbox;*.eml;*.mbs)", "All Files (*.*)"], "Import From a File"):
    discard
  if fileDialog(importPickDir, importPath, fmFolder, title = "Import From a Folder"):
    discard

proc exportDialog() =
  ## File, Export: the messages of the list (or those selected) as an mbox
  ## file, which Thunderbird, Apple Mail and others read.
  if fileDialog(exportOpen, exportPath, fmSave, ["Mailbox (*.mbox)", "All Files (*.*)"],
                "Export Messages"):
    var ms = selectedMsgs()
    if not multiSelecting():
      ms.setLen(0)
      for c in convs:
        for m in c.msgs: ms.add m
    var raws: seq[string]
    for m in ms:
      let acc = account(m.account)
      raws.add store0.rawOf(m, MailAddress(name: acc.name, email: acc.email))
    try:
      writeMbox(exportPath, raws)
      status = "Exported " & $raws.len & " messages to " & exportPath
    except CatchableError as e: status = e.msg

# ---- newsletters: Unsubscribe; Block Sender -------------------------------------------------

var unsubAsked: HashSet[int]

proc unsubscribeBar(m: Msg) =
  ## Over a newsletter (it says how to leave its list): Unsubscribe, as
  ## Gmail and Outlook offer it.
  if m.mine or m.id in unsubAsked: return
  let (header, _) = store0.unsubOf(m.id)
  if header.len == 0: return
  row:
    label "From a mailing list: " & who(m), color = ui.theme.gray
    if link("Unsubscribe"):
      unsubAsked.incl m.id
      link.cmds.send(SyncCmd(kind: scUnsubscribe, id: m.id))
      status = "Leaving the list of " & who(m) & "..."
    if link("Block the sender"): blockSender(@[m])

proc blockSender(ms: seq[Msg]) =
  ## Message, Block Sender: their mail goes to Junk, now and from now on (a
  ## rule, kept with the others in Tools, Message Rules).
  if ms.len == 0: return
  loadRules()
  var senders: seq[string]
  for m in ms:
    let s = m.fromEmail.toLowerAscii
    if s.len > 0 and s notin senders and not m.mine: senders.add s
  for s in senders:
    var r = Rule(id: rulesC.len + 1, name: "Block " & s, enabled: true, matchAll: true,
                 conditions: @[Condition(field: rfFrom, text: s)], moveTo: "junk", markRead: true)
    rulesC.add r
  saveRules()
  var all: seq[Msg]
  for s in senders:
    all.add store0.whereMessages("lower(from_email) = ? AND folder IN (SELECT id FROM folders " &
                                 "WHERE role = 'inbox')", @[toDbValue(s)], 5000)
  for m in ms:
    if not all.anyIt(it.id == m.id): all.add m
  moveMsgs(all, "junk")
  status = "Blocked " & senders.join(", ") & ": their mail goes to Junk"

# ---- safety: who it is from, links, tracking (retroui/mailauth, retroui/mailsafety) ---------

var
  safeCache: Table[int, MailSafety]      ## a message's HTML made safe, and what was found
  safetyClosed: HashSet[int]             ## the banners closed (by message)
  knownDoms: seq[string]                 ## the domains of those written to (look-alikes of them)
  knownAt = 0.0
  linkAsk = false
  linkAskUrl, linkAskWhy = ""

proc safeOf(m: Msg): MailSafety =
  ## The message's HTML as the reading pane shows it: tracking pictures out,
  ## tracking codes off the links, the links that are not what they look like.
  let key = m.id * 4 + ord(prefBool("plainRead", false)) + 2 * ord(prefBool("noTrackers", true))
  if key notin safeCache:
    if safeCache.len > 64: safeCache.clear()
    var s = cleanMail(readHtml(m))
    if not prefBool("noTrackers", true):
      s.html = readHtml(m)          # (as sent: the links' problems still found)
      s.trackers = 0
      s.codes = 0
    safeCache[key] = s
  safeCache[key]

proc knownDomains(): seq[string] =
  if epochTime() - knownAt > 300:
    knownDoms.setLen(0)
    for c in store0.contacts("", 400):
      if c.saved or c.uses >= 2:
        let at = c.email.rfind('@')
        if at > 0:
          let d = registrableDomain(c.email[at + 1 .. ^1])
          if d.len > 0 and d notin knownDoms: knownDoms.add d
    knownAt = epochTime()
  knownDoms

proc safetyBanners(m: Msg) =
  ## Over a message: a sender who is not who they say (their provider's
  ## checks, DKIM checked here), a name or domain made to fool, links that
  ## go somewhere other than they say; and, quietly, the sender checked and
  ## the tracking taken out.
  if m.mine: return
  let c = store0.senderCheckOf(m.id)
  let closed = m.id in safetyClosed or not prefBool("phishWarn", true)
  if c.state == ord(senderFailed) and not closed:
    case banner("This message may not be from " & c.domain & ": " & c.detail & ". Do not open its " &
                "links or files, or answer it, before you are sure.", bkError,
                ["Block Sender", "Move to Junk"])
    of 0: safetyClosed.incl m.id
    of 1: blockSender(@[m])
    of 2: moveMsgs(@[m], "junk")
    else: discard
  elif c.state == ord(senderUnverified) and not closed:
    if banner("Retro Mail could not confirm this came from " & c.domain & " (" & c.detail & ").",
              bkWarning) == 0: safetyClosed.incl m.id
  let warns = senderWarnings(m.fromName, m.fromEmail, knownDomains())
  if warns.len > 0 and not closed:
    case banner("Look again before you answer: " & warns[0] & ".", bkWarning, ["Block Sender"])
    of 0: safetyClosed.incl m.id
    of 1: blockSender(@[m])
    else: discard
  let s = safeOf(m)
  var tricks = 0
  var first = ""
  for l in s.links:
    if l.deceptive:
      inc tricks
      if first.len == 0: first = l.why
  if tricks > 0 and not closed:
    if banner((if tricks == 1: "A link in this message is" else: $tricks & " links in this message are") &
              " not what it looks like: " & first & ".", bkWarning) == 0: safetyClosed.incl m.id
  var notes: seq[string]
  if c.state == ord(senderVerified):
    notes.add "From " & c.domain & ", checked (" & c.detail & (if c.by.len > 0: ", " & c.by else: "") & ")"
  if s.trackers > 0:
    notes.add $s.trackers & (if s.trackers == 1: " tracking picture" else: " tracking pictures") & " taken out"
  if s.codes > 0:
    notes.add "tracking codes taken off " & $s.codes & (if s.codes == 1: " link" else: " links")
  if notes.len > 0: label notes.join(";  "), color = ui.theme.gray

proc openLinkSafely(m: Msg; url: string) =
  ## A link clicked in a message: opened without its tracking codes; one that
  ## is not what it looks like (or runs a script) asked about first.
  var words = ""
  for l in safeOf(m).links:
    if l.href == url: words = l.text
  let why = linkWarning(url, words)
  let scripted = url.toLowerAscii.strip.startsWith("javascript:") or url.toLowerAscii.strip.startsWith("data:")
  if why.len > 0 and (prefBool("phishWarn", true) or scripted):
    linkAsk = true
    linkAskUrl = url
    linkAskWhy = why
  else: discard openUrl(if prefBool("noTrackers", true): stripTracking(url) else: url)

var storeNoteOpen = true

proc storeNoteDialog() =
  ## What happened to the mail kept here as the app started (its key gone,
  ## or it could not be encrypted): told once.
  if storeNote.len == 0: return
  dialog storeNoteOpen, "The Mail on This Device", dp(460):
    paragraph storeNote
    separator()
    row:
      space available() - dp(96)
      if button("OK", isDefault = true, w = dp(96)): storeNoteOpen = false
  if not storeNoteOpen: storeNote = ""

proc linkAskDialog() =
  dialog linkAsk, "Open This Link?", dp(460):
    label "This link may not be what it looks like", bold = true
    paragraph "Retro Mail found that " & linkAskWhy & "."
    paragraph "It goes to: " & linkAskUrl, color = ui.theme.gray
    separator()
    row:
      space available() - 2 * (dp(96) + Gap) + Gap
      let script = linkAskUrl.toLowerAscii.strip.startsWith("javascript:") or
                   linkAskUrl.toLowerAscii.strip.startsWith("data:") or
                   linkAskUrl.toLowerAscii.strip.startsWith("vbscript:")
      if button("&Open It", w = dp(96), enabled = not script):
        linkAsk = false
        discard openUrl(stripTracking(linkAskUrl))
      if button("Cancel", isDefault = true, w = dp(96)): linkAsk = false

proc gotUnsub(id: int; data: string) =
  let j = try: parseJson(data) except CatchableError: newJObject()
  let m = store0.message(id)
  case j{"how"}.getStr
  of "post": status = "You have left the list of " & who(m)
  of "mail": status = "A message asking to leave the list went to " & j{"url"}.getStr
  of "open":
    discard openUrl(j{"url"}.getStr)
    status = "The list's page is open in your browser: leave it there"
  else: status = "Unsubscribe: " & j{"error"}.getStr
  if j{"how"}.getStr in ["post", "mail"]:
    showSnackbar("Left the list. Sweep away what " & who(m) & " sent?", "Sweep", 10000)
    undoWhat = "sweep:" & $id

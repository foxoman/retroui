# Retro Mail: what Outlook Express also did -- printing a message (with a
# preview, or saved as PDF), its Properties and its source, the sound of
# new mail, templates to start a message from, and Search Folders (a
# search kept in the folder list). Included by examples/mail.nim.
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

proc pickedMsg(): int =
  ## The message a command is for: the one picked in the thread, else the
  ## newest selected.
  let ms = selectedMsgs()
  if ms.len == 0: return 0
  if openFocus > 0 and openMsgs.anyIt(it.id == openFocus): openFocus else: ms[0].id

proc safeName(s: string): string =
  result = s.multiReplace(("/", "_"), ("\\", "_"), (":", "_"), ("*", "_"), ("?", "_"),
                          ("\"", "_"), ("<", "_"), (">", "_"), ("|", "_")).strip
  if result.runeLen > 80: result = result.runeSubStr(0, 80)
  if result.len == 0: result = "message"

# ---- printing ------------------------------------------------------------------------------

var
  printOpen = false
  printDoc: Report
  printTitle = ""
  printPdfOpen = false
  printPdfPath = ""

proc printHtmlOf(id: int): tuple[html, dir: string] =
  ## The message as Outlook Express printed it: who it is from and for, when,
  ## its subject, a line, then the text (its pictures from this computer).
  let m = store0.message(id)
  let acc = accountsC.filterIt(it.id == m.account)
  let me = if acc.len > 0: acc[0].email else: ""
  let subject = if m.subject.len > 0: m.subject else: "(no subject)"
  var body = if m.html.len > 0: bodyInner(m.html) else: textToHtml(m.text)
  if body.strip.len == 0: body = "<p>" & esc(m.snippet) & "</p>"
  # pictures sent inside the message: written out for the page to show
  let dir = getTempDir() / "retro-mail-print" / $id
  try:
    createDir(dir)
    var k = 0
    for cid, data in store0.cidData(id).pairs:
      let ext = if data.startsWith("\x89PNG"): ".png" elif data.startsWith("BM"): ".bmp" else: ".jpg"
      let name = "p" & $k & ext
      writeFile(dir / name, data)
      body = body.replace("cid:" & cid, name)
      inc k
  except CatchableError: discard
  var atts: seq[string]
  for a in store0.attachments(id):
    if not a.inline: atts.add a.name
  var h = "<title>" & esc(subject) & "</title>"
  h.add "<header><span>" & esc(me) & "</span><span>Page {page} of {pages}</span></header>"
  h.add "<h3>" & esc(subject) & "</h3>"
  h.add "<table class=\"plain\">"
  let fromText = if m.fromName.len > 0: m.fromName & " <" & m.fromEmail & ">" else: m.fromEmail
  for (k, v) in [("From:", fromText), ("Sent:", longDate(m.date)), ("To:", m.toList),
                 ("Cc:", m.ccList), ("Subject:", subject), ("Attach:", atts.join("; "))]:
    if v.len > 0:
      h.add "<tr><td width=\"70\"><b>" & k & "</b></td><td>" & esc(v) & "</td></tr>"
  h.add "</table><hr>"
  h.add body
  (h, dir)

proc printMessage() =
  ## File > Print: the message laid out on paper, shown first.
  let id = pickedMsg()
  if id == 0: return
  let (html, dir) = printHtmlOf(id)
  printDoc = reportFromHtml(html, dir, store0.message(id).subject)
  printTitle = store0.message(id).subject
  printOpen = true

proc printDialog() =
  if not printOpen: return
  let w = if isCompact(): ui.w - dp(16) else: min(ui.w - dp(24), dp(760))
  dialog printOpen, "Print", w:
    reportView(printDoc, height = max(dp(220), ui.h - dp(200)), key = "print")
    row:
      if button("&Print", pxPrint, isDefault = true, w = dp(100)):
        let (ok, said) = printDoc.printReport(printTitle)
        status = said
        if ok: printOpen = false
      if button("Save as P&DF...", w = dp(130)):
        printPdfPath = downloadsDir() / safeName(printTitle) & ".pdf"
        printPdfOpen = true
      space available() - dp(84)
      if button("Cancel", w = dp(84)): printOpen = false
  if fileDialog(printPdfOpen, printPdfPath, fmSave, ["PDF Files (*.pdf)", "All Files (*.*)"],
                "Save as PDF"):
    try:
      printDoc.savePdf(printPdfPath)
      status = "Saved " & printPdfPath
      printOpen = false
    except CatchableError as e: status = "Could not save the PDF: " & e.msg

# ---- Properties and the message source ---------------------------------------------------

var
  propsOpen = false
  propsMsg: Msg
  propsTab = 0
  propsHeaders = ""
  propsSource = ""
  propsError = ""
  sourceOpen = false

proc showProperties(source = false) =
  ## File > Properties (Alt+Enter); `source`: View > Message Source (Ctrl+F3).
  let id = pickedMsg()
  if id == 0: return
  propsMsg = store0.message(id)
  propsTab = 0
  propsHeaders = ""
  propsSource = ""
  propsError = ""
  propsOpen = not source
  sourceOpen = source
  link.cmds.send(SyncCmd(kind: scRaw, id: id, count: 2))

proc gotSource(id: int; data: string) =
  if id != propsMsg.id: return
  if data.startsWith("{"):
    let j = try: parseJson(data) except CatchableError: newJObject()
    propsError = "The message source could not be read: " & j{"error"}.getStr
    return
  var raw = try: readFile(data) except CatchableError: ""
  try: removeFile(data) except CatchableError: discard
  raw = raw.replace("\r\n", "\n")
  let cut = raw.find("\n\n")
  propsHeaders = if cut >= 0: raw[0 ..< cut] else: raw
  propsSource = if raw.len > 2_000_000: raw[0 ..< 2_000_000] & "\n[... the rest is not shown]" else: raw

proc propertiesDialog() =
  if propsOpen:
    let m = propsMsg
    let subject = if m.subject.len > 0: m.subject else: "(no subject)"
    let w = if isCompact(): ui.w - dp(16) else: dp(520)
    dialog propsOpen, subject & " Properties", w:
      tabs(propsTab, ["General", "Details"], true):
        case propsTab
        of 0:
          row:
            image(pixelIcon(pxMail))
            label subject, bold = true
          separator()
          var atts: seq[string]
          for a in store0.attachments(m.id):
            if not a.inline: atts.add a.name
          let f = folderOf(m.folder)
          let acc = accountsC.filterIt(it.id == m.account)
          form dp(110):
            field "Type:": label "Mail Message"
            field "From:":
              label(if m.fromName.len > 0: m.fromName & " <" & m.fromEmail & ">" else: m.fromEmail)
            if m.toList.len > 0:
              field "To:": label fit(m.toList, w - dp(150))
            if m.ccList.len > 0:
              field "Cc:": label fit(m.ccList, w - dp(150))
            field "Sent:": label longDate(m.date)
            field "Size:":
              label(if m.size > 0: sizeText(m.size) elif propsSource.len > 0: sizeText(propsSource.len)
                    else: "-")
            field "Attachments:": label(if atts.len > 0: fit(atts.join(", "), w - dp(150)) else: "None")
            field "Folder:":
              label f.name & (if acc.len > 0: "  (" & acc[0].email & ")" else: "")
            if m.tags.len > 0:
              field "Tags:": label m.tags.join(", ")
            field "Status:":
              label (if m.unread: "Unread" else: "Read") & (if m.flagged: ", flagged" else: "") &
                    (if m.important: ", high priority" else: "")
        else:
          label "The Internet headers for this message:"
          if propsError.len > 0: paragraph propsError
          elif propsSource.len == 0: label "Getting them from the server..."
          else: editArea(propsHeaders, lines = 12, wrap = false, readOnly = true)
          row:
            if button("Message &Source...", enabled = propsSource.len > 0, w = dp(150)):
              sourceOpen = true
      row:
        space available() - dp(84)
        if button("OK", isDefault = true, w = dp(84)): propsOpen = false
  if sourceOpen:
    let w = if isCompact(): ui.w - dp(16) else: min(ui.w - dp(24), dp(860))
    let subject = if propsMsg.subject.len > 0: propsMsg.subject else: "(no subject)"
    dialog sourceOpen, subject & " - Message Source", w:
      if propsError.len > 0: paragraph propsError
      elif propsSource.len == 0: label "Getting the message from the server..."
      else: editArea(propsSource, lines = max(8, (ui.h - dp(170)) div lineHeight()), wrap = false,
                     readOnly = true)
      row:
        if button("&Copy All", enabled = propsSource.len > 0, w = dp(100)):
          putClipboardText(propsSource)
          status = "The message source is on the clipboard"
        space available() - dp(84)
        if button("Close", isDefault = true, w = dp(84)): sourceOpen = false

# ---- the sound of new mail ---------------------------------------------------------------

var
  dingC: Sound
  soundPickOpen = false
  soundPickPath = ""

proc newMailSound() =
  ## Options, General: a chime (made here), a ding, the old beep, or a
  ## sound file of one's own.
  case pref("soundKind", "chime")
  of "file":
    let p = pref("soundFile")
    if p.len > 0 and fileExists(p) and playSound(p) != NoSound: return
    uiSound(usNotify)
  of "ding":
    if dingC == nil:
      dingC = joinSounds([makeTone(1319, 90, 0.3), makeTone(1047, 260, 0.3)])
    discard playSound(dingC)
  of "beep": beep()
  else: uiSound(usNotify)

proc soundDialogs() =
  if fileDialog(soundPickOpen, soundPickPath, fmOpen,
                ["Sounds (*.wav;*.mp3;*.ogg)", "All Files (*.*)"], "New Mail Sound"):
    prefs.put("soundFile", soundPickPath)
    prefs.put("soundKind", "file")
    savePrefs()
    newMailSound()

# ---- My Templates ------------------------------------------------------------------------

var
  tplSaveOpen = false
  tplName = ""

proc templatesJ(): JsonNode =
  result = try: parseJson(pref("templates", "[]")) except CatchableError: newJArray()
  if result.kind != JArray: result = newJArray()

proc useTemplate(i: int) =
  ## A template's text at the start of the message (the signature stays
  ## under it), its subject when there is none yet.
  let ts = templatesJ()
  if i < 0 or i >= ts.len: return
  let t = ts[i]
  if cSubject.strip.len == 0: cSubject = t{"subject"}.getStr
  let d = richFromHtml(t{"html"}.getStr)
  let sigFrom = max(0, composeDoc.paras.len - cSigParas)
  var keep: seq[RichPara]
  for k in 0 ..< sigFrom:
    if composeDoc.paras[k].paraText.strip.len > 0: keep.add composeDoc.paras[k]
  var paras = keep & d.paras
  for k in sigFrom ..< composeDoc.paras.len: paras.add composeDoc.paras[k]
  composeDoc.paras = paras
  if composeDoc.paras.len == 0: composeDoc.paras.add RichPara()
  cDirty = true

proc saveTemplate(name: string) =
  ## The message being written (without its signature) kept as a template.
  var d = composeDoc
  if cSigParas > 0 and d.paras.len >= cSigParas: d.paras.setLen(d.paras.len - cSigParas)
  while d.paras.len > 0 and d.paras[^1].paraText.strip.len == 0: d.paras.setLen(d.paras.len - 1)
  while d.paras.len > 0 and d.paras[0].paraText.strip.len == 0: d.paras.delete(0)
  var ts = templatesJ()
  var j = newJArray()
  for t in ts:
    if t{"name"}.getStr != name: j.add t
  j.add %*{"name": name, "subject": cSubject, "html": toHtml(d)}
  prefs.put("templates", $j)
  savePrefs()
  status = "Saved the template \"" & name & "\""

proc removeTemplate(i: int) =
  let ts = templatesJ()
  var j = newJArray()
  for k, t in ts.getElems:
    if k != i: j.add t
  prefs.put("templates", $j)
  savePrefs()

proc templatesMenu() =
  ## Insert > My Templates (and the Templates button of the tool bar).
  let ts = templatesJ()
  if ts.len == 0: discard menuItem("(no templates yet)", enabled = false)
  for i, t in ts.getElems:
    if menuItem(t{"name"}.getStr): useTemplate(i)
  menuSeparator()
  if menuItem("&Save This Message as a Template..."):
    tplName = if cSubject.strip.len > 0: cSubject.strip else: "Template " & $(ts.len + 1)
    tplSaveOpen = true
  if ts.len > 0:
    submenu "&Delete":
      for i, t in ts.getElems:
        if menuItem(t{"name"}.getStr): removeTemplate(i)

proc templateDialog() =
  dialog tplSaveOpen, "Save as Template", dp(380):
    label "Name of the template:"
    edit tplName
    row:
      space available() - dp(180)
      if button("Save", isDefault = true, enabled = tplName.strip.len > 0, w = dp(84)):
        saveTemplate(tplName.strip)
        tplSaveOpen = false
      if button("Cancel", w = dp(84)): tplSaveOpen = false

# ---- Ignore Conversation -----------------------------------------------------------------

proc ignoreConversation(ms: seq[Msg]) =
  ## Message, Ignore Conversation: the conversation goes to Deleted Items,
  ## and so do its replies as they come (a rule, in Tools, Message Rules).
  if ms.len == 0: return
  loadRules()
  var seen: HashSet[string]
  var all: seq[Msg]
  for m in ms:
    let key = $m.account & "\t" & m.thread
    if m.thread.len == 0 or key in seen: continue
    seen.incl key
    let subject = stripRe(m.subject)
    rulesC.add Rule(id: rulesC.len + 1, name: "Ignore \"" & (if subject.len > 0: subject else: "(no subject)") & "\"",
                    enabled: true, matchAll: true, markRead: true, delete: true, stop: true,
                    conditions: @[Condition(field: rfThread, text: m.thread),
                                  Condition(field: rfAccount, account: m.account)])
    for x in store0.threadMessages(m.account, m.thread):
      if folderOf(x.folder).role notin ["sent", "drafts", "trash", "outbox"]: all.add x
  saveRules()
  if all.len > 0:
    markRead(all)
    moveMsgs(all, "trash")
  status = "Ignored: its replies go to Deleted Items as they come (Tools, Message Rules)"

# ---- Find Message (Edit, Find, Ctrl+Shift+F) ----------------------------------------------

var
  findOpen = false
  fFrom, fTo, fSubject, fWords: string
  fAfterOn, fBeforeOn, fAtt, fFlag, fUnread: bool
  fAfter, fBefore: Date
  fIn = 0

const findIn = [("Every folder", ""), ("Inbox", "inbox"), ("Sent", "sent"), ("Archive", "archive"),
                ("Drafts", "drafts"), ("Deleted Items", "trash"), ("Junk", "junk")]

proc openFind() =
  if fAfter.year == 0:
    fAfter = today().addDays(-30)
    fBefore = today().addDays(1)
  findOpen = true

proc isoDay(d: Date): string =
  $d.year & "-" & align($d.month, 2, '0') & "-" & align($d.day, 2, '0')

proc findQuery(): string =
  ## The dialog's boxes as what the search box understands.
  var parts: seq[string]
  for (key, val) in [("from:", fFrom), ("to:", fTo), ("subject:", fSubject), ("", fWords)]:
    for w in strutils.splitWhitespace(val): parts.add key & w
  if fAfterOn: parts.add "after:" & isoDay(fAfter)
  if fBeforeOn: parts.add "before:" & isoDay(fBefore)
  if fAtt: parts.add "has:attachment"
  if fFlag: parts.add "is:flagged"
  if fUnread: parts.add "is:unread"
  if fIn > 0: parts.add "in:" & findIn[fIn][1]
  parts.join(" ")

proc findDialog() =
  dialog findOpen, "Find Message", (if isCompact(): ui.w - dp(16) else: dp(520)):
    form dp(110):
      field "&From:": edit fFrom
      field "&To:": edit fTo
      field "&Subject:": edit fSubject
      field "&Message:": edit fWords
      field "&Look in:":
        var names: seq[string]
        for (n, _) in findIn: names.add n
        combo(names, fIn, w = dp(180))
    row([dp(150), dp(150)]):
      checkbox("Received &after:", fAfterOn)
      datePicker(fAfter, w = dp(150), enabled = fAfterOn)
    row([dp(150), dp(150)]):
      checkbox("Received &before:", fBeforeOn)
      datePicker(fBefore, w = dp(150), enabled = fBeforeOn)
    checkbox("Message has atta&chment(s)", fAtt)
    checkbox("Message is fla&gged", fFlag)
    checkbox("Message is &unread", fUnread)
    row:
      if button("New Search", w = dp(100)):
        fFrom = ""
        fTo = ""
        fSubject = ""
        fWords = ""
        fAfterOn = false
        fBeforeOn = false
        fAtt = false
        fFlag = false
        fUnread = false
        fIn = 0
      space available() - dp(184)
      let q = findQuery()
      if button("Find &Now", isDefault = true, enabled = q.len > 0, w = dp(90)):
        query = q
        serverIds.setLen(0)
        searching = ""
        view = vMail
        selRow = -1
        selKey = ""
        listScroll = 0
        changed()
        findOpen = false
      if button("Cancel", w = dp(84)): findOpen = false

# ---- Search Folders ----------------------------------------------------------------------

var
  searchesC: seq[string]       ## the searches kept as folders
  searchesRead = false
  searchMenuFor = -1

proc savedSearches(): seq[string] =
  if not searchesRead:
    searchesRead = true
    searchesC.setLen(0)
    let j = try: parseJson(pref("searches", "[]")) except CatchableError: newJArray()
    if j.kind == JArray:
      for s in j: searchesC.add s.getStr
  searchesC

proc keepSearches() =
  prefs.put("searches", $(%searchesC))
  savePrefs()

proc saveSearch(q: string) =
  ## The search typed in the box kept as a Search Folder (its messages found
  ## again each time it is opened).
  let s = q.strip
  if s.len == 0: return
  discard savedSearches()
  if s notin searchesC:
    searchesC.add s
    keepSearches()
  status = "\"" & s & "\" is kept under Search Folders"

proc searchFolders() =
  ## The Search Folders branch of the folder tree.
  let ss = savedSearches()
  if ss.len == 0: return
  var o = treeOpen.getOrDefault("searches", true)
  branch("Search Folders", o, pixelIcon(pxFolderStar), "searches", true):
    for i, q in ss:
      leaf(q, pic = pixelIcon(pxSearch), id = "search:" & $i)
      if ui.rpressed and canInput() and mouseIn(nodeRect()):
        searchMenuFor = i
        openPopupMenu("searchmenu", ui.mx, ui.my)
  treeOpen["searches"] = o

proc openSearchFolder(i: int) =
  if i >= 0 and i < savedSearches().len: goPlace(Place(kind: plSearch, tag: searchesC[i]))

proc searchFolderMenu() =
  popupMenu("searchmenu"):
    if searchMenuFor >= 0 and searchMenuFor < searchesC.len:
      if menuItem("&Open"):
        goPlace(Place(kind: plSearch, tag: searchesC[searchMenuFor]))
      if menuItem("&Delete Search Folder"):
        let was = searchesC[searchMenuFor]
        searchesC.delete(searchMenuFor)
        keepSearches()
        if place.kind == plSearch and place.tag == was: goPlace(Place(kind: plAllInbox))

proc classicDialogs() =
  findDialog()
  printDialog()
  propertiesDialog()
  soundDialogs()
  templateDialog()

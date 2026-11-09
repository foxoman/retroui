# Retro Mail: writing mail -- new messages, replies, forwards, with rich
# text, signatures, attachments, send later and drafts. Included by
# examples/mail.nim.
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

proc templatesMenu()

var
  composing = false
  composeDoc: RichDoc
  cMode = "new"
  cTo, cCc, cBcc, cSubject: string
  cAccount = 0
  cBase: Msg
  cQuote = ""
  cQuoteText = ""
  cShowQuote = false
  cAtts: seq[tuple[path, name: string; size: int]]
  cFwdAtts: seq[Att]
  cImportant = false
  cShowCc = false
  cSig = -1
  cSigParas = 0
  cDraftId = 0
  cDirty = false
  cSavedAt = 0.0
  cAttachOpen = false
  cAttachPath = ""
  cLaterOpen = false
  cLaterDay: Date
  cLaterH = 8
  cLaterM = 0
  cAskClose = false
  cError = ""
  cField = -1             ## the address field being typed in (for suggestions)
  cFocus = 0              ## 1: the To field takes the keys first, 2: the text
  sigsC: seq[tuple[id: int; name, html: string]]

const replyBlue = Color(r: 0x1F, g: 0x49, b: 0x7D, a: 255)   ## Outlook's reply blue

proc esc(s: string): string = s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc bodyInner(html: string): string =
  ## The inside of a whole HTML page's <body> (or the HTML as it is).
  let low = html.toLowerAscii
  var a = low.find("<body")
  if a < 0: return html
  a = low.find('>', a)
  if a < 0: return html
  var b = low.rfind("</body>")
  if b < 0: b = html.len
  html[a + 1 ..< b]

proc stripRe(s: string): string =
  result = s.strip
  while true:
    let low = result.toLowerAscii
    var cut = false
    for p in ["re:", "fw:", "fwd:", "aw:", "rv:"]:
      if low.startsWith(p):
        result = result[p.len .. ^1].strip
        cut = true
    if not cut: break

proc addrsOf(list: string; skip: seq[string]): seq[string] =
  for a in parseAddresses(list):
    if a.email.len == 0 or a.email.toLowerAscii in skip: continue
    result.add(if a.name.len > 0: a.name & " <" & a.email & ">" else: a.email)

proc sigDoc(i: int): RichDoc =
  if i < 0 or i >= sigsC.len: return richDoc()
  richFromHtml(sigsC[i].html)

proc sigIndexFor(account: int; reply: bool): int =
  let id = prefInt((if reply: "sigReply" else: "sigNew") & $account, -2)
  if id == -1: return -1
  for i, s in sigsC:
    if s.id == id: return i
  if sigsC.len > 0 and id == -2: 0 else: -1

var sigAsked = false   ## (Options asked for the signatures from the web: say how it went)

type ComposeSnap = object
  ## A message as it was written, kept while Undo Send can bring it back.
  mode, to, cc, bcc, subject, quote, quoteText: string
  base: Msg
  doc: RichDoc
  atts: seq[tuple[path, name: string; size: int]]
  fwdAtts: seq[Att]
  important: bool
  account, sig, sigParas: int

var
  sentSnap: ComposeSnap
  sentAction = 0          ## the queued "send" Undo Send can still take back

proc keepWebSignature(account: int; data: string) =
  ## The signatures read from the account's service: kept, and used for the
  ## account unless the user chose others (or asked for these).
  let j = try: parseJson(data) except CatchableError: newJObject()
  let acc = account(account)
  if j.hasKey("error"):        # (asked again when Retro Mail starts next)
    if sigAsked: status = acc.email & ": the signature could not be read (" & j{"error"}.getStr & ")"
    return
  prefs.put("sigWeb" & $account, true)
  savePrefs()
  let n = j{"new"}.getStr.strip
  let r = j{"reply"}.getStr.strip
  if n.len == 0:
    if sigAsked: status = acc.email & ": no signature on the web (write one under Signatures)"
    return
  proc keep(html, name: string): int =
    for s in store0.signatures():
      if s.html.strip == html: return s.id
    store0.saveSignature(0, name, html)
  let svc = case acc.kind
            of akGmail: "Gmail"
            of akImap: "IMAP"
            of akGraph: "Outlook"
  let nid = keep(n, svc & " - " & acc.email)
  let rid = if r.len == 0 or r == n: nid else: keep(r, svc & " replies - " & acc.email)
  if sigAsked or prefInt("sigNew" & $account, -2) == -2: prefs.put("sigNew" & $account, nid)
  if sigAsked or prefInt("sigReply" & $account, -2) == -2: prefs.put("sigReply" & $account, rid)
  savePrefs()
  sigsC = store0.signatures()
  status = "The signature of " & acc.email & " from " & svc & " is used here now"

proc writingAids() =
  ## Spelling and AutoCorrect on the message being written (Options,
  ## Spelling turns them off).
  composeDoc.spell = prefBool("spellAsType", true)
  composeDoc.autoCorrect = prefBool("autoCorrect", true)

proc putSignature(i: int) =
  ## The signature at the end of the text (in place of the one there).
  if cSigParas > 0 and composeDoc.paras.len >= cSigParas:
    composeDoc.paras.setLen(composeDoc.paras.len - cSigParas)
  cSigParas = 0
  cSig = i
  if i >= 0:
    let d = sigDoc(i)
    composeDoc.paras.add RichPara()
    for p in d.paras: composeDoc.paras.add p
    cSigParas = d.paras.len + 1
  if composeDoc.paras.len == 0: composeDoc.paras.add RichPara()

proc openCompose(mode: string; base: Msg = Msg(); to = "") =
  if accountsC.len == 0:
    status = "Add an account first (File, Add Account)"
    return
  sigsC = store0.signatures()
  composing = true
  if isCompact(): phone = phCompose
  cMode = mode
  cBase = base
  cTo = to
  cCc = ""
  cBcc = ""
  cSubject = ""
  cQuote = ""
  cQuoteText = ""
  cAtts.setLen(0)
  cFwdAtts.setLen(0)
  cImportant = false
  cShowCc = false
  cShowQuote = false
  cDraftId = 0
  cDirty = false
  cError = ""
  cSigParas = 0
  cField = -1
  cAccount = 0
  let accId = if base.id > 0: base.account else: prefInt("lastAccount", accountsC[0].id)
  for i, a in accountsC:
    if a.id == accId: cAccount = i
  if base.id > 0:
    let me = accountsC[cAccount].email.toLowerAscii
    let subj = stripRe(base.subject)
    case mode
    of "forward":
      cSubject = "Fw: " & subj
      for a in store0.attachments(base.id):
        if not a.inline:
          cFwdAtts.add a
          if not a.hasData: link.cmds.send(SyncCmd(kind: scAttachment, id: a.id))
    else:
      cSubject = "Re: " & subj
      if base.mine:
        cTo = addrsOf(base.toList, @[me]).join(", ")
      else:
        cTo = (if base.fromName.len > 0: base.fromName & " <" & base.fromEmail & ">"
               else: base.fromEmail)
      if mode == "replyAll":
        var more = addrsOf(base.toList, @[me, base.fromEmail.toLowerAscii])
        if base.mine: more.setLen(0)
        if more.len > 0: cTo.add ", " & more.join(", ")
        cCc = addrsOf(base.ccList, @[me]).join(", ")
        cShowCc = cCc.len > 0
    let from0 = if base.fromName.len > 0: base.fromName & " &lt;" & esc(base.fromEmail) & "&gt;"
                else: esc(base.fromEmail)
    var head = "<p>----- Original Message -----<br><b>From:</b> " & from0 &
               "<br><b>To:</b> " & esc(base.toList)
    if base.ccList.len > 0: head.add "<br><b>Cc:</b> " & esc(base.ccList)
    head.add "<br><b>Sent:</b> " & esc(longDate(base.date)) & "<br><b>Subject:</b> " &
             esc(base.subject) & "</p>"
    let orig = if base.html.len > 0: bodyInner(base.html) else: "<p>" & esc(base.snippet) & "</p>"
    cQuote = "<div style=\"margin-top:14px\">" & head &
             "<blockquote style=\"margin:0 0 0 6px;border-left:2px solid #000080;" &
             "padding-left:10px\">" & orig & "</blockquote></div>"
    var qt = "\n\n----- Original Message -----\nFrom: " & base.fromName & " <" & base.fromEmail &
             ">\nSent: " & longDate(base.date) & "\nSubject: " & base.subject & "\n\n"
    for l in base.text.splitLines: qt.add "> " & l & "\n"
    cQuoteText = qt
  composeDoc = richDoc()
  composeDoc.paras.add RichPara()
  if mode != "new" and prefBool("replyBlue", true):
    composeDoc.base = RichStyle(color: replyBlue)  # (what you write in a reply: blue, as Outlook did)
  putSignature(sigIndexFor(accountsC[cAccount].id, mode != "new"))
  writingAids()
  cFocus = if mode == "new" and to.len == 0 or mode == "forward": 1 else: 2

proc draftJson(): JsonNode =
  %*{"mode": cMode, "base": cBase.id, "to": cTo, "cc": cCc, "bcc": cBcc, "subject": cSubject,
     "html": toHtml(composeDoc), "account": cAccount, "important": cImportant,
     "atts": cAtts.mapIt(%*{"path": it.path, "name": it.name, "size": it.size})}

proc saveDraftNow() =
  cDraftId = store0.saveDraft(cDraftId, draftJson())
  cSavedAt = epochTime()
  cDirty = false

proc openDraft(id: int; j: JsonNode) =
  let base = if j{"base"}.getInt > 0: store0.message(j{"base"}.getInt) else: Msg()
  openCompose(j{"mode"}.getStr("new"), base)
  cDraftId = id
  cTo = j{"to"}.getStr
  cCc = j{"cc"}.getStr
  cBcc = j{"bcc"}.getStr
  cShowCc = cCc.len + cBcc.len > 0
  cSubject = j{"subject"}.getStr
  cImportant = j{"important"}.getBool
  cAccount = clamp(j{"account"}.getInt, 0, accountsC.high)
  composeDoc = richFromHtml(j{"html"}.getStr)
  writingAids()
  cSigParas = 0
  for a in j{"atts"}.getElems:
    cAtts.add (a{"path"}.getStr, a{"name"}.getStr, a{"size"}.getInt)

proc mimeOf(name: string): string =
  case name.splitFile.ext.toLowerAscii
  of ".pdf": "application/pdf"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".webp": "image/webp"
  of ".txt", ".nim", ".md": "text/plain"
  of ".html", ".htm": "text/html"
  of ".zip": "application/zip"
  of ".doc": "application/msword"
  of ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  of ".xls": "application/vnd.ms-excel"
  of ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  of ".pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  of ".csv": "text/csv"
  of ".apk": "application/vnd.android.package-archive"
  of ".mp3": "audio/mpeg"
  of ".mp4": "video/mp4"
  else: "application/octet-stream"

proc recipientsJson(s: string): JsonNode =
  result = newJArray()
  for a in parseAddresses(s):
    if a.email.len > 0 and '@' in a.email:
      result.add %*{"name": a.name, "email": a.email}

proc send(later = 0.0) =
  let acc = accountsC[cAccount]
  let to = recipientsJson(cTo)
  let cc = recipientsJson(cCc)
  let bcc = recipientsJson(cBcc)
  if to.len + cc.len + bcc.len == 0:
    cError = "Who is it for? Put at least one address in To."
    return
  if cSubject.strip.len == 0 and cAtts.len == 0 and composeDoc.isEmpty:
    cError = "There is nothing to send."
    return
  let box = mailDir() / "outbox" / $int(epochTime() * 1000)
  var atts = newJArray()
  try:
    createDir(box)
    for a in cAtts:
      let dest = box / a.name
      copyFile(a.path, dest)
      atts.add %*{"path": dest, "name": a.name, "mime": mimeOf(a.name), "copy": true}
    if acc.kind in {akGmail, akImap}:
      for a in cFwdAtts:
        let data = store0.attachmentData(a.id)
        if data.len > 0:
          let dest = box / a.name
          writeFile(dest, data)
          atts.add %*{"path": dest, "name": a.name, "mime": a.mime, "copy": true}
  except CatchableError as e:
    cError = "An attachment could not be read: " & e.msg
    return
  let html = "<div style=\"font-family:Tahoma,Verdana,Arial,sans-serif;font-size:10pt\">" &
             toHtml(composeDoc) & "</div>" & cQuote
  var refs = cBase.refs
  if cBase.msgId.len > 0: refs = (refs & " " & cBase.msgId).strip
  let data = %*{"mode": cMode, "replyTo": cBase.remoteId, "threadId": (if cMode != "new" and
                acc.kind == akGmail: cBase.thread else: ""),
                "inReplyTo": (if cMode in ["reply", "replyAll"]: cBase.msgId else: ""),
                "references": (if cMode != "new": refs else: ""),
                "to": to, "cc": cc, "bcc": bcc, "subject": cSubject, "html": html,
                "text": toPlainText(composeDoc) & cQuoteText, "attachments": atts,
                "important": cImportant}
  if cBase.id > 0 and cBase.account != acc.id:
    data["mode"] = %"new"                 # (a reply from another account: a new message)
    data["replyTo"] = %""
    data["threadId"] = %""
  # Undo Send: it waits here a few seconds first (Options say how many)
  let hold = float(prefInt("undoSend", 10))
  let due = if later > 0: later elif hold > 0: epochTime() + hold else: 0.0
  let aid = store0.queueAction(acc.id, "send", data, due)
  for r in to.getElems & cc.getElems: store0.noteContact(r{"email"}.getStr, r{"name"}.getStr, epochTime())
  if later == 0 and hold > 0:
    sentSnap = ComposeSnap(mode: cMode, to: cTo, cc: cCc, bcc: cBcc, subject: cSubject,
                           quote: cQuote, quoteText: cQuoteText, base: cBase, doc: composeDoc,
                           atts: cAtts, fwdAtts: cFwdAtts, important: cImportant,
                           account: cAccount, sig: cSig, sigParas: cSigParas)
    sentAction = aid
    undoWhat = "send"
    showSnackbar("Sending \"" & (if cSubject.len > 0: cSubject else: "(no subject)") & "\"",
                 "Undo", int(hold * 1000) - 300)
  if cDraftId > 0: store0.deleteDraft(cDraftId)
  prefs.put("lastAccount", acc.id)
  savePrefs()
  composing = false
  if isCompact(): phone = phList
  status = if later > 0: "It will be sent " & longDate(later) & " (while Retro Mail runs)"
           else: "Sending \"" & cSubject & "\"..."
  wake()
  changed()

proc undoSend() =
  ## Undo Send: the message comes back to the window, as it was written.
  let waiting = sentAction > 0 and store0.value("SELECT count(*) FROM actions WHERE id = ? AND " &
                                                "error = ''", sentAction).num > 0
  if not waiting:
    status = "Too late: it has gone"
    return
  store0.doneAction(sentAction)
  sentAction = 0
  let s = sentSnap
  composing = true
  if isCompact(): phone = phCompose
  cMode = s.mode
  cBase = s.base
  cTo = s.to
  cCc = s.cc
  cBcc = s.bcc
  cShowCc = s.cc.len + s.bcc.len > 0
  cSubject = s.subject
  cQuote = s.quote
  cQuoteText = s.quoteText
  composeDoc = s.doc
  cAtts = s.atts
  cFwdAtts = s.fwdAtts
  cImportant = s.important
  cAccount = s.account
  cSig = s.sig
  cSigParas = s.sigParas
  cDraftId = 0
  cDirty = true
  cError = ""
  status = "Not sent: it is back for you to change"
  changed()

proc suggestions(field: var string) =
  ## People to complete the address being typed.
  let k = field.rfind(',')
  let frag = (if k >= 0: field[k + 1 .. ^1] else: field).strip
  if frag.len < 2 or '<' in frag or ('@' in frag and '.' in frag.split('@')[^1]): return
  let found = store0.contacts(frag, 5)
  if found.len == 0: return
  row:
    for c in found:
      let label = if c.name.len > 0: c.name & " <" & c.email & ">" else: c.email
      if link(fit(label, dp(260))):
        field = (if k >= 0: field[0 .. k] & " " else: "") & label & ", "

proc composeWindow() =
  let acc = if accountsC.len > 0: accountsC[clamp(cAccount, 0, accountsC.high)] else: Account()
  setToolbarLook(if isCompact(): blIconOnly else: blTextBelow)
  if not isCompact():
    menubar:
      menu "&File":
        if menuItem("&Send Message", "Alt+S"): send()
        if menuItem("Send &Later..."): cLaterOpen = true
        if menuItem("Save &Draft", "Ctrl+S"): saveDraftNow()
        menuSeparator()
        if menuItem("&Close", "Esc"): cAskClose = true
      menu "&Insert":
        if menuItem("File &Attachment..."): cAttachOpen = true
        submenu "&Signature":
          if menuItem("(&none)", checked = cSig < 0): putSignature(-1)
          for i, s in sigsC:
            if menuItem(s.name, checked = cSig == i): putSignature(i)
        submenu "My &Templates": templatesMenu()
      menu "&Message":
        if menuItem("&High Priority", checked = cImportant): cImportant = not cImportant
        if menuItem("&Cc and Bcc", checked = cShowCc): cShowCc = not cShowCc
  toolbar:
    if barButton(nfSend, "Send", "Send now (Alt+S)"): send()
    if barButton(pxClock, "Later", "Send later"): cLaterOpen = true
    toolSeparator()
    if barButton(nfPaperclip, "Attach", "Attach a file"): cAttachOpen = true
    if barButton(pxPen, "Signature", "Choose the signature"):
      openPopupMenu("sigmenu", ui.lastRect.x, ui.lastRect.y + ui.lastRect.h)
    if barButton(nfExclamation, "Priority", "High priority", down = cImportant):
      cImportant = not cImportant
    if barButton(pxUser, "Cc/Bcc", "Show Cc and Bcc", down = cShowCc): cShowCc = not cShowCc
    if barButton(pxDocument, "Templates", "Start from a template, or keep this one as a template"):
      openPopupMenu("tplmenu", ui.lastRect.x, ui.lastRect.y + ui.lastRect.h)
    toolSeparator()
    if barButton(pxSave, "Save", "Save the draft (Ctrl+S)"): saveDraftNow()
    if barButton(pxDelete, "Discard", "Close without sending"): cAskClose = true
  popupMenu("tplmenu"): templatesMenu()
  popupMenu("sigmenu"):
    if menuItem("(&none)", checked = cSig < 0): putSignature(-1)
    for i, s in sigsC:
      if menuItem(s.name, checked = cSig == i): putSignature(i)
    menuSeparator()
    if menuItem("&Signatures..."):
      optTab = 2
      optOpen = true
  statusbar(if cError.len > 0: cError
            elif cSavedAt > 0: "Draft saved at " & fromUnixFloat(cSavedAt).local.format("HH:mm")
            else: "New message",
            (if cSig >= 0 and cSig < sigsC.len: "Signature: " & sigsC[cSig].name else: "No signature"),
            (case acc.kind
             of akGmail: "Sends with Gmail"
             of akImap: "Sends through " & serversOf(acc).smtpHost
             of akGraph: "Sends with Microsoft 365"))
  let compact = isCompact()
  let lw = if compact: dp(54) else: dp(70)
  if cFocus == 1:
    ui.textFocusWanted = true
    cFocus = 0
  form lw:
    if accountsC.len > 1:
      field "From:":
        var names: seq[string]
        for a in accountsC: names.add(if a.name.len > 0: a.name & " <" & a.email & ">" else: a.email)
        if combo(names, cAccount): cDirty = true
    field "&To:":
      if edit(cTo):
        cDirty = true
        cField = 0
    if cField == 0: suggestions(cTo)
    if cShowCc:
      field "&Cc:":
        if edit(cCc):
          cDirty = true
          cField = 1
      if cField == 1: suggestions(cCc)
      field "&Bcc:":
        if edit(cBcc):
          cDirty = true
          cField = 2
      if cField == 2: suggestions(cBcc)
    field "&Subject:":
      if edit(cSubject): cDirty = true
  if cAtts.len + cFwdAtts.len > 0:
    row:
      label "Attach:"
      var drop = -1
      for i, a in cAtts:
        if button(fit(a.name, dp(200)) & "  (" & sizeText(a.size) & ")  x", pxFile): drop = i
      if drop >= 0:
        cAtts.delete(drop)
        cDirty = true
      for a in cFwdAtts:
        label a.name & " (" & sizeText(a.size) & ")", color = ui.theme.gray
  richToolbar(composeDoc, compact = compact)
  if cFocus == 2:
    ui.textFocusWanted = true
    cFocus = 0
  let quoteH = if cQuote.len == 0: 0 elif cShowQuote: dp(200) else: CtrlH + dp(4)
  # Ctrl+Enter sends (as Outlook), before the text takes the Enter
  if canInput() and not ui.keyUsed and ui.key == KeyEnter and CtrlPressed in ui.mods:
    ui.keyUsed = true
    send()
    return
  if richEdit(composeDoc, height = remainingH() - quoteH, key = "compose",
              placeholder = "Write your message here"):
    cDirty = true
  if cQuote.len > 0:
    if link(if cShowQuote: "Hide the original message" else: "Show the original message (it goes with your reply)"):
      cShowQuote = not cShowQuote
    if cShowQuote:
      panel(remainingH()):
        htmlBlock(cQuote, images = imagesFor(cBase))
  if cDirty and epochTime() - cSavedAt > 15: saveDraftNow()
  if canInput() and not ui.keyUsed:
    if ui.key == KeyS and AltPressed in ui.mods: send(); ui.keyUsed = true
    elif ui.key == KeyS and CtrlPressed in ui.mods: saveDraftNow(); ui.keyUsed = true
    elif ui.key == KeyEsc and ui.popup == 0: cAskClose = true; ui.keyUsed = true
  # files dropped on the window (from Explorer, Nautilus...): attached
  for p in fileDropTarget(rect(0, 0, ui.w, ui.h)):
    if fileExists(p):
      try:
        cAtts.add (p, extractFilename(p), int getFileSize(p))
        cDirty = true
        status = "Attached " & extractFilename(p)
      except OSError as e: cError = e.msg
  if fileDialog(cAttachOpen, cAttachPath, fmOpen, ["All Files (*.*)"], "Attach a File"):
    try:
      cAtts.add (cAttachPath, extractFilename(cAttachPath), int getFileSize(cAttachPath))
      cDirty = true
    except OSError as e: cError = e.msg
  dialog cLaterOpen, "Send Later", dp(320):
    if cLaterDay.year == 0: cLaterDay = today().addDays(1)
    label "Send it on:"
    datePicker(cLaterDay)
    label "At:"
    timePicker(cLaterH, cLaterM)
    paragraph "Retro Mail sends it then, when it is running (else as soon as it starts)."
    row:
      space available() - 2 * (dp(80) + Gap) + Gap
      if button("OK", isDefault = true, w = dp(80)):
        let t = dateTime(cLaterDay.year, Month(cLaterDay.month), cLaterDay.day, cLaterH, cLaterM,
                         0, 0, local()).toTime.toUnixFloat
        cLaterOpen = false
        send(max(t, epochTime()))
      if button("Cancel", w = dp(80)): cLaterOpen = false
  case msgBox(cAskClose, appName, "Keep this message as a draft?",
              ["&Save Draft", "&Discard", "Cancel"], miQuestion)
  of 1:
    saveDraftNow()
    composing = false
    if isCompact(): phone = phList
  of 2:
    if cDraftId > 0: store0.deleteDraft(cDraftId)
    composing = false
    if isCompact(): phone = phList
  else: discard

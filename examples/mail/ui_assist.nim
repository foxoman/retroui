# Retro Mail -- included by mail.nim
#
# The Assistant pane (View, Assistant): a conversation with your AI service that reads and
# finds your mail and writes for you -- a reply drafted and opened for you to read and send,
# messages marked -- with the kit's assistant (retroui/assistant). It sends only what it reads
# to answer; a draft or a change is asked first. Off until a service is set (Tools, Options,
# Assistant).

const mailAssistSystem = "You are the assistant inside Retro Mail. You help the user with their mail: find and " &
  "read messages with your tools, sum them up, answer questions about them, and draft replies or new " &
  "messages -- a draft opens for the user to read and send; never say it was sent. Messages are named by " &
  "their #id. Be brief, and write in the language the user writes in."

var
  mailChat: AiChat
  mailAi: tuple[loaded: bool; s: AiSettings]

proc loadMailAi() =
  ## (the service: the kit's AI settings, else the Anthropic key of older versions)
  if mailAi.loaded: return
  mailAi.loaded = true
  mailAi.s = loadAiSettings(secretApp)
  if not mailAi.s.connected:
    let old = loadSecret(secretApp, "ai-key")
    if old.len > 0:
      mailAi.s = AiSettings(kind: akAnthropic, url: defaultUrl(akAnthropic),
                            model: pref("aiModel", "claude-haiku-5-5"), key: old)

proc msgLine(m: Msg): string =
  "#" & $m.id & "  " & fromUnixFloat(m.date).local.format("yyyy-MM-dd HH:mm") & "  " &
    (if m.fromName.len > 0: m.fromName & " <" & m.fromEmail & ">" else: m.fromEmail) & "  \"" & m.subject & "\"" &
    (if m.unread: " (unread)" else: "") & (if m.flagged: " (flagged)" else: "") &
    (if m.snippet.len > 0: " -- " & clip(m.snippet, 140) else: "")

proc msgLines(ms: seq[Msg]): string =
  if ms.len == 0: return "no messages"
  for m in ms: result.add msgLine(m) & "\n"

proc msgArg(a: JsonNode): Msg =
  let id = if a{"id"}.kind == JInt: a{"id"}.getInt
           else: (try: parseInt(a{"id"}.getStr.strip(chars = {'#', ' '})) except ValueError: 0)
  if id > 0: store0.message(id) else: Msg()

var
  mailMeaning: MeaningIndex          ## (search by meaning: the newest messages' vectors)

proc findByMeaning(question: string; count: int; answer: proc (text: string) {.closure.}) =
  ## (the newest messages -- 400 at most -- made vectors by the embedding model on this device,
  ## once each; then those nearest the question)
  var model = ""
  for m in installedModels(muEmbed): model = modelPath(m)
  if model.len == 0:
    answer("no embedding model is on this device (Tools, Options, Assistant, Models: Qwen3 Embedding)")
    return
  if mailMeaning == nil or mailMeaning.model != model:
    mailMeaning = openMeaningIndex(mailDir() / "meaning.idx", model)
  var items: seq[MeaningItem]
  var keys: seq[string]
  for m in store0.whereMessages("1 = 1", @[], 400):
    let text = "From: " & (if m.fromName.len > 0: m.fromName else: m.fromEmail) & "\nSubject: " & m.subject &
               "\n" & m.snippet
    items.add ($m.id, $m.date, text)
    keys.add $m.id
  let ix = mailMeaning
  discard ix.update(items, proc () =
    var found: Job[seq[MeaningHit]]
    found = ix.find("Find the e-mail messages that answer the question", question, count, keys, proc () =
      if not found.done:
        answer("the search failed: " & found.error)
        return
      var ms: seq[Msg]
      for h in found.value:
        let m = store0.message(parseInt(h.key))
        if m.id != 0: ms.add m
      answer(msgLines(ms))))

proc mailAiTools(): seq[AiTool] =
  result.add aiTool("list_messages", "Lists the newest messages of a folder (the Inbox if none is named).",
    [param("folder", "string", "inbox, sent, drafts, archive, junk, deleted, or a folder's name", optional = true),
     param("unread_only", "boolean", "only those not read", optional = true),
     param("count", "integer", "how many (20 if not given)", optional = true)],
    proc (a: JsonNode): string =
      let f = a{"folder"}.getStr("inbox").toLowerAscii
      var where = if f in ["inbox", "sent", "drafts", "archive", "junk", "deleted", "trash"]:
                    "folder IN (SELECT id FROM folders WHERE role = ?)"
                  else: "folder IN (SELECT id FROM folders WHERE name LIKE ?)"
      if a{"unread_only"}.getBool: where.add " AND unread = 1"
      let arg = if f == "trash": "deleted" elif f in ["inbox", "sent", "drafts", "archive", "junk", "deleted"]: f
                else: "%" & a{"folder"}.getStr & "%"
      msgLines(store0.whereMessages(where, @[toDbValue(arg)], clamp(a{"count"}.getInt(20), 1, 100))))
  result.add aiTool("search_mail", "Finds messages whose subject, sender or text has the words given.",
    [param("text", "string", "what to look for"), param("count", "integer", "how many (20)", optional = true)],
    proc (a: JsonNode): string =
      var where = ""
      var args: seq[DbValue]
      for w in strutils.splitWhitespace(a{"text"}.getStr):
        if where.len > 0: where.add " AND "
        where.add "(subject LIKE ? OR from_name LIKE ? OR from_email LIKE ? OR snippet LIKE ?)"
        for i in 0 ..< 4: args.add toDbValue("%" & w & "%")
      if where.len == 0: return "say what to look for"
      msgLines(store0.whereMessages(where, args, clamp(a{"count"}.getInt(20), 1, 100))))
  if installedModels(muEmbed).len > 0:
    result.add aiToolLater("find_by_meaning", "Finds messages by what they are about, not their words: \"the " &
                           "invoice from Ahmed\" finds a bill from Ahmad. Slower than search_mail the first time.",
      [param("question", "string", "what the messages should be about"),
       param("count", "integer", "how many (10 if not given)", optional = true)],
      proc (a: JsonNode; done: proc (text: string) {.closure.}) =
        findByMeaning(a{"question"}.getStr, clamp(a{"count"}.getInt(10), 1, 50), done))
  result.add aiTool("read_message", "Reads a message: who sent it, to whom, when, its subject and its text " &
                    "(without what it quotes).", [param("id", "integer", "the message's #id")],
    proc (a: JsonNode): string =
      let m = msgArg(a)
      if m.id == 0: return "no such message"
      let body = if m.text.len > 0: m.text elif m.html.len > 0: plainOf(m.html) else: ""
      result = "From: " & m.fromName & " <" & m.fromEmail & ">\nTo: " & m.toList &
               (if m.ccList.len > 0: "\nCc: " & m.ccList else: "") & "\nDate: " & longDate(m.date) &
               "\nSubject: " & m.subject & "\n\n"
      if body.len > 0: result.add clip(withoutQuotes(body), 8000)
      else: result.add m.snippet & "\n(only its start: the whole message is not on this device yet)")
  result.add aiTool("draft_reply", "Opens a reply to a message with the text given, for the user to read, " &
                    "change and send.",
    [param("id", "integer", "the message's #id"), param("text", "string", "the reply's text"),
     param("reply_all", "boolean", "to everyone it went to", optional = true)],
    proc (a: JsonNode): string =
      let m = msgArg(a)
      if m.id == 0: return "no such message"
      openCompose(if a{"reply_all"}.getBool: "replyAll" else: "reply", m)
      if not composing: return "the reply could not be opened: " & status
      richInsert(composeDoc, a{"text"}.getStr)
      cDirty = true
      "the reply is open for the user to read and send",
    confirm = true)
  result.add aiTool("draft_message", "Opens a new message with the address, subject and text given, for the " &
                    "user to read, change and send.",
    [param("to", "string", "the address(es)"), param("subject", "string", "its subject"),
     param("text", "string", "its text")],
    proc (a: JsonNode): string =
      openCompose("new", Msg(), a{"to"}.getStr)
      if not composing: return "the message could not be opened: " & status
      cSubject = a{"subject"}.getStr
      richInsert(composeDoc, a{"text"}.getStr)
      cDirty = true
      "the message is open for the user to read and send",
    confirm = true)
  result.add aiTool("mark_message", "Marks a message read or unread, flagged or not.",
    [param("id", "integer", "the message's #id"), param("read", "boolean", "read (false: unread)", optional = true),
     param("flagged", "boolean", "flagged", optional = true)],
    proc (a: JsonNode): string =
      let m = msgArg(a)
      if m.id == 0: return "no such message"
      if a.hasKey("read"): markRead(@[m], unread = not a{"read"}.getBool)
      if a.hasKey("flagged") and a{"flagged"}.getBool != m.flagged: toggleFlag(@[m])
      "marked",
    confirm = true)

proc mailAssistChat(): AiChat =
  loadMailAi()
  if mailChat == nil:
    mailChat = newAiChat(mailAi.s, mailAssistSystem, mailAiTools())
    mailChat.context = proc (): string =
      let n = unreadAll()
      "Today is " & now().format("dddd yyyy-MM-dd") & ". " & $n & " unread messages." &
        (if accountsC.len > 0: " The user's address: " & accountsC[0].email & "." else: "")
  mailChat.settings = mailAi.s
  mailChat

proc mailAssistantPane() =
  ## (the pane at the right: View, Assistant)
  folderBar("Assistant", if mailAi.s.connected: mailAi.s.model else: "not connected")
  loadMailAi()
  if not mailAi.s.connected:
    paragraph("Connect an AI service of your own (Tools, Options, Assistant) and ask here: \"what came from " &
              "the bank this week?\", \"sum up the thread with Sara\", \"answer Ali that Monday suits me\". " &
              "It reads only what it needs, and a reply it drafts opens for you to send.", color = ui.theme.gray)
    if button("&Options...", w = dp(100)):
      optOpen = true
      optTab = 6
    return
  assistantPanel(mailAssistChat())

# (the same tools for an AI agent outside, when the app is driven: RETRO_DRIVE, `retrokit mcp`)
var mailToolsOffered = false
proc offerMailTools() {.nimcall.} =
  if mailToolsOffered or drivePort() == 0 or store0 == nil: return
  mailToolsOffered = true
  publishTools(mailAiTools())
beginFrameHooks.add offerMailTools

# ---- Summarize and Translate through the Assistant's service ---------------------------------------

var serviceAsk: tuple[job: Job[HttpResponse]; id: int]

proc askViaService(kind: string; m: Msg; lang: string): bool =
  ## (Summarize or Translate asked of the Assistant's service when one is set -- this device's
  ## own model sends nothing anywhere; else of Claude with the older key, on the sync worker)
  loadMailAi()
  if not mailAi.s.connected or store0 == nil: return false
  # (the device's own model reads slowly: less of a long thread)
  let budget = if mailAi.s.kind == akDevice: 6000 else: mailAssist.maxText
  var q: tuple[system, user: string]
  if kind == "summary":
    var thread: seq[tuple[sender, date, text: string]]
    let ms = store0.threadMessages(m.account, m.thread)
    for k in countdown(ms.high, 0):
      let x = ms[k]
      let body = if x.text.len > 0: x.text else: plainOf(x.html)
      thread.add ((if x.fromName.len > 0: x.fromName else: x.fromEmail),
                  fromUnixFloat(x.date).local.format("yyyy-MM-dd HH:mm"),
                  (if body.len > 0: body else: x.snippet))
    if thread.len == 0: thread.add ((if m.fromName.len > 0: m.fromName else: m.fromEmail), "", m.snippet)
    q = summaryAsk(thread, lang, store0.account(m.account).name, budget)
  else:
    let x = store0.message(m.id)
    let body = if x.text.len > 0: x.text else: plainOf(x.html)
    q = translateAsk(if body.len > 0: body else: x.snippet, lang, budget)
  let id = m.id
  serviceAsk.id = id
  serviceAsk.job = askOnce(mailAi.s, q.system, q.user, onDone = proc () =
    if serviceAsk.id != id or assistFor != id: return
    let (t, err) = onceAnswer(mailAi.s, serviceAsk.job)
    assistWaiting = false
    assistText = if err.len > 0: "It did not work: " & err else: t
    ui.redraw = true)
  true

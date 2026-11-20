## Retro Mail's Assistant pane (examples/mail/ui_assist): its tools on a store of the test's
## own -- the Inbox listed, its unread, a search, a message read without what it quotes, a
## reply drafted and opened (not sent), a new message, a message marked -- and the service it
## speaks to (the kit's AI settings, an older version's Anthropic key, this device's own model:
## Summarize and Translate through it, find by meaning offered with an embedding model).

import std/[os, json, strutils, times]

let home = getTempDir() / "retro-mailassist-" & $getCurrentProcessId()
removeDir(home)
createDir(home)
putEnv("HOME", home)
putEnv("RETRO_MAIL_HOME", home)
putEnv("RETRO_SECRETS_DIR", home / "secrets")

const mailUnderTest = true
include ../examples/mail

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

prefs = loadSettings("retro-mail")
store0 = openStore()
link.cmds.open()          # (what the app asks of its sync thread: kept, none runs here)
link.events.open()
let acc = store0.addAccount(akImap, "me@example.com", "Me", "", "")
let inbox = store0.upsertFolder(acc, "INBOX", "Inbox", "inbox", "")
let sent = store0.upsertFolder(acc, "Sent", "Sent", "sent", "")
let t0 = epochTime()
let bill = store0.upsertMessage(Msg(account: acc, folder: inbox, remoteId: "1", thread: "t1",
  subject: "Invoice for March", fromName: "Bank", fromEmail: "bank@example.com", toList: "me@example.com",
  date: t0 - 3600, snippet: "Your invoice is ready", unread: true))
store0.setBody(bill, "", "Your invoice is 20 OMR.\n\nOn Monday, Me wrote:\n> can I have the invoice?")
discard store0.upsertMessage(Msg(account: acc, folder: inbox, remoteId: "2", thread: "t2",
  subject: "Lunch", fromName: "Sara", fromEmail: "sara@example.com", toList: "me@example.com",
  date: t0 - 60, snippet: "Monday?", unread: false))
discard store0.upsertMessage(Msg(account: acc, folder: sent, remoteId: "3", thread: "t3",
  subject: "Report", fromName: "Me", fromEmail: "me@example.com", toList: "boss@example.com",
  date: t0 - 7200, snippet: "Attached", mine: true))
discard store0.saveSignature(0, "Simple", "<p>--<br>Sent with Retro Mail</p>")
reload()

let tools = mailAiTools()
var said = ""
proc use(name: string; args: JsonNode = newJObject()): string =
  said = "no tool " & name
  for t in tools:
    if t.name == name:
      t.start(args, proc (x: string) = said = x)
  said

echo "the Assistant's tools"
let inboxText = use("list_messages")
check "\"Invoice for March\"" in inboxText and "\"Lunch\"" in inboxText and "\"Report\"" notin inboxText and
      inboxText.find("Lunch") < inboxText.find("Invoice"), "the Inbox, the newest first, not the Sent"
let unread = use("list_messages", %*{"unread_only": true})
check "Invoice" in unread and "Lunch" notin unread and "(unread)" in unread, "only the unread"
check "\"Report\"" in use("list_messages", %*{"folder": "sent"}), "another folder by its role"
check "#" & $bill in use("search_mail", %*{"text": "invoice bank"}), "found by words of its subject and sender"
check use("search_mail", %*{"text": "nothing like this"}) == "no messages", "nothing found: said"
let read = use("read_message", %*{"id": bill})
check "20 OMR" in read and "can I have" notin read and "From: Bank <bank@example.com>" in read,
      "read, without what it quotes"
check use("read_message", %*{"id": 9999}) == "no such message", "a message that is not there"
let r = use("draft_reply", %*{"id": bill, "text": "Thank you, paid today."})
check r.startsWith("the reply is open") and composing and cSubject == "Re: Invoice for March" and
      "bank@example.com" in cTo and "Thank you, paid today." in toPlainText(composeDoc),
      "a reply drafted and opened for the user to send"
composing = false
check use("draft_message", %*{"to": "ali@example.com", "subject": "Monday", "text": "Monday suits me."}).startsWith(
      "the message is open") and cTo == "ali@example.com" and cSubject == "Monday" and
      "Monday suits me." in toPlainText(composeDoc), "a new message opened"
composing = false
check use("mark_message", %*{"id": bill, "read": true}) == "marked" and not store0.message(bill).unread,
      "marked read"
check tools.len == 6 and tools[3].confirm and tools[4].confirm and tools[5].confirm and not tools[0].confirm,
      "what changes something asks first; what reads does not"

echo "the service"
check not mailAssistChat().settings.connected, "none set: not connected"
mailChat.close()
mailChat = nil
mailAi.loaded = false
discard saveSecret(secretApp, "ai-key", "sk-ant-old")
prefs.put("aiModel", "claude-test")
let s = mailAssistChat().settings
check s.connected and s.kind == akAnthropic and s.key == "sk-ant-old" and s.model == "claude-test",
      "an older version's Anthropic key taken"
saveAiSettings(secretApp, AiSettings(kind: akOpenAi, url: "http://127.0.0.1:1/v1/chat/completions", model: "m"))
mailAi.loaded = false
check mailAssistChat().settings.kind == akOpenAi, "the kit's AI settings first"
check "unread messages" in mailChat.context(), "what the app shows told with each request"

echo "this device's own model"
let tinyDir = currentSourcePath().parentDir / "data" / "llm"
mailAi.s = AiSettings(kind: akDevice, url: tinyDir / "tiny-bitnet.gguf")
mailAi.loaded = true
assistFor = bill
assistWaiting = true
check askViaService("summary", store0.message(bill), ""), "Summarize through the Assistant's service"
let w0 = epochTime()
while not serviceAsk.job.ended and epochTime() - w0 < 120: sleep(20)
let (summed, why) = onceAnswer(mailAi.s, serviceAsk.job)
check serviceAsk.job.done and why == "" and summed.len > 0, "  the model on this device answered: " & why
check askViaService("translate", store0.message(bill), "Arabic"), "Translate too"
while not serviceAsk.job.ended and epochTime() - w0 < 240: sleep(20)
check serviceAsk.job.done, "  answered"
# (an embedding model on the device: the Assistant finds mail by meaning)
modelsDir = home / "Models"
createDir(modelsDir)
let em = storeModel("qwen3-embed-0.6b")
copyFile(tinyDir / "tiny-qwen3.gguf", modelPath(em))
writeFile(modelPath(em) & ".ok", em.sha256)
var named: seq[string]
for t in mailAiTools(): named.add t.name
check "find_by_meaning" in named, "find_by_meaning offered when an embedding model is there"
modelsDir = ""

store0.close()
removeDir(home)
if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_mailassist: all passed"

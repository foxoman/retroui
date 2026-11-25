## Tests of retroui/aichat, retroui/assistant and retroui/aiimage against a service of the
## test's own (tests/aimock.py): the requests as each kind of service takes them (tools,
## their calls and results, a picture), the answers read; a conversation that calls a tool,
## asks first and goes on when allowed, not when denied, two calls in one answer, a tool
## done some frames later, the rounds limited; the assistant's panel drawn and its Allow
## pressed; a picture made and one changed through a mask, at the sizes asked.

import std/[os, osproc, strutils, exitprocs, json, times, streams]
import retroui, retroui/[headless, aichat, aiimage, assistant, inspect, http]
import retroui/uirelays/access

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

useHeadless(640, 480)
startApp("AI chat", 640, 480)

echo "the requests and the answers"
block shapes:
  let tools = @[aiTool("add_note", "Adds a note.", [param("text", "string", "the note"),
                                                    param("color", "string", "its color", ["red", "blue"], optional = true)],
                       proc (a: JsonNode): string = "added")]
  let sch = tools[0].params
  check sch["required"].len == 1 and sch["properties"]["color"]["enum"].len == 2,
        "a tool's arguments as a JSON Schema (an optional one, an enum)"
  var msgs = @[AiMessage(role: arUser, text: "note: milk", png: "\x89PNG...")]
  msgs.add AiMessage(role: arAssistant, calls: @[AiCall(id: "c1", name: "add_note", args: %*{"text": "milk"})])
  msgs.add AiMessage(role: arTool, text: "added", callId: "c1", toolName: "add_note")
  let o = chatRequest(AiSettings(kind: akOpenAi, url: "http://x/v1/chat/completions", model: "m", key: "k"),
                      "be brief", tools, msgs)
  let ob = parseJson(o.body)
  check ("Authorization", "Bearer k") in o.headers and ob["messages"][0]["role"].getStr == "system" and
        ob["messages"][1]["content"][1]["type"].getStr == "image_url" and
        ob["messages"][2]["tool_calls"][0]["function"]["arguments"].getStr == "{\"text\":\"milk\"}" and
        ob["messages"][3]["role"].getStr == "tool" and ob["messages"][3]["tool_call_id"].getStr == "c1" and
        ob["tools"][0]["function"]["name"].getStr == "add_note",
        "OpenAI's: the system's words, a picture, a call, its result, the tools"
  msgs.add AiMessage(role: arTool, text: "again", callId: "c2", toolName: "add_note")
  let a = chatRequest(AiSettings(kind: akAnthropic, url: "http://x/v1/messages", model: "m", key: "k"),
                      "be brief", tools, msgs)
  let ab = parseJson(a.body)
  check ("x-api-key", "k") in a.headers and ab["system"].getStr == "be brief" and
        ab["messages"][0]["content"][0]["type"].getStr == "image" and
        ab["messages"][1]["content"][0]["type"].getStr == "tool_use" and
        ab["messages"].len == 3 and ab["messages"][2]["content"].len == 2 and
        ab["tools"][0]["input_schema"]["type"].getStr == "object",
        "Anthropic's: a picture, tool_use, two results in one message of the user's, input_schema"
  let r1 = chatReply(akOpenAi, """{"choices":[{"message":{"content":null,"tool_calls":[{"id":"a","type":"function","function":{"name":"add_note","arguments":"{\"text\":\"x\"}"}}]}}]}""")
  check r1.error.len == 0 and r1.msg.calls.len == 1 and r1.msg.calls[0].args["text"].getStr == "x",
        "OpenAI's answer: a call, its arguments read from their text"
  let r2 = chatReply(akAnthropic, """{"content":[{"type":"text","text":"Sure."},{"type":"tool_use","id":"t","name":"add_note","input":{"text":"y"}}]}""")
  check r2.msg.text == "Sure." and r2.msg.calls[0].id == "t" and r2.msg.calls[0].args["text"].getStr == "y",
        "Anthropic's answer: words and a call"
  check chatReply(akOpenAi, """{"error":{"message":"bad key"}}""").error == "bad key", "an error said"

# ---- against the service of the test's own ----

let python = if findExe("python3").len > 0: "python3" else: "python"
let mock = startProcess(python, args = [currentSourcePath().parentDir / "aimock.py"], options = {poUsePath})
proc stopAtExit(p: Process) =
  # (the exit proc keeps its own reference: the program's globals are freed before)
  addExitProc(proc () = p.terminate())
stopAtExit(mock)
let port = mock.outputStream.readLine.strip
let base = "http://127.0.0.1:" & port

var notes: seq[string]
proc noteTool(confirm: bool): AiTool =
  aiTool("add_note", "Adds a note to the list.", [param("text", "string", "the note")],
    proc (a: JsonNode): string =
      notes.add a["text"].getStr
      "added \"" & a["text"].getStr & "\", " & $notes.len & " notes now",
    confirm = confirm)

var drawPanel: AiChat
proc frame() =
  discard beginFrame()
  if drawPanel != nil: assistantPanel(drawPanel)
  else: label "chat"
  endFrame()

accessKeep = true
proc press(name: string): bool =
  ## (a button pressed as a screen reader presses it)
  let i = findNode(accessLast, name, {arButton})
  if i < 0: return false
  accessRequests.add AccessRequest(action: aaPress, id: accessLast[i].id)
  frame()
  frame()
  true

proc settle(c: AiChat; till: set[AiChatState] = {ciIdle, ciConfirm}; ms = 8000): bool =
  let t0 = epochTime()
  while (epochTime() - t0) * 1000 < ms.float:
    frame()
    if c.state in till and not (c.state == ciIdle and c.messages.len > 0 and c.messages[^1].role == arUser and
                                c.error.len == 0 and c.settings.connected):
      return true
    sleep(5)
  false

let oa = AiSettings(kind: akOpenAi, url: base & "/v1/chat/completions", model: "mock", key: "sk-test")

echo "a conversation that uses a tool"
block plain:
  let c = newAiChat(oa, "You keep notes.", [noteTool(false)])
  c.send("hello there")
  check c.settle() and c.lastAnswer == "You said: hello there", "words answered with words"
  c.send("note: milk")
  check c.settle() and notes == @["milk"] and c.lastAnswer.startsWith("Done: added \"milk\""),
        "the service asked the tool, it ran, its result went back, the answer came"
  check c.messages.len == 6 and c.messages[3].calls[0].state == acDone, "the call kept with what it did"
  c.close()

block reasoningModel:
  # (OpenAI's newer models reason, and through chat completions take no function tools while they
  # do: the service says so, and the chat asks again with reasoning_effort "none" -- and since)
  notes.setLen(0)
  let ro = AiSettings(kind: akOpenAi, url: base & "/v1/chat/completions", model: "reasoner-1", key: "sk-test")
  let r = chatRequest(ro, "", [noteTool(false)], [AiMessage(role: arUser, text: "hi")], noReasoning = true)
  check parseJson(r.body)["reasoning_effort"].getStr == "none", "asked without reasoning: reasoning_effort none"
  check "reasoning_effort" notin parseJson(chatRequest(ro, "", [], [AiMessage(role: arUser, text: "hi")],
                                                        noReasoning = true).body),
        "no tools: nothing to ask it"
  check reasoningRefused("Function tools with reasoning_effort are not supported for gpt-6.1-terra") and
        not reasoningRefused("bad key"), "the service's refusal known"
  let c = newAiChat(ro, "You keep notes.", [noteTool(false)])
  c.send("note: eggs")
  check c.settle() and c.error.len == 0 and notes == @["eggs"] and c.noReasoning,
        "refused with tools, asked again without reasoning: the tool ran (" & c.error & ")"
  c.send("note: bread")
  check c.settle() and notes == @["eggs", "bread"], "and so since"
  c.close()

block confirmed:
  notes.setLen(0)
  let c = newAiChat(oa, "", [noteTool(true)])
  c.send("note: eggs")
  check c.settle() and c.state == ciConfirm and c.waitingFor.name == "add_note" and notes.len == 0,
        "a tool that changes things waits for the user"
  c.allow()
  check c.settle() and notes == @["eggs"] and c.lastAnswer.startsWith("Done: "), "allowed: run, then the answer"
  c.send("note: tea")
  check c.settle() and c.state == ciConfirm, "asked again (allowed once, not always)"
  c.deny()
  check c.settle() and notes == @["eggs"] and "the user said no" in c.lastAnswer,
        "denied: not run, the service told so"
  c.send("two: bread, jam")
  check c.settle() and c.state == ciConfirm, "two calls: the first asks"
  c.allow(always = true)
  check c.settle() and notes == @["eggs", "bread", "jam"] and c.trusted and
        c.lastAnswer == "Done: added \"bread\", 2 notes now | added \"jam\", 3 notes now",
        "Allow All: both run, their results sent together, in order"
  c.close()

block later:
  var pending: seq[proc (text: string) {.closure.}]
  let t = aiToolLater("ui_click", "Clicks a control.", [param("name", "string", "its name")],
    proc (a: JsonNode; done: proc (text: string) {.closure.}) = pending.add done)
  let c = newAiChat(oa, "", [t])
  c.send("click: OK")
  for i in 0 ..< 200:
    frame()
    if pending.len > 0: break
    sleep(5)
  check pending.len == 1 and c.state == ciTools, "a tool that says so later: the chat waits for it"
  for i in 0 ..< 3: frame()
  check c.state == ciTools, "still waiting"
  pending[0]("clicked OK")
  check c.settle() and c.lastAnswer == "Done: clicked OK", "it said: the conversation went on"
  c.close()

block rounds:
  # (a service that asks for a tool again and again is stopped)
  let loopTool = aiTool("add_note", "", [param("text", "string", "")], proc (a: JsonNode): string = "note: again")
  let c = newAiChat(oa, "", [loopTool])
  c.maxRounds = 1
  c.send("note: x")
  check c.settle() and c.error.startsWith("stopped after 1"), "the rounds of tools limited"
  c.close()

block anthropic:
  notes.setLen(0)
  let c = newAiChat(AiSettings(kind: akAnthropic, url: base & "/v1/messages", model: "mock", key: "ak"),
                    "notes", [noteTool(false)])
  c.send("note: honey", png = "\x89PNG\r\n")
  check c.settle() and notes == @["honey"] and c.lastAnswer.startsWith("Done: added"),
        "Anthropic's kind: tool_use, tool_result, the answer"
  let st = parseJson(httpRequest("GET", base & "/state").body)
  check st["key"].getStr == "ak" and st["messages"]["messages"][0]["content"][0]["type"].getStr == "image",
        "its key and the picture sent"
  c.close()

block noService:
  let c = newAiChat(AiSettings(), "")
  c.send("hi")
  check c.error.len > 0 and not c.busy, "no service: said, nothing sent"
  c.close()

echo "the assistant's panel"
block panel:
  notes.setLen(0)
  let c = newAiChat(oa, "", [noteTool(true)])
  drawPanel = c
  c.draft = "note: cake"
  frame()
  check press("Send"), "Send pressed"
  for i in 0 ..< 400:
    frame()
    if c.state == ciConfirm: break
    sleep(5)
  frame()
  check c.state == ciConfirm and c.draft.len == 0, "sent, its box emptied; the tool asks"
  check press("Allow"), "the panel's Allow pressed"
  check c.settle() and notes == @["cake"], "it ran"
  frame()
  let shot = headlessShot()
  check shot != nil and shot.w == 640, "the panel drawn"
  check press("New") and c.messages.len == 0, "New: a new conversation"
  drawPanel = nil
  c.close()

echo "pictures"
block pictures:
  let s = AiImageSettings(url: base & "/v1/images/generations", model: "gpt-image-1", key: "ik")
  check serviceSize(1600, 1000) == (1536, 1024) and serviceSize(800, 1200) == (1024, 1536) and
        serviceSize(500, 480) == (1024, 1024), "the service's size nearest in shape"
  check s.editsUrl == base & "/v1/images/edits", "the edits' address next to it"
  let a = generateImage(s, "a lighthouse", 1600, 1000)
  check a.error.len == 0 and a.picture != nil and a.picture.w == 1600 and a.picture.h == 1000 and
        (a.picture.px[0] and 0xFFFFFF'u32) == 0xDC1E1E'u32 and a.note == "a picture of a lighthouse",
        "made: at the size asked, the service's words kept"
  let st = parseJson(httpRequest("GET", base & "/state").body)
  check st["generations"]["size"].getStr == "1536x1024" and not st["generations"].hasKey("response_format"),
        "asked at its size"
  let img = Bitmap(w: 300, h: 200, px: newSeq[uint32](300 * 200))
  var mask = Bitmap(w: 300, h: 200, px: newSeq[uint32](300 * 200))
  for i in 0 ..< mask.px.len: mask.px[i] = 0xFF000000'u32
  let e = editImage(s, "a red umbrella", img, mask)
  let st2 = parseJson(httpRequest("GET", base & "/state").body)
  check e.error.len == 0 and e.picture.w == 300 and e.picture.h == 200 and
        (e.picture.px[100] and 0xFFFFFF'u32) == 0x1EC81E'u32, "changed through a mask, at its size"
  check st2["edits"]["pngs"].getInt == 2 and st2["edits"]["prompt"].getStr == "a red umbrella" and
        st2["edits"]["size"].getStr == "1536x1024", "the picture and the mask sent as PNGs in a form"
  check generateImage(AiImageSettings(), "x", 10, 10).error.len > 0, "no service: said"

mock.terminate()
if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_aichat: all passed"

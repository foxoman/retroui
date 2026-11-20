## A conversation with an AI service that can use the app: you write, the service answers,
## and where it needs to it calls the app's own tools -- each a Nim proc the app gives, with
## the arguments it takes -- sees what they did and goes on, until it has an answer. The
## service is yours (`retroui/aiconnect`: any OpenAI-compatible one -- OpenAI, a local Ollama
## or LM Studio -- Anthropic's, or this device's own model, `retroui/devicemodel`), nothing is
## sent before one is set, and a tool that changes something can ask you first.
##
## .. code-block:: nim
##   let chat = newAiChat(loadAiSettings("notes"), "You help with the notes of this app.")
##   chat.tools.add aiTool("add_note", "Adds a note.", [param("text", "string", "the note")],
##     proc (a: JsonNode): string =
##       notes.add a["text"].getStr
##       "added; " & $notes.len & " notes now",
##     confirm = true)
##   chat.send("put milk and bread on my list")
##   # each frame the chat goes on by itself: chat.messages, chat.busy, chat.waitingFor
##
## The request goes on a worker thread (`retroui/jobs`); the tools run on the UI thread, at
## the start of a frame, and may touch any state of the app. A tool that has to wait (a
## click that shows its result some frames later) is given with `aiToolLater`: it says what
## it did through `done` when it can. A tool with `confirm` waits for `allow` or `deny`
## (`assistantPanel` in `retroui/assistant` shows the question); `trusted` lets them all run.
## Pictures go along with what you write (`send(text, png)`) to services that see them.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, base64]
import core, jobs, aiconnect, drive, devicemodel
export json, aiconnect

type
  AiParam* = object
    ## One argument of a tool.
    name*: string
    kind*: string                ## "string", "number", "integer", "boolean"
    description*: string
    choices*: seq[string]        ## (only these: an enum)
    optional*: bool

  AiTool* = object
    ## Something the service may do in the app.
    name*: string                ## (letters, digits, "_" and "-")
    description*: string         ## what it does, for the service: when to use it
    params*: JsonNode            ## its arguments: a JSON Schema object
    start*: proc (args: JsonNode; done: proc (text: string) {.closure.}) {.closure.}
      ## runs it on the UI thread; `done` -- now or in a later frame -- says what it did
    confirm*: bool               ## asks the user before it runs (it changes something)

  AiRole* = enum
    ## Who said a message.
    arUser = "user"
    arAssistant = "assistant"
    arTool = "tool"

  AiCallState* = enum
    ## Where a tool call is.
    acWaiting, acAsking, acRunning, acDone, acDenied

  AiCall* = object
    ## The service asks a tool to run.
    id*: string
    name*: string
    args*: JsonNode
    state*: AiCallState
    result*: string              ## what the tool said it did
    allowed*: bool               ## (the user said yes to it)

  AiMessage* = object
    ## One message of the conversation.
    role*: AiRole
    text*: string
    png*: string                 ## (a picture with it: PNG bytes)
    calls*: seq[AiCall]          ## (the service's: the tools it asked to run)
    callId*: string              ## (a tool's: the call it answers)
    toolName*: string

  AiChatState* = enum
    ## What a chat is doing.
    ciIdle,                      ## waiting for you
    ciAsking,                    ## its request is out
    ciTools,                     ## the service's tools running
    ciConfirm                    ## a tool waits for `allow` or `deny`

  AiChat* = ref object
    ## A conversation with a service, and the tools it may use.
    settings*: AiSettings
    system*: string              ## what the service is told first: who it helps, how
    tools*: seq[AiTool]
    messages*: seq[AiMessage]
    state*: AiChatState
    error*: string               ## why the last request failed ("" it did not)
    trusted*: bool               ## tools that `confirm` run without asking
    maxRounds*: int              ## (tool rounds a request at most: 8)
    keep*: int                   ## (messages sent along: the last 40)
    context*: proc (): string {.closure.}
      ## (what the app is showing, told with each request: the document, the selection)
    onAnswer*: proc () {.closure.}   ## (the service answered in words)
    draft*: string               ## (what is being written to it: `assistantPanel`'s box)
    attach*: proc (): string {.closure.}
      ## (a picture -- PNG bytes -- sent with each of the user's messages: what the app shows)
    req: Job[HttpResponse]
    rounds: int
    gone: bool

const toolResultMax = 6000

proc param*(name, kind, description: string; choices: openArray[string] = [];
            optional = false): AiParam =
  ## A tool's argument: `kind` "string", "number", "integer" or "boolean".
  AiParam(name: name, kind: kind, description: description, choices: @choices, optional: optional)

proc schemaOf*(params: openArray[AiParam]): JsonNode =
  ## The arguments as a JSON Schema object.
  var props = newJObject()
  var req = newJArray()
  for p in params:
    var o = %*{"type": p.kind, "description": p.description}
    if p.choices.len > 0: o["enum"] = %p.choices
    props[p.name] = o
    if not p.optional: req.add %p.name
  %*{"type": "object", "properties": props, "required": req}

proc aiToolLater*(name, description: string; params: openArray[AiParam];
                  start: proc (args: JsonNode; done: proc (text: string) {.closure.}) {.closure.};
                  confirm = false): AiTool =
  ## A tool whose work ends in a later frame: it says what it did through `done`.
  AiTool(name: name, description: description, params: schemaOf(params), start: start, confirm: confirm)

proc aiTool*(name, description: string; params: openArray[AiParam];
             run: proc (args: JsonNode): string {.closure.}; confirm = false): AiTool =
  ## A tool done at once: `run` returns what it did (or why it could not), in words.
  aiToolLater(name, description, params,
              proc (args: JsonNode; done: proc (text: string) {.closure.}) = done(run(args)), confirm)

proc find*(c: AiChat; tool: string): int =
  ## The index of a tool by its name (-1: none).
  for i, t in c.tools:
    if t.name == tool: return i
  -1

# ---- the request and the answer, for each kind of service -----------------------------------------------------

proc dataUrl(png: string): string = "data:image/png;base64," & base64.encode(png)

proc chatRequest*(s: AiSettings; system: string; tools: openArray[AiTool]; messages: openArray[AiMessage]):
    tuple[url: string; headers: seq[(string, string)]; body: string] =
  ## The request that sends the conversation, the tools with it.
  result.url = if s.url.strip.len > 0: s.url.strip else: defaultUrl(s.kind)
  result.headers = @[("Content-Type", "application/json")]
  case s.kind
  of akOpenAi, akDevice:
    if s.key.len > 0 and s.kind == akOpenAi: result.headers.add ("Authorization", "Bearer " & s.key)
    var msgs = newJArray()
    if system.len > 0: msgs.add %*{"role": "system", "content": system}
    for m in messages:
      case m.role
      of arUser:
        if m.png.len > 0:
          msgs.add %*{"role": "user", "content": [{"type": "text", "text": m.text},
                                                  {"type": "image_url", "image_url": {"url": dataUrl(m.png)}}]}
        else: msgs.add %*{"role": "user", "content": m.text}
      of arAssistant:
        var o = %*{"role": "assistant", "content": m.text}
        if m.calls.len > 0:
          var cs = newJArray()
          for c in m.calls:
            cs.add %*{"id": c.id, "type": "function",
                      "function": {"name": c.name, "arguments": $(if c.args == nil: newJObject() else: c.args)}}
          o["tool_calls"] = cs
        msgs.add o
      of arTool:
        msgs.add %*{"role": "tool", "tool_call_id": m.callId, "content": m.text}
    var body = %*{"model": s.model, "messages": msgs}
    if tools.len > 0:
      var ts = newJArray()
      for t in tools:
        ts.add %*{"type": "function", "function": {"name": t.name, "description": t.description,
                                                    "parameters": t.params}}
      body["tools"] = ts
    result.body = $body
  of akAnthropic:
    result.headers.add ("anthropic-version", "2023-06-01")
    if s.key.len > 0: result.headers.add ("x-api-key", s.key)
    var msgs = newJArray()
    for m in messages:
      case m.role
      of arUser:
        if m.png.len > 0:
          msgs.add %*{"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                         "data": base64.encode(m.png)}},
            {"type": "text", "text": m.text}]}
        else: msgs.add %*{"role": "user", "content": m.text}
      of arAssistant:
        var parts = newJArray()
        if m.text.len > 0: parts.add %*{"type": "text", "text": m.text}
        for c in m.calls:
          parts.add %*{"type": "tool_use", "id": c.id, "name": c.name,
                       "input": (if c.args == nil: newJObject() else: c.args)}
        msgs.add %*{"role": "assistant", "content": parts}
      of arTool:
        # (the results of one round go together, in one message of the user's)
        let r = %*{"type": "tool_result", "tool_use_id": m.callId, "content": m.text}
        if msgs.len > 0 and msgs[^1]["role"].getStr == "user" and msgs[^1]["content"].kind == JArray and
           msgs[^1]["content"].len > 0 and msgs[^1]["content"][0]{"type"}.getStr == "tool_result":
          msgs[^1]["content"].add r
        else: msgs.add %*{"role": "user", "content": [r]}
    var body = %*{"model": s.model, "max_tokens": 4096, "messages": msgs}
    if system.len > 0: body["system"] = %system
    if tools.len > 0:
      var ts = newJArray()
      for t in tools: ts.add %*{"name": t.name, "description": t.description, "input_schema": t.params}
      body["tools"] = ts
    result.body = $body

proc chatReply*(kind: AiKind; body: string): tuple[msg: AiMessage; error: string] =
  ## The service's message in its answer: its words and the tools it asks to run.
  result.msg.role = arAssistant
  let j = try: parseJson(body) except CatchableError: nil
  if j == nil or j.kind != JObject:
    result.error = "the service's answer is not JSON"
    return
  if j.hasKey("error"):
    let e = j["error"]
    result.error = if e.kind == JObject: e{"message"}.getStr($e) else: $e
    return
  case kind
  of akOpenAi, akDevice:
    let ch = j{"choices"}.getElems
    if ch.len == 0:
      result.error = "the service said nothing"
      return
    let m = ch[0]{"message"}
    result.msg.text = m{"content"}.getStr
    for c in m{"tool_calls"}.getElems:
      let f = c{"function"}
      var args = newJObject()
      let a = f{"arguments"}
      if a != nil and a.kind == JString and a.getStr.strip.len > 0:
        try: args = parseJson(a.getStr)
        except CatchableError: args = %*{"_unread": a.getStr}
      elif a != nil and a.kind == JObject: args = a
      result.msg.calls.add AiCall(id: c{"id"}.getStr("call" & $result.msg.calls.len), name: f{"name"}.getStr,
                                  args: args)
  of akAnthropic:
    for p in j{"content"}.getElems:
      case p{"type"}.getStr
      of "text": result.msg.text.add p{"text"}.getStr
      of "tool_use":
        result.msg.calls.add AiCall(id: p{"id"}.getStr, name: p{"name"}.getStr,
                                    args: (if p{"input"} == nil: newJObject() else: p{"input"}))
      else: discard
  if result.msg.text.len == 0 and result.msg.calls.len == 0: result.error = "the service said nothing"

# ---- the conversation, going on by itself a frame at a time ---------------------------------------------------

var liveChats: seq[AiChat]

proc stepChats() {.nimcall.}

proc newAiChat*(s: AiSettings; system = ""; tools: openArray[AiTool] = []): AiChat =
  ## A conversation with the service `s` (none connected: `send` says so).
  result = AiChat(settings: s, system: system, tools: @tools, maxRounds: 8, keep: 40)
  if liveChats.len == 0 and stepChats notin beginFrameHooks: beginFrameHooks.add stepChats
  liveChats.add result

proc close*(c: AiChat) =
  ## Ends the conversation: its request stopped, the chat let go of each frame.
  if c == nil: return
  if c.req != nil: c.req.cancel()
  c.req = nil
  c.gone = true
  c.state = ciIdle
  let i = liveChats.find(c)
  if i >= 0: liveChats.delete(i)

proc busy*(c: AiChat): bool =
  ## It is asking the service or running its tools.
  c != nil and c.state != ciIdle

proc waitingFor*(c: AiChat): AiCall =
  ## The tool call that waits for the user (`state` ciConfirm), else an empty one.
  if c == nil or c.state != ciConfirm or c.messages.len == 0: return
  for k in c.messages[^1].calls:
    if k.state == acAsking: return k

proc ask(c: AiChat) =
  ## (the conversation to the service)
  c.error = ""
  var first = max(0, c.messages.len - max(2, c.keep))
  # (it starts at one of the user's: a tool's answer alone is no start)
  while first > 0 and first < c.messages.len and c.messages[first].role != arUser: dec first
  var msgs = c.messages[first .. ^1]
  var sys = c.system
  if c.context != nil:
    let ctx = c.context()
    if ctx.len > 0:
      if c.settings.kind == akDevice:
        # (the device's own model keeps what it read of the conversation: what changes goes last,
        # with the newest of the user's, so the rest is not read again)
        var at = msgs.high
        while at >= 0 and msgs[at].role != arUser: dec at
        if at >= 0: msgs[at].text = "(What the app shows now: " & ctx & ")\n\n" & msgs[at].text
      else: sys.add (if sys.len > 0: "\n\n" else: "") & "What the app shows now: " & ctx
  let r = chatRequest(c.settings, sys, c.tools, msgs)
  c.req =
    if c.settings.kind == akDevice: deviceFetch(c.settings.url, r.body)
    else: fetch(r.url, "POST", r.headers, r.body,
                timeoutSec = (if c.settings.timeoutSec > 0: c.settings.timeoutSec else: 120))
  c.state = ciAsking

proc send*(c: AiChat; text: string; png = "") =
  ## Says `text` to the service (a picture with it: `png`), which answers in a later frame --
  ## running the tools it asks for in between.
  if c == nil or text.strip.len == 0 and png.len == 0: return
  if c.busy: return
  var pic = png
  if pic.len == 0 and c.attach != nil:
    try: pic = c.attach()
    except CatchableError: pic = ""
  c.messages.add AiMessage(role: arUser, text: text, png: pic)
  c.rounds = 0
  if not c.settings.connected:
    c.error = "no AI service is connected"
    return
  c.ask()
  ui.redraw = true

proc stop*(c: AiChat) =
  ## Stops what it is doing: the request, the tools not run yet (they are not run).
  if c == nil: return
  if c.req != nil: c.req.cancel()
  c.req = nil
  if c.messages.len > 0 and c.messages[^1].role == arAssistant:
    for k in c.messages[^1].calls.mitems:
      if k.state in {acWaiting, acAsking}:
        k.state = acDenied
        k.result = "stopped by the user"
  c.state = ciIdle

proc clear*(c: AiChat) =
  ## A new conversation: the messages forgotten.
  c.stop()
  c.messages.setLen(0)
  c.error = ""

proc doneOf(chat: AiChat; msgAt, callAt: int): proc (text: string) {.closure.} =
  ## (what a tool calls when it is done: its own, once)
  var said = false
  result = proc (text: string) =
    if said or chat.gone or msgAt >= chat.messages.len or callAt >= chat.messages[msgAt].calls.len: return
    said = true
    chat.messages[msgAt].calls[callAt].result =
      if text.len > toolResultMax: text[0 ..< toolResultMax] & "..." else: text
    chat.messages[msgAt].calls[callAt].state = acDone
    ui.redraw = true

proc runCalls(c: AiChat) =
  ## (the service's calls, in order: each started, one that asks first waits; all done -- their
  ## results to the service)
  if c.messages.len == 0: return
  let at = c.messages.high
  for i in 0 ..< c.messages[at].calls.len:
    let k = c.messages[at].calls[i]   # (read before the tool runs: what it changes is in `messages`)
    case k.state
    of acRunning, acAsking: return
    of acDone, acDenied: continue
    of acWaiting:
      let t = c.find(k.name)
      if t < 0:
        c.messages[at].calls[i].state = acDone
        c.messages[at].calls[i].result = "there is no tool named \"" & k.name & "\""
        continue
      if c.tools[t].confirm and not c.trusted and not k.allowed:
        c.messages[at].calls[i].state = acAsking
        c.state = ciConfirm
        ui.redraw = true
        return
      c.messages[at].calls[i].state = acRunning
      try: c.tools[t].start(if k.args == nil: newJObject() else: k.args, doneOf(c, at, i))
      except CatchableError as e:
        c.messages[at].calls[i].state = acDone
        c.messages[at].calls[i].result = "failed: " & e.msg
      if c.messages[at].calls[i].state == acRunning: return
  # (all done: their results, then the service again -- made first, added after: adding to
  # `messages` while its calls are walked would move them away from under the walk)
  var answers: seq[AiMessage]
  for k in c.messages[at].calls:
    answers.add AiMessage(role: arTool, text: (if k.result.len > 0: k.result else: "done"), callId: k.id,
                          toolName: k.name)
  c.messages.add answers
  inc c.rounds
  if c.rounds >= c.maxRounds:
    c.state = ciIdle
    c.error = "stopped after " & $c.rounds & " rounds of tools"
    return
  c.ask()

proc allow*(c: AiChat; always = false) =
  ## The tool waiting for the user runs (`always`: those after it too, this conversation).
  if c == nil or c.state != ciConfirm: return
  if always: c.trusted = true
  for k in c.messages[^1].calls.mitems:
    if k.state == acAsking:
      k.state = acWaiting
      k.allowed = true
      break
  c.state = ciTools
  c.runCalls()

proc deny*(c: AiChat) =
  ## The tool waiting for the user does not run: the service is told so.
  if c == nil or c.state != ciConfirm: return
  for k in c.messages[^1].calls.mitems:
    if k.state == acAsking:
      k.state = acDenied
      k.result = "the user said no: it was not done"
      break
  c.state = ciTools
  c.runCalls()

proc update*(c: AiChat) =
  ## Goes on with the conversation (each frame by itself: an app need not call it).
  if c == nil or c.gone: return
  case c.state
  of ciAsking:
    if c.req == nil or not c.req.ended: return
    let r = c.req
    c.req = nil
    if not r.done:
      c.state = ciIdle
      c.error = if r.failed: r.error else: "stopped"
      return
    let resp = r.value
    if resp.status == 0:
      c.state = ciIdle
      c.error = resp.error
      return
    let (m, err) = chatReply(c.settings.kind, resp.body)
    if err.len > 0:
      c.state = ciIdle
      c.error = (if resp.status >= 400: "HTTP " & $resp.status & ": " else: "") & err
      return
    c.messages.add m
    ui.redraw = true
    if m.calls.len == 0:
      c.state = ciIdle
      if c.onAnswer != nil: c.onAnswer()
      return
    c.state = ciTools
    c.runCalls()
  of ciTools: c.runCalls()
  of ciIdle, ciConfirm: discard

proc stepChats() {.nimcall.} =
  var i = 0
  while i < liveChats.len:
    let c = liveChats[i]
    c.update()
    if c.state == ciTools: wakeIn(30)    # (a tool that says so later: looked at again soon)
    inc i

proc partialAnswer*(c: AiChat): string =
  ## What the service has written so far of the answer it is writing ("" when it says it only
  ## once whole: a service online; the device's own model writes as it goes) -- its words, not
  ## its thinking or the tool calls it writes.
  if c == nil or c.state != ciAsking or c.settings.kind != akDevice: return ""
  result = devicePartial()
  let t = result.find("<tool_call>")
  if t >= 0: result.setLen(t)
  result = thoughtLess(result)

proc lastAnswer*(c: AiChat): string =
  ## The service's last words.
  if c == nil: return
  for i in countdown(c.messages.high, 0):
    if c.messages[i].role == arAssistant and c.messages[i].text.len > 0: return c.messages[i].text

# ---- one question, no conversation -----------------------------------------------------------------------

proc askOnce*(s: AiSettings; system, user: string; onDone: proc () {.closure.} = nil): Job[HttpResponse] =
  ## One question to the service `s`, with no tools and no conversation, on a worker: a text
  ## made shorter, a summary. Its words when it ends: `onceAnswer`.
  let r = chatRequest(s, system, [], [AiMessage(role: arUser, text: user)])
  if s.kind == akDevice: deviceFetch(s.url, r.body, onDone)
  else: fetch(r.url, "POST", r.headers, r.body,
              timeoutSec = (if s.timeoutSec > 0: s.timeoutSec else: 120), onDone = onDone)

proc onceAnswer*(s: AiSettings; j: Job[HttpResponse]): tuple[text, error: string] =
  ## The service's words for `askOnce`'s job (without a model's thinking), or why there are
  ## none ("", "" while it runs).
  if j == nil or not j.ended: return ("", "")
  if not j.done: return ("", if j.failed: j.error else: "stopped")
  let resp = j.value
  if resp.status == 0: return ("", resp.error)
  let (m, err) = chatReply(s.kind, resp.body)
  if err.len > 0: return ("", (if resp.status >= 400: "HTTP " & $resp.status & ": " else: "") & err)
  (thoughtLess(m.text), "")

# ---- tools any app has --------------------------------------------------------------------------------------

proc commandTool*(commands: seq[string]; run: proc (command: string) {.closure.};
                  name = "run_command"): AiTool =
  ## A tool that runs one of the app's menu commands by its name (`commands`: those the
  ## service may use) -- what the AI Connector's Ask did in one tool.
  let cmds = commands
  aiTool(name, "Runs one of the app's own menu commands, exactly as named in the list, on the current " &
         "document and selection.", [param("command", "string", "the command's name", cmds)],
    proc (a: JsonNode): string =
      let want = a{"command"}.getStr
      for c in cmds:
        if cmpIgnoreCase(c, want) == 0:
          run(c)
          return "ran " & c
      "not a command of this app: " & want,
    confirm = true)

# ---- the app's tools for agents outside it (the driver, `retrokit mcp`) -----------------------------------

var published: seq[AiTool]

proc publishTools*(tools: openArray[AiTool]) =
  ## Offers `tools` to AI agents outside the app as well: through the driver (an app started
  ## with RETRO_DRIVE; `retrokit mcp PORT` makes them an MCP server's tools), each run on the
  ## UI thread as the app's own assistant runs it. (`confirm` is the app's own assistant's: an
  ## agent's program asks its user before a tool runs, as MCP's do.)
  published = @tools
  appToolsJson = proc (): string =
    var a = newJArray()
    for t in published: a.add %*{"name": t.name, "description": t.description, "params": t.params}
    $a
  appToolCall = proc (name, args: string; done: proc (text: string) {.closure.}) =
    for t in published:
      if t.name == name:
        var j = newJObject()
        if args.strip.len > 0:
          try: j = parseJson(args)
          except CatchableError:
            done("the arguments are not JSON: " & args)
            return
        t.start(j, done)
        return
    done("there is no tool named \"" & name & "\"")

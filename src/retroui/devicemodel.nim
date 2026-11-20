## The device's own AI service: a model the app runs itself (`retroui/llm`; one of
## `retroui/modelstore`'s, or a GGUF file of your own), answering as an OpenAI-compatible
## service answers -- the conversation and its tools in, words and tool calls out -- so
## `retroui/aichat` and an app's assistant use it as they use any (`akDevice` in
## `retroui/aiconnect`: the model's file is its address). Nothing leaves the device.
##
## .. code-block:: nim
##   let chat = newAiChat(AiSettings(kind: akDevice, url: modelPath(storeModel("qwen3-1.7b"))))
##   chat.send("make the title shorter")           # as with any service
##   # or one answer, on a worker:
##   let j = deviceAsk(path, "You summarize mail in two sentences.", text)
##
## A model is loaded once and kept (the next answer comes sooner: what it read of the same
## conversation is kept too); one answers at a time. Tools are offered as Qwen 3 was taught
## them -- `<tool_call>{"name": ..., "arguments": ...}</tool_call>` -- which smaller models
## follow less well: BitNet b1.58 answers in words more often than it uses a tool.
## `deviceEmbed` makes texts vectors with an embedding model (search by meaning).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, locks]
import llm, jobs, http, aiconnect
export llm

type DeviceSlot = object
  ## (a model kept loaded, and its conversation)
  path: string
  model: Llm
  state: LlmState

var
  slotLock: Lock
  partLock: Lock
  chatSlot, embedSlot: DeviceSlot
  partial: string                ## (the answer so far)
initLock(slotLock)
initLock(partLock)

proc load(s: var DeviceSlot; path: string) =
  ## (the model at `path` in `s`: kept when it is the one there)
  if s.model != nil and s.path == path: return
  if s.model != nil: s.model.close()
  s.model = nil
  s.state = nil
  s.path = ""
  s.model = loadLlm(path)
  s.state = newLlmState(s.model)
  s.path = path

proc devicePartial*(): string =
  ## What the model has written of the answer it is writing (for the assistant to show as it
  ## comes).
  withLock partLock:
    {.cast(gcsafe).}: result = partial

proc releaseDeviceModels*() =
  ## Lets go of the models kept loaded (their memory), when none is answering.
  withLock slotLock:
    {.cast(gcsafe).}:
      for s in [addr chatSlot, addr embedSlot]:
        if s.model != nil: s.model.close()
        s[] = DeviceSlot()

# ---- the conversation as the model reads it ---------------------------------------------------------------

proc toolsText*(tools: JsonNode): string =
  ## The tools, as Qwen 3 is told of them (and the others follow).
  if tools == nil or tools.kind != JArray or tools.len == 0: return
  result = "\n\n# Tools\n\nYou may call one or more functions to assist with the user query.\n\n" &
    "You are provided with function signatures within <tools></tools> XML tags:\n<tools>"
  for t in tools: result.add "\n" & $t
  result.add "\n</tools>\n\nFor each function call, return a json object with function name and arguments " &
    "within <tool_call></tool_call> XML tags:\n<tool_call>\n{\"name\": <function-name>, " &
    "\"arguments\": <args-json-object>}\n</tool_call>"

proc contentText(c: JsonNode): string =
  ## (a message's words: a string, or the text parts of a list -- a picture said as one)
  if c == nil: return ""
  case c.kind
  of JString: c.getStr
  of JArray:
    var parts: seq[string]
    for p in c:
      case p{"type"}.getStr
      of "text": parts.add p{"text"}.getStr
      of "image_url", "image": parts.add "[a picture, which this model cannot see]"
      else: discard
    parts.join("\n")
  else: ""

proc turnsOf*(req: JsonNode): seq[ChatTurn] =
  ## An OpenAI chat request's messages (and tools) as the turns of a conversation.
  let tools = toolsText(req{"tools"})
  var sawSystem = false
  for m in req{"messages"}.getElems:
    let role = m{"role"}.getStr
    case role
    of "system":
      result.add ("system", contentText(m{"content"}) & tools)
      sawSystem = true
    of "user": result.add ("user", contentText(m{"content"}))
    of "assistant":
      var t = contentText(m{"content"})
      for c in m{"tool_calls"}.getElems:
        let f = c{"function"}
        var args = f{"arguments"}
        if args != nil and args.kind == JString:
          args = try: parseJson(args.getStr) except CatchableError: newJObject()
        t.add "\n<tool_call>\n" & $(%*{"name": f{"name"}.getStr, "arguments": (if args == nil: newJObject() else: args)}) &
              "\n</tool_call>"
      result.add ("assistant", t.strip)
    of "tool":
      # (a tool's answer, as Qwen 3 reads it: from the user; one round's together)
      let r = "<tool_response>\n" & contentText(m{"content"}) & "\n</tool_response>"
      if result.len > 0 and result[^1].role == "user" and result[^1].text.startsWith("<tool_response>"):
        result[^1].text.add "\n" & r
      else: result.add ("user", r)
    else: discard
  if not sawSystem and tools.len > 0: result.insert(("system", "You are a helpful assistant." & tools), 0)

proc callsOf*(text: string): tuple[words: string; calls: seq[JsonNode]] =
  ## The model's answer: its words, and the tools it asks for (`{"name", "arguments"}` each) --
  ## in <tool_call> tags, or a JSON object of a call alone.
  var rest = thoughtLess(text)
  while true:
    let a = rest.find("<tool_call>")
    if a < 0: break
    let b = rest.find("</tool_call>", a)
    let inner = if b < 0: rest[a + 11 .. ^1] else: rest[a + 11 ..< b]
    try:
      let j = parseJson(inner.strip)
      if j.kind == JObject and j{"name"}.getStr.len > 0: result.calls.add j
    except CatchableError: discard
    rest = if b < 0: rest[0 ..< a] else: rest[0 ..< a] & rest[b + 12 .. ^1]
  if result.calls.len == 0:
    # (a call written without its tags: a JSON object with a name and arguments, alone)
    let t = rest.strip(chars = Whitespace + {'`'})
    let inner = if t.startsWith("json"): t[4 .. ^1].strip else: t
    if inner.startsWith("{") and inner.endsWith("}"):
      try:
        let j = parseJson(inner)
        if j.kind == JObject and j{"name"}.getStr.len > 0 and j.hasKey("arguments"):
          result.calls.add j
          rest = ""
      except CatchableError: discard
  result.words = rest.strip

proc answerJson*(words: string; calls: openArray[JsonNode]): string =
  ## The answer as an OpenAI-compatible service writes it.
  var msg = %*{"role": "assistant", "content": words}
  if calls.len > 0:
    var cs = newJArray()
    for i, c in calls:
      let a = c{"arguments"}
      cs.add %*{"id": "call" & $i, "type": "function",
                "function": {"name": c{"name"}.getStr, "arguments": $(if a == nil: newJObject() else: a)}}
    msg["tool_calls"] = cs
  $(%*{"object": "chat.completion", "choices": [{"index": 0, "message": msg,
                                                   "finish_reason": (if calls.len > 0: "tool_calls" else: "stop")}]})

# ---- answering ----------------------------------------------------------------------------------------------

proc deviceAnswer*(path, body: string; stop: proc (): bool {.closure, gcsafe.} = nil): HttpResponse {.gcsafe.} =
  ## The model at `path` answers the OpenAI chat request `body`, here (waits: on a worker).
  ## Status 200 and its answer, or 0 and `error`.
  let req = try: parseJson(body) except CatchableError: nil
  if req == nil or req.kind != JObject: return HttpResponse(error: "the request is not JSON")
  let maxTokens = clamp(req{"max_tokens"}.getInt(req{"max_completion_tokens"}.getInt(768)), 16, 4096)
  let temp = req{"temperature"}.getFloat(0.7)
  withLock partLock:
    {.cast(gcsafe).}: partial = ""
  withLock slotLock:
    {.cast(gcsafe).}:
      try:
        chatSlot.load(path)
        let m = chatSlot.model
        let turns = turnsOf(req)
        if turns.len == 0: return HttpResponse(error: "nothing was asked")
        let how = sampling(temperature = temp, topK = 20, topP = 0.8, repeatPenalty = 1.1)
        let said = m.chat(chatSlot.state, turns, maxTokens, how,
          proc (t: string): bool =
            withLock partLock: partial.add t
            stop == nil or not stop())
        if stop != nil and stop(): return HttpResponse(error: "stopped")
        let (words, calls) = callsOf(said)
        result = HttpResponse(status: 200, body: answerJson(words, calls))
      except CatchableError as e:
        result = HttpResponse(error: "the model on this device: " & e.msg)
  withLock partLock:
    {.cast(gcsafe).}: partial = ""

proc deviceFetch*(path, body: string; onDone: proc () {.closure.} = nil): Job[HttpResponse] =
  ## `deviceAnswer` as a job (`cancel` stops the model within a token): what `aichat` asks the
  ## device with, as `fetch` asks a service.
  job(proc (c: JobCtl): HttpResponse {.gcsafe.} =
    deviceAnswer(path, body, proc (): bool = c.cancelled), onDone)

proc deviceAsk*(path, system, user: string; maxTokens = 512; temperature = 0.3;
                onDone: proc () {.closure.} = nil): Job[string] =
  ## One answer of the model at `path` to `user` (`system` first), on a worker: a summary, a
  ## text made shorter. The job's value is the answer's words.
  let body = $(%*{"max_tokens": maxTokens, "temperature": temperature,
                  "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]})
  job(proc (c: JobCtl): string {.gcsafe.} =
    let r = deviceAnswer(path, body, proc (): bool = c.cancelled)
    if r.status != 200: raise newException(IOError, r.error)
    let j = parseJson(r.body)
    j["choices"][0]["message"]{"content"}.getStr, onDone)

proc deviceEmbed*(path: string; texts: openArray[string]; stop: proc (): bool {.closure, gcsafe.} = nil):
    seq[seq[float32]] {.gcsafe.} =
  ## Each text as a vector of the embedding model at `path` (`similarity` says how near two
  ## are). Waits: on a worker. Raises `LlmError` (or `GgufError`) when the model cannot be
  ## loaded.
  withLock slotLock:
    {.cast(gcsafe).}:
      embedSlot.load(path)
      for t in texts:
        if stop != nil and stop(): break
        result.add embedSlot.model.embed(embedSlot.state, t)

deviceAnswerHook = proc (path, body: string): HttpResponse {.gcsafe.} = deviceAnswer(path, body)

proc queryText*(task, query: string): string =
  ## A query as Qwen 3 Embedding wants one: what is looked for, then the words
  ## ("Instruct: Find the mail that answers the question\nQuery: invoice from Ahmed").
  "Instruct: " & task & "\nQuery: " & query

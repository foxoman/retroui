## An AI service of your own, connected if you want one: you say what you want done in words,
## it answers with the app's own commands (from the list the app gives it), and the app runs
## those -- after showing you them. Off until you connect one; nothing is sent anywhere
## before. Any service that speaks OpenAI's chat completions (OpenAI, a local Ollama or LM
## Studio, many more) or Anthropic's Messages: its address, its model, your key.
##
## .. code-block:: nim
##   let s = AiSettings(kind: akOpenAi, url: "http://localhost:11434/v1/chat/completions",
##                      model: "llama3.1")
##   let a = askAi(s, "make it black and white and add a border", commands)
##   if a.error.len == 0:
##     for c in a.commands: runCommand(c)
##
## `saveAiSettings`/`loadAiSettings` keep the service for an app: the kind, address and model
## in its settings, the key in `retroui/secrets` (the system's keyring) -- never in a file
## anyone can read.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils]
import http, platform, secrets

type
  AiKind* = enum
    ## How the service is spoken to.
    akOpenAi = "OpenAI-compatible (chat completions)",
    akAnthropic = "Anthropic (Messages)"

  AiSettings* = object
    ## A connected AI service (empty `url`: none).
    kind*: AiKind
    url*: string                 ## its address ("" none: the connector off)
    model*: string               ## the model asked
    key*: string                 ## your key for it ("" a service on your own computer)
    timeoutSec*: int             ## (0: 90)

  AiAnswer* = object
    ## What came back.
    commands*: seq[string]       ## the app's commands to run, in order (only known ones)
    note*: string                ## what the service said of them
    unknown*: seq[string]        ## what it asked that the app has not
    error*: string               ## why there is no answer ("" there is)

proc connected*(s: AiSettings): bool = s.url.strip.len > 0 and s.model.strip.len > 0
  ## A service is connected.

proc defaultUrl*(k: AiKind): string =
  ## The usual address of a kind of service.
  case k
  of akOpenAi: "https://api.openai.com/v1/chat/completions"
  of akAnthropic: "https://api.anthropic.com/v1/messages"

const Instructions = "You drive an image and layout editor by naming its menu commands. " &
  "Answer ONLY with JSON: {\"commands\": [\"...\"], \"note\": \"one short sentence\"}. " &
  "Each command must be copied exactly from the list of commands below; use none that is not " &
  "there. Commands run in order on the current document and selection. If nothing in the " &
  "list does what is asked, answer {\"commands\": [], \"note\": \"why\"}."

proc systemText*(commands: openArray[string]; context = ""): string =
  ## What the service is told before the request: how to answer, the commands it may use, what
  ## the document is.
  result = Instructions & "\n\nCommands:\n"
  for c in commands: result.add c & "\n"
  if context.len > 0: result.add "\nThe document now: " & context & "\n"

proc requestOf*(s: AiSettings; prompt: string; commands: openArray[string]; context = ""):
    tuple[url: string; headers: seq[(string, string)]; body: string] =
  ## The request for the service: its address, headers, body.
  let sys = systemText(commands, context)
  result.url = if s.url.strip.len > 0: s.url.strip else: defaultUrl(s.kind)
  result.headers = @[("Content-Type", "application/json")]
  case s.kind
  of akOpenAi:
    if s.key.len > 0: result.headers.add ("Authorization", "Bearer " & s.key)
    result.body = $(%*{"model": s.model, "temperature": 0,
                       "messages": [{"role": "system", "content": sys}, {"role": "user", "content": prompt}]})
  of akAnthropic:
    result.headers.add ("anthropic-version", "2023-06-01")
    if s.key.len > 0: result.headers.add ("x-api-key", s.key)
    result.body = $(%*{"model": s.model, "max_tokens": 1024, "system": sys,
                       "messages": [{"role": "user", "content": prompt}]})

proc replyText*(kind: AiKind; body: string): tuple[text, error: string] =
  ## The words of a service's answer (its JSON), or why there are none.
  let j = try: parseJson(body) except CatchableError: nil
  if j == nil or j.kind != JObject: return ("", "the service's answer is not JSON")
  if j.hasKey("error"):
    let e = j["error"]
    return ("", if e.kind == JObject: e{"message"}.getStr($e) else: $e)
  case kind
  of akOpenAi:
    for c in j{"choices"}.getElems:
      let t = c{"message"}{"content"}.getStr
      if t.len > 0: return (t, "")
  of akAnthropic:
    var t = ""
    for c in j{"content"}.getElems:
      if c{"type"}.getStr == "text": t.add c{"text"}.getStr
    if t.len > 0: return (t, "")
  ("", "the service said nothing")

proc commandsOf*(text: string; commands: openArray[string]): AiAnswer =
  ## The commands in a service's words (its JSON, or one a line), only those the app has --
  ## matched as they are written, case aside.
  var names: seq[string]
  let a = text.find('{')
  let b = text.rfind('}')
  var parsed = false
  if a >= 0 and b > a:
    try:
      let j = parseJson(text[a .. b])
      for c in j{"commands"}.getElems: names.add c.getStr
      result.note = j{"note"}.getStr
      parsed = true
    except CatchableError: discard
  if not parsed:
    for line in text.splitLines:
      let l = line.strip(chars = {' ', '-', '*', '"', '`', '\t'})
      if l.len > 0: names.add l
  for n in names:
    var found = ""
    for c in commands:
      if cmpIgnoreCase(c, n.strip) == 0:
        found = c
        break
    if found.len > 0: result.commands.add found
    elif n.strip.len > 0: result.unknown.add n.strip
  if result.commands.len > 64: result.commands.setLen(64)

proc askAi*(s: AiSettings; prompt: string; commands: openArray[string]; context = ""): AiAnswer =
  ## Asks the connected service for the commands that do `prompt` (waits for its answer).
  if not s.connected: return AiAnswer(error: "no AI service is connected (Preferences > AI Connector)")
  let r = s.requestOf(prompt, commands, context)
  let resp = httpRequest("POST", r.url, r.headers, r.body, timeoutSec = (if s.timeoutSec > 0: s.timeoutSec else: 90))
  if resp.status == 0: return AiAnswer(error: resp.error)
  let (text, err) = replyText(s.kind, resp.body)
  if err.len > 0: return AiAnswer(error: (if resp.status >= 400: "HTTP " & $resp.status & ": " else: "") & err)
  commandsOf(text, commands)

proc toJson*(s: AiSettings): JsonNode =
  ## The service as JSON -- without its key, which `saveAiSettings` keeps in the keyring.
  %*{"kind": $s.kind, "url": s.url, "model": s.model, "timeout": s.timeoutSec}

proc aiSettingsFrom*(j: JsonNode): AiSettings =
  ## (a key in `j` -- an older version's -- is read too)
  if j == nil or j.kind != JObject: return
  for k in AiKind:
    if $k == j{"kind"}.getStr: result.kind = k
  result.url = j{"url"}.getStr
  result.model = j{"model"}.getStr
  result.key = j{"key"}.getStr
  result.timeoutSec = clamp(j{"timeout"}.getInt(0), 0, 600)

const AiKeyName* = "AI key"
  ## The name the service's key is kept under in `retroui/secrets`, the app's own.

proc saveAiSettings*(app: string; s: AiSettings): bool {.discardable.} =
  ## Keeps the service for `app`: its kind, address, model and wait in the app's settings
  ## (`saveSettings`), its key in `retroui/secrets` (an empty key: the one kept is forgotten).
  ## False when either could not be kept.
  var st = loadSettings(app)
  st["ai.kind"] = $s.kind
  st["ai.url"] = s.url
  st["ai.model"] = s.model
  if s.timeoutSec > 0: st["ai.timeout"] = $s.timeoutSec
  else: st.del "ai.timeout"
  st.del "ai.key"
  result = saveSettings(app, st)
  if s.key.len > 0: result = saveSecret(app, AiKeyName, s.key) and result
  else: deleteSecret(app, AiKeyName)

proc loadAiSettings*(app: string; withKey = true): AiSettings =
  ## The service `saveAiSettings` kept for `app` (none: an empty one, not connected). Its key
  ## is asked of the keyring only `withKey` -- a keychain may wait for its password: ask when
  ## the key is wanted, not as the window first shows. A key an older version wrote into the
  ## settings file is moved into the keyring then, and out of the file.
  var st = loadSettings(app)
  for k in AiKind:
    if $k == st.getOrDefault("ai.kind"): result.kind = k
  result.url = st.getOrDefault("ai.url")
  result.model = st.getOrDefault("ai.model")
  try: result.timeoutSec = clamp(parseInt(st.getOrDefault("ai.timeout", "0")), 0, 600)
  except ValueError: discard
  if st.hasKey("ai.key"):
    let old = st["ai.key"]
    if old.len == 0 or (withKey and saveSecret(app, AiKeyName, old)):
      st.del "ai.key"
      discard saveSettings(app, st)
    if old.len > 0:
      if withKey: result.key = old
      return
  if withKey: result.key = loadSecret(app, AiKeyName)

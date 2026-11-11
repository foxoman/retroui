## Retro Mail's assistant: a thread summed up, a message translated, short
## replies suggested -- by Claude, through the Anthropic Messages API, with
## the user's own API key. Only the plain text of the mail in question goes
## (the senders, the dates, the texts without what they quote, at most
## about 30,000 characters); nothing else of the mailbox.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils]
import retroui/http
import api

const
  defaultModel* = "claude-haiku-5-5"
  maxText* = 30_000          ## characters (bytes) of mail sent at most
  apiVersion = "2023-06-01"

proc aiBase*(): string =
  ## The Messages API's address (RETRO_MAIL_AI for tests).
  endpoint("ai", "https://api.anthropic.com")

proc clip*(s: string; n: int): string =
  ## The first `n` bytes of `s` at most, never cutting a UTF-8 character.
  if s.len <= n: return s
  var e = max(n, 0)
  while e > 0 and (ord(s[e]) and 0xC0) == 0x80: dec e
  s[0 ..< e]

proc clipEnd(s: string; n: int): string =
  ## The last `n` bytes of `s` at most, on a character's start.
  if s.len <= n: return s
  var b = s.len - n
  while b < s.len and (ord(s[b]) and 0xC0) == 0x80: inc b
  s[b .. ^1]

proc withoutQuotes*(text: string): string =
  ## A message's own text: without quoted lines (">") nor what follows the
  ## line that starts a quoted message ("On ... wrote:", "-----Original
  ## Message-----", Outlook's "From: / Sent:" block) once the writer's own
  ## text came; blank lines run together.
  let lines = text.replace("\r\n", "\n").replace('\r', '\n').split('\n')
  var kept: seq[string]
  var own = false
  var blank = false
  for k, raw in lines:
    let l = raw.strip(leading = false)
    let s = l.strip.toLowerAscii
    if s.startsWith(">"): continue
    if own:
      if s.startsWith("-----original message") or s.startsWith("----- original message") or
         (s.startsWith("on ") and s.endsWith("wrote:")) or s.endsWith("كتب:") or
         s.startsWith("________________________________"):
        break
      if s.startsWith("from:"):
        var j = k + 1
        while j < lines.len and lines[j].strip.len == 0: inc j
        if j < lines.len:
          let n = lines[j].strip.toLowerAscii
          if n.startsWith("sent:") or n.startsWith("date:"): break
    if s.len == 0:
      if blank or kept.len == 0: continue
      blank = true
    else:
      blank = false
      own = true
    kept.add l
  kept.join("\n").strip

proc threadForAi*(thread: seq[tuple[sender, date, text: string]]; budget = maxText): string =
  ## The thread as it goes to the assistant: oldest first, each message's
  ## sender, date and own text. Longer than `budget`: the newest messages
  ## are kept (one cut short if need be) and a line says how many earlier
  ## ones were left out.
  var parts: seq[string]
  for m in thread:
    parts.add "From: " & m.sender.strip & "\nDate: " & m.date.strip & "\n\n" &
              clip(withoutQuotes(m.text), budget * 2 div 5)
  const sep = "\n\n---\n\n"
  var kept: seq[string]
  var used = 0
  var i = parts.high
  while i >= 0:
    let need = parts[i].len + sep.len
    if used + need > budget - 60:
      let room = budget - 60 - used - sep.len - 6
      if room > 300:
        kept.add clip(parts[i], room) & "\n[...]"
        used += room + 6 + sep.len
        dec i
      break
    kept.add parts[i]
    used += need
    dec i
  var outp: seq[string]
  if i >= 0: outp.add "(" & $(i + 1) & " earlier message" & (if i > 0: "s" else: "") & " left out)"
  for k in countdown(kept.high, 0): outp.add kept[k]
  outp.join(sep)

proc ask(key, model, system, user: string; maxTokens: int): string =
  ## One question to the Messages API; the text of its answer.
  result = ""         # (a value at once: see tools/writecheck.py)
  if key.strip.len == 0:
    var e = newException(ApiError, "the assistant: no API key is set")
    e.status = 401
    raise e
  let body = %*{"model": (if model.strip.len > 0: model.strip else: defaultModel),
                "max_tokens": maxTokens, "system": system,
                "messages": [{"role": "user", "content": user}]}
  let r = httpRequest("POST", aiBase() & "/v1/messages",
                      [("x-api-key", key.strip), ("anthropic-version", apiVersion),
                       ("content-type", "application/json"), ("accept", "application/json")],
                      $body, timeoutSec = 120)
  if not r.ok: fail(r, "the assistant")
  var j: JsonNode
  try: j = parseJson(r.body)
  except CatchableError: raise newException(ApiError, "the assistant: an answer that is not JSON")
  for c in j{"content"}.getElems:
    if c{"type"}.getStr == "text": result.add c{"text"}.getStr
  result = result.strip
  if result.len == 0: raise newException(ApiError, "the assistant: no answer came")

proc forWhom(me: string): string =
  if me.strip.len > 0: " (" & me.strip & ")" else: ""

proc summarize*(key, model: string; thread: seq[tuple[sender, date, text: string]];
                language = ""; me = ""): string =
  ## A few short bullet points on the thread (oldest message first), then
  ## what is asked of the reader (`me`: their name or address). In
  ## `language`, else the thread's own. Raises ApiError (the API's message:
  ## a key refused, too many requests -- `retryAfter` -- ...).
  let lang = if language.strip.len > 0: language.strip else: "the language most of the thread is written in"
  let system = "You sum up e-mail threads for the person reading them" & forWhom(me) & ". Write in " &
    lang & ", in plain text (no headings, no bold). First 2 to 5 short bullet points, each starting " &
    "with \"- \": what the thread is about, what was decided, what is still open. Then a line " &
    "\"What is asked of you:\" (in the same language) and one or two short bullet points saying " &
    "what the others ask of the reader, or \"- Nothing.\""
  ask(key, model, system, "<thread>\n" & threadForAi(thread) & "\n</thread>", 700)

proc translate*(key, model, text, toLanguage: string): string =
  ## `text` (plain, at most `maxText` bytes of it) in `toLanguage`.
  if text.strip.len == 0: return ""
  let system = "Translate the text the user gives into " & toLanguage.strip & ". Keep its meaning " &
    "and tone, names, numbers, addresses, links and line breaks. Answer with the translation only, " &
    "nothing before or after it."
  ask(key, model, system, clip(text.strip, maxText), 8192)

proc suggestReplies*(key, model, threadText: string; me = ""): seq[string] =
  ## Three short replies to the thread's last message, ready to send.
  ## (`threadText`: the thread as text, the last message last; its end is
  ## kept when it is long.)
  let system = "You suggest replies to the last message of an e-mail thread, to be sent by its " &
    "reader" & forWhom(me) & ". Give three different short replies (one or two sentences each, " &
    "ready to send as they are, in the language of the last message): one that agrees or says " &
    "yes, one that asks about what is still unclear, one that declines or puts it off. Answer " &
    "with a JSON array of the three strings and nothing else."
  let a = ask(key, model, system, "<thread>\n" & clipEnd(threadText.strip, maxText) & "\n</thread>", 600)
  let s = a.find('[')
  let e = a.rfind(']')
  if s >= 0 and e > s:
    try:
      for x in parseJson(a[s .. e]).getElems:
        if x.kind == JString and x.getStr.strip.len > 0: result.add x.getStr.strip
    except CatchableError: discard
  if result.len == 0:
    for l in a.splitLines:
      var t = l.strip
      while t.len > 0 and t[0] in {'-', '*', '0'..'9', '.', ')', ' '}: t = t[1 .. ^1]
      t = t.strip(chars = {'"', ' '})
      if t.len > 0: result.add t
  if result.len > 3: result.setLen(3)

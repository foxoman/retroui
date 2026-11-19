## Tests of the AI connector (retroui/aiconnect): the request each kind of service takes, the
## commands read from its answer -- only the app's own --, a service served here, the key kept
## in the keyring and not in the settings file.

import std/[json, strutils, net, os]
import retroui/[aiconnect, platform, secrets]

let cmds = @["Black & White...", "Gaussian Blur...", "Stroke...", "Flatten Image", "Invert"]

block requests:
  let o = AiSettings(kind: akOpenAi, url: "http://localhost:1/v1/chat/completions", model: "m1", key: "k")
  let r = o.requestOf("make it grey", cmds, "a photo 800 x 600, 2 layers")
  let j = parseJson(r.body)
  doAssert j["model"].getStr == "m1" and j["messages"].len == 2
  doAssert "Gaussian Blur..." in j["messages"][0]["content"].getStr
  doAssert "2 layers" in j["messages"][0]["content"].getStr
  doAssert ("Authorization", "Bearer k") in r.headers
  let a = AiSettings(kind: akAnthropic, url: "", model: "claude-x", key: "s")
  let r2 = a.requestOf("invert it", cmds)
  doAssert r2.url == "https://api.anthropic.com/v1/messages"
  doAssert ("x-api-key", "s") in r2.headers and ("anthropic-version", "2023-06-01") in r2.headers
  doAssert parseJson(r2.body)["system"].getStr.startsWith("You drive")
  doAssert not AiSettings().connected and o.connected
  var noKey = o
  noKey.key = ""
  doAssert aiSettingsFrom(o.toJson) == noKey and not o.toJson.hasKey("key")
  doAssert aiSettingsFrom(%*{"url": "u", "model": "m", "key": "old"}).key == "old"   # (an older file's)

block keptInTheKeyring:
  # (in folders of the test's own: the settings and the secrets)
  let root = getTempDir() / "retro-aiconnect-test"
  removeDir(root)
  putEnv("XDG_DATA_HOME", root / "data")
  putEnv("RETRO_SECRETS_DIR", root / "secrets")
  const app = "Retro AI Test"
  let file = dataDir(app) / "settings.ini"
  doAssert not loadAiSettings(app).connected and loadAiSettings(app).key == ""
  # an older version's settings, the key in them in plain text:
  var st = loadSettings(app)
  st["ai.kind"] = $akAnthropic
  st["ai.url"] = "https://api.anthropic.com/v1/messages"
  st["ai.model"] = "claude-x"
  st["ai.key"] = "sk-old-key"
  st["theme"] = "kept"
  doAssert saveSettings(app, st)
  let noAsk = loadAiSettings(app, withKey = false)
  doAssert noAsk.connected and noAsk.kind == akAnthropic and noAsk.key == ""
  doAssert "sk-old-key" in readFile(file)                 # (not moved before the key is wanted)
  let moved = loadAiSettings(app)
  doAssert moved.key == "sk-old-key" and moved.model == "claude-x"
  doAssert "sk-old-key" notin readFile(file) and not loadSettings(app).hasKey("ai.key")
  doAssert loadSecret(app, AiKeyName) == "sk-old-key"
  doAssert loadSettings(app)["theme"] == "kept"           # (the app's other settings stay)
  doAssert loadAiSettings(app) == moved
  # kept again, a new key:
  var s = moved
  s.key = "sk-new-key"
  s.timeoutSec = 30
  doAssert saveAiSettings(app, s)
  doAssert "sk-new-key" notin readFile(file) and loadSecret(app, AiKeyName) == "sk-new-key"
  doAssert loadAiSettings(app) == s
  # disconnected: nothing kept
  doAssert saveAiSettings(app, AiSettings())
  doAssert loadSecret(app, AiKeyName) == "" and not loadAiSettings(app).connected
  # an empty key an older version wrote is taken out of the file, the keyring not asked
  st = loadSettings(app)
  st["ai.key"] = ""
  doAssert saveSettings(app, st)
  discard loadAiSettings(app, withKey = false)
  doAssert not loadSettings(app).hasKey("ai.key")
  removeDir(root)

block answers:
  let t = replyText(akOpenAi, $(%*{"choices": [{"message": {"content": "{\"commands\": [\"black & white...\", " &
                                   "\"Delete Everything\", \"Invert\"], \"note\": \"Grey, then inverted.\"}"}}]}))
  doAssert t.error == ""
  let ans = commandsOf(t.text, cmds)
  doAssert ans.commands == @["Black & White...", "Invert"] and ans.unknown == @["Delete Everything"]
  doAssert ans.note == "Grey, then inverted."
  let t2 = replyText(akAnthropic, $(%*{"content": [{"type": "text", "text": "Sure:\n```json\n{\"commands\": " &
                                      "[\"Flatten Image\"]}\n```"}]}))
  doAssert commandsOf(t2.text, cmds).commands == @["Flatten Image"]
  doAssert commandsOf("- Invert\n- Stroke...", cmds).commands == @["Invert", "Stroke..."]
  doAssert replyText(akOpenAi, "{\"error\": {\"message\": \"bad key\"}}").error == "bad key"
  doAssert replyText(akOpenAi, "not json").error.len > 0

block served:
  # (a service on this computer, as a local model would be: the whole way round)
  var srv = newSocket()
  srv.setSockOpt(OptReuseAddr, true)
  srv.bindAddr(Port(0), "127.0.0.1")
  srv.listen()
  let port = srv.getLocalAddr()[1]
  proc serve(s: Socket) {.thread.} =
    var c: Socket
    s.accept(c)
    var req = ""
    while "\r\n\r\n" notin req: req.add c.recv(1)
    var n = 0
    for line in req.splitLines:
      if line.toLowerAscii.startsWith("content-length:"): n = parseInt(line.split(':')[1].strip)
    discard c.recv(n)
    let body = $(%*{"choices": [{"message": {"content": "{\"commands\": [\"Invert\"]}"}}]})
    c.send("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " & $body.len &
           "\r\nConnection: close\r\n\r\n" & body)
    c.close()
  var th: Thread[Socket]
  createThread(th, serve, srv)
  let s = AiSettings(kind: akOpenAi, url: "http://127.0.0.1:" & $port & "/v1/chat/completions", model: "local")
  let ans = askAi(s, "invert it", cmds)
  joinThread(th)
  srv.close()
  doAssert ans.error == "" and ans.commands == @["Invert"], $ans
  doAssert askAi(AiSettings(), "x", cmds).error.len > 0

echo "ai connector ok"

## Tests of the AI connector (retroui/aiconnect): the request each kind of service takes, the
## commands read from its answer -- only the app's own --, a service served here.

import std/[json, strutils, net]
import retroui/aiconnect

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
  doAssert aiSettingsFrom(o.toJson) == o

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

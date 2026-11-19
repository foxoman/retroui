## An app worked by AI agents: the driver's picture of the window (`shot`), the app's own tools
## offered and run through it (`publishTools`, `tools`, `tool`), a command run from inside the
## app (`driveAsk`) and the assistant's tools that work the app's controls (`uiTools`), and the
## MCP server (`retrokit mcp`) -- initialize, the tools listed, a control clicked, the
## controls read, a picture, the app's own tool run -- here the test is the app and the agent
## at once, its frames run while it waits.

import std/[json, strutils, base64]
import retroui
import retroui/[driveclient, aichat, assistant, mcpserver, imaging]
import harness

fakeDriver()
startApp("Agents", W, H)

var count = 0
var said = ""
view = proc () =
  row:
    if button("&Count"): inc count
    label "Count: " & $count
  row([60, -1]):
    label "&Note:"
    edit said

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

publishTools([aiTool("add", "Adds a number to the count.", [param("n", "integer", "how many")],
                     proc (a: JsonNode): string =
                       count += a{"n"}.getInt
                       "the count is " & $count)])

run(2)
let port = startDriver(0)
run(2)
let app = driveConnect(port)
proc askJson(j: JsonNode): JsonNode = app.ask(j, timeoutMs = 10000, idle = proc () = run())

echo "the driver: a picture, the app's tools"
block driver:
  let s = askJson(%*{"cmd": "shot"})
  let pic = decodePng(base64.decode(s{"png"}.getStr))
  check s{"ok"}.getBool and s{"w"}.getInt == W and pic != nil and pic.w == W and pic.h == H,
        "shot: the window's picture as a PNG"
  let small = askJson(%*{"cmd": "shot", "max": 320})
  check small{"w"}.getInt == 320 and small{"h"}.getInt == 240, "shot with max: scaled down"
  let ts = askJson(%*{"cmd": "tools"})
  check ts{"tools"}.len == 1 and ts{"tools"}[0]{"name"}.getStr == "add" and
        ts{"tools"}[0]{"params"}{"properties"}{"n"}{"type"}.getStr == "integer", "tools: the app's own"
  let t = askJson(%*{"cmd": "tool", "name": "add", "args": "{\"n\": 5}"})
  check t{"ok"}.getBool and t{"text"}.getStr == "the count is 5" and count == 5, "tool: run, what it did"
  check askJson(%*{"cmd": "tool", "name": "nope"}){"text"}.getStr.startsWith("there is no tool"),
        "a tool that is not there: said"

echo "inside the app: driveAsk and the assistant's tools"
block inside:
  var got = ""
  driveAsk("""{"cmd":"click","name":"Count"}""", proc (r: string) = got = r)
  for i in 0 ..< 20:
    run()
    if got.len > 0: break
  check count == 6 and parseJson(got){"ok"}.getBool, "a click asked from inside, answered once done"
  let tools = uiTools()
  var text = ""
  tools[0].start(newJObject(), proc (t: string) = text = t)
  for i in 0 ..< 20:
    run()
    if text.len > 0: break
  check "button \"Count\"" in text and "\"Count: 6\"" in text and "textField \"Note:\"" in text,
        "ui_controls: the window as lines\n" & text
  text = ""
  tools[1].start(%*{"name": "Count"}, proc (t: string) = text = t)
  for i in 0 ..< 20:
    run()
    if text.len > 0: break
  check text == "clicked \"Count\"" and count == 7, "ui_click"
  text = ""
  tools[1].start(%*{"name": "Note"}, proc (t: string) = text = t)
  for i in 0 ..< 20:
    run()
    if text.len > 0: break
  text = ""
  tools[2].start(%*{"text": "hello"}, proc (t: string) = text = t)
  for i in 0 ..< 20:
    run()
    if text.len > 0: break
  check text == "typed it" and said == "hello", "ui_type into the box clicked"
  text = ""
  tools[1].start(%*{"name": "Nothing here"}, proc (t: string) = text = t)
  for i in 0 ..< 20:
    run()
    if text.len > 0: break
  check text.startsWith("could not: no control"), "a control not there: said"
  check tools[1].confirm and not tools[0].confirm, "those that change something ask first"

echo "the MCP server"
block mcp:
  proc call(meth: string; params: JsonNode = newJObject(); id = 1): JsonNode =
    handle(app, %*{"jsonrpc": "2.0", "id": id, "method": meth, "params": params}, idle = proc () = run())
  let init = call("initialize", %*{"protocolVersion": "2025-06-18", "capabilities": {},
                                   "clientInfo": {"name": "test", "version": "1"}})
  check init{"result"}{"protocolVersion"}.getStr == "2025-06-18" and
        init{"result"}{"capabilities"}.hasKey("tools"), "initialize"
  check handle(app, %*{"jsonrpc": "2.0", "method": "notifications/initialized"}) == nil,
        "a notification: no answer"
  let list = call("tools/list")
  var names: seq[string]
  for t in list{"result"}{"tools"}.getElems: names.add t{"name"}.getStr
  check "ui_click" in names and "ui_screenshot" in names and "add" in names and
        list{"result"}{"tools"}[0].hasKey("inputSchema"), "tools/list: the window's and the app's own"
  let before = count
  let c = call("tools/call", %*{"name": "ui_click", "arguments": {"name": "Count"}})
  check c{"result"}{"isError"}.getBool == false and count == before + 1, "tools/call ui_click"
  let tr = call("tools/call", %*{"name": "ui_controls", "arguments": {}})
  check "Count: " & $count in tr{"result"}{"content"}[0]{"text"}.getStr, "tools/call ui_controls"
  let sh = call("tools/call", %*{"name": "ui_screenshot", "arguments": {"max": 200}})
  check sh{"result"}{"content"}[0]{"type"}.getStr == "image" and
        sh{"result"}{"content"}[0]{"mimeType"}.getStr == "image/png", "tools/call ui_screenshot: an image"
  let own = call("tools/call", %*{"name": "add", "arguments": {"n": 10}})
  check own{"result"}{"content"}[0]{"text"}.getStr == "the count is " & $(before + 11), "the app's own tool"
  let bad = call("tools/call", %*{"name": "ui_click", "arguments": {"name": "Nothing"}})
  check bad{"result"}{"isError"}.getBool, "a failure: isError"
  check call("no/such"){"error"}{"code"}.getInt == -32601, "an unknown method"

app.close()
if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_mcp: all passed"

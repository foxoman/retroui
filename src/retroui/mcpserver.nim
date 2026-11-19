## Any retroui app as an MCP server: an AI agent (Claude's desktop app, an editor's agent, any
## program that speaks the Model Context Protocol) sees the app's window and works it -- its
## controls by their names, a click, typing, a key, a picture of the window -- and runs the
## app's own tools where the app publishes them (`retroui/aichat`'s `publishTools`). The app
## runs with RETRO_DRIVE; this speaks MCP on its standard input and output and the driver to
## the app (`retroui/drive`). `retrokit mcp PORT` runs it:
##
## .. code-block:: sh
##   RETRO_DRIVE=7000 ./photo &
##   retrokit mcp 7000           # (what the agent starts: it talks on stdin and stdout)
##
## An agent's settings name the command, e.g. `{"command": "retrokit", "args": ["mcp", "7000"]}`.
## Only the machine itself reaches the driver; the agent's program asks its user before a tool
## runs, as MCP's do.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils]
import driveclient

const McpVersion = "2025-06-18"

type UiTool = tuple[name, description: string; params: JsonNode]

proc schema(props: openArray[(string, string, string)]; required: openArray[string]): JsonNode =
  var p = newJObject()
  for (n, t, d) in props: p[n] = %*{"type": t, "description": d}
  %*{"type": "object", "properties": p, "required": %required}

proc uiTools(): seq[UiTool] =
  @[("ui_controls", "Lists the app's window as it is now: each control a line -- its role, its name in " &
       "quotes, its value, its states -- indented inside what holds it. Look before you click.",
     schema([], [])),
    ("ui_screenshot", "A picture of the app's window as it is now.",
     schema([("max", "integer", "its longest side in pixels (smaller windows as they are); 1280 if not given")], [])),
    ("ui_click", "Clicks a control of the app by its name, as ui_controls lists it.",
     schema([("name", "string", "the control's name"),
             ("role", "string", "its role when several have the name (button, menuItem, tab, listItem...)"),
             ("double", "boolean", "a double click"), ("right", "boolean", "the right button")], ["name"])),
    ("ui_type", "Types text where the keyboard's focus is (click a box first).",
     schema([("text", "string", "what to type")], ["text"])),
    ("ui_key", "Presses a key or a shortcut: Enter, Esc, Tab, ctrl+s, alt+f, F2.",
     schema([("key", "string", "the key")], ["key"])),
    ("ui_set", "Sets a control's value as a screen reader does: a text box's text, a slider's number, a " &
       "drop-down's item.", schema([("name", "string", "the control's name"), ("value", "string", "its value")],
                                   ["name", "value"])),
    ("ui_wait", "Waits until a control is there (or gone), or a number of milliseconds.",
     schema([("name", "string", "the control to wait for"), ("gone", "boolean", "until it is gone"),
             ("ms", "integer", "or milliseconds to wait"), ("timeout", "integer", "at most, in ms (5000)")], []))]

proc treeLines(r: JsonNode): string =
  var depth: seq[int]
  for n in r{"nodes"}.getElems:
    let p = n{"parent"}.getInt(-1)
    depth.add(if p >= 0 and p < depth.len: depth[p] + 1 else: 0)
    result.add repeat("  ", min(depth[^1], 12)) & describe(n) & "\n"

proc textResult(t: string; isError = false): JsonNode =
  %*{"content": [{"type": "text", "text": t}], "isError": isError}

proc callUi(app: DriveClient; name: string; a: JsonNode; idle: proc ()): JsonNode =
  ## (one of the window's tools, through the driver)
  var req: JsonNode
  case name
  of "ui_controls": req = %*{"cmd": "tree"}
  of "ui_screenshot": req = %*{"cmd": "shot", "max": a{"max"}.getInt(1280)}
  of "ui_click":
    req = %*{"cmd": "click", "name": a{"name"}.getStr}
    if a{"role"}.getStr.len > 0: req["role"] = %a{"role"}.getStr
    if a{"double"}.getBool: req["clicks"] = %2
    if a{"right"}.getBool: req["button"] = %"right"
  of "ui_type": req = %*{"cmd": "type", "text": a{"text"}.getStr}
  of "ui_key": req = %*{"cmd": "key", "key": a{"key"}.getStr}
  of "ui_set": req = %*{"cmd": "set", "name": a{"name"}.getStr, "value": a{"value"}.getStr}
  of "ui_wait":
    if a{"name"}.getStr.len > 0:
      req = %*{"cmd": "wait", "name": a{"name"}.getStr, "timeout": a{"timeout"}.getInt(5000)}
      if a{"gone"}.getBool: req["gone"] = %true
    else: req = %*{"cmd": "wait", "ms": clamp(a{"ms"}.getInt(500), 0, 60000)}
  else: return textResult("no tool " & name, true)
  let r = app.ask(req, timeoutMs = 90000, idle = idle)
  if not r{"ok"}.getBool: return textResult(r{"error"}.getStr("it failed"), true)
  case name
  of "ui_controls": textResult(treeLines(r))
  of "ui_screenshot":
    %*{"content": [{"type": "image", "data": r{"png"}.getStr, "mimeType": "image/png"}], "isError": false}
  of "ui_wait": textResult("done")
  else: textResult("done" & (if r.hasKey("node"): ": " & describe(r["node"]) else: ""))

proc handle*(app: DriveClient; msg: JsonNode; idle: proc () = nil): JsonNode =
  ## The answer to one MCP message (nil: a notification, none). `idle`: run while the app is
  ## waited for (a test that is the app as well: its frames).
  let id = msg{"id"}
  let meth = msg{"method"}.getStr
  if id == nil or id.kind == JNull: return nil
  var res: JsonNode
  try:
    case meth
    of "initialize":
      let asked = msg{"params"}{"protocolVersion"}.getStr(McpVersion)
      res = %*{"protocolVersion": asked, "capabilities": {"tools": {"listChanged": false}},
               "serverInfo": {"name": "retroui", "version": "1"},
               "instructions": "These tools work a desktop app's window: list its controls, click them by " &
                 "name, type, press keys, look at a picture of it. The app's own tools (when it has them) do " &
                 "its work directly: prefer them."}
    of "ping": res = newJObject()
    of "tools/list":
      var ts = newJArray()
      for (n, d, p) in uiTools(): ts.add %*{"name": n, "description": d, "inputSchema": p}
      let own = app.ask(%*{"cmd": "tools"}, timeoutMs = 10000, idle = idle)
      for t in own{"tools"}.getElems:
        ts.add %*{"name": t{"name"}.getStr, "description": t{"description"}.getStr, "inputSchema": t{"params"}}
      res = %*{"tools": ts}
    of "tools/call":
      let p = msg{"params"}
      let name = p{"name"}.getStr
      let args = if p{"arguments"} != nil and p{"arguments"}.kind == JObject: p{"arguments"} else: newJObject()
      if name.startsWith("ui_"): res = callUi(app, name, args, idle)
      else:
        let r = app.ask(%*{"cmd": "tool", "name": name, "args": $args}, timeoutMs = 300000, idle = idle)
        res = if r{"ok"}.getBool: textResult(r{"text"}.getStr) else: textResult(r{"error"}.getStr, true)
    else:
      return %*{"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "no method " & meth}}
  except DriveError as e:
    return %*{"jsonrpc": "2.0", "id": id, "result": textResult("the app did not answer: " & e.msg, true)}
  %*{"jsonrpc": "2.0", "id": id, "result": res}

proc serveMcp*(port: int; input = stdin; output = stdout): int =
  ## Speaks MCP on `input` and `output` (a message a line) for the app whose driver listens on
  ## `port`, until the input ends. 1: the app could not be reached.
  var app: DriveClient
  try: app = driveConnect(port, timeoutMs = 10000, probe = true)
  except DriveError as e:
    stderr.writeLine "retrokit mcp: ", e.msg
    return 1
  defer: app.close()
  var line = ""
  while input.readLine(line):
    if line.strip.len == 0: continue
    var msg: JsonNode
    try: msg = parseJson(line)
    except CatchableError:
      output.writeLine $(%*{"jsonrpc": "2.0", "id": nil, "error": {"code": -32700, "message": "not JSON"}})
      output.flushFile
      continue
    let r = handle(app, msg)
    if r != nil:
      output.writeLine $r
      output.flushFile
  0

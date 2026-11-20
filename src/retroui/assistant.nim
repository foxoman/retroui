## An assistant in any app: a conversation with your AI service beside the app's work, which
## does things in the app with the tools the app gives it -- as a copilot does in an office
## program. `assistantPanel` draws it (the messages, what each tool did, a tool that asks
## first with Allow and Don't, the box to write in); `retroui/aichat` is the conversation.
##
## .. code-block:: nim
##   var chat = newAiChat(loadAiSettings("notes"), "You help with the notes of this app.",
##                        [noteTool, commandTool(menuCommands(), runCommand)])
##   chat.tools.add uiTools()          # (and the app's own controls, by their names)
##   app "Notes", 900, 600:
##     row([-1, 320]):
##       notesView()
##       assistantPanel(chat)
##
## `uiTools` lets the service see and work the app's own controls -- every button, box and
## list by the name a screen reader reads (`retroui/drive`) -- so an app with no tools of
## its own has an assistant too. What it writes reads as Markdown; Arabic right to left.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils]
import core, widgets, extras, markdown, aichat, drive
export aichat

proc argsText(a: JsonNode): string =
  ## (a call's arguments, short)
  if a == nil or a.kind != JObject: return ""
  var parts: seq[string]
  for k, v in a:
    var t = if v.kind == JString: v.getStr else: $v
    if t.len > 60: t = t[0 ..< 57] & "..."
    parts.add k & ": " & t
  parts.join(", ")

proc toolLabel(name: string): string =
  ## ("add_text_layer": "add text layer")
  name.replace('_', ' ').replace('-', ' ')

proc assistantPanel*(c: AiChat; height = -1;
                     connectHint = "No AI service is connected."): bool {.discardable.} =
  ## The conversation with `c`'s service, `height` pixels high (-1: down to the bottom), and
  ## its box to write in: Enter or Send sends, Stop stops, New starts again. True when
  ## something was sent this frame.
  if c == nil: return
  let total = if height < 0: remainingH() else: height
  # (narrow -- a dock's column, a phone --: the box on a line of its own, the buttons under it)
  let narrow = available() < dp(380)
  let inputH = (FontH + dp(14) + Pad) * (if narrow: 2 else: 1)
  let gray = ui.theme.gray
  beginPanel(max(FontH * 3, total - inputH), key = "assistant")
  if c.messages.len == 0 and not c.busy:
    paragraph(if c.settings.connected: "Ask for what you want done; it can use the app to do it, and " &
                                        "asks before it changes anything."
              else: connectHint, color = gray)
  var lastY = 0
  var act = 0                    # (a tool allowed or not: once the messages are drawn)
  for mi, m in c.messages:
    case m.role
    of arUser:
      label("You", bold = true)
      markdown(m.text)
      if m.png.len > 0: label("(a picture with it)", color = gray)
    of arAssistant:
      if m.text.strip.len > 0:
        label("Assistant", bold = true)
        markdown(m.text)
      for k in m.calls:
        case k.state
        of acDone: paragraph("- " & toolLabel(k.name) & ": " & k.result, color = gray)
        of acDenied: paragraph("- " & toolLabel(k.name) & ": not done", color = gray)
        of acRunning: paragraph("- " & toolLabel(k.name) & "...", color = gray)
        of acWaiting: discard
        of acAsking:
          group("Allow this?"):
            label(toolLabel(k.name), bold = true)
            let a = argsText(k.args)
            if a.len > 0: paragraph(a)
            row:
              if button("&Allow", w = dp(80)): act = 1
              if button("Allow A&ll", w = dp(90)): act = 2
              if button("&Don't", w = dp(80)): act = 3
    of arTool: discard
    if mi == c.messages.high: lastY = ui.lastRect.y
  if c.state == ciAsking:
    # (the device's own model writes as it goes: what it has so far)
    let so = c.partialAnswer
    if so.strip.len > 0:
      label("Assistant", bold = true)
      markdown(so)
      wakeIn(100)
    row:
      spinner()
      label("Thinking...", color = gray)
  if c.error.len > 0: paragraph(c.error, color = color(170, 0, 0))
  # (the newest at the bottom, in view, once each message comes)
  let id = idOf("assistant-seen")
  var st = state(id)
  let count = c.messages.len * 4 + ord(c.state)
  if st.aux != count:
    st.aux = count
    state(id) = st
    revealInPanel(rect(0, max(lastY, 0) + dp(100000), 1, 1))
  endPanel()
  case act
  of 1: c.allow()
  of 2: c.allow(always = true)
  of 3: c.deny()
  else: discard
  var enter = false
  template box() =
    accessNameOr("Ask the assistant")
    discard edit(c.draft)
    let id = ui.lastId
    if ui.focus == id and id != 0: ui.takesEnter = true   # (Enter sends: #9)
    enter = ui.focus == id and id != 0 and keyHit(KeyEnter)
  template buttons() =
    if c.busy:
      if button("&Stop"): c.stop()
    elif button("&Send", enabled = c.draft.strip.len > 0) or (enter and c.draft.strip.len > 0):
      c.send(c.draft)
      c.draft = ""
      result = true
    if button("&New", enabled = c.messages.len > 0): c.clear()
  if narrow:
    row([-1]):
      box()
    row([-1, -1]):
      buttons()
  else:
    row([-1, 70, 64]):
      box()
      buttons()

# ---- the app's own controls as tools (any app: no tools of its own needed) --------------------------------

proc treeText*(answer: string; most = 400): string =
  ## (a driver's `tree` answer as lines a service reads: a control a line, indented by where it
  ## is -- its role, "name", its value, its states)
  let j = try: parseJson(answer) except CatchableError: nil
  if j == nil or not j{"ok"}.getBool: return "the controls could not be read"
  var depth: seq[int]
  var n = 0
  for node in j{"nodes"}.getElems:
    let p = node{"parent"}.getInt(-1)
    depth.add(if p >= 0 and p < depth.len: depth[p] + 1 else: 0)
    let name = node{"name"}.getStr
    let role = node{"role"}.getStr
    if name.len == 0 and role in ["group", "pane", "label", "image"]: continue
    if n >= most:
      result.add "... (more not listed)\n"
      break
    inc n
    var line = repeat("  ", min(depth[^1], 12)) & role & " \"" & name & "\""
    let v = node{"value"}.getStr
    if v.len > 0: line.add " = \"" & (if v.len > 80: v[0 ..< 77] & "..." else: v) & "\""
    var states: seq[string]
    for st in node{"states"}.getElems:
      if st.getStr in ["disabled", "checked", "selected", "focused", "expanded", "readOnly"]: states.add st.getStr
    if states.len > 0: line.add " (" & states.join(", ") & ")"
    result.add line & "\n"

proc said(answer, what: string): string =
  ## (a driver's answer in words)
  let j = try: parseJson(answer) except CatchableError: nil
  if j == nil: return "no answer"
  if not j{"ok"}.getBool: return "could not: " & j{"error"}.getStr
  what

proc uiTools*(): seq[AiTool] =
  ## Tools that let the service see and work the app's own controls, by the names a screen
  ## reader reads (`retroui/drive`): the controls listed, a click, typing, a key, a value set.
  ## Those that change something ask first. Any app has them -- an assistant for an app that
  ## has no tools of its own.
  result.add aiToolLater("ui_controls", "Lists the app's window as it is now: each control a line -- its " &
      "role, its name in quotes, its value, its states -- indented inside what holds it. Look before " &
      "you click; look again after.", [],
    proc (a: JsonNode; done: proc (text: string) {.closure.}) =
      driveAsk("""{"cmd":"tree"}""", proc (r: string) = done(treeText(r))))
  result.add aiToolLater("ui_click", "Clicks a control of the app by its name (as ui_controls lists it): a " &
      "button, a menu and its items, a tab, a list's item, a box to type in.",
      [param("name", "string", "the control's name"),
       param("role", "string", "its role when several have the name (button, menuItem, tab, listItem...)",
             optional = true),
       param("double", "boolean", "a double click", optional = true)],
    proc (a: JsonNode; done: proc (text: string) {.closure.}) =
      var cmd = %*{"cmd": "click", "name": a{"name"}.getStr}
      if a{"role"}.getStr.len > 0: cmd["role"] = %a{"role"}.getStr
      if a{"double"}.getBool: cmd["clicks"] = %2
      let n = a{"name"}.getStr
      driveAsk($cmd, proc (r: string) = done(said(r, "clicked \"" & n & "\""))),
    confirm = true)
  result.add aiToolLater("ui_type", "Types text where the keyboard's focus is (click a box first).",
      [param("text", "string", "what to type")],
    proc (a: JsonNode; done: proc (text: string) {.closure.}) =
      driveAsk($(%*{"cmd": "type", "text": a{"text"}.getStr}), proc (r: string) = done(said(r, "typed it"))),
    confirm = true)
  result.add aiToolLater("ui_key", "Presses a key or a shortcut: \"Enter\", \"Esc\", \"Tab\", \"ctrl+s\", " &
      "\"alt+f\", \"F2\".", [param("key", "string", "the key")],
    proc (a: JsonNode; done: proc (text: string) {.closure.}) =
      let k = a{"key"}.getStr
      driveAsk($(%*{"cmd": "key", "key": k}), proc (r: string) = done(said(r, "pressed " & k))),
    confirm = true)
  result.add aiToolLater("ui_set", "Sets a control's value as a screen reader does: a text box's text, a " &
      "slider's number, a drop-down's or a list's item.",
      [param("name", "string", "the control's name"), param("value", "string", "its new value")],
    proc (a: JsonNode; done: proc (text: string) {.closure.}) =
      let n = a{"name"}.getStr
      driveAsk($(%*{"cmd": "set", "name": n, "value": a{"value"}.getStr}),
               proc (r: string) = done(said(r, "set \"" & n & "\""))),
    confirm = true)

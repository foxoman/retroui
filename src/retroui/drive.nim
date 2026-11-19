## The driver: an app started with RETRO_DRIVE=PORT takes commands on
## 127.0.0.1:PORT -- one JSON object a line, one answer a line -- and does
## them as a person would: it finds a control by its name (as a screen
## reader reads it, as the inspector shows it), clicks it, types, presses
## keys, waits for a window to come. For tests, smoke runs and the Android
## emulator job, from any language; `retrokit drive` speaks it from a shell:
##
## .. code-block:: sh
##   RETRO_DRIVE=7000 ./notes &
##   retrokit drive 7000 click "New"
##   retrokit drive 7000 type "Shopping list"
##   retrokit drive 7000 key ctrl+s
##   retrokit drive 7000 wait "Saved" --timeout 3000
##   retrokit drive 7000 tree
##
## The commands (`cmd`), and what else each takes:
##
## ==========  ===============================================================
## tree        every control of the last frame: `nodes`, each with its
##             `index`, `role`, `name`, `value`, `states`, `x y w h` (the
##             window's logical pixels) and `parent`
## find        a control: `name` (any case; failing that, a part of it; ""
##             any), `role` ("button", "textField", "menuItem"...; several
##             as "button|link"), `nth` (the n-th, from 0) -- or `index`, or
##             `node`: a node's `id` (the same while it is shown).
##             With no role, a control that is not a label comes first (the
##             label "Name:" names the box after it: the box is meant)
## click       the middle of a control (as `find`), or `x`, `y`; `button`
##             ("left", "right", "middle"), `clicks` (2: a double click),
##             `finger` (true: a finger, not a mouse), `hold` (ms the
##             button or the finger stays down: 600 with a finger is a long
##             press, a touch screen's right click)
## move        the pointer over a control or to `x`, `y` (hover, tips)
## scroll      the wheel over a control or at `x`, `y`: `lines` (up > 0)
## focused     the control with the keyboard's focus is this one (as
##             `find`): fails, saying which has it, when it is another
## press       a control pressed as a screen reader presses it (no pointer)
## focus       the keyboard's focus to a control
## set         a control's value as a screen reader sets it: `value` (a
##             text box's text, a slider's number, a list's item)
## key         `key`: "Enter", "F12", "ctrl+s", "shift+Tab", "alt+f"
## type        `text`, as typed on a keyboard (any language)
## wait        `frames` frames, or `ms` milliseconds, or until a control
##             (as `find`) is there -- `gone`: true, until it is not --
##             at most `timeout` ms (5000)
## info        the window: `title`, `w`, `h`, `zoom`, `rtl`, `frames`, the
##             `focused` control, `dp` (logical pixels in a design pixel:
##             a size in dp is `w / dp`), `touch` (a touch screen),
##             `fingers` (finger-sized controls), `keyboard` (the focused
##             control asks for the on-screen keyboard), `below` (the
##             window's bottom the system covers: its bars, the keyboard)
## quit        the window's close box, as a person clicks it (the app may
##             still ask "Save changes?")
## ==========  ===============================================================
##
## Every answer has `ok` (and `error` when it is false) and the `id` the
## command had. An action (click, key, type...) is answered once the app has
## taken it and drawn the frames after it, with the control as it is then
## (`node`): the next command sees what it did.
##
## **A script from the command line**, no port: `RETRO_SCRIPT` -- steps split by ";" --
## runs them in the app as it starts; `RETRO_SNAPSHOT` keeps the window in memory (nothing
## shown, `RETRO_SIZE` its size), writes its picture as a PNG once the steps are done and the
## app is at rest, and ends the app (1: a step failed, said on stderr; 2: not a script);
## `RETRO_PLAY` plays the steps in the window at a person's pace, a dot where each click lands
## -- for a film or a GIF of a feature:
##
## .. code-block:: sh
##   RETRO_SCRIPT="click:New;type:Shopping list;key:ctrl+s;wait:Saved" RETRO_SNAPSHOT=new.png ./notes
##   RETRO_PLAY="click:Add;type:Milk;key:enter;wait:2" ./notes
##
## The steps: `click:NAME`, `dblclick:NAME`, `rclick:NAME`, `type:TEXT`, `key:ctrl+s`,
## `wait:SECONDS` or `wait:NAME` (until it is there), `focus:NAME`, `set:NAME=VALUE`,
## `shot:FILE` (a picture then), `quit`; "\;" a semicolon in a step.
##
## Only the machine itself can connect (127.0.0.1), one program at a time,
## and only an app started with RETRO_DRIVE opens a port; RETRO_DRIVE=0
## takes any free port and says which on stderr. While it waits for a
## command no frame is drawn (it looks every 50 ms). Not in web pages.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/strutils
import uirelays/[input, access]
when not defined(wasm):
  import std/[os, nativesockets]
  import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
  import core, gfx, inspect, headless, appicon

var drivePortNow = 0

proc drivePort*(): int = drivePortNow
  ## The port the driver listens on; 0 when it does not (no RETRO_DRIVE).

proc roleWord*(r: AccessRole): string =
  ## A role as the driver names it: "button", "textField", "menuItem".
  result = ($r)[2 .. ^1]
  result[0] = result[0].toLowerAscii

proc parseRoles*(s: string): set[AccessRole] =
  ## "button", "text field", "menuItem|link": the roles named (any case,
  ## spaces or not); unknown names are left out.
  for part in s.split({'|', ','}):
    let want = part.toLowerAscii.replace(" ", "").replace("_", "")
    if want.len == 0: continue
    for r in AccessRole:
      if ($r)[2 .. ^1].toLowerAscii == want: result.incl r

proc parseKey*(s: string; key: var KeyCode; mods: var set[Modifier]): bool =
  ## "ctrl+shift+s", "Enter", "F12", "alt+f": the key and its modifiers.
  mods = {}
  let parts = s.split('+')
  for i, p in parts:
    let w = p.strip.toLowerAscii
    if i < parts.len - 1:
      case w
      of "ctrl", "control", "cmd", "command": mods.incl CtrlPressed
      of "shift": mods.incl ShiftPressed
      of "alt", "option": mods.incl AltPressed
      of "gui", "super", "win", "meta": mods.incl GuiPressed
      else: return false
      continue
    let name = case w
      of "escape": "esc"
      of "return": "enter"
      of "del": "delete"
      of "ins": "insert"
      of "pgup": "pageup"
      of "pgdn", "pgdown": "pagedown"
      of " ", "spacebar": "space"
      else: w
    for k in KeyCode:
      if k != KeyNone and ($k)[3 .. ^1].toLowerAscii == name:
        key = k
        return true
  false

when not defined(wasm):
  # ---- a command's fields: a flat JSON object read here (no JSON library:
  # an app carries the driver, so it stays small) ----

  type
    Field = tuple[key, val: string; text: bool]   # text: it came as a JSON string
    Req = seq[Field]

  proc has(q: Req; k: string): bool =
    for f in q:
      if f.key == k: return true

  proc str(q: Req; k: string; d = ""): string =
    for f in q:
      if f.key == k: return f.val
    d

  proc num(q: Req; k: string; d = 0): int =
    for f in q:
      if f.key == k:
        try: return int(parseFloat(f.val))
        except ValueError: return d
    d

  proc flag(q: Req; k: string): bool = q.str(k) in ["true", "1"]

  proc isNumber(q: Req; k: string): bool =
    for f in q:
      if f.key == k: return not f.text

  proc parseReq(s: string; q: var Req): bool =
    ## (one object of strings, numbers, true, false and null; false when it
    ## is not that)
    var i = 0
    template ws() =
      while i < s.len and s[i] in {' ', '\t', '\r', '\n'}: inc i
    proc quoted(s: string; i: var int; v: var string): bool =
      inc i                                  # (the opening ")
      while i < s.len:
        let c = s[i]
        if c == '"':
          inc i
          return true
        if c == '\\' and i + 1 < s.len:
          inc i
          case s[i]
          of 'n': v.add '\n'
          of 't': v.add '\t'
          of 'r': v.add '\r'
          of 'b': v.add '\b'
          of 'f': v.add '\f'
          of 'u':
            if i + 4 >= s.len: return false
            var cp = 0
            try: cp = parseHexInt(s[i + 1 .. i + 4]) except ValueError: return false
            i += 4
            # (a surrogate pair: the letter past U+FFFF)
            if cp in 0xD800 .. 0xDBFF and i + 6 < s.len and s[i + 1] == '\\' and s[i + 2] == 'u':
              var lo = 0
              try: lo = parseHexInt(s[i + 3 .. i + 6]) except ValueError: lo = 0
              if lo in 0xDC00 .. 0xDFFF:
                cp = 0x10000 + (cp - 0xD800) shl 10 + (lo - 0xDC00)
                i += 6
            v.add Rune(cp).toUTF8
          else: v.add s[i]                   # (\" \\ \/)
          inc i
        else:
          v.add c
          inc i
      false
    ws()
    if i >= s.len or s[i] != '{': return false
    inc i
    ws()
    if i < s.len and s[i] == '}': return true
    while i < s.len:
      ws()
      if i >= s.len or s[i] != '"': return false
      var k = ""
      if not quoted(s, i, k): return false
      ws()
      if i >= s.len or s[i] != ':': return false
      inc i
      ws()
      if i >= s.len: return false
      if s[i] == '"':
        var v = ""
        if not quoted(s, i, v): return false
        q.add (k, v, true)
      else:
        let a = i
        while i < s.len and s[i] notin {',', '}', ' ', '\t', '\r', '\n'}: inc i
        let v = s[a ..< i]
        if v.len == 0 or v[0] in {'[', '{'}: return false
        if v != "null": q.add (k, v, false)
      ws()
      if i < s.len and s[i] == ',':
        inc i
        continue
      if i < s.len and s[i] == '}': return true
      return false
    false

  proc jstr(s: string): string =
    ## (a string as JSON writes it)
    result = "\""
    for c in s:
      case c
      of '"': result.add "\\\""
      of '\\': result.add "\\\\"
      of '\n': result.add "\\n"
      of '\r': result.add "\\r"
      of '\t': result.add "\\t"
      of '\0' .. '\x08', '\x0B', '\x0C', '\x0E' .. '\x1F':
        result.add "\\u00" & toHex(ord(c), 2)
      else: result.add c
    result.add '"'

  type
    Waiting = enum wNone, wSettle, wFrames, wMs, wNode, wHold
    Pending = object
      what: Waiting
      req: Req
      count: int                  # frames seen
      frames: int                 # frames asked for
      untilMs: int                # (ui.now) when it is given up, or done
      target: uint32              # the control acted on: its id
      name: string
      roles: set[AccessRole]
      nth: int
      gone: bool
      x, y: int                   # (a held press: where it is let go)
      button: MouseButton
      mouse: bool

  var
    listenFd = osInvalidSocket
    clientFd = osInvalidSocket
    inBuf = ""
    pending: Pending
    framesRun = 0

  proc readable(fd: SocketHandle): bool =
    var fds = @[fd]
    try: selectRead(fds, 0) > 0
    except OSError: false

  proc dropClient() =
    if clientFd != osInvalidSocket: clientFd.close()
    clientFd = osInvalidSocket
    inBuf.setLen(0)
    pending = Pending()

  var
    scripting = false             # (RETRO_SCRIPT, RETRO_SNAPSHOT, RETRO_PLAY: the steps given)
    playing = false               # (RETRO_PLAY: at a person's pace, a dot where each lands)
    steps: seq[Req]
    stepAt = 0
    scriptFailed = false
    snapshotPath = ""
    nextStepAt = 0
    restFrom = 0                  # (the steps done: when it began to wait for the app to rest)
    dots: seq[tuple[x, y, at: int]]

  proc answer(req: Req; res: string) =
    ## (`res`: the answer's fields, `"ok":true,...`; the command's id added)
    if scripting:
      # (a step of a script: a failure said, and the script ends there)
      if res.startsWith("\"ok\":false"):
        scriptFailed = true
        var why = res
        let e = res.find("\"error\":")
        if e >= 0: why = res[e + 8 .. ^1]
        stderr.writeLine "RETRO_SCRIPT: step " & $stepAt & " (" & req.str("step") & ") failed: " & why
      return
    if clientFd == osInvalidSocket: return
    var line = "{" & res
    for f in req:
      if f.key == "id": line.add ",\"id\":" & (if f.text: jstr(f.val) else: f.val)
    line.add "}\n"
    var sent = 0
    while sent < line.len:
      # (a client gone is no SIGPIPE: MSG_NOSIGNAL, or on Apple's systems the
      # socket's SO_NOSIGPIPE, set when it was taken)
      let n =
        when defined(nimdoc): line.len - sent    # (the docs' build: no sockets)
        elif defined(windows) or defined(macosx) or defined(ios):
          send(clientFd, addr line[sent], cint(line.len - sent), 0'i32)
        else: send(clientFd, addr line[sent], line.len - sent, MSG_NOSIGNAL)
      if n <= 0:
        dropClient()
        return
      sent += int(n)

  proc fail(req: Req; why: string) =
    answer(req, "\"ok\":false,\"error\":" & jstr(why))

  proc nodeJson(i: int; n: AccessNode): string =
    let r = nodeRect(n)
    result = "{\"index\":" & $i & ",\"id\":" & $n.id & ",\"role\":" & jstr(roleWord(n.role)) & ",\"name\":" &
             jstr(n.name) & ",\"x\":" & $r.x & ",\"y\":" & $r.y & ",\"w\":" & $r.w &
             ",\"h\":" & $r.h & ",\"parent\":" & $n.parent
    if n.value.len > 0: result.add ",\"value\":" & jstr(n.value)
    if n.help.len > 0: result.add ",\"help\":" & jstr(n.help)
    if n.key.len > 0: result.add ",\"key\":" & jstr(n.key)
    if n.letter != '\0': result.add ",\"letter\":" & jstr($n.letter)
    if n.states.len > 0:
      result.add ",\"states\":["
      var first = true
      for s in n.states:
        var w = ($s)[2 .. ^1]
        w[0] = w[0].toLowerAscii
        if not first: result.add ','
        result.add jstr(w)
        first = false
      result.add ']'
    result.add '}'

  proc byId(id: uint32): int =
    for i, n in accessLast:
      if n.id == id: return i
    -1

  proc findCtl(name: string; roles: set[AccessRole]; nth: int): int =
    ## (a control by its name: with no role asked, one that is not a label
    ## first -- a label names the box after it, and the box is meant)
    if roles.len > 0: return findNode(accessLast, name, roles, nth)
    var others: set[AccessRole]
    for r in AccessRole:
      if r != arLabel: others.incl r
    result = findNode(accessLast, name, others, nth)
    if result < 0: result = findNode(accessLast, name, {}, nth)

  proc lookup(req: Req): int =
    ## (the control a command is for, in the last frame's tree; -1 none)
    if req.has("index"):
      let i = req.num("index", -1)
      return if i in 0 ..< accessLast.len: i else: -1
    if req.has("node"):
      var id = 0'u32
      try: id = uint32(parseBiggestUInt(req.str("node"))) except ValueError: return -1
      return byId(id)
    findCtl(req.str("name"), parseRoles(req.str("role")), req.num("nth"))

  proc noControl(req: Req): string =
    "no control called \"" & req.str("name") & "\"" &
      (if req.has("role"): " (" & req.str("role") & ")" else: "")

  proc pointOf(req: Req; ex, ey: var int; at: var int): string =
    ## (where a command points, in the driver's units: a control's middle,
    ## or `x`, `y` in logical pixels; "" or why not)
    at = -1
    if req.has("x") and req.has("y") and not req.has("name"):
      let x = req.num("x")
      let y = req.num("y")
      if x < 0 or y < 0 or x >= ui.w or y >= ui.h:
        return "the point " & $x & "," & $y & " is outside the window (" & $ui.w & " x " &
               $ui.h & ")"
      let z = max(1, zoom)
      ex = (if ui.rtl: ui.w - 1 - x else: x) * z + z div 2
      ey = y * z + z div 2
      return ""
    at = lookup(req)
    if at < 0: return noControl(req)
    let n = accessLast[at]
    let r = nodeRect(n)
    if r.w <= 0 or r.h <= 0 or r.x + r.w div 2 < 0 or r.y + r.h div 2 < 0 or
       r.x + r.w div 2 >= ui.w or r.y + r.h div 2 >= ui.h:
      return "\"" & n.name & "\" is out of sight (at " & $r.x & "," & $r.y & ")"
    ex = n.x + n.w div 2
    ey = n.y + n.h div 2
    ""

  proc nextFrame() =
    ## (another frame soon: a wake-up, which stays -- a redraw asked for is
    ## dropped after a few in a row, to show the frame)
    wakeIn(1)

  proc settle(req: Req; target: uint32) =
    ## (answered once the events are taken and two frames ran after them)
    pending = Pending(what: wSettle, req: req, target: target)
    nextFrame()

  proc doCommand(req: Req) =
    let cmd = req.str("cmd").toLowerAscii
    case cmd
    of "tree":
      var nodes = ""
      for i, n in accessLast:
        if i > 0: nodes.add ','
        nodes.add nodeJson(i, n)
      answer(req, "\"ok\":true,\"nodes\":[" & nodes & "]")
    of "find":
      let i = lookup(req)
      if i < 0: fail(req, noControl(req))
      else: answer(req, "\"ok\":true,\"node\":" & nodeJson(i, accessLast[i]))
    of "focused":
      var at = -1
      for i, n in accessLast:
        if asFocused in n.states: at = i
      let i = lookup(req)
      if at < 0: fail(req, "nothing has the focus")
      elif i == at or (i >= 0 and accessLast[i].id == accessLast[at].id):
        answer(req, "\"ok\":true,\"node\":" & nodeJson(at, accessLast[at]))
      else:
        let n = accessLast[at]
        fail(req, "the focus is on " & roleWord(n.role) & " \"" & n.name & "\", not " &
                  (if req.has("role"): req.str("role") & " " else: "") & "\"" & req.str("name") & "\"")
    of "info":
      var res = "\"ok\":true,\"title\":" &
                jstr(if accessLast.len > 0: accessLast[0].name else: "") &
                ",\"w\":" & $ui.w & ",\"h\":" & $ui.h & ",\"zoom\":" & $max(1, zoom) &
                ",\"rtl\":" & $ui.rtl & ",\"frames\":" & $framesRun &
                ",\"dp\":" & $dpf(1.0) & ",\"touch\":" & $ui.touch & ",\"fingers\":" & $fingers() &
                ",\"keyboard\":" & $keyboardWanted() & ",\"below\":" & $(ui.h - ui.bottom)
      for i, n in accessLast:
        if asFocused in n.states:
          res.add ",\"focused\":" & nodeJson(i, n)
          # (what it is in: a list's item reaches the list, scrolled or not)
          res.add ",\"within\":["
          var p = int(n.parent)
          var first = true
          var guard = 0
          while p > 0 and p < accessLast.len and guard < 64:
            if not first: res.add ','
            res.add $accessLast[p].id
            first = false
            p = int(accessLast[p].parent)
            inc guard
          res.add ']'
          break
      answer(req, res)
    of "click", "move", "scroll":
      var ex, ey, at: int
      let why = pointOf(req, ex, ey, at)
      if why.len > 0:
        fail(req, why)
        return
      let mouse = not req.flag("finger")
      feedEvent Event(kind: MouseMoveEvent, x: ex, y: ey, fromMouse: mouse)
      if cmd == "click":
        let b = case req.str("button", "left").toLowerAscii
                of "right": RightButton
                of "middle": MiddleButton
                else: LeftButton
        let hold = req.num("hold")
        if hold > 0:
          # (held: let go after `hold` ms of frames -- a long press)
          feedEvent Event(kind: MouseDownEvent, x: ex, y: ey, button: b, clicks: 1,
                          fromMouse: mouse)
          pending = Pending(what: wHold, req: req, untilMs: ui.now + hold, x: ex, y: ey,
                            button: b, mouse: mouse,
                            target: if at >= 0: accessLast[at].id else: 0'u32)
          wakeIn(1)
          return
        for c in 1 .. clamp(req.num("clicks", 1), 1, 3):
          feedEvent Event(kind: MouseDownEvent, x: ex, y: ey, button: b, clicks: c,
                          fromMouse: mouse)
          feedEvent Event(kind: MouseUpEvent, x: ex, y: ey, button: b, fromMouse: mouse)
      elif cmd == "scroll":
        feedEvent Event(kind: MouseWheelEvent, y: req.num("lines", -3), fromMouse: mouse)
      settle(req, if at >= 0: accessLast[at].id else: 0'u32)
    of "press", "focus", "set":
      let i = lookup(req)
      if i < 0:
        fail(req, noControl(req))
        return
      let id = accessLast[i].id
      case cmd
      of "press": accessRequests.add AccessRequest(action: aaPress, id: id)
      of "focus": accessRequests.add AccessRequest(action: aaFocus, id: id)
      else:
        var q = AccessRequest(action: aaSetValue, id: id, text: req.str("value"))
        try: q.num = parseFloat(q.text) except ValueError: discard
        accessRequests.add q
      settle(req, id)
    of "key":
      var k: KeyCode
      var mods: set[Modifier]
      if not parseKey(req.str("key"), k, mods):
        fail(req, "no key called \"" & req.str("key") & "\"")
        return
      feedEvent Event(kind: KeyDownEvent, key: k, mods: mods, hasMods: true)
      feedEvent Event(kind: KeyUpEvent, key: k, mods: mods, hasMods: true)
      settle(req, 0)
    of "type":
      for r in req.str("text").runes:
        # (as a keyboard: a key down before each letter, then the letter)
        feedEvent Event(kind: KeyDownEvent, key: KeyNone, hasMods: true)
        var e = Event(kind: TextInputEvent)
        let s = r.toUTF8
        for j in 0 ..< min(4, s.len): e.text[j] = s[j]
        feedEvent e
      settle(req, 0)
    of "wait":
      if req.has("frames"):
        pending = Pending(what: wFrames, req: req, frames: max(1, req.num("frames")))
        nextFrame()
      elif req.has("name") or req.has("role"):
        pending = Pending(what: wNode, req: req, name: req.str("name"),
                          roles: parseRoles(req.str("role")), nth: req.num("nth"),
                          gone: req.flag("gone"),
                          untilMs: ui.now + max(0, req.num("timeout", 5000)))
        nextFrame()
      else:
        let ms = max(0, req.num("ms"))
        pending = Pending(what: wMs, req: req, untilMs: ui.now + ms)
        wakeIn(max(1, ms))
    of "quit":
      answer(req, "\"ok\":true")
      feedEvent Event(kind: WindowCloseEvent)
    else:
      fail(req, "no command \"" & cmd & "\" (tree, find, focused, info, click, move, scroll, " &
                "press, focus, set, key, type, wait, quit)")

  proc pendingDone(): bool =
    ## (the command waited for is done: answered)
    let p = pending
    case p.what
    of wNone: return true
    of wSettle:
      if eventsWaiting() > 0 or accessRequests.len > 0:
        pending.count = 0
        nextFrame()
        return false
      inc pending.count
      if pending.count < 3:
        nextFrame()
        return false
      var res = "\"ok\":true"
      if p.target != 0:
        let i = byId(p.target)
        if i >= 0: res.add ",\"node\":" & nodeJson(i, accessLast[i])
      pending = Pending()
      answer(p.req, res)
    of wFrames:
      inc pending.count
      if pending.count <= p.frames:
        nextFrame()
        return false
      pending = Pending()
      answer(p.req, "\"ok\":true")
    of wHold:
      if ui.now < p.untilMs:
        wakeIn(max(1, min(50, p.untilMs - ui.now)))   # (frames while it is held)
        return false
      feedEvent Event(kind: MouseUpEvent, x: p.x, y: p.y, button: p.button, fromMouse: p.mouse)
      pending = Pending(what: wSettle, req: p.req, target: p.target)
      nextFrame()
      return false
    of wMs:
      if ui.now < p.untilMs:
        wakeIn(p.untilMs - ui.now)
        return false
      pending = Pending()
      answer(p.req, "\"ok\":true")
    of wNode:
      let i = findCtl(p.name, p.roles, p.nth)
      if (i >= 0) != p.gone:
        pending = Pending()
        if i >= 0: answer(p.req, "\"ok\":true,\"node\":" & nodeJson(i, accessLast[i]))
        else: answer(p.req, "\"ok\":true")
        return true
      if ui.now >= p.untilMs:
        pending = Pending()
        fail(p.req, "\"" & p.name & "\" " & (if p.gone: "still there" else: "not there") &
                    " after " & p.req.str("timeout", "5000") & " ms")
        return true
      # (the app's own frames show it, or the time runs out)
      wakeIn(p.untilMs - ui.now)
      return false
    true

  proc driveFrame() =
    ## (every frame's start: the last frame's tree is whole in `accessLast`)
    inc framesRun
    if clientFd == osInvalidSocket and listenFd.readable:
      try:
        let (c, _) = accept(listenFd)
        if c != osInvalidSocket:
          clientFd = c
          when defined(macosx) or defined(ios):
            setSockOptInt(c, SOL_SOCKET, 0x1022, 1)      # (SO_NOSIGPIPE)
          inBuf.setLen(0)
      except OSError: discard
    if clientFd == osInvalidSocket: return
    while clientFd.readable:
      var chunk = newString(65536)
      let n = recv(clientFd, addr chunk[0], cint(chunk.len), 0'i32)
      if n <= 0:
        dropClient()
        return
      chunk.setLen(int(n))
      inBuf.add chunk
      if inBuf.len > 1 shl 24:
        dropClient()                  # (no line in 16 MB: not a driver's client)
        return
    if pending.what != wNone and not pendingDone(): return
    if accessLast.len == 0:
      if inBuf.len > 0: nextFrame()     # (the first frame first)
      return
    while pending.what == wNone and clientFd != osInvalidSocket:
      let nl = inBuf.find('\n')
      if nl < 0: break
      let line = inBuf[0 ..< nl].strip
      inBuf = inBuf[nl + 1 .. ^1]
      if line.len == 0: continue
      var req: Req
      if not parseReq(line, req):
        fail(@[], "a command is a JSON object of strings and numbers, a line: " &
                  "{\"cmd\": \"click\", \"name\": \"OK\"} -- not " & line)
        continue
      doCommand(req)

  # ---- a script: RETRO_SCRIPT, RETRO_SNAPSHOT, RETRO_PLAY -----------------------------------------

  proc parseScript*(s: string; steps: var seq[string]): string =
    ## (a script's steps, split at ";" -- "\;" a semicolon in a step --; "" or why it is not one)
    var cur = ""
    var i = 0
    while i < s.len:
      if s[i] == '\\' and i + 1 < s.len and s[i + 1] == ';':
        cur.add ';'
        i += 2
        continue
      if s[i] == ';':
        if cur.strip.len > 0: steps.add cur.strip
        cur = ""
      else: cur.add s[i]
      inc i
    if cur.strip.len > 0: steps.add cur.strip
    for st in steps:
      let verb = st.split(':', 1)[0].strip.toLowerAscii
      if verb notin ["click", "dblclick", "rclick", "type", "key", "wait", "shot", "quit", "focus", "set"]:
        return "no step \"" & verb & "\" (click, dblclick, rclick, type, key, wait, shot, focus, set, quit)"
    ""

  proc stepReq(st: string): Req =
    ## (a step as a driver's command: "click:Open", "type:Hi", "key:ctrl+s", "wait:2" seconds or
    ## "wait:Saved" a control, "shot:FILE", "set:Name=value", "focus:Name", "quit")
    let parts = st.split(':', 1)
    let verb = parts[0].strip.toLowerAscii
    let arg = if parts.len > 1: parts[1] else: ""
    result.add ("step", st, true)
    case verb
    of "click", "dblclick", "rclick":
      result.add ("cmd", "click", true)
      result.add ("name", arg.strip, true)
      if verb == "dblclick": result.add ("clicks", "2", false)
      if verb == "rclick": result.add ("button", "right", true)
    of "type": result.add [("cmd", "type", true), ("text", arg, true)]
    of "key": result.add [("cmd", "key", true), ("key", arg.strip, true)]
    of "wait":
      result.add ("cmd", "wait", true)
      try: result.add ("ms", $int(parseFloat(arg.strip) * 1000), false)
      except ValueError: result.add ("name", arg.strip, true)
    of "shot": result.add [("cmd", "shot", true), ("file", arg.strip, true)]
    of "focus": result.add [("cmd", "focus", true), ("name", arg.strip, true)]
    of "set":
      let kv = arg.split('=', 1)
      result.add [("cmd", "set", true), ("name", kv[0].strip, true),
                  ("value", (if kv.len > 1: kv[1] else: ""), true)]
    else: result.add ("cmd", "quit", true)

  proc writeShot(path: string): bool =
    ## (the window's picture as a PNG: the window kept in memory, `headless`)
    if path.len == 0: return false
    let b = headlessShot()
    if b == nil or b.w <= 0: return false
    let data = png(b.w, b.h, b.px)
    var str = newString(data.len)
    if data.len > 0: copyMem(addr str[0], unsafeAddr data[0], data.len)
    try:
      if path.parentDir.len > 0: createDir(path.parentDir)
      writeFile(path, str)
      true
    except IOError, OSError: false

  proc finishScript() =
    ## (the steps done: the picture written once the app is at rest -- or two seconds -- and the
    ## app ended; a script alone leaves it running)
    if snapshotPath.len > 0:
      if restFrom == 0: restFrom = ui.now
      if not scriptFailed and ui.wakeAt != 0 and ui.now - restFrom < 2000:
        nextFrame()                   # (an animation finishing first)
        return
      var code = if scriptFailed: 1 else: 0
      if not scriptFailed and not writeShot(snapshotPath):
        stderr.writeLine "RETRO_SNAPSHOT: could not write " & snapshotPath
        code = 1
      quit(code)
    if scriptFailed and not playing: quit(1)
    scripting = false

  proc dotsDraw() =
    ## (RETRO_PLAY: a dot where each click landed, fading)
    var i = 0
    while i < dots.len:
      let age = ui.now - dots[i].at
      if age > 700:
        dots.delete(i)
        continue
      let a = uint8(160 * (700 - age) div 700)
      disc(dots[i].x.float, dots[i].y.float, float(dpf(14.0)), color(230, 40, 40, a))
      wakeIn(16)
      inc i

  proc scriptFrame() =
    ## (every frame's start while a script runs: its next step once the last one is done)
    inc framesRun
    if not scripting: return
    if pending.what != wNone and not pendingDone(): return
    if accessLast.len == 0:
      nextFrame()                     # (the first frame first)
      return
    if scriptFailed or stepAt >= steps.len:
      finishScript()
      return
    if playing and ui.now < nextStepAt:
      wakeIn(nextStepAt - ui.now)
      return
    let req = steps[stepAt]
    inc stepAt
    if req.str("cmd") == "shot":
      if not writeShot(req.str("file")):
        stderr.writeLine "RETRO_SCRIPT: step " & $stepAt & " (" & req.str("step") &
                         "): no picture (RETRO_SNAPSHOT keeps the window in memory; RETRO_PLAY shows it)"
      nextFrame()
      return
    if playing:
      if req.str("cmd") == "click":
        let i = lookup(req)
        if i >= 0:
          let r = nodeRect(accessLast[i])
          dots.add (r.x + r.w div 2, r.y + r.h div 2, ui.now)
      if req.str("cmd") == "type" and req.str("text").runeLen > 1:
        # (typed a letter at a time, as a person types)
        var rest: seq[Req]
        for r in req.str("text").runes:
          rest.add @[("step", req.str("step"), true), ("cmd", "type", true), ("text", r.toUTF8, true)]
        steps = steps[0 ..< stepAt - 1] & rest & steps[stepAt .. ^1]
        dec stepAt
        nextFrame()
        return
      nextStepAt = ui.now + (if req.str("cmd") == "type": 90 else: 700)
    doCommand(req)

  proc startScript*(script: string; play = false; snapshot = ""): string =
    ## Runs the steps of `script` in this app (as RETRO_SCRIPT does): each a control clicked,
    ## text typed, a key, a wait -- `play` at a person's pace with a dot where each click lands
    ## (RETRO_PLAY: for a film of the app); `snapshot`: the window kept in memory, its picture
    ## written there once the steps are done and the app ended (RETRO_SNAPSHOT). "" or why the
    ## script is not one.
    var texts: seq[string]
    let why = parseScript(script, texts)
    if why.len > 0: return why
    for t in texts: steps.add stepReq(t)
    scripting = true
    playing = play
    snapshotPath = snapshot
    accessKeep = true
    beginFrameHooks.add scriptFrame
    if play: endFrameHooks.add dotsDraw
    ""

  proc drivePoll(): bool =
    ## (while the app waits: something to accept or to read)
    if clientFd != osInvalidSocket: clientFd.readable
    else: listenFd.readable

  proc startDriver*(port: int): int =
    ## Listen for a driver on 127.0.0.1:`port` (0: any free port), as
    ## RETRO_DRIVE does; the port, or 0 when it could not.
    if drivePortNow != 0: return drivePortNow
    var why = ""
    let fd = createNativeSocket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    if fd == osInvalidSocket: why = osErrorMsg(osLastError())
    else:
      try:
        setSockOptInt(fd, SOL_SOCKET, SO_REUSEADDR, 1)
        let ai = getAddrInfo("127.0.0.1", Port(port), AF_INET, SOCK_STREAM, IPPROTO_TCP)
        let bound = bindAddr(fd, ai.ai_addr, ai.ai_addrlen.SockLen) >= 0
        freeAddrInfo(ai)
        if not bound or fd.listen(1) < 0: why = osErrorMsg(osLastError())
        else: drivePortNow = int(getLocalAddr(fd, AF_INET)[1])
      except OSError as e: why = e.msg
      if why.len > 0: fd.close()
    if drivePortNow == 0:
      stderr.writeLine "RETRO_DRIVE: no port " & $port & " (" & why & ")"
      return 0
    listenFd = fd
    accessKeep = true
    beginFrameHooks.add driveFrame
    idlePollers.add drivePoll
    drivePortNow

  block:
    # (a script of steps from the command line: RETRO_SCRIPT, its picture RETRO_SNAPSHOT --
    # the window in memory, nothing shown --, RETRO_PLAY played in the window as a person would)
    let play = getEnv("RETRO_PLAY")
    let script = getEnv("RETRO_SCRIPT")
    let shot = getEnv("RETRO_SNAPSHOT")
    if play.len > 0 or script.len > 0 or shot.len > 0:
      if shot.len > 0 and play.len == 0:
        var (w, h) = (1280, 800)
        let size = getEnv("RETRO_SIZE").split('x')
        if size.len == 2:
          try: (w, h) = (parseInt(size[0]), parseInt(size[1])) except ValueError: discard
        useHeadless(w, h)
      let why = startScript(if play.len > 0: play else: script, play = play.len > 0,
                            snapshot = if play.len > 0: "" else: shot)
      if why.len > 0:
        stderr.writeLine "RETRO_SCRIPT: " & why
        quit(2)
  block:
    let v = getEnv("RETRO_DRIVE")
    if v.len > 0:
      let p = try: parseInt(v) except ValueError: -1
      if p in 0 .. 65535:
        let got = startDriver(p)
        if got > 0: stderr.writeLine "RETRO_DRIVE: listening on 127.0.0.1:" & $got
      else:
        stderr.writeLine "RETRO_DRIVE: not a port: " & v
else:
  proc startDriver*(port: int): int = 0
    ## (no sockets in a web page)

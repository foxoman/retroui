## The other end of the driver (`retroui/drive`): connect to an app
## started with RETRO_DRIVE=PORT and send it commands -- from a test, a
## tool, `retrokit drive`. No window and no toolkit here: any program can
## import it.
##
## .. code-block:: nim
##   import retroui/driveclient
##   let app = driveConnect(7000)
##   discard app.ask(%*{"cmd": "click", "name": "New", "role": "button"})
##   discard app.ask(request(["type", "Shopping list"]))
##   echo app.ask(request(["find", "Title:"]))["node"]["value"]
##   app.close()
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, strutils, net, nativesockets, monotimes, times, os]
from std/unicode import runeLen, runeSubStr

type
  DriveClient* = ref object
    ## A connection to a driven app.
    sock: Socket
    buf: string
    next: int                   # the next command's id

  DriveError* = object of CatchableError
    ## The app could not be reached, or did not answer in time.

proc driveConnect*(port: int; host = "127.0.0.1"; timeoutMs = 10000): DriveClient =
  ## Connect to the app driven on `port`, trying until `timeoutMs` (an app
  ## just started takes a moment to listen).
  let t0 = getMonoTime()
  while true:
    try:
      let s = newSocket(buffered = false)
      s.connect(host, Port(port))
      return DriveClient(sock: s)
    except OSError as e:
      if (getMonoTime() - t0).inMilliseconds > timeoutMs:
        raise newException(DriveError, "no app driven on " & host & ":" & $port & " (" &
                           e.msg & ")")
      sleep(100)

proc close*(c: DriveClient) =
  ## The connection closed (the app goes on).
  try: c.sock.close() except CatchableError: discard

proc send*(c: DriveClient; req: JsonNode) =
  ## A command sent, without waiting for its answer (`reply`).
  try: c.sock.send($req & "\n")
  except OSError as e: raise newException(DriveError, "the app is gone (" & e.msg & ")")

proc reply*(c: DriveClient; timeoutMs = 30000; idle: proc () = nil): JsonNode =
  ## The next answer. `idle` is called while none is there -- a test that
  ## runs the app's frames itself, in the same program -- else it waits.
  let t0 = getMonoTime()
  while true:
    let nl = c.buf.find('\n')
    if nl >= 0:
      let line = c.buf[0 ..< nl]
      c.buf = c.buf[nl + 1 .. ^1]
      try: return parseJson(line)
      except CatchableError: raise newException(DriveError, "not an answer: " & line)
    if (getMonoTime() - t0).inMilliseconds > timeoutMs:
      raise newException(DriveError, "no answer in " & $timeoutMs & " ms")
    var fds = @[c.sock.getFd]
    if selectRead(fds, if idle == nil: 100 else: 0) > 0:
      var chunk = newString(65536)
      let n = c.sock.recv(addr chunk[0], chunk.len)
      if n <= 0: raise newException(DriveError, "the app closed the connection")
      chunk.setLen(n)
      c.buf.add chunk
    elif idle != nil: idle()

proc ask*(c: DriveClient; req: JsonNode; timeoutMs = 30000; idle: proc () = nil): JsonNode =
  ## A command sent and its answer (`ok`, and `error` when it is false).
  var r = req
  if r.kind == JObject and not r.hasKey("id"):
    r = copy(req)
    inc c.next
    r["id"] = %c.next
  c.send(r)
  while true:
    result = c.reply(timeoutMs, idle)
    if not r.hasKey("id") or not result.hasKey("id") or result["id"] == r["id"]: return

proc request*(words: openArray[string]): JsonNode =
  ## A command from words, as `retrokit drive` takes them:
  ##
  ## - `tree`, `info`, `quit`
  ## - `find NAME`, `press NAME`, `focus NAME`
  ## - `click NAME` or `click X,Y` (`--right`, `--double`, `--finger`)
  ## - `move NAME`, `scroll NAME LINES` (up > 0)
  ## - `set NAME VALUE`, `key ctrl+s`, `type TEXT`
  ## - `wait MS`, `wait --frames N`, `wait NAME [--gone] [--timeout MS]`
  ##
  ## and after a name `--role R` (button, textField, menuItem...), `--nth N`.
  ## A word that starts with `{` is a command in JSON.
  if words.len == 0: return %*{"cmd": "info"}
  if words[0].startsWith("{"): return parseJson(words.join(" "))
  result = %*{"cmd": words[0].toLowerAscii}
  var free: seq[string]
  var i = 1
  while i < words.len:
    let w = words[i]
    if w.startsWith("--"):
      var k = w[2 .. ^1]
      var v = ""
      let eq = k.find({'=', ':'})
      if eq >= 0:
        v = k[eq + 1 .. ^1]
        k = k[0 ..< eq]
      case k
      of "right": result["button"] = %"right"
      of "middle": result["button"] = %"middle"
      of "double": result["clicks"] = %2
      of "finger": result["finger"] = %true
      of "gone": result["gone"] = %true
      of "role", "nth", "timeout", "frames", "index":
        if v.len == 0 and i + 1 < words.len:
          inc i
          v = words[i]
        if k == "role": result[k] = %v
        else: result[k] = %(try: parseInt(v) except ValueError: 0)
      else: raise newException(ValueError, "no option --" & k)
    else: free.add w
    inc i
  let cmd = result["cmd"].getStr
  template place(s: string) =
    let p = s.split(',')
    if p.len == 2 and p[0].strip.allCharsInSet(Digits) and p[1].strip.allCharsInSet(Digits) and
       p[0].strip.len > 0 and p[1].strip.len > 0:
      result["x"] = %parseInt(p[0].strip)
      result["y"] = %parseInt(p[1].strip)
    else: result["name"] = %s
  case cmd
  of "type":
    result["text"] = %free.join(" ")
  of "key":
    if free.len > 0: result["key"] = %free[0]
  of "set":
    if free.len > 0: result["name"] = %free[0]
    if free.len > 1: result["value"] = %free[1 .. ^1].join(" ")
  of "scroll":
    if free.len > 0: place(free[0])
    if free.len > 1: result["lines"] = %(try: parseInt(free[1]) except ValueError: -3)
  of "wait":
    if free.len > 0:
      if free[0].allCharsInSet(Digits): result["ms"] = %parseInt(free[0])
      else: result["name"] = %free[0]
  of "click", "move":
    if free.len > 0: place(free[0])
  else:
    if free.len > 0: result["name"] = %free[0]

proc describe*(n: JsonNode): string =
  ## A node of an answer as one line: `Button "OK" at 8,38 72x24 (focused)`.
  if n == nil or n.kind != JObject: return ""
  var role = n{"role"}.getStr
  if role.len > 0: role[0] = role[0].toUpperAscii
  result = role
  if n{"name"}.getStr.len > 0: result.add " \"" & n{"name"}.getStr & "\""
  var v = n{"value"}.getStr.strip.replace("\r", "").replace("\n", " / ")
  if v.runeLen > 60: v = v.runeSubStr(0, 57) & "..."
  if v.len > 0: result.add " = " & v
  result.add " at " & $n{"x"}.getInt & "," & $n{"y"}.getInt & " " & $n{"w"}.getInt & "x" &
             $n{"h"}.getInt
  if n.hasKey("states"):
    var st: seq[string]
    for s in n["states"]: st.add s.getStr
    result.add " (" & st.join(", ") & ")"

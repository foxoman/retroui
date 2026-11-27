## The VPN (glue/java/.../DnsVpn.java), from Nim by reflection
## (retroui/native). The Java is in the APK only when retroapk was given it
## (--java:examples/retrodns/glue: build.sh and the kit's builds do); without
## it `vpnStatus().present` is false. The VPN
## runs in a small process of its own; these calls reach it from the app's.

import std/strutils
import retroui/native
import catalog

const VpnClass = "net.foxoman.retrodns.DnsVpn"

type
  VpnState* = enum vsOff, vsStarting, vsOn, vsFailed
  VpnStatus* = object
    present*: bool        ## this APK has the VPN (retroapk's --java put it in)
    state*: VpnState
    server*, mode*: string
    answered*, failed*: int
    avgMs*: int           ## -1: no answer yet
    asking*: bool         ## Android's consent dialog was shown
    error*: string
    lastFailure*: string  ## why the last lookup failed, in plain words ("it timed out")
    memKb*: int           ## the VPN process's memory (Android's count), 0: unknown
    getsPast*: string     ## how it gets past a network that cut its hello ("its hello sent in
                          ## pieces", "no server name sent"; "": not needed)
    switched*: string     ## why it went on to another server (Switch When a Server Stops Answering)
    blockedNames*: int    ## lookups the block list answered with no such name

proc toInt(s: string; default = 0): int =
  try: parseInt(s.strip) except ValueError: default

proc vpnStatus*(): VpnStatus =
  if not javaAvailable(): return
  let s = javaStatic(VpnClass, "status", jactivity())
  if javaError().len > 0: return
  let f = s.split('\t')
  if f.len < 9: return
  result.present = true
  result.state = VpnState(clamp(toInt(f[0]), 0, 3))
  result.server = f[1]
  result.mode = f[2]
  result.answered = toInt(f[3])
  result.failed = toInt(f[4])
  result.avgMs = toInt(f[5], -1)
  result.asking = f[6] == "1"
  result.error = f[7]
  result.lastFailure = f[8]
  if f.len > 9: result.memKb = toInt(f[9])
  if f.len > 12:
    result.getsPast = f[10]
    result.switched = f[11]
    result.blockedNames = toInt(f[12])

proc vpnRecent*(): seq[tuple[app, name: string; count, agoMs: int]] =
  ## What the VPN looked up lately, the newest last: which app asked (its package; "" before
  ## Android 10, which does not say), the name, how often, how long ago.
  if not javaAvailable(): return
  let s = javaStatic(VpnClass, "recent", jactivity())
  if javaError().len > 0: return
  for line in s.splitLines:
    let f = line.split('\t')
    if f.len >= 4: result.add (f[0], f[1], toInt(f[2]), toInt(f[3]))

proc vpnAllowed*(): bool =
  ## Android has allowed this app's VPN already (no dialog on connect).
  javaAvailable() and javaStatic(VpnClass, "prepared", jactivity()) == "true"

proc vpnConnect*(config: string): string =
  ## "starting", "asking" (Android's consent dialog is up: call again when
  ## the app is back), or "error\t<why>".
  if not javaAvailable(): return "error\tthe VPN is in the Android app only"
  onUiThread:
    result = javaStatic(VpnClass, "connect", jactivity(), config)
    if javaError().len > 0: result = "error\t" & javaError()

proc vpnDisconnect*() =
  if javaAvailable():
    onUiThread:
      discard javaStatic(VpnClass, "disconnect", jactivity())

proc vpnReady*(s: Server): bool = s.doh.len + s.dot.len > 0
  ## `s` has encrypted DNS, which the VPN sends lookups with (Google Play
  ## wants what a VPN sends from the device encrypted).

proc vpnMode*(s: Server; prefer = ""): string =
  ## How the VPN reaches `s`: "doh" (DNS over HTTPS) or "dot" (DNS over TLS) -- `prefer`'s when
  ## `s` has it ("doh", "dot"; "": HTTPS when it has it, else TLS).
  if prefer == "dot" and s.dot.len > 0: "dot"
  elif prefer == "doh" and s.doh.len > 0: "doh"
  elif s.doh.len > 0: "doh"
  else: "dot"

proc vpnConfig*(s: Server; next: openArray[Server] = []; blocks: openArray[string] = [];
                prefer = ""): string =
  ## The VPN's settings for `s`: DNS over HTTPS when it has it, else TLS (`prefer`: "doh" or
  ## "dot" first, where the server has it: `vpnMode`), and an address of it (no server name
  ## sent, where its certificate allows); then the servers it goes on to when `s` stops
  ## answering, after "---" lines; then the block list ("block=name", "block=!name" an
  ## exception).
  proc one(s: Server): string =
    "name=" & s.name & "\nmode=" & vpnMode(s, prefer) &
      "\ndoh=" & s.doh & "\ndot=" & s.dot & "\nip=" & (if s.ipv4.len > 0: s.ipv4[0] else: "") & "\n"
  result = one(s)
  for n in next:
    if vpnReady(n) and n.name != s.name: result.add "---\n" & one(n)
  for b in blocks: result.add "block=" & b & "\n"

proc blockLines*(text: string): seq[string] =
  ## A block list's names: a line each, "!name" an exception, "#" a remark; "0.0.0.0 name" and
  ## "127.0.0.1 name" (a hosts file's lines) read as the name.
  for raw in text.splitLines:
    var l = raw
    let hash = l.find('#')
    if hash >= 0: l = l[0 ..< hash]
    var parts = l.splitWhitespace
    if parts.len == 2 and parts[0] in ["0.0.0.0", "127.0.0.1", "::", "::1"]: parts = parts[1 .. 1]
    if parts.len != 1: continue
    let n = parts[0].toLowerAscii.strip(chars = {'.'})
    let bare = if n.startsWith("!"): n[1 .. ^1] else: n
    if bare.len > 0 and bare.allCharsInSet({'a'..'z', '0'..'9', '-', '.', '_'}): result.add n

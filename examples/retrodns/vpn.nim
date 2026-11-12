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
    memKb*: int           ## the VPN process's memory (Android's count), 0: unknown

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
  if f.len > 9: result.memKb = toInt(f[9])

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

proc vpnConfig*(s: Server): string =
  ## The VPN's settings for `s`: DNS over HTTPS when it has it, else TLS.
  "name=" & s.name & "\nmode=" & (if s.doh.len > 0: "doh" else: "dot") &
    "\ndoh=" & s.doh & "\ndot=" & s.dot & "\n"

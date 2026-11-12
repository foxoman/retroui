## Retro DNS on a computer: the DNS servers of the whole computer changed,
## the system asking for its administrator first (retroui/admin) --
##
## * Windows: every network adapter's servers (PowerShell's
##   Set-DnsClientServerAddress), and DNS over HTTPS for them where Windows
##   11 has it
## * Linux and the BSDs: NetworkManager's connections (nmcli), with DNS over
##   TLS where systemd-resolved does it; or systemd-resolved alone
##   (resolvectl, until the network reconnects)
## * macOS: every network service's servers (networksetup), for a server
##   with plain DNS only
##
## -- and on macOS and iOS a profile of encrypted DNS (DNS over HTTPS or
## TLS), which the system's Settings installs when the user agrees (no
## administrator: Settings asks itself).
##
## The scripts are made of the server's addresses and DoH address only,
## each checked first (`goodIpv4`, `goodIpv6`, `goodDohUrl`): a server
## imported from a CSV file can put nothing else in them.

import std/[strutils, os, base64]
import retroui/rsa
import retroui/uirelays/target
import catalog
when not (androidApp or defined(ios) or defined(wasm) or defined(js)): import retroui/admin

type
  HereWay* = enum
    ## How Retro DNS gives a server to this device.
    hwNone        ## it cannot here (a web page; a server with nothing usable)
    hwVpn         ## Android: its own VPN (vpn.nim)
    hwSystem      ## the computer's DNS servers, as its administrator
    hwProfile     ## macOS, iOS: a profile of encrypted DNS, installed by Settings

proc addrsOf*(s: Server): seq[string] =
  ## `s`'s addresses that are well formed, IPv4 first.
  for a in s.ipv4:
    if goodIpv4(a): result.add a
  for a in s.ipv6:
    if goodIpv6(a): result.add a

proc encrypted(s: Server): bool =
  goodDohUrl(s.doh) or goodHost(s.dot)

proc hereWay*(s: Server): HereWay =
  ## How `s` is used on this device (and whether it can be).
  when androidApp: hwVpn
  elif defined(ios):
    if encrypted(s): hwProfile else: hwNone
  elif defined(wasm) or defined(js): hwNone
  elif defined(macosx):
    if encrypted(s): hwProfile
    elif addrsOf(s).len > 0 and canRunAsAdmin(): hwSystem
    else: hwNone
  else:
    if addrsOf(s).len > 0 and canRunAsAdmin(): hwSystem else: hwNone

# ---- the scripts --------------------------------------------------------------------------------

proc psText(s: string): string = "'" & s.replace("'", "''") & "'"
  ## (`s` as a PowerShell string in single quotes)

proc windowsScript*(s: Server; errFile: string): string =
  ## PowerShell that gives every network adapter `s`'s addresses (and their
  ## DoH address, where Windows 11 knows DoH), as the administrator.
  var list: seq[string]
  for a in addrsOf(s): list.add psText(a)
  let doh = if goodDohUrl(s.doh): s.doh else: ""
  "$ErrorActionPreference = 'Stop'\n" &
  "trap { $_ | Out-File -Encoding utf8 -FilePath " & psText(errFile) & "; exit 1 }\n" &
  "$dns = @(" & list.join(",") & ")\n" &
  "$doh = " & psText(doh) & "\n" &
  "$ads = @(Get-NetAdapter -Physical)\n" &
  "if ($ads.Count -eq 0) { $ads = @(Get-NetAdapter | Where-Object Status -eq 'Up') }\n" &
  "if ($doh -ne '' -and (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)) {\n" &
  "  foreach ($ip in $dns) {\n" &
  "    if (Get-DnsClientDohServerAddress -ServerAddress $ip -ErrorAction SilentlyContinue) {\n" &
  "      Set-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $doh -AllowFallbackToUdp $true -AutoUpgrade $true\n" &
  "    } else {\n" &
  "      Add-DnsClientDohServerAddress -ServerAddress $ip -DohTemplate $doh -AllowFallbackToUdp $true -AutoUpgrade $true\n" &
  "    }\n" &
  "  }\n" &
  "}\n" &
  "foreach ($a in $ads) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $dns }\n" &
  "Clear-DnsClientCache\n" &
  "exit 0\n"

proc windowsResetScript*(errFile: string): string =
  ## PowerShell that gives every adapter its network's own DNS again.
  "$ErrorActionPreference = 'Stop'\n" &
  "trap { $_ | Out-File -Encoding utf8 -FilePath " & psText(errFile) & "; exit 1 }\n" &
  "$ads = @(Get-NetAdapter -Physical)\n" &
  "if ($ads.Count -eq 0) { $ads = @(Get-NetAdapter | Where-Object Status -eq 'Up') }\n" &
  "foreach ($a in $ads) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses }\n" &
  "Clear-DnsClientCache\n" &
  "exit 0\n"

const LinuxConnections =
  "nmcli -t -f UUID,TYPE connection show --active | " &
  "awk -F: '$2 !~ /loopback|bridge|tun|vpn|wireguard|bond|dummy|veth/ {print $1}'"
  ## (NetworkManager's connections out to the network)
const LinuxDevice =
  "ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == \"dev\") {print $(i + 1); exit}}'"
  ## (the device of the default route, for resolvectl)

proc linuxScript*(s: Server): string =
  ## sh that gives NetworkManager's connections `s`'s addresses (DNS over TLS
  ## when the server has it and the system can), else systemd-resolved's
  ## device of the default route; as root.
  var v4, v6: seq[string]
  for a in addrsOf(s):
    if ':' in a: v6.add a else: v4.add a
  let tls = if goodHost(s.dot): "opportunistic" else: "no"
  "ok=0\n" &
  "if command -v nmcli >/dev/null 2>&1; then\n" &
  "  for c in $(" & LinuxConnections & "); do\n" &
  "    nmcli connection modify \"$c\" ipv4.dns '" & v4.join(" ") & "' ipv4.ignore-auto-dns yes " &
    "ipv6.dns '" & v6.join(" ") & "' ipv6.ignore-auto-dns yes || exit 2\n" &
  "    nmcli connection modify \"$c\" connection.dns-over-tls " &
    (if tls == "no": "default" else: tls) & " 2>/dev/null\n" &
  "    d=$(nmcli -g GENERAL.DEVICES connection show \"$c\")\n" &
  "    nmcli device reapply \"$d\" 2>/dev/null || nmcli connection up \"$c\" >/dev/null\n" &
  "    ok=1\n" &
  "  done\n" &
  "fi\n" &
  "if [ $ok = 0 ] && command -v resolvectl >/dev/null 2>&1; then\n" &
  "  d=$(" & LinuxDevice & ")\n" &
  "  [ -n \"$d\" ] || { echo 'no network is connected'; exit 3; }\n" &
  "  resolvectl dns \"$d\" " & (v4 & v6).join(" ") & " || exit 2\n" &
  "  resolvectl dnsovertls \"$d\" " & tls & "\n" &
  "  resolvectl domain \"$d\" '~.'\n" &
  "  resolvectl flush-caches\n" &
  "  ok=1\n" &
  "fi\n" &
  "[ $ok = 1 ] || { echo 'neither NetworkManager nor systemd-resolved is here'; exit 3; }\n"

proc linuxResetScript*(): string =
  ## sh that gives the connections their network's own DNS again; as root.
  "ok=0\n" &
  "if command -v nmcli >/dev/null 2>&1; then\n" &
  "  for c in $(" & LinuxConnections & "); do\n" &
  "    nmcli connection modify \"$c\" ipv4.dns '' ipv4.ignore-auto-dns no " &
    "ipv6.dns '' ipv6.ignore-auto-dns no || exit 2\n" &
  "    nmcli connection modify \"$c\" connection.dns-over-tls default 2>/dev/null\n" &
  "    d=$(nmcli -g GENERAL.DEVICES connection show \"$c\")\n" &
  "    nmcli device reapply \"$d\" 2>/dev/null || nmcli connection up \"$c\" >/dev/null\n" &
  "    ok=1\n" &
  "  done\n" &
  "fi\n" &
  "if [ $ok = 0 ] && command -v resolvectl >/dev/null 2>&1; then\n" &
  "  d=$(" & LinuxDevice & ")\n" &
  "  [ -n \"$d\" ] && resolvectl revert \"$d\"\n" &
  "  ok=1\n" &
  "fi\n" &
  "[ $ok = 1 ] || { echo 'neither NetworkManager nor systemd-resolved is here'; exit 3; }\n"

const MacServices =
  "networksetup -listallnetworkservices | tail -n +2 | grep -v '^\\*' | while IFS= read -r s; do "
  ## (every network service that is on)

proc macScript*(s: Server): string =
  ## sh that gives every network service of the Mac `s`'s addresses; as root.
  MacServices & "networksetup -setdnsservers \"$s\" " & addrsOf(s).join(" ") & "; done\n" &
  "dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null; exit 0\n"

proc macResetScript*(): string =
  ## sh that gives them their network's own DNS again; as root.
  MacServices & "networksetup -setdnsservers \"$s\" Empty; done\n" &
  "dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null; exit 0\n"

proc encodedCommand*(script: string): string =
  ## `script` as PowerShell's -EncodedCommand takes it (UTF-16 LE, base64).
  var units = newStringOfCap(script.len * 2)
  for c in script:
    units.add c
    units.add '\0'
  base64.encode(units)

proc adminCommand*(script: string): (string, seq[string]) =
  ## The program and its words that run `script` (PowerShell on Windows,
  ## sh elsewhere).
  when defined(windows):
    ("powershell.exe", @["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                         "-WindowStyle", "Hidden", "-EncodedCommand", encodedCommand(script)])
  else:
    ("/bin/sh", @["-c", script])

proc useScript*(s: Server; errFile: string): string =
  ## This system's script that gives the computer `s`'s addresses.
  when defined(windows): windowsScript(s, errFile)
  elif defined(macosx): macScript(s)
  else: linuxScript(s)

proc resetScript*(errFile: string): string =
  ## This system's script that gives it its network's own DNS again.
  when defined(windows): windowsResetScript(errFile)
  elif defined(macosx): macResetScript()
  else: linuxResetScript()

# ---- a profile of encrypted DNS (macOS, iOS) -----------------------------------------------------

proc xmlText(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc uuidOf*(text: string): string =
  ## A UUID that is always the same for `text` (so a profile installed again
  ## replaces the one before).
  var b: seq[byte]
  for c in text: b.add byte(c)
  let d = sha256(b)
  var h = ""
  for i in 0 ..< 16:
    var x = d[i]
    if i == 6: x = (x and 0x0F) or 0x50          # (version 5)
    if i == 8: x = (x and 0x3F) or 0x80          # (variant 1)
    h.add toHex(int(x), 2)
  h[0 ..< 8] & "-" & h[8 ..< 12] & "-" & h[12 ..< 16] & "-" & h[16 ..< 20] & "-" & h[20 ..< 32]

proc mobileConfig*(s: Server): string =
  ## An Apple configuration profile that sends the device's lookups to `s`,
  ## encrypted: DNS over HTTPS when it has it, else over TLS.
  let name = "Retro DNS: " & s.name
  var addrs = ""
  for a in addrsOf(s): addrs.add "<string>" & a & "</string>"
  let dns =
    if goodDohUrl(s.doh):
      "<key>DNSProtocol</key><string>HTTPS</string><key>ServerURL</key><string>" &
        xmlText(s.doh) & "</string>"
    else:
      "<key>DNSProtocol</key><string>TLS</string><key>ServerName</key><string>" &
        xmlText(s.dot) & "</string>"
  let key = s.key.multiReplace((":", "."), (" ", "-"))
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
  "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" &
  "<plist version=\"1.0\"><dict>\n" &
  "<key>PayloadContent</key><array><dict>\n" &
  "<key>DNSSettings</key><dict>" & dns &
    (if addrs.len > 0: "<key>ServerAddresses</key><array>" & addrs & "</array>" else: "") &
    "</dict>\n" &
  "<key>PayloadDisplayName</key><string>" & xmlText(name) & "</string>\n" &
  "<key>PayloadIdentifier</key><string>net.foxoman.retrodns.dns." & xmlText(key) & "</string>\n" &
  "<key>PayloadType</key><string>com.apple.dnsSettings.managed</string>\n" &
  "<key>PayloadUUID</key><string>" & uuidOf("dns " & s.key) & "</string>\n" &
  "<key>PayloadVersion</key><integer>1</integer>\n" &
  "</dict></array>\n" &
  "<key>PayloadDescription</key><string>The DNS server " & xmlText(s.name) &
    ", encrypted, for every app (Retro DNS).</string>\n" &
  "<key>PayloadDisplayName</key><string>" & xmlText(name) & "</string>\n" &
  "<key>PayloadIdentifier</key><string>net.foxoman.retrodns." & xmlText(key) & "</string>\n" &
  "<key>PayloadRemovalDisallowed</key><false/>\n" &
  "<key>PayloadType</key><string>Configuration</string>\n" &
  "<key>PayloadUUID</key><string>" & uuidOf("profile " & s.key) & "</string>\n" &
  "<key>PayloadVersion</key><integer>1</integer>\n" &
  "</dict></plist>\n"

proc profilePath*(dir: string; s: Server): string =
  ## Where `s`'s profile is written, in `dir`.
  var safe = ""
  for c in s.name:
    safe.add(if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_'}: c else: '-')
  dir / "RetroDNS-" & safe & ".mobileconfig"

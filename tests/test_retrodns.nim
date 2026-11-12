## Retro DNS (examples/retrodns): its servers well formed, the user's own
## kept as CSV, the VPN's settings, and the scripts that change a computer's
## DNS -- made of checked addresses only, whatever a CSV file holds -- and
## the profile of encrypted DNS for macOS and iOS.

import std/[strutils, base64, sets, os]
import retroui/charts
import ../examples/retrodns/[catalog, vpn, desktop]

let all = builtinServers()

block servers:
  doAssert all.len >= 40
  var keys: HashSet[string]
  for s in all:
    doAssert s.key.startsWith("b:") and s.key notin keys, s.key
    keys.incl s.key
    doAssert s.group in Groups, s.name
    doAssert s.name.len > 0 and s.note.len > 20, s.name
    doAssert s.dot.len + s.doh.len + s.ipv4.len + s.ipv6.len > 0, s.name
    if s.doh.len > 0: doAssert goodDohUrl(s.doh), s.name & ": " & s.doh
    if s.dot.len > 0: doAssert goodHost(s.dot), s.name & ": " & s.dot
    for a in s.ipv4: doAssert goodIpv4(a), s.name & ": " & a
    for a in s.ipv6: doAssert goodIpv6(a), s.name & ": " & a
    doAssert vpnReady(s) == (s.doh.len + s.dot.len > 0)

block addressChecks:
  doAssert goodIpv4("1.1.1.1") and not goodIpv4("1.1.1") and not goodIpv4("256.1.1.1")
  doAssert not goodIpv4("1.1.1.1;reboot")
  doAssert goodIpv6("2606:4700:4700::1111") and not goodIpv6("::1 && x") and not goodIpv6("abc")
  doAssert goodDohUrl("https://dns.google/dns-query")
  doAssert not goodDohUrl("http://dns.google/dns-query"), "https only"
  doAssert not goodDohUrl("https://x.example/'; Remove-Item C:\\"), "nothing a script reads"
  doAssert goodHost("dns.quad9.net") and not goodHost("dns quad9") and not goodHost(".x.net")

block yourOwnServers:
  let mine = Server(key: customKey("Home", "dns.home.example"), name: "Home", group: "Mine",
                    dot: "dns.home.example", doh: "https://dns.home.example/dns-query",
                    ipv4: @["192.168.1.2"], ipv6: @["fd00::2"], note: "My router, with its own filter",
                    plain: true, custom: true)
  let back = fromTable(parseCsv(toCsv(serversTable([mine]))))
  doAssert back.len == 1
  let b = back[0]
  doAssert b.name == "Home" and b.dot == mine.dot and b.doh == mine.doh and b.custom
  doAssert b.ipv4 == mine.ipv4 and b.ipv6 == mine.ipv6 and b.note == mine.note
  doAssert b.key == mine.key
  doAssert splitAddrs("1.1.1.1, 1.0.0.1;9.9.9.9") == @["1.1.1.1", "1.0.0.1", "9.9.9.9"]

block vpnSettings:
  var cf: Server
  for s in all:
    if s.key == "b:cloudflare": cf = s
  doAssert cf.name == "Cloudflare"
  doAssert vpnConfig(cf) == "name=Cloudflare\nmode=doh\ndoh=https://cloudflare-dns.com/dns-query" &
                            "\ndot=one.one.one.one\n"
  let tlsOnly = Server(name: "T", dot: "dns.example.com")
  doAssert "mode=dot" in vpnConfig(tlsOnly)

# a server out of a CSV file someone sent: every field tries to get into a script
let bad = Server(key: "c:bad", name: "Bad'\"<x>", group: "Mine",
                 dot: "dns.example.com; reboot", doh: "https://x.example/'); Remove-Item C:\\ -Recurse #",
                 ipv4: @["1.1.1.1", "8.8.8.8; rm -rf /", "$(reboot)"],
                 ipv6: @["2606:4700::1111", "::1' || reboot '"], custom: true)
let cloudflare = block:
  var r: Server
  for s in all:
    if s.key == "b:cloudflare": r = s
  r

block computerScripts:
  doAssert addrsOf(bad) == @["1.1.1.1", "2606:4700::1111"], "only well-formed addresses"
  for script in [windowsScript(bad, "C:\\Users\\me\\err.txt"), linuxScript(bad), macScript(bad)]:
    for evil in ["rm -rf", "reboot", "Remove-Item", "dns.example.com", "Bad"]:
      doAssert evil notin script, evil & " in\n" & script
  # Windows: every adapter, with DoH where Windows has it
  let w = windowsScript(cloudflare, "C:\\Users\\O'Neil\\err.txt")
  doAssert "$dns = @('1.1.1.1','1.0.0.1','2606:4700:4700::1111','2606:4700:4700::1001')" in w
  doAssert "$doh = 'https://cloudflare-dns.com/dns-query'" in w
  doAssert "Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $dns" in w
  doAssert "'C:\\Users\\O''Neil\\err.txt'" in w, "a quote in a path doubled"
  doAssert "-ResetServerAddresses" in windowsResetScript("e.txt")
  # PowerShell's -EncodedCommand: the script as UTF-16 LE, base64
  let enc = decode(encodedCommand(w))
  var back = ""
  for i in countup(0, enc.len - 2, 2):
    doAssert enc[i + 1] == '\0'
    back.add enc[i]
  doAssert back == w
  # Linux: NetworkManager's connections, DNS over TLS when the server has it
  let l = linuxScript(cloudflare)
  doAssert "ipv4.dns '1.1.1.1 1.0.0.1' ipv4.ignore-auto-dns yes" in l
  doAssert "ipv6.dns '2606:4700:4700::1111 2606:4700:4700::1001'" in l
  doAssert "connection.dns-over-tls opportunistic" in l and "resolvectl dnsovertls \"$d\" opportunistic" in l
  let plain = Server(name: "P", ipv4: @["95.85.95.85"])
  doAssert "connection.dns-over-tls default" in linuxScript(plain)
  doAssert "ipv4.ignore-auto-dns no" in linuxResetScript() and "resolvectl revert" in linuxResetScript()
  # macOS: every network service
  doAssert "networksetup -setdnsservers \"$s\" 1.1.1.1 1.0.0.1 2606:4700:4700::1111" in macScript(cloudflare)
  doAssert "-setdnsservers \"$s\" Empty" in macResetScript()
  when defined(windows):
    doAssert adminCommand("x")[0] == "powershell.exe"
  else:
    doAssert adminCommand("echo hi") == ("/bin/sh", @["-c", "echo hi"])

block appleProfile:
  let p = mobileConfig(cloudflare)
  doAssert p.startsWith("<?xml") and p.endsWith("</dict></plist>\n")
  doAssert "<key>DNSProtocol</key><string>HTTPS</string>" in p
  doAssert "<key>ServerURL</key><string>https://cloudflare-dns.com/dns-query</string>" in p
  doAssert "<string>1.1.1.1</string>" in p
  doAssert "com.apple.dnsSettings.managed" in p and "<string>Configuration</string>" in p
  doAssert p.count("<dict>") == p.count("</dict>") and p.count("<array>") == p.count("</array>")
  let t = mobileConfig(Server(key: "c:t", name: "A & B <tls>", dot: "dns.example.com"))
  doAssert "<string>TLS</string><key>ServerName</key><string>dns.example.com</string>" in t
  doAssert "A &amp; B &lt;tls&gt;" in t and "<tls>" notin t
  let u = uuidOf("dns b:cloudflare")
  doAssert u == uuidOf("dns b:cloudflare") and u != uuidOf("dns b:google")
  doAssert u.len == 36 and u[8] == '-' and u[14] == '5' and u[19] in {'8', '9', 'A', 'B'}
  doAssert profilePath("dir", Server(name: "Quad9 (ECS)")) == "dir" / "RetroDNS-Quad9--ECS-.mobileconfig"

block thisComputer:
  # (macOS: a profile for an encrypted server; Windows and Linux: the
  # computer's own DNS, when its administrator can be asked)
  let w = hereWay(cloudflare)
  when defined(macosx): doAssert w == hwProfile
  else: doAssert w in {hwSystem, hwNone}
  doAssert hereWay(Server(name: "nothing")) == hwNone

echo "test_retrodns: ok"

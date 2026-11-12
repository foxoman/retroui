## The DNS servers Retro DNS knows, and the user's own (kept as CSV).
##
## Addresses checked against the providers' own pages and well-sourced
## lists in November 2026. Gone and left out: Mullvad DNS (closed
## 2 November 2026) and dns0.eu (closed October 2025).
##
## The VPN sends lookups to a server's DoH address, else to its DNS-over-TLS
## host (`dot`, also what Android's Private DNS setting takes). Servers with
## neither are kept for their addresses (Wi-Fi, a router).

import std/[strutils, sequtils]
import retroui/charts            # DataTable, parseCsv, readCsv, writeCsv

type
  Server* = object
    key*: string          ## stable id: "b:..." built in, "c:..." the user's
    name*: string
    group*: string        ## one of `Groups`
    note*: string         ## what it is good for
    dot*: string          ## Private DNS host name (DNS over TLS)
    doh*: string          ## DNS over HTTPS address
    ipv4*: seq[string]
    ipv6*: seq[string]
    plain*: bool          ## answers plain DNS on port 53
    custom*: bool         ## added by the user

const Groups* = ["Fast", "Privacy", "Security", "Ad-block", "Family",
                 "Unfiltered", "Regional", "Mine"]

proc goodHost*(h: string): bool =
  ## `h` is a host name such as dns.example.com.
  h.len >= 4 and '.' in h and h[0] != '.' and h[^1] != '.' and
    h.allIt(it in {'a'..'z', '0'..'9', '-', '.'})

proc goodIpv4*(s: string): bool =
  ## `s` is an IPv4 address (1.1.1.1).
  let parts = s.split('.')
  if parts.len != 4: return false
  for p in parts:
    if p.len == 0 or p.len > 3 or not p.allIt(it in Digits): return false
    if parseInt(p) > 255: return false
  true

proc goodIpv6*(s: string): bool =
  ## `s` looks like an IPv6 address (2606:4700::1111): hex digits and colons.
  s.len in 2 .. 45 and ':' in s and s.allIt(it in HexDigits or it in {':', '.'})

proc goodDohUrl*(s: string): bool =
  ## `s` is a DNS-over-HTTPS address (https://dns.example/dns-query) of the
  ## letters a URL needs, nothing a script would read otherwise.
  s.startsWith("https://") and s.len in 12 .. 300 and
    s.allIt(it in {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', ':', '/', '?', '=', '&', '%', '+'})

proc splitAddrs*(s: string): seq[string] =
  ## "1.1.1.1, 1.0.0.1" or "1.1.1.1 1.0.0.1" as a list.
  s.split({' ', ',', ';', '\t', '\n', '\r'}).filterIt(it.len > 0)

proc b(key, name, group, dot, doh, ipv4, ipv6, note: string; plain = true): Server =
  Server(key: "b:" & key, name: name, group: group, dot: dot, doh: doh,
         ipv4: splitAddrs(ipv4), ipv6: splitAddrs(ipv6), note: note, plain: plain)

proc builtinServers*(): seq[Server] =
  @[
    # ---- Fast ----
    b("cloudflare", "Cloudflare", "Fast",
      "one.one.one.one", "https://cloudflare-dns.com/dns-query",
      "1.1.1.1 1.0.0.1", "2606:4700:4700::1111 2606:4700:4700::1001",
      "One of the fastest resolvers in most countries, on a worldwide network. " &
      "Cloudflare says it never sells your lookups or uses them for ads, and wipes " &
      "its logs within a day. A good first choice."),
    b("google", "Google Public DNS", "Fast",
      "dns.google", "https://dns.google/dns-query",
      "8.8.8.8 8.8.4.4", "2001:4860:4860::8888 2001:4860:4860::8844",
      "Very fast and reliable almost everywhere, with no filtering. Google keeps " &
      "full logs for a day or two and some anonymised logs longer. Try it when " &
      "sites load oddly with other servers."),
    b("quad9-ecs", "Quad9 with ECS", "Fast",
      "dns11.quad9.net", "https://dns11.quad9.net/dns-query",
      "9.9.9.11 149.112.112.11", "2620:fe::11 2620:fe::fe:11",
      "Quad9's malware blocking plus ECS: it passes on part of your network address " &
      "so video and app servers near you are picked. Better streaming, a little " &
      "less private."),
    b("he", "Hurricane Electric", "Fast",
      "ordns.he.net", "https://ordns.he.net/dns-query",
      "74.82.42.42", "2001:470:20::2",
      "The open resolver of one of the largest internet backbones. No filtering; " &
      "plain, encrypted and IPv6."),
    b("gcore", "Gcore Public DNS", "Fast",
      "", "",
      "95.85.95.85 2.56.220.2", "",
      "A free resolver on Gcore's worldwide CDN network. No filtering. Plain DNS " &
      "only: set it on your Wi-Fi or router."),

    # ---- Privacy ----
    b("dnssb", "DNS.SB", "Privacy",
      "dot.sb", "https://doh.dns.sb/dns-query",
      "185.222.222.222 45.11.45.11", "2a09:: 2a11::",
      "No logging and no censorship, with DNSSEC. Run by xTom, a hosting company, " &
      "with servers on every continent."),
    b("wikimedia", "Wikimedia DNS", "Privacy",
      "wikimedia-dns.org", "https://wikimedia-dns.org/dns-query",
      "185.71.138.138", "2001:67c:930::1",
      "Run by the Wikimedia Foundation, the people behind Wikipedia. No filtering " &
      "and minimal logs. Encrypted only: it does not answer plain DNS.",
      plain = false),
    b("digiges", "Digitale Gesellschaft", "Privacy",
      "dns.digitale-gesellschaft.ch", "https://dns.digitale-gesellschaft.ch/dns-query",
      "185.95.218.42 185.95.218.43", "2a05:fc84::42 2a05:fc84::43",
      "A Swiss digital-rights association that publishes a yearly transparency " &
      "report. No filtering. Encrypted only.",
      plain = false),
    b("uncensored", "UncensoredDNS", "Privacy",
      "anycast.uncensoreddns.org", "https://anycast.uncensoreddns.org/dns-query",
      "91.239.100.100", "2001:67c:28a4::",
      "Run for more than 15 years by a Danish volunteer. No logging and no " &
      "filtering."),
    b("cira-private", "CIRA Canadian Shield: Private", "Privacy",
      "private.canadianshield.cira.ca", "https://private.canadianshield.cira.ca/dns-query",
      "149.112.121.10 149.112.122.10", "2620:10a:80bb::10 2620:10a:80bc::10",
      "From the non-profit that runs Canada's .ca domains. Plain resolution with " &
      "no commercial use of your data. Its terms are for people in Canada."),
    b("rethink", "RethinkDNS", "Privacy",
      "max.rethinkdns.com", "https://sky.rethinkdns.com/dns-query",
      "", "",
      "Open-source resolver. As it is here it blocks nothing; build your own " &
      "blocklist at rethinkdns.com and add that address with Add."),

    # ---- Security ----
    b("quad9", "Quad9", "Security",
      "dns.quad9.net", "https://dns.quad9.net/dns-query",
      "9.9.9.9 149.112.112.112", "2620:fe::fe 2620:fe::9",
      "A Swiss non-profit. Blocks malware and phishing sites from many threat " &
      "feeds and does not log your IP address. Mullvad now points its users here."),
    b("cf-malware", "Cloudflare: Malware blocking", "Security",
      "security.cloudflare-dns.com", "https://security.cloudflare-dns.com/dns-query",
      "1.1.1.2 1.0.0.2", "2606:4700:4700::1112 2606:4700:4700::1002",
      "Cloudflare's speed plus blocking of known malware and phishing sites."),
    b("cd-malware", "Control D: Malware", "Security",
      "p1.freedns.controld.com", "https://freedns.controld.com/p1",
      "76.76.2.1 76.76.10.1", "2606:1a40::1 2606:1a40:1::1",
      "Blocks malware and phishing. Control D keeps no logs on its free servers."),
    b("cb-security", "CleanBrowsing: Security", "Security",
      "security-filter-dns.cleanbrowsing.org", "https://doh.cleanbrowsing.org/doh/security-filter/",
      "185.228.168.9 185.228.169.9", "2a0d:2a00:1::2 2a0d:2a00:2::2",
      "Blocks phishing, malware and malicious domains; its list is updated every " &
      "hour."),
    b("dns4eu", "DNS4EU: Protective", "Security",
      "protective.joindns4.eu", "https://protective.joindns4.eu/dns-query",
      "86.54.11.1 86.54.11.201", "2a13:1001::86:54:11:1 2a13:1001::86:54:11:201",
      "The EU-backed resolver: blocks malicious sites with European threat " &
      "intelligence and anonymises IP addresses before any logging. Its terms are " &
      "for people in the EU."),
    b("cira-protected", "CIRA Canadian Shield: Protected", "Security",
      "protected.canadianshield.cira.ca", "https://protected.canadianshield.cira.ca/dns-query",
      "149.112.121.20 149.112.122.20", "2620:10a:80bb::20 2620:10a:80bc::20",
      "CIRA's private resolver plus malware, botnet and phishing blocking. For " &
      "people in Canada."),
    b("ultra-threat", "UltraDNS: Threat Protection", "Security",
      "", "",
      "156.154.70.2 156.154.71.2", "2610:a1:1018::2 2610:a1:1019::2",
      "DigiCert's free resolver (once Neustar's). Blocks malware, ransomware, " &
      "spyware and phishing. Plain DNS only."),
    b("comodo", "Comodo Secure DNS", "Security",
      "", "",
      "8.26.56.26 8.20.247.20", "",
      "Blocks known malware and phishing sites. Plain DNS only."),
    b("opendns", "OpenDNS Home", "Security",
      "", "https://doh.opendns.com/dns-query",
      "208.67.222.222 208.67.220.220", "2620:119:35::35 2620:119:53::53",
      "Cisco's resolver; blocks phishing sites."),

    # ---- Ad-block ----
    b("adguard", "AdGuard DNS", "Ad-block",
      "dns.adguard-dns.com", "https://dns.adguard-dns.com/dns-query",
      "94.140.14.14 94.140.15.15", "2a10:50c0::ad1:ff 2a10:50c0::ad2:ff",
      "Blocks ads, trackers and phishing in every app and browser, not just one. " &
      "Some apps that live on ads may misbehave."),
    b("cd-ads", "Control D: Ads and tracking", "Ad-block",
      "p2.freedns.controld.com", "https://freedns.controld.com/p2",
      "76.76.2.2 76.76.10.2", "2606:1a40::2 2606:1a40:1::2",
      "Blocks malware, ads and trackers. No logs on the free servers."),
    b("dns4eu-noads", "DNS4EU: No ads", "Ad-block",
      "noads.joindns4.eu", "https://noads.joindns4.eu/dns-query",
      "86.54.11.13 86.54.11.213", "2a13:1001::86:54:11:13 2a13:1001::86:54:11:213",
      "DNS4EU's protection plus ad blocking. For people in the EU."),
    b("alternate", "Alternate DNS", "Ad-block",
      "", "",
      "76.76.19.19 76.223.122.150", "2602:fcbc::ad 2602:fcbc:2::ad",
      "A free ad-blocking resolver. Plain DNS only."),

    # ---- Family ----
    b("cf-family", "Cloudflare: Family", "Family",
      "family.cloudflare-dns.com", "https://family.cloudflare-dns.com/dns-query",
      "1.1.1.3 1.0.0.3", "2606:4700:4700::1113 2606:4700:4700::1003",
      "Blocks malware and adult content. A fast, simple choice for a child's phone."),
    b("adguard-family", "AdGuard DNS: Family", "Family",
      "family.adguard-dns.com", "https://family.adguard-dns.com/dns-query",
      "94.140.14.15 94.140.15.16", "2a10:50c0::bad1:ff 2a10:50c0::bad2:ff",
      "Blocks ads, trackers and adult content, and turns on Safe Search."),
    b("cb-adult", "CleanBrowsing: Adult filter", "Family",
      "adult-filter-dns.cleanbrowsing.org", "https://doh.cleanbrowsing.org/doh/adult-filter/",
      "185.228.168.10 185.228.169.11", "2a0d:2a00:1::1 2a0d:2a00:2::1",
      "Blocks adult content and malicious sites, and forces Safe Search. Lets " &
      "mixed sites through."),
    b("cb-family", "CleanBrowsing: Family filter", "Family",
      "family-filter-dns.cleanbrowsing.org", "https://doh.cleanbrowsing.org/doh/family-filter/",
      "185.228.168.168 185.228.169.168", "2a0d:2a00:1:: 2a0d:2a00:2::",
      "The strictest: also blocks proxy and VPN sites and mixed-content sites, and " &
      "forces Safe Search and YouTube's restricted mode. Made for young children."),
    b("cd-social", "Control D: Social", "Family",
      "p3.freedns.controld.com", "https://freedns.controld.com/p3",
      "76.76.2.3 76.76.10.3", "2606:1a40::3 2606:1a40:1::3",
      "Blocks malware, ads, trackers and social networks: for focus time or a " &
      "child's tablet."),
    b("cd-family", "Control D: Family friendly", "Family",
      "family.freedns.controld.com", "https://freedns.controld.com/family",
      "76.76.2.4 76.76.10.4", "2606:1a40::4 2606:1a40:1::4",
      "Blocks malware, ads, trackers, adult content and drugs."),
    b("dns4eu-child", "DNS4EU: Child protection", "Family",
      "child.joindns4.eu", "https://child.joindns4.eu/dns-query",
      "86.54.11.12 86.54.11.212", "2a13:1001::86:54:11:12 2a13:1001::86:54:11:212",
      "DNS4EU's protection plus blocking of explicit, violent and drug content. " &
      "For people in the EU."),
    b("dns4eu-child-noads", "DNS4EU: Child protection, no ads", "Family",
      "child-noads.joindns4.eu", "https://child-noads.joindns4.eu/dns-query",
      "86.54.11.11 86.54.11.211", "2a13:1001::86:54:11:11 2a13:1001::86:54:11:211",
      "DNS4EU's strictest: protection, the child filter and ad blocking together."),
    b("cira-family", "CIRA Canadian Shield: Family", "Family",
      "family.canadianshield.cira.ca", "https://family.canadianshield.cira.ca/dns-query",
      "149.112.121.30 149.112.122.30", "2620:10a:80bb::30 2620:10a:80bc::30",
      "CIRA's protection plus blocking of adult content. For people in Canada."),
    b("opendns-family", "OpenDNS FamilyShield", "Family",
      "", "https://doh.familyshield.opendns.com/dns-query",
      "208.67.222.123 208.67.220.123", "",
      "Blocks adult content with no account and no setup."),
    b("ultra-family", "UltraDNS: Family Secure", "Family",
      "", "",
      "156.154.70.3 156.154.71.3", "2610:a1:1018::3 2610:a1:1019::3",
      "Threat protection plus blocking of gambling, pornography, violence and " &
      "hate sites. Plain DNS only."),

    # ---- Unfiltered ----
    b("quad9-unsecured", "Quad9: Unsecured", "Unfiltered",
      "dns10.quad9.net", "https://dns10.quad9.net/dns-query",
      "9.9.9.10 149.112.112.10", "2620:fe::10 2620:fe::fe:10",
      "Quad9's privacy without any blocking: for when a safe site gets blocked."),
    b("adguard-unfiltered", "AdGuard DNS: Unfiltered", "Unfiltered",
      "unfiltered.adguard-dns.com", "https://unfiltered.adguard-dns.com/dns-query",
      "94.140.14.140 94.140.14.141", "2a10:50c0::1:ff 2a10:50c0::2:ff",
      "AdGuard's network with no blocking at all."),
    b("cd-unfiltered", "Control D: Unfiltered", "Unfiltered",
      "p0.freedns.controld.com", "https://freedns.controld.com/p0",
      "76.76.2.0 76.76.10.0", "2606:1a40:: 2606:1a40:1::",
      "No filtering and no logs, on a fast anycast network."),
    b("dns4eu-unfiltered", "DNS4EU: Unfiltered", "Unfiltered",
      "unfiltered.joindns4.eu", "https://unfiltered.joindns4.eu/dns-query",
      "86.54.11.100 86.54.11.200", "2a13:1001::86:54:11:100 2a13:1001::86:54:11:200",
      "The privacy-minded EU resolver with no filtering. For people in the EU."),
    b("ultra-unfiltered", "UltraDNS: Unfiltered", "Unfiltered",
      "", "",
      "64.6.64.6 64.6.65.6", "2620:74:1b::1:1 2620:74:1c::2:2",
      "The former Verisign public DNS, now run by DigiCert. No filtering. Plain " &
      "DNS only."),

    # ---- Regional ----
    b("alidns", "AliDNS (Alibaba)", "Regional",
      "dns.alidns.com", "https://dns.alidns.com/dns-query",
      "223.5.5.5 223.6.6.6", "2400:3200::1 2400:3200:baba::1",
      "Alibaba's resolver: fast in China and East Asia. Answers follow Chinese rules."),
    b("dnspod", "DNSPod (Tencent)", "Regional",
      "dot.pub", "https://doh.pub/dns-query",
      "119.29.29.29 119.28.28.28", "2402:4e00::",
      "Tencent's resolver: fast in mainland China. Answers follow Chinese rules."),
    b("114dns", "114DNS", "Regional",
      "", "",
      "114.114.114.114 114.114.115.115", "",
      "A popular resolver in China. Plain DNS only."),
    b("quad101", "Quad101 (TWNIC)", "Regional",
      "", "https://dns.twnic.tw/dns-query",
      "101.101.101.101 101.102.103.104", "2001:de4::101 2001:de4::102",
      "Taiwan's network information centre. No filtering."),
    b("yandex", "Yandex DNS: Basic", "Regional",
      "", "",
      "77.88.8.8 77.88.8.1", "2a02:6b8::feed:0ff 2a02:6b8:0:1::feed:0ff",
      "Fast in Russia and nearby countries. No filtering. Plain DNS only."),
    b("yandex-safe", "Yandex DNS: Safe", "Regional",
      "", "",
      "77.88.8.88 77.88.8.2", "2a02:6b8::feed:bad 2a02:6b8:0:1::feed:bad",
      "Yandex DNS that blocks infected and fraudulent sites. Plain DNS only."),
    b("yandex-family", "Yandex DNS: Family", "Regional",
      "", "",
      "77.88.8.7 77.88.8.3", "2a02:6b8::feed:a11 2a02:6b8:0:1::feed:a11",
      "Yandex DNS without adult content. Plain DNS only."),
  ]

# ---- the user's servers, as CSV ------------------------------------------------------------------

const CsvHeaders* = ["Name", "Group", "Private DNS host", "DoH address", "IPv4", "IPv6",
                     "Note"]

proc customKey*(name, dot: string): string =
  "c:" & name.strip.toLowerAscii & "|" & dot.strip.toLowerAscii

proc serversTable*(list: openArray[Server]): DataTable =
  result.headers = @CsvHeaders
  for s in list:
    result.rows.add @[s.name, s.group, s.dot, s.doh, s.ipv4.join(" "), s.ipv6.join(" "),
                      s.note]

proc cellAt(r: seq[string]; i: int): string =
  if i >= 0 and i < r.len: r[i].strip else: ""

proc fromTable*(t: DataTable): seq[Server] =
  ## The servers in a table (its columns found by name, else by place).
  proc col(t: DataTable; names: openArray[string]; fallback: int): int =
    for i, h in t.headers:
      let hh = h.strip.toLowerAscii
      for n in names:
        if hh == n: return i
    fallback
  let cName = t.col(["name"], 0)
  let cGroup = t.col(["group"], 1)
  let cDot = t.col(["private dns host", "dot", "private dns", "host"], 2)
  let cDoh = t.col(["doh address", "doh", "dns over https"], 3)
  let cV4 = t.col(["ipv4", "ip"], 4)
  let cV6 = t.col(["ipv6"], 5)
  let cNote = t.col(["note", "notes", "what it is good for"], 6)
  for r in t.rows:
    let name = r.cellAt(cName)
    if name.len == 0: continue
    var group = r.cellAt(cGroup)
    if group notin Groups: group = "Mine"
    let dot = r.cellAt(cDot)
    var s = Server(key: customKey(name, dot), name: name, group: group,
                   dot: dot, doh: r.cellAt(cDoh), ipv4: splitAddrs(r.cellAt(cV4)),
                   ipv6: splitAddrs(r.cellAt(cV6)), note: r.cellAt(cNote),
                   plain: true, custom: true)
    if s.dot.len + s.doh.len + s.ipv4.len + s.ipv6.len == 0: continue
    result.add s

proc loadCustom*(path: string): seq[Server] =
  let t = readCsv(path)
  if t.headers.len == 0: return
  fromTable(t)

proc saveCustom*(path: string; list: openArray[Server]): bool =
  writeCsv(path, serversTable(list))

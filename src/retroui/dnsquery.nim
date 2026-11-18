## DNS questions -- the TXT, MX, SRV, A and AAAA records of a name -- asked
## of the system's own resolver (its servers in /etc/resolv.conf, or
## Windows' own list), over UDP and, for a long answer, TCP; and over HTTPS
## (DNS-over-HTTPS) where there is no resolver to ask (Android, a web page)
## or it does not answer. For mail: the DKIM keys and DMARC policies that
## say whether a message is really from who it says (`retroui/mailauth`),
## and the servers of an address (`retroui/mailsetup`).
##
## .. code-block:: nim
##   let r = dnsQuery("_dmarc.example.com", "TXT")
##   case r.status
##   of dnsOk: echo r.answers          # @["v=DMARC1; p=reject; ..."]
##   of dnsNoName: echo "no such record"
##   of dnsFailed: echo "no answer: ", r.error
##
## A TXT record's strings come joined (as DKIM and DMARC read them); an MX
## is "10 mx.example.com", an SRV "0 1 993 imap.example.com". Answers are
## kept for as long as they say (at most an hour), per thread.
##
## `RETRO_DNS` (host:port, e.g. "127.0.0.1:5353") asks that server only --
## the tests' own; `RETRO_MAIL_DOH` is the DNS-over-HTTPS service
## ("https://dns.google/resolve" when not set). The names kept for examples
## and tests (.test, .example, .invalid, .localhost, example.com...) are
## not asked: no one has them.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, os, json, uri, times, tables]
import http
const Sockets = not defined(wasm) and not defined(js)
when Sockets:
  import std/[net, nativesockets, sysrand]

type
  DnsStatus* = enum
    dnsOk       ## answers came
    dnsNoName   ## the name, or a record of that kind, is not there (NXDOMAIN, or no data)
    dnsFailed   ## nothing could say (no network, no answer in time, a server error)
  DnsResult* = object
    status*: DnsStatus
    answers*: seq[string]   ## the records, as text (see the module's notes)
    error*: string          ## why `dnsFailed`
    ttl*: int               ## seconds the answers may be kept (the least of theirs)

const
  kinds = [("A", 1), ("NS", 2), ("CNAME", 5), ("MX", 15), ("TXT", 16), ("AAAA", 28), ("SRV", 33)]
  MaxCache = 512

proc kindCode(kind: string): int =
  for (n, c) in kinds:
    if n == kind.toUpperAscii: return c
  -1

var cache {.threadvar.}: Table[string, tuple[r: DnsResult; until: float]]

proc dohBase(): string = getEnv("RETRO_MAIL_DOH", "https://dns.google/resolve")

# ---- the wire format (RFC 1035) ---------------------------------------------------------

proc question*(name: string; code: int; id: uint16): string =
  ## (a query: one question, recursion asked for, EDNS0 for a 1232-byte answer)
  let labels = name.strip(chars = {'.'}).split('.')
  for label in labels:
    if label.len == 0 or label.len > 63: return ""
  result = newStringOfCap(64)
  result.add char(id shr 8)
  result.add char(id and 0xFF)
  result.add "\x01\x00"                        # RD
  result.add "\x00\x01\x00\x00\x00\x00\x00\x01" # one question, one additional (OPT)
  for label in labels:
    result.add char(label.len)
    result.add label
  result.add '\0'
  result.add char(code shr 8)
  result.add char(code and 0xFF)
  result.add "\x00\x01"                        # IN
  result.add "\x00\x00\x29\x04\xD0\x00\x00\x00\x00\x00\x00"  # OPT: root, 1232 bytes, no options

proc u16(s: string; i: int): int {.inline.} =
  if i + 1 >= s.len: return -1
  (ord(s[i]) shl 8) or ord(s[i + 1])

proc nameAt(s: string; at: var int): string =
  ## (a name, compression pointers followed -- at most 64 of them)
  var i = at
  var jumped = false
  var hops = 0
  while i < s.len:
    let n = ord(s[i])
    if n == 0:
      if not jumped: at = i + 1
      return
    if (n and 0xC0) == 0xC0:
      if i + 1 >= s.len: break
      if not jumped: at = i + 2
      jumped = true
      inc hops
      if hops > 64: break
      i = ((n and 0x3F) shl 8) or ord(s[i + 1])
      continue
    if i + 1 + n > s.len: break
    if result.len > 0: result.add '.'
    result.add s[i + 1 .. i + n]
    i += n + 1
  at = s.len + 1        # (broken)

proc parseAnswer*(s: string; id: uint16; code: int; truncated: var bool): DnsResult =
  ## (the records of kind `code` in an answer to query `id`)
  truncated = false
  if s.len < 12 or u16(s, 0) != int(id) or (ord(s[2]) and 0x80) == 0:
    return DnsResult(status: dnsFailed, error: "not an answer")
  if (ord(s[2]) and 0x02) != 0:
    truncated = true
    return DnsResult(status: dnsFailed, error: "cut short")
  let rcode = ord(s[3]) and 0x0F
  if rcode == 3: return DnsResult(status: dnsNoName)
  if rcode != 0: return DnsResult(status: dnsFailed, error: "the server answered " & $rcode)
  let qd = u16(s, 4)
  let an = u16(s, 6)
  var at = 12
  for q in 0 ..< qd:
    discard nameAt(s, at)
    at += 4
  for a in 0 ..< an:
    discard nameAt(s, at)
    if at + 10 > s.len: break
    let typ = u16(s, at)
    let ttl = (u16(s, at + 4) shl 16) or u16(s, at + 6)
    let rdlen = u16(s, at + 8)
    at += 10
    if at + rdlen > s.len: break
    let rd = s[at ..< at + rdlen]
    if typ == code:
      result.ttl = if result.answers.len == 0: ttl else: min(result.ttl, ttl)
      case typ
      of 1:
        if rd.len == 4: result.answers.add $ord(rd[0]) & "." & $ord(rd[1]) & "." & $ord(rd[2]) & "." & $ord(rd[3])
      of 28:
        if rd.len == 16:
          var parts: seq[string]
          for k in 0 ..< 8: parts.add toHex(u16(rd, 2 * k), 4).toLowerAscii
          result.answers.add parts.join(":")
      of 16:
        var t = ""
        var k = 0
        while k < rd.len:
          let n = ord(rd[k])
          t.add rd[k + 1 ..< min(rd.len, k + 1 + n)]
          k += n + 1
        result.answers.add t
      of 15:
        var p = at + 2
        result.answers.add $u16(s, at) & " " & nameAt(s, p)
      of 33:
        var p = at + 6
        result.answers.add $u16(s, at) & " " & $u16(s, at + 2) & " " & $u16(s, at + 4) & " " & nameAt(s, p)
      else:
        var p = at
        result.answers.add nameAt(s, p)
    at += rdlen
  result.status = if result.answers.len > 0: dnsOk else: dnsNoName

# ---- where to ask ----------------------------------------------------------------------

when defined(windows):
  type
    IpAddrString {.pure.} = object
      next: ptr IpAddrString
      ipAddress, ipMask: array[16, char]
      context: uint32
    FixedInfo {.pure.} = object
      hostName: array[132, char]
      domainName: array[132, char]
      currentDnsServer: pointer
      dnsServerList: IpAddrString
      nodeType: uint32
      scopeId: array[260, char]
      enableRouting, enableProxy, enableDns: uint32
  proc GetNetworkParams(info: pointer; size: ptr uint32): uint32 {.stdcall, dynlib: "iphlpapi.dll", importc.}

proc servers*(): seq[tuple[host: string; port: int]] =
  ## The resolvers this system asks (RETRO_DNS alone when it is set).
  let forced = getEnv("RETRO_DNS")
  if forced.len > 0:
    let k = forced.rfind(':')
    if k > 0: return @[(forced[0 ..< k].strip(chars = {'[', ']'}), (try: parseInt(forced[k + 1 .. ^1]) except ValueError: 53))]
    return @[(forced, 53)]
  when defined(windows):
    var size = 0'u32
    discard GetNetworkParams(nil, addr size)
    if size > 0 and size < 1_000_000:
      var buf = newSeq[byte](int(size))
      if GetNetworkParams(addr buf[0], addr size) == 0:
        var p = addr cast[ptr FixedInfo](addr buf[0]).dnsServerList
        var n = 0
        while p != nil and n < 8:
          let ip = $cast[cstring](addr p.ipAddress[0])
          if ip.len > 0 and ip != "0.0.0.0": result.add (ip, 53)
          p = p.next
          inc n
  else:
    for path in [getEnv("PREFIX") / "etc/resolv.conf", "/etc/resolv.conf"]:
      if result.len > 0 or not fileExists(path): continue
      try:
        for line in lines(path):
          let f = line.splitWhitespace
          if f.len >= 2 and f[0] == "nameserver" and '%' notin f[1]:
            result.add (f[1], 53)
      except IOError, OSError: discard

when Sockets:
  proc askUdp(host: string; port: int; q: string; id: uint16; code: int; timeoutMs: int;
              truncated: var bool): DnsResult =
    let v6 = ':' in host
    let s = newSocket(if v6: AF_INET6 else: AF_INET, SOCK_DGRAM, IPPROTO_UDP, buffered = false)
    defer: s.close()
    s.sendTo(host, Port(port), q)
    let until = epochTime() + timeoutMs / 1000
    while true:
      let left = int((until - epochTime()) * 1000)
      if left <= 0: return DnsResult(status: dnsFailed, error: "no answer in time")
      var fds = @[s.getFd]
      if selectRead(fds, left) <= 0: return DnsResult(status: dnsFailed, error: "no answer in time")
      var data = ""
      var fromHost = ""
      var fromPort: Port
      discard s.recvFrom(data, 4096, fromHost, fromPort)
      # (an answer from anyone else, or to another question, is not this one's)
      if fromPort != Port(port): continue
      if data.len >= 2 and u16(data, 0) != int(id): continue
      return parseAnswer(data, id, code, truncated)

  proc askTcp(host: string; port: int; q: string; id: uint16; code: int; timeoutMs: int): DnsResult =
    let s = newSocket(if ':' in host: AF_INET6 else: AF_INET, SOCK_STREAM, IPPROTO_TCP)
    defer: s.close()
    s.connect(host, Port(port), timeoutMs)
    s.send(char(q.len shr 8) & char(q.len and 0xFF) & q)
    let head = s.recv(2, timeoutMs)
    if head.len != 2: return DnsResult(status: dnsFailed, error: "no answer")
    let n = u16(head, 0)
    let body = s.recv(n, timeoutMs)
    var t = false
    parseAnswer(body, id, code, t)

proc askDoh(name, kind: string; timeoutSec: int): DnsResult =
  let r = httpRequest("GET", dohBase() & "?name=" & encodeUrl(name) & "&type=" & kind,
                      [("Accept", "application/dns-json")], timeoutSec = timeoutSec)
  if not r.ok: return DnsResult(status: dnsFailed, error: (if r.error.len > 0: r.error else: "HTTP " & $r.status))
  try:
    let j = parseJson(r.body)
    let st = j{"Status"}.getInt
    if st == 3: return DnsResult(status: dnsNoName)
    if st != 0: return DnsResult(status: dnsFailed, error: "the server answered " & $st)
    let code = kindCode(kind)
    for a in j{"Answer"}.getElems:
      if a{"type"}.getInt != code: continue
      let ttl = a{"TTL"}.getInt(300)
      result.ttl = if result.answers.len == 0: ttl else: min(result.ttl, ttl)
      var d = a{"data"}.getStr
      if code == 16:
        # ("\"v=DKIM1; k=rsa; \" \"p=MIIB...\"": the quoted strings, joined)
        if d.startsWith("\""):
          var t = ""
          var inside = false
          var k = 0
          while k < d.len:
            let c = d[k]
            if c == '"': inside = not inside
            elif inside:
              if c == '\\' and k + 1 < d.len:
                inc k
                t.add d[k]
              else: t.add c
            inc k
          d = t
      elif code in [5, 15, 33, 2]:
        d = d.strip(chars = {'.'})
      result.answers.add d
    result.status = if result.answers.len > 0: dnsOk else: dnsNoName
  except CatchableError as e:
    result = DnsResult(status: dnsFailed, error: e.msg)

proc dnsQuery*(name, kind: string; timeoutSec = 4): DnsResult {.gcsafe.} =
  ## The `kind` records ("TXT", "MX", "SRV", "A", "AAAA", "CNAME", "NS")
  ## of `name`: from the system's resolver, else over HTTPS. Never raises.
  let code = kindCode(kind)
  if code < 0 or name.len == 0 or name.len > 253:
    return DnsResult(status: dnsFailed, error: "not a question that can be asked")
  let key = kind.toUpperAscii & " " & name.toLowerAscii.strip(chars = {'.'})
  # (names kept for examples and tests -- RFC 2606, 6761 -- are never anyone's:
  # not asked, unless a test's own server is the one asked)
  let low = key[key.find(' ') + 1 .. ^1]
  if getEnv("RETRO_DNS").len == 0:
    for t in [".test", ".example", ".invalid", ".localhost", "example.com", "example.net", "example.org"]:
      if low.endsWith(t) and (t[0] == '.' or low == t or low.endsWith("." & t)):
        return DnsResult(status: dnsNoName)
  let now = epochTime()
  {.cast(gcsafe).}:
    if key in cache and cache[key].until > now: return cache[key].r
  var res = DnsResult(status: dnsFailed, error: "no resolver")
  when Sockets:
    let ss = servers()
    for (host, port) in ss:
      try:
        var idb: array[2, byte]
        discard urandom(idb)
        let id = (uint16(idb[0]) shl 8) or uint16(idb[1])
        let q = question(name, code, id)
        if q.len == 0: return DnsResult(status: dnsFailed, error: "not a name")
        var truncated = false
        res = askUdp(host, port, q, id, code, timeoutSec * 1000 div max(1, min(ss.len, 2)), truncated)
        if truncated: res = askTcp(host, port, q, id, code, timeoutSec * 1000)
      except CatchableError as e:
        res = DnsResult(status: dnsFailed, error: e.msg)
      if res.status != dnsFailed: break
    if res.status == dnsFailed and getEnv("RETRO_DNS").len == 0:
      res = askDoh(name, kind, timeoutSec)
  else:
    res = askDoh(name, kind, timeoutSec)
  {.cast(gcsafe).}:
    if res.status != dnsFailed:
      if cache.len >= MaxCache: cache.clear()
      # (a name not there is asked again after five minutes)
      let keep = if res.status == dnsOk: clamp(res.ttl, 30, 3600) else: 300
      cache[key] = (res, now + float(keep))
  res

proc dnsLookup*(name, kind: string; timeoutSec = 4): seq[string] {.gcsafe.} =
  ## Just the answers of `dnsQuery` (none: none, or none could be had).
  dnsQuery(name, kind, timeoutSec).answers

proc forgetDnsAnswers*() =
  ## Asks again next time (this thread's answers kept are dropped).
  cache.clear()

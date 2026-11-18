## NTLM (MS-NLMP, version 2): how a Windows server -- an Exchange of a
## company's own, an intranet site -- takes a password over HTTP without
## seeing it: the client says it wants to sign in (`ntlmNegotiate`), the
## server answers with a challenge, the client answers that with what only
## the password could make (`ntlmAuthenticate`). The three go on one
## connection, kept open; the server knows the connection from then on.
## With MD4, MD5 and HMAC-MD5 in plain Nim (what NTLM is made of).
##
## .. code-block:: nim
##   let t1 = ntlmNegotiate()                       # "Authorization: NTLM " & t1
##   # ... the server's 401: "WWW-Authenticate: NTLM <challenge>"
##   let t3 = ntlmAuthenticate(challenge, "EXAMPLE\\maryam", password)
##   # "Authorization: NTLM " & t3, on the same connection
##
## User names: "DOMAIN\\user", "user@domain" or just "user".
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, base64, sysrand, times]

# ---- MD4 (RFC 1320) and MD5 (RFC 1321) --------------------------------------------------

proc rotl(x: uint32; n: int): uint32 {.inline.} = (x shl n) or (x shr (32 - n))

proc padded(data: string): string =
  result = data
  result.add '\x80'
  while result.len mod 64 != 56: result.add '\0'
  let bits = uint64(data.len) * 8
  for i in 0 ..< 8: result.add char((bits shr (8 * i)) and 0xFF)

proc words(s: string; at: int): array[16, uint32] =
  for i in 0 ..< 16:
    let k = at + 4 * i
    result[i] = uint32(ord(s[k])) or (uint32(ord(s[k + 1])) shl 8) or
                (uint32(ord(s[k + 2])) shl 16) or (uint32(ord(s[k + 3])) shl 24)

proc digestOf(h: array[4, uint32]): string =
  for v in h:
    for i in 0 ..< 4: result.add char((v shr (8 * i)) and 0xFF)

proc md4*(data: string): string =
  ## The MD4 digest of `data` (16 bytes). Broken as a hash: only for NTLM.
  var h = [0x67452301'u32, 0xefcdab89'u32, 0x98badcfe'u32, 0x10325476'u32]
  let p = padded(data)
  var at = 0
  while at < p.len:
    let x = words(p, at)
    var (a, b, c, d) = (h[0], h[1], h[2], h[3])
    template f(x, y, z: uint32): uint32 = (x and y) or ((not x) and z)
    template g(x, y, z: uint32): uint32 = (x and y) or (x and z) or (y and z)
    template hh(x, y, z: uint32): uint32 = x xor y xor z
    for i in [0, 4, 8, 12]:
      a = rotl(a + f(b, c, d) + x[i], 3)
      d = rotl(d + f(a, b, c) + x[i + 1], 7)
      c = rotl(c + f(d, a, b) + x[i + 2], 11)
      b = rotl(b + f(c, d, a) + x[i + 3], 19)
    for i in [0, 1, 2, 3]:
      a = rotl(a + g(b, c, d) + x[i] + 0x5a827999'u32, 3)
      d = rotl(d + g(a, b, c) + x[i + 4] + 0x5a827999'u32, 5)
      c = rotl(c + g(d, a, b) + x[i + 8] + 0x5a827999'u32, 9)
      b = rotl(b + g(c, d, a) + x[i + 12] + 0x5a827999'u32, 13)
    for i in [0, 2, 1, 3]:
      a = rotl(a + hh(b, c, d) + x[i] + 0x6ed9eba1'u32, 3)
      d = rotl(d + hh(a, b, c) + x[i + 8] + 0x6ed9eba1'u32, 9)
      c = rotl(c + hh(d, a, b) + x[i + 4] + 0x6ed9eba1'u32, 11)
      b = rotl(b + hh(c, d, a) + x[i + 12] + 0x6ed9eba1'u32, 15)
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    at += 64
  digestOf(h)

const
  md5S = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
          5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
          4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
          6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]
  md5K = block:
    var k: array[64, uint32]
    # (floor(abs(sin(i + 1)) * 2^32): written out, sin at compile time is not exact everywhere)
    k = [0xd76aa478'u32, 0xe8c7b756'u32, 0x242070db'u32, 0xc1bdceee'u32, 0xf57c0faf'u32, 0x4787c62a'u32,
         0xa8304613'u32, 0xfd469501'u32, 0x698098d8'u32, 0x8b44f7af'u32, 0xffff5bb1'u32, 0x895cd7be'u32,
         0x6b901122'u32, 0xfd987193'u32, 0xa679438e'u32, 0x49b40821'u32, 0xf61e2562'u32, 0xc040b340'u32,
         0x265e5a51'u32, 0xe9b6c7aa'u32, 0xd62f105d'u32, 0x02441453'u32, 0xd8a1e681'u32, 0xe7d3fbc8'u32,
         0x21e1cde6'u32, 0xc33707d6'u32, 0xf4d50d87'u32, 0x455a14ed'u32, 0xa9e3e905'u32, 0xfcefa3f8'u32,
         0x676f02d9'u32, 0x8d2a4c8a'u32, 0xfffa3942'u32, 0x8771f681'u32, 0x6d9d6122'u32, 0xfde5380c'u32,
         0xa4beea44'u32, 0x4bdecfa9'u32, 0xf6bb4b60'u32, 0xbebfbc70'u32, 0x289b7ec6'u32, 0xeaa127fa'u32,
         0xd4ef3085'u32, 0x04881d05'u32, 0xd9d4d039'u32, 0xe6db99e5'u32, 0x1fa27cf8'u32, 0xc4ac5665'u32,
         0xf4292244'u32, 0x432aff97'u32, 0xab9423a7'u32, 0xfc93a039'u32, 0x655b59c3'u32, 0x8f0ccc92'u32,
         0xffeff47d'u32, 0x85845dd1'u32, 0x6fa87e4f'u32, 0xfe2ce6e0'u32, 0xa3014314'u32, 0x4e0811a1'u32,
         0xf7537e82'u32, 0xbd3af235'u32, 0x2ad7d2bb'u32, 0xeb86d391'u32]
    k

proc md5*(data: string): string =
  ## The MD5 digest of `data` (16 bytes). Broken as a hash: only for NTLM.
  var h = [0x67452301'u32, 0xefcdab89'u32, 0x98badcfe'u32, 0x10325476'u32]
  let p = padded(data)
  var at = 0
  while at < p.len:
    let m = words(p, at)
    var (a, b, c, d) = (h[0], h[1], h[2], h[3])
    for i in 0 ..< 64:
      var f: uint32
      var g: int
      case i div 16
      of 0: f = (b and c) or ((not b) and d); g = i
      of 1: f = (d and b) or ((not d) and c); g = (5 * i + 1) mod 16
      of 2: f = b xor c xor d; g = (3 * i + 5) mod 16
      else: f = c xor (b or (not d)); g = (7 * i) mod 16
      let t = d
      d = c
      c = b
      b = b + rotl(a + f + md5K[i] + m[g], md5S[i])
      a = t
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    at += 64
  digestOf(h)

proc hmacMd5*(key, data: string): string =
  ## HMAC-MD5 (RFC 2104).
  var k = if key.len > 64: md5(key) else: key
  k.setLen(64)
  var ipad, opad = newString(64)
  for i in 0 ..< 64:
    ipad[i] = char(ord(k[i]) xor 0x36)
    opad[i] = char(ord(k[i]) xor 0x5c)
  md5(opad & md5(ipad & data))

# ---- the messages --------------------------------------------------------------------

const
  flagUnicode = 0x00000001'u32
  flagOem = 0x00000002'u32
  flagRequestTarget = 0x00000004'u32
  flagNtlm = 0x00000200'u32
  flagAlwaysSign = 0x00008000'u32
  flagExtended = 0x00080000'u32
  flagTargetInfo = 0x00800000'u32
  flag128 = 0x20000000'u32
  flag56 = 0x80000000'u32
  negotiateFlags = flagUnicode or flagOem or flagRequestTarget or flagNtlm or flagAlwaysSign or
                   flagExtended or flagTargetInfo or flag128 or flag56

proc le16(v: int): string = char(v and 0xFF) & char((v shr 8) and 0xFF)
proc le32(v: uint32): string =
  for i in 0 ..< 4: result.add char((v shr (8 * i)) and 0xFF)
proc rd16(s: string; i: int): int = (if i + 1 < s.len: ord(s[i]) or (ord(s[i + 1]) shl 8) else: 0)
proc rd32(s: string; i: int): uint32 =
  if i + 3 >= s.len: return 0
  uint32(ord(s[i])) or (uint32(ord(s[i + 1])) shl 8) or (uint32(ord(s[i + 2])) shl 16) or
    (uint32(ord(s[i + 3])) shl 24)

proc utf16le*(s: string): string =
  ## (UTF-8 as UTF-16LE, the way NTLM writes names and passwords)
  var i = 0
  while i < s.len:
    var cp = ord(s[i])
    var n = 1
    if cp >= 0xF0 and i + 3 < s.len:
      cp = ((cp and 0x07) shl 18) or ((ord(s[i + 1]) and 0x3F) shl 12) or ((ord(s[i + 2]) and 0x3F) shl 6) or
           (ord(s[i + 3]) and 0x3F)
      n = 4
    elif cp >= 0xE0 and i + 2 < s.len:
      cp = ((cp and 0x0F) shl 12) or ((ord(s[i + 1]) and 0x3F) shl 6) or (ord(s[i + 2]) and 0x3F)
      n = 3
    elif cp >= 0xC0 and i + 1 < s.len:
      cp = ((cp and 0x1F) shl 6) or (ord(s[i + 1]) and 0x3F)
      n = 2
    if cp >= 0x10000:
      let v = cp - 0x10000
      result.add le16(0xD800 or (v shr 10))
      result.add le16(0xDC00 or (v and 0x3FF))
    else: result.add le16(cp)
    i += n

proc ntlmNegotiate*(): string =
  ## The first message (base64, for "Authorization: NTLM ...").
  encode("NTLMSSP\0" & le32(1) & le32(negotiateFlags) & repeat('\0', 16))

type NtlmChallenge* = object
  ## What the server's challenge (its second message) says.
  flags*: uint32
  challenge*: string        ## 8 bytes
  targetInfo*: string       ## its AV pairs, as sent
  domain*: string           ## its NetBIOS domain (from the AV pairs), UTF-8 if ASCII

proc parseChallenge*(b64: string): NtlmChallenge =
  ## The server's challenge, from "WWW-Authenticate: NTLM <this>". Raises
  ## `ValueError` when it is not one.
  let s = decode(b64.strip)
  if s.len < 32 or not s.startsWith("NTLMSSP\0") or rd32(s, 8) != 2:
    raise newException(ValueError, "not an NTLM challenge")
  result.flags = rd32(s, 20)
  result.challenge = s[24 ..< 32]
  if s.len >= 48:
    let n = rd16(s, 40)
    let off = int(rd32(s, 44))
    if off + n <= s.len: result.targetInfo = s[off ..< off + n]
  var i = 0
  let ti = result.targetInfo
  while i + 4 <= ti.len:
    let id = rd16(ti, i)
    let n = rd16(ti, i + 2)
    if id == 0 or i + 4 + n > ti.len: break
    if id == 2:
      var d = ""
      for k in countup(i + 4, i + 3 + n, 2): d.add char(ord(ti[k]))
      result.domain = d
    i += 4 + n

proc splitUser(user: string): tuple[domain, name: string] =
  let b = user.find('\\')
  if b > 0: return (user[0 ..< b], user[b + 1 .. ^1])
  let at = user.rfind('@')
  if at > 0: return (user[at + 1 .. ^1], user[0 ..< at])
  ("", user)

proc ntowfv2*(user, domain, password: string): string =
  ## NTOWFv2: what the password and the user make (MS-NLMP 3.3.2).
  hmacMd5(md4(utf16le(password)), utf16le(user.toUpperAscii & domain))

proc ntlmv2Response*(user, domain, password, serverChallenge, clientChallenge, targetInfo: string;
                     timestamp: uint64): tuple[nt, lm: string] =
  ## The NTLMv2 and LMv2 answers to a challenge (MS-NLMP 3.3.2).
  let key = ntowfv2(user, domain, password)
  var ts = ""
  for i in 0 ..< 8: ts.add char((timestamp shr (8 * i)) and 0xFF)
  let temp = "\x01\x01\0\0\0\0\0\0" & ts & clientChallenge & "\0\0\0\0" & targetInfo & "\0\0\0\0"
  let proof = hmacMd5(key, serverChallenge & temp)
  result.nt = proof & temp
  result.lm = hmacMd5(key, serverChallenge & clientChallenge) & clientChallenge

proc ntlmAuthenticate*(challenge, user, password: string; workstation = "RETRO"): string =
  ## The third message (base64, for "Authorization: NTLM ..."): the answer
  ## to `challenge` (the base64 of the server's "WWW-Authenticate: NTLM").
  let ch = parseChallenge(challenge)
  var (domain, name) = splitUser(user)
  if domain.len == 0: domain = ch.domain
  var cc = newString(8)
  discard urandom(cc.toOpenArrayByte(0, 7))
  # (the server's time when it says one, else ours: 100 ns since 1601)
  var stamp = uint64((epochTime() + 11644473600.0) * 10_000_000.0)
  var i = 0
  let ti = ch.targetInfo
  var hasStamp = false
  while i + 4 <= ti.len:
    let id = rd16(ti, i)
    let n = rd16(ti, i + 2)
    if id == 0: break
    if id == 7 and n == 8:
      stamp = 0
      for k in 0 ..< 8: stamp = stamp or (uint64(ord(ti[i + 4 + k])) shl (8 * k))
      hasStamp = true
    i += 4 + n
  var (nt, lm) = ntlmv2Response(name, domain, password, ch.challenge, cc, ch.targetInfo, stamp)
  if hasStamp: lm = repeat('\0', 24)     # (MS-NLMP: no LMv2 with the server's time)
  let d = utf16le(domain)
  let u = utf16le(name)
  let w = utf16le(workstation)
  var off = 64
  proc field(data: string; off: var int): string =
    result = le16(data.len) & le16(data.len) & le32(uint32(off))
    off += data.len
  var head = "NTLMSSP\0" & le32(3)
  head.add field(lm, off)
  head.add field(nt, off)
  head.add field(d, off)
  head.add field(u, off)
  head.add field(w, off)
  head.add field("", off)                       # (no session key: HTTP needs none)
  head.add le32(ch.flags and negotiateFlags and not 0x40000000'u32)
  encode(head & lm & nt & d & u & w)

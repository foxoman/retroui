## Is a message really from who it says? The checks of a message's sender
## (the domain of its From address): its DKIM signatures, verified here
## (RSA and Ed25519, RFC 6376 and 8463, against the keys the domain
## publishes in DNS), what the mail provider found when it took the message
## in (its Authentication-Results: DMARC, DKIM, SPF -- trusted only from the
## provider's own servers, and only its topmost one, since anyone can write
## one into a message they send), and the domain's DMARC policy.
##
## .. code-block:: nim
##   let c = checkSender(raw, trusted = providerAuthservs("imap.gmail.com"))
##   case c.state
##   of senderVerified: echo "from ", c.domain, " (", c.detail, ")"
##   of senderFailed: echo "NOT from ", c.domain, ": ", c.detail
##   of senderUnverified: echo c.domain, " asks for proof; there is none"
##   of senderUnknown: discard
##
##   # just the headers (a Gmail or Microsoft Graph message):
##   let h = checkHeaders(headers, providerAuthservs("gmail"))
##
## A DKIM signature counts when its domain is the From address's own (or
## its organization's: "mail.example.com" for "example.com", DMARC's
## relaxed alignment, by the Public Suffix List); one of another domain
## proves nothing about the sender. Signatures that prove nothing are not
## counted as proof: SHA-1, a body only partly signed ("l="), a key marked
## for testing, a key shorter than 1024 bits. Never raises.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, times]
import mime, dnsquery, domains, sha2, rsa
import vault                     # (Monocypher's Ed25519)
from codec import unbase64

type
  AuthResult* = object
    ## One method's result in an Authentication-Results header.
    meth*, result*: string               ## "dkim", "pass" (lower case)
    props*: seq[(string, string)]        ## ("header.d", "example.com"): names lower case
  AuthResults* = object
    ## An Authentication-Results header (RFC 8601).
    authserv*: string                    ## who wrote it ("mx.google.com"; "" none named: Microsoft's)
    results*: seq[AuthResult]

  DkimState* = enum
    dkimPass       ## verified: the domain signed it and nothing signed has changed
    dkimFail       ## does not verify: changed on the way, a wrong or missing key, damaged
    dkimNeutral    ## verifies, but proves nothing (SHA-1, part of the body, a testing key)
    dkimTempError  ## the key could not be had (no network): ask again later
  DkimResult* = object
    state*: DkimState
    domain*, selector*: string           ## d= and s=
    detail*: string                      ## why, in words

  SenderState* = enum
    senderUnknown     ## nothing says either way (not signed, no policy, not checked)
    senderVerified    ## it is from its From address's domain
    senderUnverified  ## its domain asks that its mail be proven, and this message is not
    senderFailed      ## it is not from that domain (or it names more than one sender)
  SenderCheck* = object
    state*: SenderState
    domain*: string          ## the From address's domain (lower case)
    by*: string              ## who found it: "mx.google.com", "this device"
    detail*: string          ## in words ("DMARC passed", "signed by example.com")
    dkim*: seq[DkimResult]   ## the signatures, verified here (none: not verified here)

  TxtLookup* = proc (name: string): DnsResult {.gcsafe.}
    ## A TXT question (for the tests: their own records); nil: DNS.

# ---- Authentication-Results ------------------------------------------------------------

proc dropComments(s: string): string =
  ## (the text without its (comments), quoted strings kept as they are)
  var depth = 0
  var quoted = false
  var i = 0
  while i < s.len:
    let c = s[i]
    if quoted:
      result.add c
      if c == '\\' and i + 1 < s.len:
        result.add s[i + 1]
        inc i
      elif c == '"': quoted = false
    elif c == '"' and depth == 0:
      quoted = true
      result.add c
    elif c == '(':
      inc depth
      if depth == 1: result.add ' '
    elif c == ')' and depth > 0: dec depth
    elif depth == 0: result.add c
    inc i

proc splitOutside(s: string; sep: char): seq[string] =
  ## (`s` split at `sep` not inside a quoted string)
  var cur = ""
  var quoted = false
  for c in s:
    if c == '"': quoted = not quoted
    if c == sep and not quoted:
      result.add cur
      cur = ""
    else: cur.add c
  result.add cur

proc unquote(s: string): string =
  if s.len >= 2 and s[0] == '"' and s[^1] == '"': s[1 .. ^2].replace("\\\"", "\"") else: s

proc parseAuthResults*(value: string): AuthResults =
  ## An Authentication-Results (or ARC-Authentication-Results) header's
  ## value: who wrote it and each method's result.
  var segs = splitOutside(dropComments(value.replace("\r\n", " ").replace('\n', ' ')), ';')
  if segs.len == 0: return
  var first = segs[0].strip
  if first.toLowerAscii.startsWith("i=") and segs.len > 1:   # (ARC's instance tag first)
    segs.delete(0)
    first = segs[0].strip
  let firstWord = first.splitWhitespace
  if firstWord.len > 0 and '=' notin firstWord[0]:
    result.authserv = firstWord[0].toLowerAscii.strip(chars = {'.'})
    segs.delete(0)
  for seg in segs:
    let words = seg.splitWhitespace
    if words.len == 0: continue
    let e = words[0].find('=')
    if e <= 0: continue      # ("none": no results)
    var r = AuthResult(meth: words[0][0 ..< e].toLowerAscii,
                       result: words[0][e + 1 .. ^1].toLowerAscii.unquote)
    let slash = r.meth.find('/')                  # ("dkim/1": a version)
    if slash > 0: r.meth = r.meth[0 ..< slash]
    for w in words[1 .. ^1]:
      let k = w.find('=')
      if k > 0: r.props.add (w[0 ..< k].toLowerAscii, w[k + 1 .. ^1].unquote)
    result.results.add r

proc prop*(r: AuthResult; name: string): string =
  ## A property's value ("header.d"), "" when it has none.
  for (k, v) in r.props:
    if k == name: return v

proc providerAuthservs*(host: string): seq[string] =
  ## Who writes the Authentication-Results a provider's mail comes with,
  ## for an account's server (`host`: "imap.gmail.com", "outlook.office365.com")
  ## or kind ("gmail", "microsoft"): exact names, ".suffix" for any of a
  ## family of servers, "" for a header that names none (Microsoft's). None
  ## for a provider not known here (its mail is then checked here only).
  let h = host.toLowerAscii.strip(chars = {'.'})
  template ends(s: string): bool = h == s or h.endsWith("." & s)
  if h == "gmail" or ends("gmail.com") or ends("googlemail.com"): @["mx.google.com"]
  elif h == "microsoft" or ends("office365.com") or ends("outlook.com") or ends("hotmail.com") or
       ends("live.com"): @[""]
  elif ends("yahoo.com") or ends("aol.com") or ends("ymail.com"): @[".yahoo.com", ".aol.com"]
  elif ends("me.com") or ends("icloud.com") or ends("mac.com"): @[".icloud.com"]
  elif ends("fastmail.com") or ends("messagingengine.com"): @[".messagingengine.com"]
  elif ends("zoho.com") or ends("zoho.eu") or ends("zohomail.com"): @["mx.zohomail.com", "mx.zoho.eu", "mx.zoho.com"]
  else: @[]

proc topAuthserv*(headers: openArray[(string, string)]): tuple[found: bool; id: string] =
  ## Who wrote the topmost Authentication-Results (the last server's:
  ## the account's provider's own, when it writes them).
  for (k, v) in headers:
    if k.toLowerAscii == "authentication-results":
      return (true, parseAuthResults(v).authserv)

proc trustedId(id: string; trusted: openArray[string]): bool =
  for t in trusted:
    if t.len == 0:
      if id.len == 0: return true
    elif t[0] == '.':
      if id.endsWith(t): return true
    elif id == t: return true

# ---- the message's header fields as written -------------------------------------------

proc crlf(raw: string): string =
  ## (lines ended CRLF, as DKIM signs them: a file read from disk may have LF only)
  var bare = false
  for i, c in raw:
    if c == '\n' and (i == 0 or raw[i - 1] != '\r'):
      bare = true
      break
  if not bare: return raw
  result = newStringOfCap(raw.len + raw.len div 30)
  for i, c in raw:
    if c == '\n' and (i == 0 or raw[i - 1] != '\r'): result.add '\r'
    result.add c

proc fields(raw: string; bodyAt: var int): seq[tuple[name, text: string]] =
  ## (each header field: its name and its whole text, folding and CRLF kept)
  var i = 0
  bodyAt = raw.len
  while i < raw.len:
    if raw[i] == '\r' and i + 1 < raw.len and raw[i + 1] == '\n':
      bodyAt = i + 2
      return
    var j = raw.find("\r\n", i)
    while j >= 0 and j + 2 < raw.len and raw[j + 2] in {' ', '\t'}:
      j = raw.find("\r\n", j + 2)
    let stop = if j < 0: raw.len else: j + 2
    let text = raw[i ..< stop]
    let colon = text.find(':')
    if colon > 0 and text[0] notin {' ', '\t'}:
      result.add (text[0 ..< colon].strip, text)
    i = stop
    if result.len > 2000: break

proc valueOf(text: string): string =
  let colon = text.find(':')
  if colon < 0: "" else: text[colon + 1 .. ^1]

# ---- DKIM (RFC 6376, 8463, 8301) -------------------------------------------------------

proc tags(s: string): seq[(string, string)] =
  for part in s.split(';'):
    let e = part.find('=')
    if e <= 0: continue
    var v = ""
    for c in part[e + 1 .. ^1]:
      if c notin {' ', '\t', '\r', '\n'}: v.add c
    result.add (part[0 ..< e].strip(chars = Whitespace), v)
  # (b= and bh= are base64: their spaces are nothing; other values keep none either)

proc tag(ts: seq[(string, string)]; name: string; default = ""): string =
  for (k, v) in ts:
    if k == name: return v
  default

proc hasTag(ts: seq[(string, string)]; name: string): bool =
  for (k, _) in ts:
    if k == name: return true

proc relaxedHeader(name, text: string): string =
  var v = valueOf(text).replace("\r\n", "")
  var squeezed = newStringOfCap(v.len)
  var space = false
  for c in v:
    if c in {' ', '\t'}: space = true
    else:
      if space and squeezed.len > 0: squeezed.add ' '
      space = false
      squeezed.add c
  name.toLowerAscii & ":" & squeezed & "\r\n"

proc canonHeader(relaxed: bool; name, text: string): string =
  if relaxed: relaxedHeader(name, text) else: text

proc canonBody(body: string; relaxed: bool): string =
  if relaxed:
    result = newStringOfCap(body.len)
    var i = 0
    while i < body.len:
      var j = body.find("\r\n", i)
      let last = j < 0
      if last: j = body.len
      var line = newStringOfCap(j - i)
      var space = false
      for k in i ..< j:
        let c = body[k]
        if c in {' ', '\t'}: space = true
        else:
          if space: line.add ' '
          space = false
          line.add c
      result.add line
      if not last: result.add "\r\n"
      i = j + 2
    # (empty lines at the end are not counted)
    while result.endsWith("\r\n\r\n"): result.setLen(result.len - 2)
    if result == "\r\n": result = ""
    if result.len > 0 and not result.endsWith("\r\n"): result.add "\r\n"
  else:
    result = body
    while result.endsWith("\r\n\r\n"): result.setLen(result.len - 2)
    if result.len == 0 or not result.endsWith("\r\n"):
      if result.len == 0: result = "\r\n" else: result.add "\r\n"

proc withoutB(text: string): string =
  ## (the DKIM-Signature field with its b= value taken out, the rest as written)
  let colon = text.find(':')
  if colon < 0: return text
  result = text[0 .. colon]
  var i = colon + 1
  while i <= text.len:
    var j = text.find(';', i)
    if j < 0: j = text.len
    let part = text[i ..< j]
    let e = part.find('=')
    if e > 0 and part[0 ..< e].strip(chars = Whitespace) == "b":
      result.add part[0 .. e]
      # (what follows the value -- the CRLF of the field's end -- stays)
      var tail = part[e + 1 .. ^1]
      var keep = ""
      if tail.endsWith("\r\n") and j == text.len: keep = "\r\n"
      result.add keep
    else: result.add part
    if j < text.len: result.add ';'
    i = j + 1

proc derItem(b: string; at: var int): tuple[tag: int; a, z: int] =
  if at + 2 > b.len: return (-1, 0, 0)
  let tag = ord(b[at])
  var len = ord(b[at + 1])
  var p = at + 2
  if (len and 0x80) != 0:
    let n = len and 0x7F
    if n == 0 or n > 3 or p + n > b.len: return (-1, 0, 0)
    len = 0
    for i in 0 ..< n: len = (len shl 8) or ord(b[p + i])
    p += n
  if p + len > b.len: return (-1, 0, 0)
  at = p + len
  (tag, p, p + len)

proc rsaPublic(der: string): tuple[n, e: seq[byte]] =
  ## (n and e of a SubjectPublicKeyInfo, or of a bare RSAPublicKey; empty: neither)
  var at = 0
  let outer = derItem(der, at)
  if outer.tag != 0x30: return
  var p = outer.a
  var first = derItem(der, p)
  var key = der
  var kp = 0
  if first.tag == 0x30:                       # (SubjectPublicKeyInfo: the algorithm, then the key's bits)
    let bits = derItem(der, p)
    if bits.tag != 0x03 or bits.z - bits.a < 2: return
    key = der[bits.a + 1 ..< bits.z]
    kp = 0
    let s = derItem(key, kp)
    if s.tag != 0x30: return
    kp = s.a
  else:
    kp = outer.a
  var nums: seq[seq[byte]]
  for k in 0 .. 1:
    let it = derItem(key, kp)
    if it.tag != 0x02: return
    var v: seq[byte]
    for i in it.a ..< it.z: v.add byte(ord(key[i]))
    while v.len > 1 and v[0] == 0: v.delete(0)
    nums.add v
  (nums[0], nums[1])

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  for i, c in s: result[i] = byte(ord(c))

proc lookupTxt(lookup: TxtLookup; name: string): DnsResult =
  if lookup != nil: lookup(name) else: dnsQuery(name, "TXT")

proc verifyOne(raw: string; flds: seq[tuple[name, text: string]]; bodyAt: int; sigText: string;
               lookup: TxtLookup): DkimResult =
  let ts = tags(valueOf(sigText).replace("\r\n", ""))
  result.domain = ts.tag("d").toLowerAscii
  result.selector = ts.tag("s")
  result.state = dkimFail
  template fail(why: string) =
    result.detail = why
    return
  if ts.tag("v") != "1": fail "not a DKIM signature this reads (v=" & ts.tag("v") & ")"
  let algo = ts.tag("a").toLowerAscii
  if result.domain.len == 0 or result.selector.len == 0 or ts.tag("b").len == 0 or
     ts.tag("bh").len == 0 or ts.tag("h").len == 0:
    fail "the signature is missing a part"
  if algo notin ["rsa-sha256", "ed25519-sha256", "rsa-sha1"]: fail "signed with " & algo & ", not known here"
  var heads: seq[string]
  for h in ts.tag("h").split(':'):
    heads.add h.strip.toLowerAscii
  if "from" notin heads: fail "the From line is not signed"
  let ident = ts.tag("i")
  if ident.len > 0:
    let at = ident.rfind('@')
    let idom = (if at >= 0: ident[at + 1 .. ^1] else: ident).toLowerAscii
    if idom != result.domain and not idom.endsWith("." & result.domain):
      fail "its i= is not of its domain"
  let x = ts.tag("x")
  if x.len > 0:
    try:
      if parseBiggestInt(x).float < epochTime(): fail "the signature has expired"
    except ValueError: fail "a damaged expiry"
  let canon = ts.tag("c", "simple/simple").toLowerAscii.split('/')
  let relaxedHead = canon[0] == "relaxed"
  let relaxedBody = canon.len > 1 and canon[1] == "relaxed"
  if canon[0] notin ["simple", "relaxed"] or (canon.len > 1 and canon[1] notin ["simple", "relaxed"]):
    fail "a canonicalization not known here"
  # the body
  var body = canonBody(raw[min(bodyAt, raw.len) .. ^1], relaxedBody)
  var partial = false
  if ts.hasTag("l"):
    let l = try: parseInt(ts.tag("l")) except ValueError: -1
    if l < 0 or l > body.len: fail "a wrong body length"
    if l < body.len: partial = true
    body.setLen(l)
  if algo == "rsa-sha1":
    result.state = dkimNeutral
    fail "SHA-1, which no longer proves anything"
  let bh = try: unbase64(ts.tag("bh")) except ValueError: ""
  if sha256(body).toBinary != bh: fail "the message was changed after it was signed (its body)"
  # the key
  let q = lookupTxt(lookup, result.selector & "._domainkey." & result.domain)
  if q.status == dnsFailed:
    result.state = dkimTempError
    fail "its key could not be had: " & q.error
  if q.status == dnsNoName: fail "its domain publishes no such key"
  var kt: seq[(string, string)]
  var found = false
  for txt in q.answers:
    kt = tags(txt)
    if kt.hasTag("p") and (kt.tag("v", "DKIM1") == "DKIM1"):
      found = true
      break
  if not found: fail "its domain's key is damaged"
  let keyType = kt.tag("k", "rsa").toLowerAscii
  if kt.tag("p").len == 0: fail "its key has been withdrawn"
  if (algo.startsWith("rsa") and keyType != "rsa") or (algo.startsWith("ed25519") and keyType != "ed25519"):
    fail "its key is of another kind"
  let hs = kt.tag("h")
  if hs.len > 0 and "sha256" notin hs.toLowerAscii.split(':'): fail "its key is not for SHA-256"
  let svc = kt.tag("s", "*")
  if svc != "*" and "email" notin svc.split(':'): fail "its key is not for mail"
  let flags = kt.tag("t").toLowerAscii.split(':')
  if "s" in flags and ident.len > 0:
    let at = ident.rfind('@')
    if (if at >= 0: ident[at + 1 .. ^1] else: ident).toLowerAscii != result.domain:
      fail "its key is for " & result.domain & " itself only"
  # the header fields signed: each name's last one first (bottom up), then the signature itself
  var used = newSeq[bool](flds.len)
  var data = ""
  for h in heads:
    var k = flds.high
    while k >= 0:
      if not used[k] and flds[k].name.toLowerAscii == h: break
      dec k
    if k >= 0:
      used[k] = true
      data.add canonHeader(relaxedHead, flds[k].name, flds[k].text)
  var me = canonHeader(relaxedHead, "DKIM-Signature", withoutB(sigText))
  if me.endsWith("\r\n"): me.setLen(me.len - 2)
  if relaxedHead:
    # (the value's end, with no spaces after it once b= is empty)
    while me.len > 0 and me[^1] in {' ', '\t'}: me.setLen(me.len - 1)
  data.add me
  let sig = try: unbase64(ts.tag("b")) except ValueError: ""
  var ok = false
  let pkey = try: unbase64(kt.tag("p")) except ValueError: ""
  if keyType == "rsa":
    let (n, e) = rsaPublic(pkey)
    if n.len == 0: fail "its domain's key is damaged"
    if n.len < 128: fail "its key is too short to prove anything"
    if sig.len > n.len: fail "a damaged signature"
    var s = bytesOf(sig)
    while s.len < n.len: s.insert(0'u8, 0)
    ok = verify(n, e, bytesOf(data), s)
  else:
    if pkey.len != 32 or sig.len != 64: fail "a damaged signature or key"
    var pk: array[32, byte]
    var sg: array[64, byte]
    for i in 0 ..< 32: pk[i] = byte(ord(pkey[i]))
    for i in 0 ..< 64: sg[i] = byte(ord(sig[i]))
    let digest = sha256(data)
    ok = crypto_ed25519_check(addr sg, addr pk, unsafeAddr digest[0], 32) == 0
  if not ok: fail "the message was changed after it was signed, or the signature is not its domain's"
  if partial:
    result.state = dkimNeutral
    fail "only part of the body is signed: what was added after it is not"
  if "y" in flags:
    result.state = dkimNeutral
    fail "its domain is still testing its key"
  result.state = dkimPass
  result.detail = "signed by " & result.domain

proc verifyDkim*(raw: string; lookup: TxtLookup = nil): seq[DkimResult] {.gcsafe.} =
  ## Each DKIM signature of message `raw` (its whole source), verified (at
  ## most 8: the rest are not counted).
  let msg = crlf(raw)
  var bodyAt = 0
  let flds = fields(msg, bodyAt)
  for f in flds:
    if f.name.toLowerAscii == "dkim-signature":
      if result.len >= 8: break
      result.add verifyOne(msg, flds, bodyAt, f.text, lookup)

# ---- DMARC policy (RFC 7489) -----------------------------------------------------------

proc dmarcPolicy*(domain: string; lookup: TxtLookup = nil): tuple[found: bool; policy: string; failed: bool] {.gcsafe.} =
  ## The domain's DMARC policy ("none", "quarantine", "reject"): its own
  ## record, else its organization's (whose sp= then says). `failed`: DNS
  ## could not say.
  proc ask(name: string): tuple[status: DnsStatus; rec: seq[(string, string)]] =
    let q = lookupTxt(lookup, "_dmarc." & name)
    result.status = q.status
    for a in q.answers:
      if a.strip.startsWith("v=DMARC1"):
        result.rec = tags(a)
        return
    if result.status == dnsOk: result.status = dnsNoName
  let d = domain.toLowerAscii
  var r = ask(d)
  if r.status == dnsFailed: return (false, "", true)
  if r.rec.len > 0: return (true, r.rec.tag("p").toLowerAscii, false)
  let org = registrableDomain(d)
  if org.len > 0 and org != d:
    r = ask(org)
    if r.status == dnsFailed: return (false, "", true)
    if r.rec.len > 0:
      return (true, r.rec.tag("sp", r.rec.tag("p")).toLowerAscii, false)
  (false, "", false)

# ---- the verdict ----------------------------------------------------------------------

proc domainOfAddress(s: string): string =
  let at = s.rfind('@')
  if at < 0: "" else: s[at + 1 .. ^1].strip(chars = {'>', ' ', '.'}).toLowerAscii

proc aligned(a, b: string): bool =
  let x = a.toLowerAscii.strip(chars = {'.'})
  let y = b.toLowerAscii.strip(chars = {'.'})
  x.len > 0 and y.len > 0 and (x == y or sameOrganization(x, y))

proc fromOf(headers: openArray[(string, string)]): tuple[domain: string; count, addresses: int] =
  for (k, v) in headers:
    if k.toLowerAscii == "from":
      inc result.count
      let a = parseAddresses(v)
      result.addresses += a.len
      if a.len > 0 and result.domain.len == 0: result.domain = domainOfAddress(a[0].email)

proc checkHeaders*(headers: openArray[(string, string)]; trusted: openArray[string];
                   dkim: seq[DkimResult] = @[]): SenderCheck =
  ## The verdict from the message's header fields (as `MimePart.headers`
  ## has them: top first) -- the provider's Authentication-Results, from the
  ## servers `trusted` names (`providerAuthservs`) -- and the signatures
  ## verified here (`dkim`, none: none verified here).
  let f = fromOf(headers)
  result.domain = f.domain
  result.dkim = dkim
  if f.count == 0 or f.domain.len == 0:
    result.detail = "it names no sender"
    return
  if f.count > 1 or f.addresses > 1:
    result.state = senderFailed
    result.by = "this device"
    result.detail = "it names more than one sender"
    return
  # a signature verified here, of the sender's own domain, proves it
  for d in dkim:
    if d.state == dkimPass and aligned(d.domain, f.domain):
      result.state = senderVerified
      result.by = "this device"
      result.detail = d.detail
      return
  # the provider's: the topmost header of each of its servers'
  var seenIds: seq[string]
  var got: seq[AuthResult]
  var by = ""
  for (k, v) in headers:
    if k.toLowerAscii != "authentication-results": continue
    let ar = parseAuthResults(v)
    if not trustedId(ar.authserv, trusted) or ar.authserv in seenIds: continue
    seenIds.add ar.authserv
    if by.len == 0: by = (if ar.authserv.len > 0: ar.authserv else: "the provider")
    for r in ar.results:
      var dup = false
      for g in got:
        if g.meth == r.meth: dup = true
      if not dup: got.add r
  if got.len == 0: return
  result.by = by
  var dmarc, compauth = ""
  for r in got:
    case r.meth
    of "dmarc":
      let hf = r.prop("header.from").toLowerAscii
      if hf.len == 0 or hf == f.domain: dmarc = r.result
    of "compauth": compauth = r.result
    else: discard
  if dmarc == "pass":
    result.state = senderVerified
    result.detail = "DMARC passed"
    return
  if dmarc == "fail" or compauth == "fail":
    result.state = senderFailed
    result.detail = (if dmarc == "fail": "DMARC failed: " else: "its checks failed: ") &
                    f.domain & " did not send it"
    return
  for r in got:
    if r.result != "pass": continue
    if r.meth == "dkim":
      var d = r.prop("header.d")
      if d.len == 0: d = domainOfAddress(r.prop("header.i"))
      if aligned(d, f.domain):
        result.state = senderVerified
        result.detail = "signed by " & d.toLowerAscii
        return
    elif r.meth == "spf":
      var m = r.prop("smtp.mailfrom")
      if '@' in m: m = domainOfAddress(m)
      if aligned(m, f.domain):
        result.state = senderVerified
        result.detail = "sent from a server " & f.domain & " names"
        return

proc checkSender*(raw: string; trusted: openArray[string] = []; lookup: TxtLookup = nil;
                  policy = true): SenderCheck =
  ## The verdict on message `raw` (its whole source): the provider's
  ## results (from `trusted` servers), else its signatures verified here,
  ## and, when neither proves it, the domain's DMARC policy (`policy`): a
  ## domain that asks for its mail to be proven makes an unproven message
  ## `senderUnverified`.
  let root = parseMime(raw)
  # (the provider's own word first: when it settles it, no DNS is asked)
  result = checkHeaders(root.headers, trusted)
  if result.state in {senderVerified, senderFailed}: return
  let sigs = verifyDkim(raw, lookup)
  result = checkHeaders(root.headers, trusted, sigs)
  if result.state == senderUnknown and policy and result.domain.len > 0:
    var temp = false
    for d in sigs:
      if d.state == dkimTempError: temp = true
    if temp: return
    let p = dmarcPolicy(result.domain, lookup)
    if p.found and p.policy in ["reject", "quarantine"]:
      result.state = senderUnverified
      result.by = "this device"
      result.detail = result.domain & " asks that its mail be signed; this message is not signed by it"

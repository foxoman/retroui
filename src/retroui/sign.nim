## Signatures that stores and systems ask of what an app is shipped in,
## made in Nim (RSA: `retroui/rsa`; no OpenSSL, no signtool, no jarsigner):
##
## - `jarSign`: the JAR signature (v1) of an Android App Bundle (.aab), what
##   Google Play takes from your upload key
## - `authenticodeSign`: Windows' Authenticode signature of a program (.exe,
##   .dll), what SmartScreen and the Microsoft Store look for
## - `cmsSignedData`: the CMS / PKCS #7 signature both are made of
##
## Keys are PEM (PKCS #8 or PKCS #1, unencrypted), certificates DER or PEM.
## A .pfx (PKCS #12) of a certificate authority is turned into them with
## `openssl pkcs12 -in my.pfx -nocerts -nodes -out key.pem` and
## `openssl pkcs12 -in my.pfx -clcerts -nokeys -out cert.pem`.

import std/[strutils, base64, os, sequtils, sysrand]
import rsa
from codec import unbase64

type SignError* = object of CatchableError

proc bad(why: string) {.noreturn.} = raise newException(SignError, why)

# ---- DER -----------------------------------------------------------------------------------

proc derLen(n: int): seq[byte] =
  if n < 0x80: return @[byte(n)]
  var b: seq[byte]
  var v = n
  while v > 0:
    b.insert byte(v and 0xFF)
    v = v shr 8
  @[byte(0x80 or b.len)] & b

proc tlv*(tag: byte; content: openArray[byte]): seq[byte] =
  ## A DER element: its tag, length and content.
  result = @[tag] & derLen(content.len)
  result.add content

proc derSeq*(parts: varargs[seq[byte]]): seq[byte] =
  var c: seq[byte]
  for p in parts: c.add p
  tlv(0x30, c)

proc after(a, b: seq[byte]): bool =
  for i in 0 ..< min(a.len, b.len):
    if a[i] != b[i]: return a[i] > b[i]
  a.len > b.len

proc derSet*(parts: varargs[seq[byte]]): seq[byte] =
  ## A SET (its elements sorted, as DER wants a SET OF sorted).
  var ps = @parts
  for i in 1 ..< ps.len:
    var j = i
    while j > 0 and after(ps[j - 1], ps[j]):
      swap(ps[j - 1], ps[j])
      dec j
  var c: seq[byte]
  for p in ps: c.add p
  tlv(0x31, c)

proc derInt*(v: int): seq[byte] =
  var b: seq[byte]
  var x = v
  while true:
    b.insert byte(x and 0xFF)
    x = x shr 8
    if x == 0 and (b[0] and 0x80) == 0: break
  tlv(0x02, b)

proc derOid*(s: string): seq[byte] =
  let parts = s.split('.')
  var c = @[byte(parseInt(parts[0]) * 40 + parseInt(parts[1]))]
  for p in parts[2 .. ^1]:
    var v = parseInt(p)
    var b = @[byte(v and 0x7F)]
    v = v shr 7
    while v > 0:
      b.insert byte(0x80 or (v and 0x7F))
      v = v shr 7
    c.add b
  tlv(0x06, c)

proc derNull*(): seq[byte] = @[0x05'u8, 0x00]
proc derOctets*(content: openArray[byte]): seq[byte] = tlv(0x04, content)
proc ctx*(n: int; content: openArray[byte]; constructed = true): seq[byte] =
  ## A context-specific element [n] (EXPLICIT when it wraps a whole element).
  tlv(byte((if constructed: 0xA0 else: 0x80) or n), content)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc strOf(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

type Tlv = tuple[tag: byte; a, z, start: int]

proc readTlv(b: openArray[byte]; at: var int): Tlv =
  if at + 2 > b.len: bad("a damaged DER element")
  let start = at
  let tag = b[at]
  var len = int(b[at + 1])
  var p = at + 2
  if (len and 0x80) != 0:
    let n = len and 0x7F
    if n == 0 or n > 4 or p + n > b.len: bad("a damaged DER element")
    len = 0
    for i in 0 ..< n: len = (len shl 8) or int(b[p + i])
    p += n
  if len < 0 or p + len > b.len: bad("a damaged DER element")
  at = p + len
  (tag, p, p + len, start)

# ---- certificates --------------------------------------------------------------------------

proc base64Ok(body: string): bool =
  ## (only base64's letters: Nim's `decode` raising on a wrong one leaks
  ## the text it was making, so the letters are checked first)
  for c in body:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '+', '/', '=', '-', '_'}: return false
  true

proc readCert*(data: string): seq[byte] =
  ## A certificate from DER or PEM ("BEGIN CERTIFICATE"): its DER.
  if "-----BEGIN CERTIFICATE-----" in data:
    var body = ""
    var inside = false
    for line in data.splitLines:
      let l = line.strip
      if l == "-----BEGIN CERTIFICATE-----": inside = true
      elif l == "-----END CERTIFICATE-----": break
      elif inside: body.add l
    if not base64Ok(body): bad("the certificate's PEM is damaged")
    try: return bytesOf(unbase64(body))
    except ValueError: bad("the certificate's PEM is damaged")
  bytesOf(data)

proc issuerAndSerial*(cert: openArray[byte]): seq[byte] =
  ## IssuerAndSerialNumber of a certificate (who issued it, its number):
  ## how a signature names the certificate it was made with.
  var at = 0
  let c = readTlv(cert, at)
  if c.tag != 0x30: bad("not a certificate")
  var p = c.a
  let tbs = readTlv(cert, p)
  if tbs.tag != 0x30: bad("not a certificate")
  var q = tbs.a
  var e = readTlv(cert, q)
  if e.tag == 0xA0: e = readTlv(cert, q)              # (the version)
  if e.tag != 0x02: bad("the certificate has no serial number")
  let serial = cert[e.start ..< e.z]
  discard readTlv(cert, q)                            # (its signature's algorithm)
  let issuer = readTlv(cert, q)
  if issuer.tag != 0x30: bad("the certificate has no issuer")
  derSeq(@(cert[issuer.start ..< issuer.z]), @serial)

proc readCerts*(data: string): seq[seq[byte]] =
  ## Every certificate of a PEM file (a chain), or the one of a DER file.
  if "-----BEGIN CERTIFICATE-----" notin data: return @[bytesOf(data)]
  var body = ""
  var inside = false
  for line in data.splitLines:
    let l = line.strip
    if l == "-----BEGIN CERTIFICATE-----":
      inside = true
      body = ""
    elif l == "-----END CERTIFICATE-----":
      inside = false
      if not base64Ok(body): bad("a certificate's PEM is damaged")
      try: result.add bytesOf(unbase64(body))
      except ValueError: bad("a certificate's PEM is damaged")
    elif inside: body.add l

proc oidText(b: openArray[byte]): string =
  if b.len == 0: return ""
  result = $(int(b[0]) div 40) & "." & $(int(b[0]) mod 40)
  var v = 0
  for i in 1 ..< b.len:
    v = (v shl 7) or int(b[i] and 0x7F)
    if (b[i] and 0x80) == 0:
      result.add "." & $v
      v = 0

proc certSubject*(cert: openArray[byte]): string =
  ## The certificate's subject as Windows writes it ("CN=Me, O=My Company,
  ## C=OM": its last part first): what an MSIX's publisher must be.
  var at = 0
  let c = readTlv(cert, at)
  if c.tag != 0x30: bad("not a certificate")
  var p = c.a
  let tbs = readTlv(cert, p)
  var q = tbs.a
  var e = readTlv(cert, q)
  if e.tag == 0xA0: e = readTlv(cert, q)              # (the version; then the serial)
  for _ in 0 ..< 3: e = readTlv(cert, q)              # algorithm, issuer, validity
  let subject = readTlv(cert, q)
  if subject.tag != 0x30: bad("the certificate has no subject")
  var parts: seq[string]
  var r = subject.a
  while r < subject.z:
    let rdn = readTlv(cert, r)
    var s = rdn.a
    while s < rdn.z:
      let atv = readTlv(cert, s)
      var t = atv.a
      let oid = readTlv(cert, t)
      let value = readTlv(cert, t)
      let key = case oidText(cert.toOpenArray(oid.a, oid.z - 1))
                of "2.5.4.3": "CN"
                of "2.5.4.6": "C"
                of "2.5.4.7": "L"
                of "2.5.4.8": "S"
                of "2.5.4.9": "STREET"
                of "2.5.4.10": "O"
                of "2.5.4.11": "OU"
                of "2.5.4.5": "SERIALNUMBER"
                of "2.5.4.17": "PostalCode"
                of "1.2.840.113549.1.9.1": "E"
                of "0.9.2342.19200300.100.1.25": "DC"
                else: "OID." & oidText(cert.toOpenArray(oid.a, oid.z - 1))
      var v = strOf(cert.toOpenArray(value.a, value.z - 1))
      if value.tag == 0x1E:                           # (BMPString)
        var u = ""
        var i = 0
        while i + 1 < v.len:
          u.add v[i + 1]
          i += 2
        v = u
      if v.len == 0 or v.anyIt(it in {',', '+', '=', '"', '<', '>', '#', ';', '\n'}) or
         v[0] == ' ' or v[^1] == ' ':
        v = "\"" & v.replace("\"", "\"\"") & "\""
      parts.add key & "=" & v
  var reversed: seq[string]
  for i in countdown(parts.high, 0): reversed.add parts[i]
  reversed.join(", ")

# ---- CMS (PKCS #7) SignedData ----------------------------------------------------------------

const
  oidData* = "1.2.840.113549.1.7.1"
  oidSignedData = "1.2.840.113549.1.7.2"
  oidSha256 = "2.16.840.1.101.3.4.2.1"
  oidRsa = "1.2.840.113549.1.1.1"
  oidContentType = "1.2.840.113549.1.9.3"
  oidMessageDigest = "1.2.840.113549.1.9.4"
  oidSigningTime = "1.2.840.113549.1.9.5"

proc attribute*(oid: string; value: seq[byte]): seq[byte] =
  ## A signed attribute (its type and its one value).
  derSeq(derOid(oid), derSet(value))

type Timestamper* = proc (query: seq[byte]): seq[byte] {.closure.}
  ## Sends an RFC 3161 query (`timestampQuery`) to a time-stamping
  ## authority and gives back its answer (POST, "application/timestamp-query";
  ## retrokit's `--timestamp:URL` does it with retroui/http).

proc timestampQuery*(signature: openArray[byte]): seq[byte] =
  ## The RFC 3161 query for a time stamp of `signature` (its SHA-256, a
  ## random nonce, the authority's certificate asked for).
  var nonce = newSeq[byte](8)
  if not urandom(nonce): bad("no random numbers")
  nonce[0] = nonce[0] and 0x7F
  let imprint = derSeq(derSeq(derOid(oidSha256), derNull()), derOctets(sha256(signature)))
  derSeq(derInt(1), imprint, tlv(0x02, nonce), tlv(0x01, @[0xFF'u8]))

proc timestampToken*(answer: openArray[byte]; signature: openArray[byte]): seq[byte] =
  ## The token (a CMS signature of the authority) in an RFC 3161 answer, for
  ## `signature`; raises `SignError` when the authority refused, or stamped
  ## something else.
  var at = 0
  let resp = readTlv(answer, at)
  if resp.tag != 0x30: bad("the time-stamping authority's answer is damaged")
  var p = resp.a
  let status = readTlv(answer, p)
  var q = status.a
  let code = readTlv(answer, q)
  if code.tag != 0x02 or code.z - code.a != 1 or answer[code.a] > 1:
    bad("the time-stamping authority refused (status " &
        (if code.z > code.a: $int(answer[code.z - 1]) else: "?") & ")")
  if p >= resp.z: bad("the time-stamping authority sent no time stamp")
  let token = readTlv(answer, p)
  result = @(answer[token.start ..< token.z])
  let digest = sha256(signature)
  var found = false
  for i in 0 .. result.len - 32:
    if result[i] == digest[0] and result[i ..< i + 32] == @digest:
      found = true
      break
  if not found: bad("the time stamp is of something else")

proc cmsSignedData*(key: RsaKey; cert: seq[byte]; content: openArray[byte]; contentType = oidData;
                    detached = true; signedAttrs = true; digestOf: seq[byte] = @[];
                    extraAttrs: seq[seq[byte]] = @[]; chain: seq[seq[byte]] = @[];
                    timestamper: Timestamper = nil;
                    timestampOid = "1.2.840.113549.1.9.16.2.14"): seq[byte] =
  ## A CMS ContentInfo of SignedData: `content` (of `contentType`) signed by
  ## `key` with SHA-256 and RSA, `cert` (and `chain`) in it. `detached`: the
  ## content left out (a JAR's .SF is beside it). `signedAttrs`: its digest,
  ## its type and `extraAttrs` signed (else the content itself);
  ## `digestOf`: what the digest is taken of, when not the whole content
  ## (Authenticode: the content's inside). `timestamper`: the signature
  ## stamped with the time by an authority (kept as `timestampOid`), so that
  ## it stays good after the certificate expires.
  let algo = derSeq(derOid(oidSha256), derNull())
  var encap = derSeq(derOid(contentType))
  if not detached:
    encap = derSeq(derOid(contentType), ctx(0, @content))
  var signerParts: seq[seq[byte]] = @[derInt(1), issuerAndSerial(cert), algo]
  var sig: seq[byte]
  if signedAttrs:
    let digested = if digestOf.len > 0: digestOf else: @content
    let md = sha256(digested)
    var attrs = @[attribute(oidContentType, derOid(contentType)),
                  attribute(oidMessageDigest, derOctets(md))]
    attrs.add extraAttrs
    let setDer = derSet(attrs)
    # (signed as a SET; carried as [0] IMPLICIT)
    sig = key.sign(setDer)
    var implicit = setDer
    implicit[0] = 0xA0
    signerParts.add implicit
  else:
    sig = key.sign(content)
  signerParts.add derSeq(derOid(oidRsa), derNull())
  signerParts.add derOctets(sig)
  if timestamper != nil:
    let token = timestampToken(timestamper(timestampQuery(sig)), sig)
    signerParts.add tlv(0xA1, attribute(timestampOid, token))
  var certs = cert
  for c in chain: certs.add c
  let signed = derSeq(derInt(1), derSet(algo), encap, tlv(0xA0, certs), derSet(derSeq(signerParts)))
  derSeq(derOid(oidSignedData), ctx(0, signed))

# ---- JAR (v1) signatures: Android App Bundles --------------------------------------------

proc wrap72(line: string): string =
  ## (a manifest's line: at most 72 bytes, then continued with a space)
  var s = line
  result = s[0 ..< min(72, s.len)] & "\r\n"
  s = if s.len > 72: s[72 .. ^1] else: ""
  while s.len > 0:
    result.add " " & s[0 ..< min(71, s.len)] & "\r\n"
    s = if s.len > 71: s[71 .. ^1] else: ""

proc b64sha(s: string): string = encode(sha256(bytesOf(s)))

proc jarSign*(entries: openArray[(string, string)]; key: RsaKey; cert: seq[byte];
              createdBy = "Retro Nim UI"): seq[(string, string)] =
  ## The META-INF files of a JAR signature of `entries` (name, bytes):
  ## MANIFEST.MF with each entry's SHA-256, CERT.SF with the manifest's and
  ## each section's, CERT.RSA the signature of CERT.SF. Put them first in
  ## the zip.
  var mf = "Manifest-Version: 1.0\r\nCreated-By: " & createdBy & "\r\n\r\n"
  let mainAttrs = mf
  var sections: seq[(string, string)]
  for (name, data) in entries:
    if name.startsWith("META-INF/"): continue
    let sec = wrap72("Name: " & name) & "SHA-256-Digest: " & b64sha(data) & "\r\n\r\n"
    sections.add (name, sec)
    mf.add sec
  var sf = "Signature-Version: 1.0\r\nCreated-By: " & createdBy & "\r\n" &
           "SHA-256-Digest-Manifest: " & b64sha(mf) & "\r\n" &
           "SHA-256-Digest-Manifest-Main-Attributes: " & b64sha(mainAttrs) & "\r\n\r\n"
  for (name, sec) in sections:
    sf.add wrap72("Name: " & name) & "SHA-256-Digest: " & b64sha(sec) & "\r\n\r\n"
  let rsaBlock = cmsSignedData(key, cert, bytesOf(sf), detached = true, signedAttrs = false)
  @[("META-INF/MANIFEST.MF", mf), ("META-INF/CERT.SF", sf), ("META-INF/CERT.RSA", strOf(rsaBlock))]

# ---- Authenticode: Windows programs ---------------------------------------------------------

const
  oidSpcIndirectData = "1.3.6.1.4.1.311.2.1.4"
  oidSpcPeImageData = "1.3.6.1.4.1.311.2.1.15"
  oidSpcStatementType = "1.3.6.1.4.1.311.2.1.11"
  oidSpcIndividual = "1.3.6.1.4.1.311.2.1.21"
  oidSpcOpusInfo = "1.3.6.1.4.1.311.2.1.12"

type PeLayout = object
  checksumAt, certDirAt, certAt, certSize, headersEnd: int

proc u16le(s: string; at: int): int = int(uint8(s[at])) or (int(uint8(s[at + 1])) shl 8)
proc u32le(s: string; at: int): int =
  ## (a 32-bit number; one past what an int holds, on 32-bit systems, is
  ## read as the most an int holds: it fails every check of a size)
  let v = uint32(uint8(s[at])) or (uint32(uint8(s[at + 1])) shl 8) or (uint32(uint8(s[at + 2])) shl 16) or
          (uint32(uint8(s[at + 3])) shl 24)
  int(min(uint64(v), uint64(high(int))))
proc put32le(s: var string; at, v: int) =
  for k in 0 .. 3: s[at + k] = char((v shr (8 * k)) and 255)

proc peLayout(pe: string): PeLayout =
  if pe.len < 0x40 or pe[0 .. 1] != "MZ": bad("not a Windows program (no MZ)")
  let peAt = u32le(pe, 0x3C)
  if peAt < 0 or peAt > pe.len - 24 or pe[peAt ..< peAt + 4] != "PE\0\0": bad("not a Windows program (no PE)")
  let opt = peAt + 24
  if opt + 2 > pe.len: bad("a damaged program")
  let magic = u16le(pe, opt)
  let dirs = case magic
             of 0x10B: opt + 96         # PE32
             of 0x20B: opt + 112        # PE32+
             else: bad("an unknown kind of program")
  result.checksumAt = opt + 64
  result.certDirAt = dirs + 4 * 8      # (the fifth directory: certificates)
  if result.certDirAt + 8 > pe.len: bad("a damaged program")
  result.certAt = u32le(pe, result.certDirAt)
  result.certSize = u32le(pe, result.certDirAt + 4)
  result.headersEnd = u32le(pe, opt + 60)

proc peChecksum*(pe: string): uint32 =
  ## The checksum of a program as Windows works it out (its own field skipped).
  let l = peLayout(pe)
  var sum = 0'u64
  var i = 0
  while i + 1 < pe.len:
    if i == l.checksumAt or i == l.checksumAt + 2:
      i += 2
      continue
    sum += uint64(u16le(pe, i))
    sum = (sum and 0xFFFF) + (sum shr 16)
    i += 2
  if (pe.len and 1) != 0: sum += uint64(uint8(pe[^1]))
  sum = (sum and 0xFFFF) + (sum shr 16)
  sum = (sum and 0xFFFF) + (sum shr 16)
  uint32(sum) + uint32(pe.len)

proc authenticodeDigest*(pe: string): seq[byte] =
  ## The SHA-256 Authenticode hash: the program without its checksum, its
  ## certificate directory and its certificates.
  let l = peLayout(pe)
  var stop = pe.len
  if l.certAt > 0 and l.certSize > 0:
    if l.certAt < l.certDirAt + 8 or l.certAt > pe.len: bad("the program's signature is not where it can be")
    stop = l.certAt
  var data = newStringOfCap(stop)
  data.add pe[0 ..< l.checksumAt]
  data.add pe[l.checksumAt + 4 ..< l.certDirAt]
  data.add pe[l.certDirAt + 8 ..< stop]
  @(sha256(bytesOf(data)))

proc bmp(s: string): seq[byte] =
  for c in s:
    result.add 0
    result.add byte(c)

proc indirectSignature*(kind: seq[byte]; digest: openArray[byte]; key: RsaKey; cert: seq[byte];
                        description = ""; url = ""; chain: seq[seq[byte]] = @[];
                        timestamper: Timestamper = nil): seq[byte] =
  ## An Authenticode signature (SpcIndirectDataContent): the SHA-256
  ## `digest` of what is signed, `kind` saying what it is (a program's
  ## SpcPeImageData, an MSIX's SpcSipInfo...), `description` and `url`
  ## shown when Windows asks.
  let indirect = derSeq(kind, derSeq(derSeq(derOid(oidSha256), derNull()), derOctets(digest)))
  # (the digest signed is of what is inside the SEQUENCE)
  var at = 0
  let t = readTlv(indirect, at)
  let inside = indirect[t.a ..< t.z]
  var opus: seq[byte]
  if description.len > 0: opus.add ctx(0, ctx(0, bmp(description), constructed = false))
  if url.len > 0: opus.add ctx(1, ctx(0, bytesOf(url), constructed = false))
  let extra = @[attribute(oidSpcStatementType, derSeq(derOid(oidSpcIndividual))),
                attribute(oidSpcOpusInfo, derSeq(opus))]
  # (an RFC 3161 time stamp, kept where Windows looks: 1.3.6.1.4.1.311.3.3.1)
  cmsSignedData(key, cert, indirect, contentType = oidSpcIndirectData, detached = false,
                signedAttrs = true, digestOf = inside, extraAttrs = extra, chain = chain,
                timestamper = timestamper, timestampOid = "1.3.6.1.4.1.311.3.3.1")

proc authenticodeSign*(pe: string; key: RsaKey; cert: seq[byte]; description = ""; url = "";
                       chain: seq[seq[byte]] = @[]; timestamper: Timestamper = nil): string =
  ## Program `pe` signed (Authenticode, SHA-256): an older signature
  ## replaced, its checksum made again. `description` and `url` show in
  ## Windows' prompt ("Retro Files", the app's site); `timestamper`: stamped
  ## with the time (the signature stays good after the certificate expires).
  var p = pe
  var l = peLayout(p)
  # (an older signature: taken off)
  if l.certAt > 0 and l.certSize > 0 and l.certAt <= p.len and l.certSize <= p.len - l.certAt and
     l.certAt >= l.headersEnd and l.certAt >= l.certDirAt + 8:
    p.setLen(l.certAt)
    put32le(p, l.certDirAt, 0)
    put32le(p, l.certDirAt + 4, 0)
  while p.len mod 8 != 0: p.add '\0'
  l = peLayout(p)
  let digest = authenticodeDigest(p)
  let peImage = derSeq(tlv(0x03, @[0'u8]), ctx(0, ctx(2, ctx(0, bmp("<<<Obsolete>>>"), constructed = false))))
  let sig = indirectSignature(derSeq(derOid(oidSpcPeImageData), peImage), digest, key, cert,
                              description, url, chain, timestamper)
  # WIN_CERTIFICATE: its length, revision 2.0, PKCS #7; 8-byte aligned
  var w = newString(8)
  var body = strOf(sig)
  while (8 + body.len) mod 8 != 0: body.add '\0'
  put32le(w, 0, 8 + body.len)
  w[4] = '\0'; w[5] = '\2'; w[6] = '\2'; w[7] = '\0'
  let certAt = p.len
  p.add w
  p.add body
  put32le(p, l.certDirAt, certAt)
  put32le(p, l.certDirAt + 4, 8 + body.len)
  put32le(p, l.checksumAt, 0)
  put32le(p, l.checksumAt, int(peChecksum(p)))
  p

proc isSigned*(pe: string): bool =
  ## The program carries a signature (not checked: Windows does that).
  try:
    let l = peLayout(pe)
    l.certAt > 0 and l.certSize > 8
  except SignError: false

proc devKey*(dir: string; subject = "CN=Retro Nim UI developer"): tuple[key: RsaKey; cert: seq[byte]] =
  ## A key and a self-signed certificate made once in `dir` (to try
  ## signing; a store or Windows' SmartScreen want one of an authority's).
  let kp = dir / "dev-key.pem"
  let cp = dir / "dev-cert.der"
  if fileExists(kp) and fileExists(cp):
    try: return (readRsaKey(readFile(kp)), bytesOf(readFile(cp)))
    except CatchableError: discard
  let k = newRsaKey(2048)
  let c = selfSignedCert(k, subject, 10, codeSigning = true)
  createDir(dir)
  writeFile(kp, k.pem)
  writeFile(cp, strOf(c))
  (k, c)

## What apps are shipped in, made and signed in Nim: the DER and CMS parts,
## JAR signatures (App Bundles), Authenticode (Windows programs), MSIX
## packages, macOS bundles signed ad hoc, iOS archives. Checked again with
## osslsigncode, jarsigner and rcodesign when this machine has them.

import std/[os, osproc, strutils, base64]
import retroui/[sign, rsa, msix, macapp, zip, codec]

let tmp = getTempDir() / "retro-test-store"
removeDir(tmp)
createDir(tmp)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)
proc strOf(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)
proc sha(s: string): string = strOf(sha256(bytesOf(s)))
proc le32(s: string; at: int): int =
  int(uint32(uint8(s[at])) or (uint32(uint8(s[at + 1])) shl 8) or (uint32(uint8(s[at + 2])) shl 16) or
      (uint32(uint8(s[at + 3])) shl 24))
proc le16(s: string; at: int): int = int(uint8(s[at])) or (int(uint8(s[at + 1])) shl 8)
proc be32u(s: string; at: int): int64 =
  int64((uint32(uint8(s[at])) shl 24) or (uint32(uint8(s[at + 1])) shl 16) or
        (uint32(uint8(s[at + 2])) shl 8) or uint32(uint8(s[at + 3])))
proc be32(s: string; at: int): int = int(be32u(s, at))
proc put(s: var string; at: int; v: int64; n: int) =
  for k in 0 ..< n: s[at + k] = char((v shr (8 * k)) and 255)

# ---- DER --------------------------------------------------------------------------------------

doAssert derInt(0) == @[2'u8, 1, 0]
doAssert derInt(127) == @[2'u8, 1, 127]
doAssert derInt(128) == @[2'u8, 2, 0, 0x80]
doAssert derInt(0x01010000) == @[2'u8, 4, 1, 1, 0, 0]
doAssert derOid("1.2.840.113549") == @[6'u8, 6, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d]
doAssert derSet(@[2'u8, 1, 5], @[2'u8, 1, 3]) == @[0x31'u8, 6, 2, 1, 3, 2, 1, 5], "a SET is sorted"
doAssert tlv(4, newSeq[byte](200))[0 .. 2] == @[4'u8, 0x81, 200]
doAssert tlv(4, newSeq[byte](300))[0 .. 3] == @[4'u8, 0x82, 1, 44]

# ---- keys and certificates --------------------------------------------------------------------

let (key, cert) = devKey(tmp / "keys", "CN=Retro Test, O=Foxoman, C=OM")
doAssert certSubject(cert) == "CN=Retro Test, O=Foxoman, C=OM", certSubject(cert)
doAssert devKey(tmp / "keys").cert == cert, "made once, then read back"
let pem = "-----BEGIN CERTIFICATE-----\n" & encode(strOf(cert)) & "\n-----END CERTIFICATE-----\n"
doAssert readCerts(pem).len == 1 and readCerts(pem)[0] == cert
doAssert readCerts(pem & "\n" & pem).len == 2, "a chain"
doAssert readCert(pem) == cert and readCert(strOf(cert)) == cert
doAssert strOf(cert).contains("\x06\x08\x2b\x06\x01\x05\x05\x07\x03\x03"), "marked for signing code"
doAssertRaises(SignError): discard certSubject(@[0x30'u8, 0x05, 1])
doAssertRaises(SignError): discard issuerAndSerial(@[0x04'u8, 0x00])

# ---- JAR signatures (App Bundles) -------------------------------------------------------------

let longName = "base/" & "x".repeat(100) & ".txt"
let entries = @[("a.txt", "hello"), (longName, "1"), ("META-INF/old.SF", "skipped")]
let meta = jarSign(entries, key, cert)
doAssert meta.len == 3 and meta[0][0] == "META-INF/MANIFEST.MF" and meta[2][0] == "META-INF/CERT.RSA"
let mf = meta[0][1]
doAssert "Name: a.txt\r\nSHA-256-Digest: " & encode(sha("hello")) & "\r\n" in mf
doAssert "old.SF" notin mf, "META-INF is not listed"
for line in mf.split("\r\n"): doAssert line.len <= 72, "lines of 72 bytes at most"
doAssert "SHA-256-Digest-Manifest: " & encode(sha(mf)) in meta[1][1]
let firstSection = mf[mf.find("Name: a.txt") ..< mf.find("Name: base/")]
doAssert "Name: a.txt\r\nSHA-256-Digest: " & encode(sha(firstSection)) in meta[1][1]
doAssert meta[2][1].contains(strOf(cert)), "the certificate in the signature"

# ---- Authenticode (Windows programs) ----------------------------------------------------------

proc tinyPe(): string =
  ## A Windows program of two pages: its headers and one section.
  result = newString(0x400)
  result[0] = 'M'; result[1] = 'Z'
  result.put(0x3C, 0x40, 4)
  result[0x40 .. 0x43] = "PE\0\0"
  let coff = 0x44
  result.put(coff, 0x8664, 2); result.put(coff + 2, 1, 2); result.put(coff + 16, 0xF0, 2)
  result.put(coff + 18, 0x22, 2)
  let opt = coff + 20
  result.put(opt, 0x20B, 2)
  result.put(opt + 16, 0x1000, 4)            # entry point
  result.put(opt + 24, 0x40000000, 4)        # (image base, low half)
  result.put(opt + 32, 0x1000, 4); result.put(opt + 36, 0x200, 4)
  result.put(opt + 56, 0x2000, 4); result.put(opt + 60, 0x200, 4)
  result.put(opt + 68, 3, 2)
  result.put(opt + 108, 16, 4)
  let sec = opt + 240
  result[sec ..< sec + 5] = ".text"
  result.put(sec + 8, 0x10, 4); result.put(sec + 12, 0x1000, 4)
  result.put(sec + 16, 0x200, 4); result.put(sec + 20, 0x200, 4)
  result.put(sec + 36, 0x60000020'i64, 4)
  for i in 0 ..< 16: result[0x200 + i] = char(0xC3)

let pe = tinyPe()
let signed = authenticodeSign(pe, key, cert, "Retro Test", "https://example.org")
doAssert isSigned(signed) and not isSigned(pe)
doAssert signed.len mod 8 == 0
let certDir = 0x44 + 20 + 112 + 4 * 8
doAssert le32(signed, certDir) == pe.len and le32(signed, certDir + 4) == signed.len - pe.len
doAssert le32(signed, pe.len + 4) == 0x00020200, "WIN_CERTIFICATE: revision 2, PKCS #7"
doAssert uint32(le32(signed, 0x44 + 20 + 64)) == peChecksum(signed), "the checksum made again"
let digest = authenticodeDigest(signed)
doAssert digest == authenticodeDigest(pe), "the digest leaves out the signature"
doAssert strOf(digest) in signed, "the digest is what is signed"
doAssert "R\0e\0t\0r\0o\0 \0T\0e\0s\0t" in signed, "the name Windows shows"
let again = authenticodeSign(signed, key, cert, "Retro Test", "https://example.org")
doAssert again.len == signed.len and isSigned(again), "signed again: the old signature replaced"
doAssertRaises(SignError): discard authenticodeSign("not a program", key, cert)
doAssertRaises(SignError): discard authenticodeSign("MZ" & "\0".repeat(100), key, cert)

let ossl = findExe("osslsigncode")
let certPem = tmp / "cert.pem"
writeFile(certPem, pem)
if ossl.len > 0:
  writeFile(tmp / "signed.exe", signed)
  let (o, code) = execCmdEx(quoteShellCommand([ossl, "verify", "-CAfile", certPem, "-in", tmp / "signed.exe"]))
  doAssert code == 0 and "Signature verification: ok" in o, o

# a time stamp, from an authority made here with OpenSSL (when it is here)
var stamper: Timestamper = nil
let openssl = findExe("openssl")
let t = tmp / "tsa"     # (at the top: the authority's closure keeps it)
if openssl.len > 0:
  createDir(t)
  let (o, code) = execCmdEx(quoteShellCommand([openssl, "req", "-x509", "-newkey", "rsa:2048", "-nodes",
    "-keyout", t / "tsa.key", "-out", t / "tsa.pem", "-days", "30", "-subj", "/CN=Test TSA",
    "-addext", "extendedKeyUsage=critical,timeStamping", "-addext", "keyUsage=critical,digitalSignature"]))
  if code == 0:
    writeFile(t / "serial", "01\n")
    writeFile(t / "tsa.cnf", "[ tsa ]\ndefault_tsa = tsa1\n[ tsa1 ]\nserial = " & t / "serial" &
      "\ncrypto_device = builtin\nsigner_cert = " & t / "tsa.pem" & "\nsigner_key = " & t / "tsa.key" &
      "\nsigner_digest = sha256\ndefault_policy = 1.2.3.4.1\ndigests = sha256\naccuracy = secs:1\n" &
      "ordering = yes\ntsa_name = yes\ness_cert_id_chain = no\ness_cert_id_alg = sha256\n")
    stamper = proc (q: seq[byte]): seq[byte] =
      writeFile(t / "q.tsq", strOf(q))
      let (o, code) = execCmdEx(quoteShellCommand([openssl, "ts", "-reply", "-config", t / "tsa.cnf",
                                                   "-queryfile", t / "q.tsq", "-out", t / "r.tsr"]))
      doAssert code == 0, o
      bytesOf(readFile(t / "r.tsr"))
    let stamped = authenticodeSign(pe, key, cert, "Retro Test", "", @[], stamper)
    doAssert stamped.len > signed.len + 500, "the authority's token in it"
    doAssert "\x06\x0a\x2b\x06\x01\x04\x01\x82\x37\x03\x03\x01" in stamped, "where Windows looks for it"
    if ossl.len > 0:
      writeFile(tmp / "stamped.exe", stamped)
      let (o, code) = execCmdEx(quoteShellCommand([ossl, "verify", "-CAfile", certPem, "-TSA-CAfile",
                                                   t / "tsa.pem", "-in", tmp / "stamped.exe"]))
      doAssert code == 0 and "Timestamp Server Signature verification: ok" in o, o
  else: echo "(no time-stamping authority: ", o.strip, ")"
# an authority that refuses, or stamps something else
doAssertRaises(SignError):
  discard authenticodeSign(pe, key, cert, timestamper = proc (q: seq[byte]): seq[byte] =
    @[0x30'u8, 0x05, 0x30, 0x03, 0x02, 0x01, 0x02])
doAssertRaises(SignError):
  discard authenticodeSign(pe, key, cert, timestamper = proc (q: seq[byte]): seq[byte] =
    @[0x30'u8, 0x0D, 0x30, 0x03, 0x02, 0x01, 0x00, 0x30, 0x06, 0x04, 0x04, 1, 2, 3, 4])

# ---- MSIX ------------------------------------------------------------------------------------

var big = newString(200_000)
for i in 0 ..< big.len: big[i] = char((i * 7 + i div 997) and 255)
var app = MsixApp(name: "Retro.Test", publisher: certSubject(cert), version: "1.2.0.0",
                  displayName: "Retro Test", publisherName: "Foxoman", exe: "test.exe",
                  capabilities: @["internetClient"])
app.files.add ("test.exe", signed)
app.files.add ("data/big file.bin", big)
app.files.add ("notes/empty.txt", "")
let package = buildMsix(app, key, cert, timestamper = stamper)
let msixPath = tmp / "test.msix"
writeFile(msixPath, package)

let found = zipEntries(msixPath)
var names: seq[string]
for e in found: names.add e.name
doAssert names == @["test.exe", "data/big%20file.bin", "notes/empty.txt", "Assets/Square150x150Logo.png",
                    "Assets/Square44x44Logo.png", "Assets/StoreLogo.png", "AppxManifest.xml",
                    "AppxBlockMap.xml", "[Content_Types].xml", "AppxSignature.p7x"], $names
proc lfhAt(name: string): int =
  ## (where the entry's local header is)
  var i = package.find("PK\3\4")
  while i >= 0:
    if le16(package, i + 26) == name.len and package[i + 30 ..< i + 30 + name.len] == name: return i
    i = package.find("PK\3\4", i + 1)
  doAssert false, name
proc entry(name: string): string =
  for e in found:
    if e.name == name: return readEntry(msixPath, e)
  doAssert false, name
doAssert entry("test.exe") == signed and entry("data/big%20file.bin") == big
let manifest = entry("AppxManifest.xml")
doAssert "<Identity Name=\"Retro.Test\" Publisher=\"CN=Retro Test, O=Foxoman, C=OM\" Version=\"1.2.0.0\"" in manifest
doAssert "<Capability Name=\"internetClient\"/>" in manifest and "runFullTrust" in manifest
doAssert entry("Assets/StoreLogo.png")[1 .. 3] == "PNG"
let types = entry("[Content_Types].xml")
for t in ["Extension=\"exe\" ContentType=\"application/x-msdownload\"",
          "PartName=\"/AppxBlockMap.xml\" ContentType=\"application/vnd.ms-appx.blockmap+xml\"",
          "PartName=\"/AppxSignature.p7x\" ContentType=\"application/vnd.ms-appx.signature\"",
          "Extension=\"xml\" ContentType=\"application/vnd.ms-appx.manifest+xml\""]:
  doAssert t in types, t

# the block map: each 64 KB block's SHA-256, and (deflated) its own compressed size
let blockMap = entry("AppxBlockMap.xml")
for e in found:
  if e.name in ["AppxBlockMap.xml", "[Content_Types].xml", "AppxSignature.p7x"]: continue
  let path = e.name.replace("%20", " ").replace('/', '\\')
  let at = blockMap.find("<File Name=\"" & path & "\"")
  doAssert at >= 0, path
  let fileXml = blockMap[at ..< blockMap.find("</File>", at)]
  let data = readEntry(msixPath, e)
  let lfh = 30 + e.name.len
  doAssert "Size=\"" & $data.len & "\" LfhSize=\"" & $lfh & "\"" in fileXml
  var i, k, packedAt = 0
  var p = fileXml.find("<Block ")
  while p >= 0:
    let h = fileXml[fileXml.find("Hash=\"", p) + 6 ..< fileXml.find("\"", fileXml.find("Hash=\"", p) + 6)]
    let piece = data[i ..< min(data.len, i + 65536)]
    doAssert h == encode(sha(piece)), path & " block " & $k
    let s = fileXml.find("Size=\"", p)
    if e.compression == 8:
      doAssert s >= 0 and s < fileXml.find("/>", p)
      let size = parseInt(fileXml[s + 6 ..< fileXml.find("\"", s + 6)])
      # (each block inflates on its own)
      let base = lfhAt(e.name) + lfh + packedAt
      # (a last, empty block after it: it ends on a whole byte)
      let raw = package[base ..< base + size] & "\x01\x00\x00\xff\xff"
      doAssert strOf(inflate(bytesOf(raw), maxOut = 65536)) == piece, path
      packedAt += size
    i += 65536
    inc k
    p = fileXml.find("<Block ", p + 1)
  doAssert k == (data.len + 65535) div 65536, path
  if e.compression == 8: doAssert packedAt == e.packed, path

# the signature: "PKCX", and the digest of the records, the directory, the types, the block map
let p7x = entry("AppxSignature.p7x")
doAssert p7x.startsWith("PKCX\x30")
let records = package[0 ..< lfhAt("AppxSignature.p7x")]
var cdAt = 0
for i in countdown(package.len - 22, 0):
  if package[i ..< i + 4] == "PK\6\6":
    cdAt = int(le32(package, i + 48))
    break
let cdAll = package[cdAt ..< package.len - 56 - 20 - 22]
let cd = cdAll[0 ..< cdAll.len - (46 + "AppxSignature.p7x".len)]
var ending = "PK\6\6" & "\x2c\0\0\0\0\0\0\0" & "\x2d\0\x2d\0" & "\0\0\0\0\0\0\0\0"
for v in [found.len - 1, found.len - 1, cd.len, records.len, records.len + cd.len]:
  if ending.len == 4 + 8 + 4 + 8 + 32: ending.add "PK\6\7\0\0\0\0"
  for k in 0 ..< 8: ending.add char((int64(v) shr (8 * k)) and 255)
ending.add "\1\0\0\0PK\5\6\0\0\0\0\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\0\0"
let expected = "APPXAXPC" & sha(records) & "AXCD" & sha(cd & ending) & "AXCT" & sha(types) &
               "AXBM" & sha(blockMap)
doAssert expected in p7x, "the package's digest is what is signed"

doAssertRaises(MsixError):
  var bad = app
  bad.version = "1.0"
  discard buildMsix(bad, key, cert)
doAssertRaises(MsixError):
  var bad = app
  bad.exe = "missing.exe"
  discard buildMsix(bad, key, cert)
doAssertRaises(MsixError):
  var bad = app
  bad.name = "has space"
  discard buildMsix(bad, key, cert)
doAssertRaises(MsixError):
  var bad = app
  bad.files.add ("AppxManifest.xml", "")
  discard buildMsix(bad, key, cert)
doAssertRaises(MsixError):
  var bad = app
  bad.publisher = "Me"
  discard buildMsix(bad, key, cert)

if ossl.len > 0:
  let (o, code) = execCmdEx(quoteShellCommand([ossl, "verify", "-CAfile", certPem, "-in", msixPath]))
  doAssert code == 0 and "Signature verification: ok" in o and "Succeeded" in o, o
  doAssert o.count("Calculated message digest") == 4
  if stamper != nil:
    let (o2, code2) = execCmdEx(quoteShellCommand([ossl, "verify", "-CAfile", certPem, "-TSA-CAfile",
                                                   tmp / "tsa" / "tsa.pem", "-in", msixPath]))
    doAssert code2 == 0 and "Timestamp Server Signature verification: ok" in o2, o2

# ---- macOS: the icon, the bundle, the ad hoc signature -----------------------------------------

doAssert sha1("").toHex.toLowerAscii == "da39a3ee5e6b4b0d3255bfef95601890afd80709"
doAssert sha1("abc").toHex.toLowerAscii == "a9993e364706816aba3e25717850c26c9cd0d89d"
doAssert sha1("a".repeat(1000)).toHex.toLowerAscii == "291e9a6c66994949b57ba5e650361e98fc36b1ba"

let ic = icns("")
doAssert ic.startsWith("icns") and be32(ic, 4) == ic.len
var at = 8
var kinds: seq[string]
while at < ic.len:
  kinds.add ic[at ..< at + 4]
  doAssert ic[at + 9 .. at + 11] == "PNG"
  at += be32(ic, at + 4)
doAssert at == ic.len and kinds.len == 10 and "ic10" in kinds and "icp4" in kinds

proc tinyMachO(cpu: int): string =
  ## A 64-bit macOS program: __TEXT (one page) and __LINKEDIT.
  result = newString(0x1010)
  result.put(0, 0xFEEDFACF'i64, 4); result.put(4, cpu, 4); result.put(12, 2, 4)
  result.put(16, 2, 4); result.put(20, 144, 4); result.put(24, 0x200085, 4)
  var c = 32
  for (name, fileoff, size) in [("__TEXT", 0, 0x1000), ("__LINKEDIT", 0x1000, 0x10)]:
    result.put(c, 0x19, 4); result.put(c + 4, 72, 4)
    result[c + 8 ..< c + 8 + name.len] = name
    result.put(c + 24, fileoff, 4); result.put(c + 28, 1, 4)
    result.put(c + 32, 0x1000, 4)
    result.put(c + 40, fileoff, 4); result.put(c + 48, size, 4)
    result.put(c + 56, (if name == "__TEXT": 5 else: 1), 4); result.put(c + 60, (if name == "__TEXT": 5 else: 1), 4)
    c += 72
  for i in 0x1000 ..< 0x1010: result[i] = char(i and 255)

proc checkSignature(m, ident: string; plist, res: string) =
  ## The code directory read back: every page's hash, the bound files'.
  let ncmds = le32(m, 16)
  var c = 32
  var sigOff, sigSize = -1
  for i in 0 ..< ncmds:
    if le32(m, c) == 0x1D:
      sigOff = le32(m, c + 8)
      sigSize = le32(m, c + 12)
    c += le32(m, c + 4)
  doAssert sigOff > 0 and sigOff + sigSize == m.len
  doAssert be32u(m, sigOff) == 0xFADE0CC0'i64
  let count = be32(m, sigOff + 8)
  doAssert count == 3
  doAssert be32(m, sigOff + 12) == 0 and be32(m, sigOff + 20) == 2 and be32(m, sigOff + 28) == 0x10000
  let cd = sigOff + be32(m, sigOff + 16)
  doAssert be32u(m, cd) == 0xFADE0C02'i64 and be32(m, cd + 8) == 0x20400
  doAssert be32(m, cd + 12) == 2, "ad hoc"
  let hashAt = cd + be32(m, cd + 16)
  let identAt = cd + be32(m, cd + 20)
  doAssert m[identAt ..< identAt + ident.len + 1] == ident & "\0"
  let pages = be32(m, cd + 28)
  let limit = be32(m, cd + 32)
  doAssert limit == sigOff and pages == (limit + 4095) div 4096
  doAssert uint8(m[cd + 36]) == 32 and uint8(m[cd + 37]) == 2 and uint8(m[cd + 39]) == 12
  for p in 0 ..< pages:
    doAssert m[hashAt + 32 * p ..< hashAt + 32 * (p + 1)] ==
             sha(m[p * 4096 ..< min(limit, (p + 1) * 4096)]), "page " & $p
  let req = sigOff + be32(m, sigOff + 24)
  doAssert m[hashAt - 64 ..< hashAt - 32] == sha(m[req ..< req + 12]), "the requirements' hash"
  doAssert m[hashAt - 32 ..< hashAt] == (if plist.len > 0: sha(plist) else: "\0".repeat(32))
  doAssert m[hashAt - 96 ..< hashAt - 64] == (if res.len > 0: sha(res) else: "\0".repeat(32))

let arm = tinyMachO(0x0100000C)
let armSigned = signMachO(arm, "org.retro.test")
checkSignature(armSigned, "org.retro.test", "", "")
doAssert le32(armSigned, 16) == 3 and le32(armSigned, 20) == 160, "LC_CODE_SIGNATURE added"
doAssert le32(armSigned, 32 + 72 + 48) == armSigned.len - 0x1000, "__LINKEDIT holds the signature"
doAssert le32(armSigned, 32 + 72 + 32) mod 0x4000 == 0, "on Apple silicon's 16 KB pages"
let armAgain = signMachO(armSigned, "org.retro.test")
doAssert armAgain == armSigned, "signed again: the same signature"
doAssertRaises(MacError): discard signMachO("not a program at all, no", "x")

# universal: both slices signed, each where its alignment puts it
let x86 = tinyMachO(0x01000007)
var fatProgram = ""
block:
  var h = "\xca\xfe\xba\xbe\0\0\0\2"
  proc be(v: int): string =
    for i in countdown(3, 0): result.add char((v shr (8 * i)) and 255)
  h.add be(0x01000007) & be(3) & be(0x1000) & be(x86.len) & be(12)
  h.add be(0x0100000C) & be(0) & be(0x4000) & be(arm.len) & be(14)
  fatProgram = h & "\0".repeat(0x1000 - h.len) & x86 & "\0".repeat(0x4000 - 0x1000 - x86.len) & arm
let fatSigned = signMachO(fatProgram, "org.retro.fat")
doAssert be32u(fatSigned, 0) == 0xCAFEBABE'i64 and be32(fatSigned, 4) == 2
for s in 0 .. 1:
  let off = be32(fatSigned, 8 + 20 * s + 8)
  let size = be32(fatSigned, 8 + 20 * s + 12)
  doAssert off mod (1 shl be32(fatSigned, 8 + 20 * s + 16)) == 0
  checkSignature(fatSigned[off ..< off + size], "org.retro.fat", "", "")

# a bundle: written, signed, its resources sealed
let progPath = tmp / "prog"
writeFile(progPath, arm)
let bundle = writeMacApp(tmp / "mac", progPath, "Retro Test", "org.retro.test", "1.2",
                         files = @[("sub/a b&c.txt", "x\n")])
doAssert bundle == tmp / "mac" / "Retro Test.app"
let plist = readFile(bundle / "Contents" / "Info.plist")
for k in ["<key>CFBundleIdentifier</key>\n\t<string>org.retro.test</string>",
          "<key>CFBundleExecutable</key>\n\t<string>Retro Test</string>",
          "<key>CFBundleShortVersionString</key>\n\t<string>1.2</string>"]:
  doAssert k in plist, k
adhocSign(bundle)
let res = readFile(bundle / "Contents" / "_CodeSignature" / "CodeResources")
let sub = "x\n"
doAssert "<key>Resources/sub/a b&amp;c.txt</key>\n\t\t<data>\n\t\t" &
         encode(sha1(sub)) & "\n\t\t</data>" in res
doAssert "<key>hash2</key>\n\t\t\t<data>\n\t\t\t" & encode(sha(sub)) & "\n\t\t\t</data>" in res
doAssert "<key>Info.plist</key>" notin res and "MacOS/" notin res.replace("|MacOS|", "")
checkSignature(readFile(bundle / "Contents" / "MacOS" / "Retro Test"), "org.retro.test", plist, res)
doAssert fpUserExec in getFilePermissions(bundle / "Contents" / "MacOS" / "Retro Test")

let rcodesign = getEnv("RETRO_RCODESIGN", findExe("rcodesign"))
if rcodesign.len > 0 and fileExists(rcodesign):
  # (an ad hoc signature has no CMS: rcodesign says so, and nothing else)
  for p in [bundle / "Contents" / "MacOS" / "Retro Test"]:
    let (o, _) = execCmdEx(quoteShellCommand([rcodesign, "verify", p]))
    doAssert "mismatch" notin o and "parse failure" notin o, o

# the zip of the bundle, and an .ipa
zipBundle(bundle, tmp / "app.zip")
var zipped: seq[string]
for e in zipEntries(tmp / "app.zip"): zipped.add e.name
doAssert "Retro Test.app/Contents/MacOS/Retro Test" in zipped and
         "Retro Test.app/Contents/_CodeSignature/CodeResources" in zipped
ipaOf(bundle, tmp / "app.ipa")
for e in zipEntries(tmp / "app.ipa"): doAssert e.name.startsWith("Payload/Retro Test.app/")

removeDir(tmp)
echo "test_store: ok"

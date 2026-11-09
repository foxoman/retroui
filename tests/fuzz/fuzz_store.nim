## Feeds damaged inputs to what reads and signs packages: certificates,
## time-stamping answers, Windows programs, macOS programs, zip archives
## (ZIP64, MSIX). Nothing may fail other than with the module's own error
## (SignError, MacError, ZipError): no crash, no Defect.
##
##   nim c -r -d:release --stackTrace:on --lineTrace:on tests/fuzz/fuzz_store.nim 3000

import std/[os, random, strutils]
import retroui/[sign, rsa, msix, macapp, zip]

let rounds = if paramCount() >= 1: parseInt(paramStr(1)) else: 3000
var r = initRand(20261109)
let tmp = getTempDir() / "retro-fuzz-store"
createDir(tmp)

proc strOf(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)
proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc mutate(s: string; seeds: openArray[string]): string =
  result = s
  for _ in 0 .. r.rand(5):
    if result.len == 0: result.add char(r.rand(255))
    case r.rand(9)
    of 0, 1: result[r.rand(result.high)] = char(r.rand(255))
    of 2: result[r.rand(result.high)] = char([0, 0x30, 0x31, 0x80, 0x81, 0x82, 0x84, 0xFF][r.rand(7)])
    of 3:
      let a = r.rand(result.high)
      result.delete(a .. min(result.high, a + r.rand(40)))
    of 4: result.insert($char(r.rand(255)) & $char(r.rand(255)), r.rand(result.len))
    of 5:
      # a 32-bit number somewhere: an offset, a size, a count
      if result.len >= 4:
        let at = r.rand(result.len - 4)
        let v = [0'u32, 1, 0x7FFFFFFF, 0x80000000'u32, 0xFFFFFFFF'u32, uint32(result.len),
                 uint32(r.rand(1 shl 20))][r.rand(6)]
        for k in 0 .. 3: result[at + k] = char((v shr (8 * k)) and 255)
    of 6:
      let b = seeds[r.rand(seeds.high)]
      if b.len > 0:
        let a = r.rand(b.high)
        result.insert(b[a .. min(b.high, a + r.rand(300))], r.rand(result.len))
    of 7: result.setLen(r.rand(result.len))
    of 8:
      # a big-endian number (Mach-O's code signature, DER lengths)
      if result.len >= 4:
        let at = r.rand(result.len - 4)
        let v = [0'u32, 0xFADE0CC0'u32, 0xFADE0C02'u32, 0xCAFEBABE'u32, 0xFFFFFFFF'u32][r.rand(4)]
        for k in 0 .. 3: result[at + k] = char((v shr (8 * (3 - k))) and 255)
    else: discard

# ---- seeds -------------------------------------------------------------------------------------

let (key, cert) = devKey(tmp / "keys", "CN=Fuzz, O=Retro, C=OM")
let certPem = "-----BEGIN CERTIFICATE-----\n" & "MII" & "\n-----END CERTIFICATE-----\n"

proc tinyPe(): string =
  result = newString(0x400)
  result[0] = 'M'; result[1] = 'Z'
  result[0x3C] = '\x40'
  result[0x40 .. 0x43] = "PE\0\0"
  result[0x44] = '\x64'; result[0x45] = '\x86'; result[0x46] = '\1'; result[0x54] = '\xF0'
  result[0x58] = '\x0B'; result[0x59] = '\x02'
  result[0x58 + 60] = '\0'; result[0x58 + 61] = '\2'
  result[0x58 + 108] = '\x10'
proc tinyMachO(): string =
  result = newString(0x1010)
  for (at, v) in [(0, 0xFEEDFACF'u32), (4, 0x0100000C'u32), (12, 2'u32), (16, 2'u32), (20, 144'u32)]:
    for k in 0 .. 3: result[at + k] = char((v shr (8 * k)) and 255)
  var c = 32
  for (name, fileoff, size) in [("__TEXT", 0, 0x1000), ("__LINKEDIT", 0x1000, 0x10)]:
    result[c] = '\x19'; result[c + 4] = '\x48'
    result[c + 8 ..< c + 8 + name.len] = name
    result[c + 41] = char(fileoff shr 8); result[c + 49] = char(size shr 8); result[c + 48] = char(size and 255)
    c += 72

let pe = tinyPe()
let signedPe = authenticodeSign(pe, key, cert, "Fuzz")
let macho = tinyMachO()
let signedMacho = signMachO(macho, "org.retro.fuzz")
let fatMacho = block:
  proc be(v: int): string =
    for i in countdown(3, 0): result.add char((v shr (8 * i)) and 255)
  var h = "\xca\xfe\xba\xbe" & be(2)
  h.add be(0x01000007) & be(3) & be(0x1000) & be(macho.len) & be(12)
  h.add be(0x0100000C) & be(0) & be(0x4000) & be(macho.len) & be(14)
  h & "\0".repeat(0x1000 - h.len) & macho & "\0".repeat(0x4000 - 0x1000 - macho.len) & macho
var app = MsixApp(name: "Retro.Fuzz", publisher: certSubject(cert), version: "1.0.0.0",
                  displayName: "Fuzz", publisherName: "Retro", exe: "f.exe")
app.files.add ("f.exe", signedPe)
app.files.add ("data/b.bin", "x".repeat(70_000))
let package = buildMsix(app, key, cert)
var zw = newZipWriter()
zw.addFile("a.txt", "hello hello hello")
zw.addFile("b/c.bin", "\0\1\2".repeat(100))
let plainZip = zw.finish()
let tsAnswer = strOf(@[0x30'u8, 0x03, 0x30, 0x01, 0x02])   # (status only)

let seeds = @[strOf(cert), signedPe, signedMacho, package, plainZip, pe, macho, fatMacho]
var refused, accepted = 0

template guard(what: string; body: untyped) =
  try:
    body
    inc accepted
  except SignError, MacError, ZipError, MsixError, RsaError:
    inc refused

for round in 0 ..< rounds:
  # certificates (DER and PEM), names, the signer's identity
  let c = mutate(strOf(cert), seeds)
  guard("certificate"):
    discard certSubject(bytesOf(c))
  guard("issuer"):
    discard issuerAndSerial(bytesOf(c))
  guard("pem"):
    discard readCerts(if r.rand(1) == 0: certPem.replace("MII", mutate("MIIB", seeds)) else: c)
  # an authority's answer
  guard("time stamp"):
    discard timestampToken(bytesOf(mutate(if r.rand(3) == 0: tsAnswer else: strOf(cert), seeds)),
                           bytesOf("sig"))
  # Windows programs: read, digested, signed
  let p = mutate(if r.rand(1) == 0: pe else: signedPe, seeds)
  guard("pe"):
    discard isSigned(p)
    discard authenticodeDigest(p)
    discard peChecksum(p)
  if round mod 8 == 0:
    guard("pe sign"):
      discard authenticodeSign(p, key, cert, "Fuzz")
  # macOS programs (one or universal)
  let m = mutate([macho, signedMacho, fatMacho][r.rand(2)], seeds)
  guard("mach-o"):
    discard signMachO(m, "org.retro.fuzz")
  # zip archives: their directory read, every entry
  let z = mutate(if r.rand(1) == 0: package else: plainZip, seeds)
  let zp = tmp / "f.zip"
  writeFile(zp, z)
  guard("zip"):
    for e in zipEntries(zp):
      try: discard readEntry(zp, e)
      except ZipError, IOError: inc refused
  # an icon from a damaged PNG
  if round mod 16 == 0:
    guard("icon"):
      discard icns(mutate(strOf(@[0x89'u8, 0x50, 0x4E, 0x47]), seeds))
  if round mod 500 == 0: echo round, " rounds"

removeDir(tmp)
echo "fuzz_store: ", rounds, " rounds, ", accepted, " accepted, ", refused, " refused, no crash"

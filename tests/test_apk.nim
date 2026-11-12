## Unit checks of the APK builder's own SHA-256, CRC-32 and PNG writer, and
## of the Android sysroot it carries (APKs without the NDK).

import std/[strutils, os, osproc]
import ../src/retroapk {.all.}
import retroui/[appicon, rsa, zip, androiddex]
from retroui/sign import jarSign
import retroui/symbolize

proc hex(b: Bytes): string =
  for x in b: result.add x.toHex(2).toLowerAscii

doAssert hex(sha256(@[])) ==
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
doAssert hex(sha256("abc".toBytes)) ==
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
var long = newSeq[byte](1_000_000)
for i in 0 ..< long.len: long[i] = byte('a')
doAssert hex(sha256(long)) ==
  "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
doAssert crc32("123456789".toBytes) == 0xCBF43926'u32
let icon = iconPng(192)
doAssert icon[1 .. 3] == "PNG".toBytes and icon.len < 10_000, "a small PNG"

# deflate round trip, through a small inflater for fixed-Huffman blocks
proc inflateFixed(z: Bytes): Bytes =
  var pos = 0
  proc bit(): int =
    result = int(z[pos shr 3] shr (pos and 7)) and 1
    inc pos
  proc bits(n: int): int =
    for i in 0 ..< n: result = result or (bit() shl i)
  proc huff(n: int): int =
    for i in 0 ..< n: result = (result shl 1) or bit()
  const lenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35,
                   43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
  const lenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3,
                    4, 4, 4, 4, 5, 5, 5, 5, 0]
  const distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
                    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193,
                    12289, 16385, 24577]
  const distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8,
                     9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  doAssert bit() == 1 and bits(2) == 1, "one fixed-Huffman block"
  while true:
    var c = huff(7)
    if c <= 0x17: c += 256
    else:
      c = (c shl 1) or bit()
      if c in 0x30 .. 0xBF: c -= 0x30
      elif c in 0xC0 .. 0xC7: c = c - 0xC0 + 280
      else: c = ((c shl 1) or bit()) - 0x190 + 144
    if c < 256: result.add byte(c)
    elif c == 256: break
    else:
      let li = c - 257
      let length = lenBase[li] + bits(lenExtra[li])
      let di = huff(5)
      let dist = distBase[di] + bits(distExtra[di])
      for k in 0 ..< length: result.add result[result.len - dist]

var sample: Bytes
for i in 0 ..< 70_000: sample.add byte((i * 7 + i div 300) mod 251)
sample.add "the quick brown fox jumps over the lazy dog, the quick brown fox".toBytes
for data in [sample, @[], "a".toBytes, readFile("tests/test_apk.nim").toBytes]:
  doAssert inflateFixed(deflate(data)) == data, "deflate round trip"

# gzip: a member made by the test (with a file name in its header) read back
proc gzipOf(data: Bytes; name = ""): string =
  var g = "\x1f\x8b\x08" & (if name.len > 0: "\x08" else: "\x00") & "\0\0\0\0\0\xff"
  if name.len > 0: g.add name & "\0"
  g.add deflate(data).toStr
  for v in [crc32(data), uint32(data.len)]:
    for i in 0 .. 3: g.add char((v shr (8 * i)) and 0xFF)
  g
doAssert gunzip(gzipOf(sample, "sample.bin")) == sample
doAssert gunzip(gzipOf(@[])) == newSeq[byte]()
var damaged = gzipOf(sample)
damaged[^6] = char(ord(damaged[^6]) xor 1)
doAssertRaises(ValueError): discard gunzip(damaged)

# the sysroot carried for building without the NDK: everything each ABI
# needs, each library for its own machine
doAssert SysrootPacked.len > 500_000 and SysrootPacked.len < 4_000_000,
  "tools/android/sysroot.tar.gz is carried (" & $SysrootPacked.len & " bytes)"
let sys = getTempDir() / "retro-test-sysroot-" & $getCurrentProcessId()
removeDir(sys)
untar(gunzip(SysrootPacked), sys)
for f in ["NOTICE", "licenses/bionic-libc.NOTICE", "licenses/llvm-compiler-rt.LICENSE.TXT",
          "licenses/frameworks-native.NOTICE", "usr/include/stdio.h", "usr/include/jni.h",
          "usr/include/android/native_activity.h", "usr/include/android/log.h"]:
  doAssert fileExists(sys / f), f
proc machine(path: string): int =
  let f = readFile(path)
  doAssert f.startsWith("\x7fELF"), path
  ord(f[18]) or (ord(f[19]) shl 8)
for (abi, dir, rtName, m) in [("arm64-v8a", "aarch64-linux-android", "aarch64", 183),
                              ("x86_64", "x86_64-linux-android", "x86_64", 62)]:
  doAssert abi in SysrootAbis
  doAssert fileExists(sys / "usr/include" / dir / "asm/unistd.h"), abi
  let lib = sys / "usr/lib" / dir / $SysrootApi
  for so in ["libc.so", "libm.so", "libdl.so", "liblog.so", "libandroid.so"]:
    doAssert machine(lib / so) == m, abi & " " & so
    doAssert neededLibs(lib / so).len == 0, so & " is a stub: it needs nothing"
  for o in ["crtbegin_so.o", "crtend_so.o", "crtbegin_dynamic.o", "crtend_android.o"]:
    doAssert machine(lib / o) == m, abi & " " & o
  let rt = sys / "usr/lib" / dir / "libclang_rt.builtins-" & rtName & "-android.a"
  doAssert readFile(rt).startsWith("!<arch>\n"), rt
removeDir(sys)

# the wrappers Nim runs: the arguments reach the program unchanged
when not defined(windows):
  let w = getTempDir() / "retro-test-wrapper-" & $getCurrentProcessId()
  doAssert writeWrapper(w, [("RETRO_T", "it's")], ["printf"], ["[%s]"], ["[$RETRO_T]"])
  doAssert not writeWrapper(w, [("RETRO_T", "it's")], ["printf"], ["[%s]"], ["[$RETRO_T]"])
  doAssert writeWrapper(w, [("RETRO_T", "it's")], ["printf"], ["[%s]"], ["after"]), "changed"
  let (o, code) = execCmdEx(quoteShellCommand([w, "a b", "c'd", "$HOME"]))
  # (execCmdEx ends the last line with a newline of its own)
  doAssert code == 0 and o.strip == "[a b][c'd][$HOME][after]", $code & " " & o.repr
  # and its environment (zig's ZIG_LIBC) reaches it
  doAssert writeWrapper(w, [("RETRO_T", "it's $x")],
                        ["sh", "-c", "printf '%s|' \"$RETRO_T\" \"$@\"", "sh"], [], [])
  let (o2, code2) = execCmdEx(quoteShellCommand([w, "x y"]))
  doAssert code2 == 0 and o2.strip == "it's $x|x y|", o2.repr
  removeFile(w)

# ---- an App Bundle (.aab): aapt2's proto formats, a JAR signature ---------------------------------

type PbField = tuple[field, wire: int; data: string; v: uint64]

proc pbRead(b: string): seq[PbField] =
  ## (a protocol buffer's fields, one level)
  var i = 0
  proc varint(): uint64 =
    var shift = 0
    while true:
      let c = uint8(b[i])
      inc i
      result = result or (uint64(c and 0x7F) shl shift)
      if (c and 0x80) == 0: break
      shift += 7
  while i < b.len:
    let key = varint()
    let f = int(key shr 3)
    let w = int(key and 7)
    case w
    of 0: result.add (f, w, "", varint())
    of 2:
      let n = int(varint())
      result.add (f, w, b[i ..< i + n], 0'u64)
      i += n
    else: doAssert false, "wire type " & $w

proc pbOne(b: string; field: int): string =
  for f in pbRead(b):
    if f.field == field: return f.data
proc pbAll(b: string; field: int): seq[string] =
  for f in pbRead(b):
    if f.field == field: result.add f.data
proc pbInt(b: string; field: int): uint64 =
  for f in pbRead(b):
    if f.field == field and f.wire == 0: return f.v

let xm = XNode(name: "manifest", attrs: @[
  XAttr(name: "package", kind: TString, str: "org.retro.t"),
  iAttr("versionCode", 0x0101021b, 7),
  sAttr("versionName", 0x0101021c, "1.2")],
  kids: @[XNode(name: "application", attrs: @[
    iAttr("icon", 0x01010002, int(IconRes), TRef),
    bAttr("hasCode", 0x0101000c, true),
    iAttr("configChanges", 0x0101001f, 0x5000FFFF, THex)],
    kids: @[XNode(name: "layout", attrs: @[iAttr("minWidth", 0x0101013f, dp(480), TDimen)])])])
let px = protoXml(xm).toStr
let root = px.pbOne(1)
doAssert root.pbOne(3) == "manifest"
let nsDecl = root.pbOne(1)
doAssert nsDecl.pbOne(1) == "android" and nsDecl.pbOne(2) == AndroidNs
proc attrNamed(el, name: string): string =
  for a in el.pbAll(4):
    if a.pbOne(2) == name: return a
  doAssert false, name
let pkgAttr = root.attrNamed("package")
doAssert pkgAttr.pbOne(1) == "" and pkgAttr.pbOne(3) == "org.retro.t", "package: no namespace"
let vc = root.attrNamed("versionCode")
doAssert vc.pbOne(1) == AndroidNs and vc.pbInt(5) == 0x0101021b'u64
doAssert vc.pbOne(6).pbOne(7).pbInt(6) == 7, "a decimal: its primitive"
doAssert root.attrNamed("versionName").pbOne(6).pbOne(2).pbOne(1) == "1.2", "a string item"
let appEl = root.pbOne(5).pbOne(1)
doAssert appEl.pbOne(3) == "application"
doAssert appEl.attrNamed("icon").pbOne(6).pbOne(1).pbInt(2) == uint64(IconRes), "a reference"
doAssert appEl.attrNamed("hasCode").pbOne(6).pbOne(7).pbInt(8) == 1, "a boolean"
doAssert appEl.attrNamed("configChanges").pbOne(6).pbOne(7).pbInt(7) == 0x5000FFFF'u64, "hex"
let layoutEl = appEl.pbOne(5).pbOne(1)
doAssert layoutEl.attrNamed("minWidth").pbOne(6).pbOne(7).pbInt(13) == uint64(dp(480)), "a dimension"
# resources.pb: package 0x7f, drawable (1), icon (0) -> the PNG
let rt = protoResources("org.retro.t").toStr
let pkg = rt.pbOne(2)
doAssert pkg.pbOne(1).pbInt(1) == 0x7f and pkg.pbOne(2) == "org.retro.t"
let typ = pkg.pbOne(3)
doAssert typ.pbOne(1).pbInt(1) == 1 and typ.pbOne(2) == "drawable"
let ent = typ.pbOne(3)
doAssert ent.pbOne(2) == "icon"
let fileRef = ent.pbOne(6).pbOne(2).pbOne(4).pbOne(5)
doAssert fileRef.pbOne(1) == IconPath and fileRef.pbInt(2) == 1, "a PNG file"
let bc = bundleConfig().toStr
doAssert bc.pbOne(1).pbOne(2).len > 0, "the bundletool version"
doAssert bc.pbOne(2).pbOne(2).pbInt(1) == 1, "native libraries uncompressed"

# a whole bundle, signed: jarsigner and bundletool check it when they are here
block:
  let key = newRsaKey()
  let cert = key.selfSignedCert("CN=retro test")
  var files = @[("BundleConfig.pb", bc), ("base/manifest/AndroidManifest.xml", px),
                ("base/resources.pb", rt), ("base/dex/classes.dex", classesDex),
                ("base/" & IconPath, iconPng(48).toStr)]
  var z: ZipFile
  for (n, data) in jarSign(files, key, cert) & files: z.addFile(n, data.toBytes, 1)
  let aab = getTempDir() / "retro-test-" & $getCurrentProcessId() & ".aab"
  writeFile(aab, z.finish.toStr)
  let names = block:
    var r: seq[string]
    for e in zipEntries(aab): r.add e.name
    r
  doAssert names[0 .. 2] == @["META-INF/MANIFEST.MF", "META-INF/CERT.SF", "META-INF/CERT.RSA"]
  if findExe("jarsigner").len > 0:
    let (o, code) = execCmdEx(quoteShellCommand(["jarsigner", "-verify", aab]))
    doAssert code == 0 and "jar verified" in o, o
  let bt = getEnv("RETRO_BUNDLETOOL")
  if bt.len > 0 and fileExists(bt):
    let (o, code) = execCmdEx(quoteShellCommand(["java", "-jar", bt, "validate", "--bundle=" & aab]))
    doAssert code == 0 and "Feature module: base" in o, o
  removeFile(aab)

block symbolized:
  # a crash report's frames named from a library's symbol table: this
  # program's own (an ELF file with its names, on Linux)
  let me = readFile(getAppFilename())
  if me.startsWith("\x7fELF") and me[4] == '\x02':
    let e = readElfSymbols(me)
    doAssert e.ok, e.error
    var some = ElfSymbol()
    for s in e.syms:
      if s.size > 64 and "__" in s.name: (some = s; break)
    doAssert some.name.len > 0
    let off = some.start + 16
    doAssert e.lookup(off) == (some.name, 16'u64)
    let report = "--- the app stopped\n  #00 0x7f0000 libmain.so+0x" & toHex(off) & "\n" &
                 "F DEBUG   :       #01 pc " & toHex(off) & "  /data/app/x/lib/x86_64/libmain.so\n"
    writeFile(getTempDir() / "retro-sym.so", me)
    let named = symbolizeReport(report, getTempDir() / "retro-sym.so")
    doAssert named.count(nimName(some.name)) == 2, named
    removeFile(getTempDir() / "retro-sym.so")
  doAssert nimName("beginFrame__OOZsrcZretrouiZcore_u12585") == "beginFrame (src/retroui/core)"
  doAssert nimName("memcpy") == "memcpy"
  doAssert not readElfSymbols("not a library").ok
block appsOwnJava:
  # --java's manifest.txt: entries in <application> or <manifest>, nested,
  # their values as Android keeps them, one already there left out
  let entries = parseManifestEntries("""
# a VPN of the app's own
service android:name=org.me.Vpn android:permission=android.permission.BIND_VPN_SERVICE android:exported=false android:process=:vpn
  intent-filter
    action android:name=android.net.VpnService

receiver android:name=org.me.Stop android:exported=false android:priority=10
uses-permission android:name=android.permission.INTERNET
uses-permission android:name=android.permission.FOREGROUND_SERVICE
""")
  doAssert entries.len == 4
  doAssert entries[0].name == "service" and entries[0].kids.len == 1
  doAssert entries[0].kids[0].kids[0].name == "action"
  doAssert entries[0].attrs[2].kind == TBool and entries[0].attrs[2].data == 0
  doAssert entries[0].attrs[3].resId == 0x01010011'u32 and entries[0].attrs[3].str == ":vpn"
  doAssert entries[1].attrs[2].kind == TDec and entries[1].attrs[2].data == 10
  var m = XNode(name: "manifest", kids: @[
    XNode(name: "uses-sdk"),
    XNode(name: "uses-permission", attrs: @[sAttr("name", 0x01010003, "android.permission.INTERNET")]),
    XNode(name: "application", kids: @[XNode(name: "activity")])])
  doAssert m.mergeEntries(entries) == 3, "INTERNET was there"
  doAssert m.kids.len == 4 and m.kids[2].name == "uses-permission" and m.kids[3].name == "application"
  doAssert m.kids[3].kids.len == 3 and m.kids[3].kids[1].name == "service"
  doAssert m.mergeEntries(entries) == 0, "all of them there now"
  # both of retroapk's manifests carry them
  let bin = axml(m).toStr
  let proto = protoXml(m).toStr
  for s in ["org.me.Vpn", "android.net.VpnService", ":vpn", "org.me.Stop"]:
    doAssert s in proto, s
    var utf16 = ""
    for c in s: utf16.add c & '\0'
    doAssert utf16 in bin, s
  for bad in ["  service android:name=x", "service android:name", "service android:colour=red"]:
    var failed = false
    try: discard parseManifestEntries(bad)
    except ValueError: failed = true
    doAssert failed, bad

echo "apk tool tests passed"

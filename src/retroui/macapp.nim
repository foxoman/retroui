## macOS apps (.app) and iOS archives (.ipa) made in Nim, on any system:
##
## - `icns`: a macOS icon file from a PNG
## - `macInfoPlist`, `writeMacApp`: the bundle (Contents/MacOS, Info.plist,
##   the icon, PkgInfo)
## - `adhocSign`: the bundle signed ad hoc, the way `codesign --sign -`
##   does it (the program's code directory, the sealed resources): what
##   Apple silicon asks of every program, and what keeps macOS from calling
##   a downloaded app "damaged"
## - `ipaOf`: an iOS app (.app) as the .ipa that TestFlight and the App
##   Store take (its signing, with your profile, is codesign's, on a Mac)
##
## A Developer ID signature, notarization and stapling are Apple's own
## tools' (`codesign`, `xcrun notarytool`, `xcrun stapler`), on a Mac:
## `retrokit mac` runs them.

import std/[os, strutils, base64, algorithm]
import rsa, appicon, imaging, zip

type MacError* = object of CatchableError

proc bad(why: string) {.noreturn.} = raise newException(MacError, why)

proc xmlEsc(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc strOf(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc be(s: var string; v: uint64; n: int) =
  for i in countdown(n - 1, 0): s.add char((v shr (8 * i)) and 255)

# ---- the icon --------------------------------------------------------------------------------

proc pngAt(icon: string; size: int): string =
  if icon.len == 0: return strOf(iconPng(size))
  let px = windowIconFromPng(icon, [size])
  if px.len < 2 + size * size: bad("the icon is not a PNG file")
  strOf(png(size, size, px.toOpenArray(2, 1 + size * size)))

proc icns*(icon: string): string =
  ## An .icns of every size macOS draws (16 to 1024 px, as PNGs) from a
  ## PNG (square, 1024 px is best); empty: the drawn 3.1 window.
  var body = ""
  for (kind, size) in [("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128),
                       ("ic13", 256), ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]:
    let p = pngAt(icon, size)
    body.add kind
    body.be(uint64(8 + p.len), 4)
    body.add p
  result = "icns"
  result.be(uint64(8 + body.len), 4)
  result.add body

# ---- the bundle ------------------------------------------------------------------------------

proc macInfoPlist*(name, id, exe, version: string; build = ""; minMac = "11.0";
                   category = "public.app-category.productivity"; extra = ""): string =
  ## Info.plist of an app: its name, id, program, version (and build
  ## number), lowest macOS; `extra`: more keys, as plist XML.
  let b = if build.len > 0: build else: version
  """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleDisplayName</key>
	<string>$1</string>
	<key>CFBundleExecutable</key>
	<string>$3</string>
	<key>CFBundleIconFile</key>
	<string>icon.icns</string>
	<key>CFBundleIdentifier</key>
	<string>$2</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$1</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$4</string>
	<key>CFBundleVersion</key>
	<string>$5</string>
	<key>LSApplicationCategoryType</key>
	<string>$7</string>
	<key>LSMinimumSystemVersion</key>
	<string>$6</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSSupportsAutomaticGraphicsSwitching</key>
	<true/>
	<key>NSCameraUsageDescription</key>
	<string>$1 uses the camera when you ask it to.</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>$1 records sound when you ask it to.</string>
$8</dict>
</plist>
""" % [xmlEsc(name), xmlEsc(id), xmlEsc(exe), xmlEsc(version), xmlEsc(b), xmlEsc(minMac),
       xmlEsc(category), extra]

proc writeMacApp*(dir, program, name, id, version: string; icon = ""; build = "";
                  minMac = "11.0"; files: seq[(string, string)] = @[]): string =
  ## `dir`/<name>.app with `program` (a macOS program: one architecture or
  ## universal) in it, its Info.plist, icon and `files` (path in
  ## Contents/Resources, bytes). Returns the bundle's path. Not signed yet:
  ## `adhocSign` it, or codesign it on a Mac.
  var exe = ""
  for c in name:
    if c.isAlphaNumeric or c in {' ', '-', '_', '.'}: exe.add c
  exe = exe.strip
  if exe.len == 0: exe = "App"
  let app = dir / exe & ".app"
  if dirExists(app): removeDir(app)
  createDir(app / "Contents" / "MacOS")
  createDir(app / "Contents" / "Resources")
  copyFile(program, app / "Contents" / "MacOS" / exe)
  setFilePermissions(app / "Contents" / "MacOS" / exe,
                     {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
                      fpOthersRead, fpOthersExec})
  writeFile(app / "Contents" / "Info.plist", macInfoPlist(name, id, exe, version, build, minMac))
  writeFile(app / "Contents" / "PkgInfo", "APPL????")
  writeFile(app / "Contents" / "Resources" / "icon.icns", icns(if icon.len > 0: readFile(icon) else: ""))
  for (p, data) in files:
    let target = app / "Contents" / "Resources" / p
    createDir(target.parentDir)
    writeFile(target, data)
  app

# ---- the code signature (ad hoc) --------------------------------------------------------------

const
  MhMagic64 = 0xFEEDFACF'u32
  FatMagic = 0xCAFEBABE'u32
  LcSegment64 = 0x19'u32
  LcCodeSignature = 0x1D'u32
  PageBits = 12              # the code directory's pages: 4 KB

proc u32le(s: string; at: int): uint32 =
  uint32(uint8(s[at])) or (uint32(uint8(s[at + 1])) shl 8) or (uint32(uint8(s[at + 2])) shl 16) or
    (uint32(uint8(s[at + 3])) shl 24)
proc u64le(s: string; at: int): uint64 = uint64(u32le(s, at)) or (uint64(u32le(s, at + 4)) shl 32)
proc put32le(s: var string; at: int; v: uint64) =
  for k in 0 .. 3: s[at + k] = char((v shr (8 * k)) and 255)
proc put64le(s: var string; at: int; v: uint64) =
  for k in 0 .. 7: s[at + k] = char((v shr (8 * k)) and 255)
proc u32be(s: string; at: int): uint32 =
  (uint32(uint8(s[at])) shl 24) or (uint32(uint8(s[at + 1])) shl 16) or
    (uint32(uint8(s[at + 2])) shl 8) or uint32(uint8(s[at + 3]))

proc alignUp(v, a: int): int = (v + a - 1) div a * a

proc sha256s(s: string; a = 0; b = -1): string =
  let e = if b < 0: s.len else: b
  if e <= a: return strOf(sha256(newSeq[byte]()))
  strOf(sha256(s.toOpenArrayByte(a, e - 1)))

proc signThin(macho, ident: string; infoPlist, resources: string; mainBinary = true): string =
  ## One Mach-O (64-bit) with an ad hoc signature: its pages' SHA-256, its
  ## Info.plist's and sealed resources', an empty set of requirements.
  var m = macho
  if m.len < 32 or u32le(m, 0) != MhMagic64: bad("not a 64-bit macOS program")
  let cpu = u32le(m, 4)
  let ncmds = int(u32le(m, 16))
  var sizeCmds = int(u32le(m, 20))
  var at = 32
  var linkedit, sigCmd, textOff, textSize = -1
  var firstSection = m.len
  if ncmds > 4096 or 32 + sizeCmds > m.len: bad("a damaged program")
  for i in 0 ..< ncmds:
    if at + 8 > 32 + sizeCmds: bad("a damaged program")
    let cmd = u32le(m, at)
    let size = int(u32le(m, at + 4))
    if size < 8 or at + size > 32 + sizeCmds: bad("a damaged program")
    if cmd == LcSegment64:
      if size < 72: bad("a damaged program")
      let segName = m[at + 8 ..< at + 24].strip(leading = false, chars = {'\0'})
      if segName == "__LINKEDIT": linkedit = at
      if segName == "__TEXT":
        let o = u64le(m, at + 40)
        let n = u64le(m, at + 48)
        if o > uint64(m.len) or n > uint64(m.len): bad("a damaged program")
        textOff = int(o)
        textSize = int(n)
      let nsects = int(u32le(m, at + 64))
      if nsects > (size - 72) div 80: bad("a damaged program")
      for s in 0 ..< nsects:
        let sect = at + 72 + 80 * s
        let off = int(u32le(m, sect + 48))
        let flags = u32le(m, sect + 64)
        # (zero-fill sections take no room in the file)
        if off > 0 and (flags and 0xFF) notin [1'u32, 0x0C, 0x12]: firstSection = min(firstSection, off)
    elif cmd == LcCodeSignature:
      if size < 16: bad("a damaged program")
      sigCmd = at
    at += size
  if linkedit < 0: bad("the program has no __LINKEDIT")
  let leOff64 = u64le(m, linkedit + 40)
  if leOff64 > uint64(m.len): bad("a damaged program")
  let leOff = int(leOff64)
  # an older signature: taken off (the program ends where it began)
  var sigOff: int
  if sigCmd >= 0:
    sigOff = int(u32le(m, sigCmd + 8))
    if sigOff < leOff or sigOff > m.len or sigOff < 32 + sizeCmds: bad("a damaged signature")
    m.setLen(sigOff)
  else:
    if 32 + sizeCmds + 16 > firstSection: bad("no room for a signature in the program's header")
    for k in 32 + sizeCmds ..< 32 + sizeCmds + 16:
      if m[k] != '\0': bad("no room for a signature in the program's header")
    sigCmd = 32 + sizeCmds
    put32le(m, sigCmd, LcCodeSignature)
    put32le(m, sigCmd + 4, 16)
    put32le(m, 16, uint64(ncmds + 1))
    sizeCmds += 16
    put32le(m, 20, uint64(sizeCmds))
    sigOff = alignUp(m.len, 16)
  while m.len < sigOff: m.add '\0'
  # the sizes of what is signed, then the signature's
  let pages = (sigOff + (1 shl PageBits) - 1) shr PageBits
  let identZ = ident & "\0"
  const CdHeader = 88
  let specials = 3
  let hashOffset = CdHeader + identZ.len + specials * 32
  let cdLen = hashOffset + pages * 32
  let reqs = block:
    var r = ""
    r.be(0xFADE0C01'u32, 4); r.be(12, 4); r.be(0, 4)
    r
  var cms = ""
  cms.be(0xFADE0B01'u32, 4); cms.be(8, 4)
  let superLen = 12 + 3 * 8 + cdLen + reqs.len + cms.len
  let sigSize = alignUp(superLen, 16)
  put32le(m, sigCmd + 8, uint64(sigOff))
  put32le(m, sigCmd + 12, uint64(sigSize))
  let pageSize = if cpu == 0x0100000C'u32: 0x4000 else: 0x1000     # arm64: 16 KB pages
  let leFileSize = sigOff + sigSize - leOff
  put64le(m, linkedit + 32, uint64(alignUp(leFileSize, pageSize)))   # vmsize
  put64le(m, linkedit + 48, uint64(leFileSize))                     # filesize
  # the code directory (version 2.4: its executable segment)
  var cd = ""
  cd.be(0xFADE0C02'u32, 4); cd.be(uint64(cdLen), 4); cd.be(0x20400, 4)
  cd.be(0x2, 4)                                     # ad hoc
  cd.be(uint64(hashOffset), 4); cd.be(uint64(CdHeader), 4)
  cd.be(uint64(specials), 4); cd.be(uint64(pages), 4); cd.be(uint64(sigOff), 4)
  cd.add char(32); cd.add char(2); cd.add char(0); cd.add char(PageBits)   # SHA-256, 4 KB pages
  cd.be(0, 4)                                       # spare
  cd.be(0, 4); cd.be(0, 4); cd.be(0, 4)             # scatter, team, spare
  cd.be(0, 8)                                       # 64-bit code limit (not used)
  cd.be(uint64(max(textOff, 0)), 8); cd.be(uint64(max(textSize, 0)), 8)
  cd.be(if mainBinary: 1 else: 0, 8)                # the main program
  cd.add identZ
  let zero = newString(32)
  cd.add(if resources.len > 0: sha256s(resources) else: zero)        # slot -3: resources
  cd.add sha256s(reqs)                                                 # slot -2: requirements
  cd.add(if infoPlist.len > 0: sha256s(infoPlist) else: zero)        # slot -1: Info.plist
  for p in 0 ..< pages:
    cd.add sha256s(m, p shl PageBits, min(sigOff, (p + 1) shl PageBits))
  assert cd.len == cdLen
  var sb = ""
  sb.be(0xFADE0CC0'u32, 4); sb.be(uint64(superLen), 4); sb.be(3, 4)
  let base = 12 + 3 * 8
  sb.be(0, 4); sb.be(uint64(base), 4)
  sb.be(2, 4); sb.be(uint64(base + cd.len), 4)
  sb.be(0x10000, 4); sb.be(uint64(base + cd.len + reqs.len), 4)
  sb.add cd
  sb.add reqs
  sb.add cms
  while sb.len < sigSize: sb.add '\0'
  m.add sb
  m

proc signMachO*(program, ident: string; infoPlist = ""; resources = ""; mainBinary = true): string =
  ## A macOS program (one architecture or universal) signed ad hoc as
  ## `ident`; `infoPlist` and `resources`: the bundle's Info.plist and
  ## CodeResources it is bound to.
  if program.len >= 8 and u32be(program, 0) == FatMagic:
    let n = int(u32be(program, 4))
    if n <= 0 or n > 16 or 8 + 20 * n > program.len: bad("a damaged universal program")
    var slices: seq[tuple[cpu, sub: uint32; align: int; data: string]]
    for i in 0 ..< n:
      let h = 8 + 20 * i
      let off = int(u32be(program, h + 8))
      let size = int(u32be(program, h + 12))
      let align = int(u32be(program, h + 16))
      if off + size > program.len or off < 8 + 20 * n or align > 16:
        bad("a damaged universal program")
      slices.add (u32be(program, h), u32be(program, h + 4), align,
                  signThin(program[off ..< off + size], ident, infoPlist, resources, mainBinary))
    var head = ""
    head.be(FatMagic, 4); head.be(uint64(n), 4)
    var body = ""
    var offs: seq[int]
    var at = 8 + 20 * n
    for s in slices:
      let a = 1 shl s.align
      let off = alignUp(at, a)
      offs.add off
      at = off + s.data.len
    for i, s in slices:
      head.be(s.cpu, 4); head.be(s.sub, 4); head.be(uint64(offs[i]), 4)
      head.be(uint64(s.data.len), 4); head.be(uint64(s.align), 4)
    result = head
    for i, s in slices:
      while result.len < offs[i]: result.add '\0'
      result.add s.data
  else:
    result = signThin(program, ident, infoPlist, resources, mainBinary)

const ResourceRules = """	<key>rules</key>
	<dict>
		<key>^Resources/</key>
		<true/>
		<key>^Resources/.*\.lproj/</key>
		<dict>
			<key>optional</key>
			<true/>
			<key>weight</key>
			<real>1000</real>
		</dict>
		<key>^Resources/.*\.lproj/locversion.plist$</key>
		<dict>
			<key>omit</key>
			<true/>
			<key>weight</key>
			<real>1100</real>
		</dict>
		<key>^Resources/Base\.lproj/</key>
		<dict>
			<key>weight</key>
			<real>1010</real>
		</dict>
		<key>^version.plist$</key>
		<true/>
	</dict>
	<key>rules2</key>
	<dict>
		<key>.*\.dSYM($|/)</key>
		<dict>
			<key>weight</key>
			<real>11</real>
		</dict>
		<key>^(.*/)?\.DS_Store$</key>
		<dict>
			<key>omit</key>
			<true/>
			<key>weight</key>
			<real>2000</real>
		</dict>
		<key>^(Frameworks|SharedFrameworks|PlugIns|Plug-ins|XPCServices|Helpers|MacOS|Library/(Automator|Spotlight|LoginItems))/</key>
		<dict>
			<key>nested</key>
			<true/>
			<key>weight</key>
			<real>10</real>
		</dict>
		<key>^.*</key>
		<true/>
		<key>^Info\.plist$</key>
		<dict>
			<key>omit</key>
			<true/>
			<key>weight</key>
			<real>20</real>
		</dict>
		<key>^PkgInfo$</key>
		<dict>
			<key>omit</key>
			<true/>
			<key>weight</key>
			<real>20</real>
		</dict>
		<key>^Resources/</key>
		<dict>
			<key>weight</key>
			<real>20</real>
		</dict>
		<key>^Resources/.*\.lproj/</key>
		<dict>
			<key>optional</key>
			<true/>
			<key>weight</key>
			<real>1000</real>
		</dict>
		<key>^Resources/.*\.lproj/locversion.plist$</key>
		<dict>
			<key>omit</key>
			<true/>
			<key>weight</key>
			<real>1100</real>
		</dict>
		<key>^Resources/Base\.lproj/</key>
		<dict>
			<key>weight</key>
			<real>1010</real>
		</dict>
		<key>^[^/]+$</key>
		<dict>
			<key>nested</key>
			<true/>
			<key>weight</key>
			<real>10</real>
		</dict>
		<key>^embedded\.provisionprofile$</key>
		<dict>
			<key>weight</key>
			<real>20</real>
		</dict>
		<key>^version\.plist$</key>
		<dict>
			<key>weight</key>
			<real>20</real>
		</dict>
	</dict>
"""

proc sha1*(data: string): string =
  ## SHA-1 (20 bytes): only for the older half of CodeResources, which
  ## macOS still lists.
  var h = [0x67452301'u32, 0xEFCDAB89'u32, 0x98BADCFE'u32, 0x10325476'u32, 0xC3D2E1F0'u32]
  var msg = data
  let bits = uint64(data.len) * 8
  msg.add '\x80'
  while msg.len mod 64 != 56: msg.add '\0'
  for i in countdown(7, 0): msg.add char((bits shr (8 * i)) and 255)
  var w: array[80, uint32]
  template rotl(x: uint32; n: int): uint32 = (x shl n) or (x shr (32 - n))
  for chunk in 0 ..< msg.len div 64:
    for i in 0 .. 15:
      let o = chunk * 64 + 4 * i
      w[i] = (uint32(uint8(msg[o])) shl 24) or (uint32(uint8(msg[o + 1])) shl 16) or
             (uint32(uint8(msg[o + 2])) shl 8) or uint32(uint8(msg[o + 3]))
    for i in 16 .. 79: w[i] = rotl(w[i - 3] xor w[i - 8] xor w[i - 14] xor w[i - 16], 1)
    var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
    for i in 0 .. 79:
      var f, k: uint32
      if i < 20: (f = (b and c) or ((not b) and d); k = 0x5A827999'u32)
      elif i < 40: (f = b xor c xor d; k = 0x6ED9EBA1'u32)
      elif i < 60: (f = (b and c) or (b and d) or (c and d); k = 0x8F1BBCDC'u32)
      else: (f = b xor c xor d; k = 0xCA62C1D6'u32)
      let t = rotl(a, 5) + f + e + k + w[i]
      e = d; d = c; c = rotl(b, 30); b = a; a = t
    h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e
  for x in h:
    for i in countdown(3, 0): result.add char((x shr (8 * i)) and 255)

proc dataLines(raw: string; tabs: string): string =
  tabs & "<data>\n" & tabs & encode(raw) & "\n" & tabs & "</data>\n"

proc codeResources*(contents: string): string =
  ## _CodeSignature/CodeResources of a bundle's Contents folder: the SHA-1
  ## and SHA-256 of each of its files (not the program, Info.plist, PkgInfo).
  var files: seq[string]
  for f in walkDirRec(contents, relative = true):
    let p = f.replace('\\', '/')
    if p in ["Info.plist", "PkgInfo"] or p.startsWith("MacOS/") or p.startsWith("_CodeSignature/") or
       p.endsWith(".DS_Store"):
      continue
    files.add p
  files.sort()
  var v1 = ""
  var v2 = ""
  for p in files:
    let data = readFile(contents / p)
    let s1 = sha1(data)
    if p.startsWith("Resources/"):
      v1.add "\t\t<key>" & xmlEsc(p) & "</key>\n" & dataLines(s1, "\t\t")
    v2.add "\t\t<key>" & xmlEsc(p) & "</key>\n\t\t<dict>\n\t\t\t<key>hash2</key>\n" &
           dataLines(sha256s(data), "\t\t\t") & "\t\t</dict>\n"
  "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" &
    "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" &
    "<plist version=\"1.0\">\n<dict>\n\t<key>files</key>\n\t<dict>\n" & v1 & "\t</dict>\n" &
    "\t<key>files2</key>\n\t<dict>\n" & v2 & "\t</dict>\n" & ResourceRules & "</dict>\n</plist>\n"

proc plistValue(plist, key: string): string =
  let k = plist.find("<key>" & key & "</key>")
  if k < 0: return ""
  let a = plist.find("<string>", k)
  let b = plist.find("</string>", a)
  if a < 0 or b < 0: return ""
  plist[a + 8 ..< b]

proc adhocSign*(app: string) =
  ## Signs the bundle `app` (.app) ad hoc: its resources sealed
  ## (_CodeSignature/CodeResources), its program signed with them and its
  ## Info.plist. Apple silicon runs it; a Mac that downloaded it asks once
  ## (right click, Open) as for any app not notarized.
  let contents = app / "Contents"
  let plistPath = contents / "Info.plist"
  if not fileExists(plistPath): bad(app & " has no Contents/Info.plist")
  let plist = readFile(plistPath)
  let exe = plistValue(plist, "CFBundleExecutable")
  let id = plistValue(plist, "CFBundleIdentifier")
  if exe.len == 0 or id.len == 0: bad("Info.plist has no CFBundleExecutable or CFBundleIdentifier")
  let program = contents / "MacOS" / exe
  if not fileExists(program): bad("no program " & program)
  createDir(contents / "_CodeSignature")
  let res = codeResources(contents)
  writeFile(contents / "_CodeSignature" / "CodeResources", res)
  let perms = getFilePermissions(program)
  # (a new file, not the old one written over: macOS keeps a program's
  # signature with the file it read it from, and would kill the new one)
  let fresh = program & ".signing"
  writeFile(fresh, signMachO(readFile(program), id, plist, res))
  setFilePermissions(fresh, perms)
  moveFile(fresh, program)

# ---- iOS archives ------------------------------------------------------------------------------

proc zipBundle*(app, output: string; inside = "") =
  ## The bundle `app` zipped with its folder, its programs marked as such
  ## (as `ditto -c -k --keepParent` does): to send a Mac app; `inside`: in
  ## that folder of the zip.
  if not dirExists(app): bad("no bundle " & app)
  var z = newZipWriter()
  let name = app.strip(leading = false, chars = {'/', '\\'}).extractFilename
  let top = if inside.len > 0: inside & "/" & name else: name
  var paths: seq[string]
  for f in walkDirRec(app, relative = true): paths.add f
  paths.sort()
  for f in paths:
    let full = app / f
    let exec = fpUserExec in getFilePermissions(full)
    z.addFile(top & "/" & f.replace('\\', '/'), readFile(full), executable = exec)
  writeFile(output, z.finish())

proc ipaOf*(app: string; output: string) =
  ## The iOS bundle `app` (.app, already signed with codesign) as an .ipa
  ## (Payload/<name>.app, zipped): what Transporter, `xcrun altool` and
  ## TestFlight take.
  zipBundle(app, output, "Payload")

## MSIX packages, the Microsoft Store's and Windows' installers, made in Nim
## (no MakeAppx, no SignTool, no Windows SDK): the program and its files,
## the manifest, the block map, the content types, and the signature
## (`retroui/sign`: Authenticode's, SHA-256).
##
## ```nim
## import retroui/[msix, rsa, sign]
## var p = MsixApp(name: "Foxoman.RetroFiles", publisher: "CN=Sultan Al Isaiee",
##                 displayName: "Retro Files", publisherName: "Sultan Al Isaiee",
##                 version: "1.2.0.0", exe: "retrofiles.exe")
## p.files.add ("retrofiles.exe", readFile("retrofiles.exe"))
## writeFile("RetroFiles.msix", buildMsix(p, key, cert))
## ```
##
## `publisher` must be the certificate's subject, word for word. For the
## Store, use the name, publisher and publisher name Partner Center gives the
## app; the Store signs it again. To install it yourself, Windows must trust
## the certificate (a self-signed one: put it in "Trusted People" of the
## local machine), then open the .msix or run `Add-AppxPackage`.

import std/[strutils, base64]
import rsa, sign, codec, appicon, imaging

type
  MsixApp* = object
    name*: string            ## the package's name: Company.App (letters, digits, . and -)
    publisher*: string       ## "CN=...": the signing certificate's subject
    version*: string         ## four numbers: 1.2.0.0
    arch*: string            ## x64 (default), arm64, x86, neutral
    displayName*: string     ## the app's name in Start and Settings
    publisherName*: string   ## the publisher's name shown to people
    description*: string
    exe*: string             ## the program, its path in the package
    icon*: string            ## a PNG (square, 256 px or more); empty: the 3.1 window
    background*: string      ## the tile's color: "transparent" (default) or #RRGGBB
    minWindows*: string      ## lowest Windows: 10.0.17763.0 (default, 1809)
    files*: seq[(string, string)]  ## the program and every file it needs: (path, bytes)
    capabilities*: seq[string]     ## more: internetClient, webcam, microphone...

  MsixError* = object of CatchableError

const
  BlockSize = 65536
  MaxSmall = 0xFFFFFFFE'i64            ## (bigger: its sizes after the data, zip64)

proc bad(why: string) {.noreturn.} = raise newException(MsixError, why)

proc xmlEsc(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc winPath(p: string): string = p.replace('/', '\\')

proc logoPng(icon: string; size: int): string =
  ## The icon at `size` px (averaged down; the 3.1 window when no icon).
  if icon.len == 0:
    let b = iconPng(size)
    result = newString(b.len)
    if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)
    return
  let px = windowIconFromPng(icon, [size])
  if px.len < 2 + size * size: bad("the icon is not a PNG file")
  let b = png(size, size, px.toOpenArray(2, 1 + size * size))
  result = newString(b.len)
  copyMem(addr result[0], unsafeAddr b[0], b.len)

proc manifestOf*(a: MsixApp): string =
  ## AppxManifest.xml: a desktop program (full trust).
  let arch = if a.arch.len > 0: a.arch else: "x64"
  let minWin = if a.minWindows.len > 0: a.minWindows else: "10.0.17763.0"
  var caps = "    <rescap:Capability Name=\"runFullTrust\"/>\n"
  for c in a.capabilities:
    if c != "runFullTrust": caps = "    <Capability Name=\"" & xmlEsc(c) & "\"/>\n" & caps
  let desc = if a.description.len > 0: a.description else: a.displayName
  """<?xml version="1.0" encoding="utf-8"?>
<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"
  xmlns:uap="http://schemas.microsoft.com/appx/manifest/uap/windows10"
  xmlns:rescap="http://schemas.microsoft.com/appx/manifest/foundation/windows10/restrictedcapabilities"
  IgnorableNamespaces="uap rescap">
  <Identity Name="$1" Publisher="$2" Version="$3" ProcessorArchitecture="$4"/>
  <Properties>
    <DisplayName>$5</DisplayName>
    <PublisherDisplayName>$6</PublisherDisplayName>
    <Logo>Assets\StoreLogo.png</Logo>
  </Properties>
  <Dependencies>
    <TargetDeviceFamily Name="Windows.Desktop" MinVersion="$7" MaxVersionTested="10.0.26100.0"/>
  </Dependencies>
  <Resources>
    <Resource Language="en-us"/>
  </Resources>
  <Applications>
    <Application Id="App" Executable="$8" EntryPoint="Windows.FullTrustApplication">
      <uap:VisualElements DisplayName="$5" Description="$9" BackgroundColor="$10"
        Square150x150Logo="Assets\Square150x150Logo.png" Square44x44Logo="Assets\Square44x44Logo.png"/>
    </Application>
  </Applications>
  <Capabilities>
$11  </Capabilities>
</Package>
""" % [xmlEsc(a.name), xmlEsc(a.publisher), a.version, arch, xmlEsc(a.displayName),
       xmlEsc(a.publisherName), minWin, xmlEsc(winPath(a.exe)), xmlEsc(desc),
       (if a.background.len > 0: a.background else: "transparent"), caps]

proc check(a: MsixApp) =
  if a.name.len < 3 or a.name.len > 50: bad("the name must be 3 to 50 letters (Company.App)")
  for c in a.name:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '.', '-'}: bad("the name may have letters, digits, . and - only")
  if not a.publisher.startsWith("CN="): bad("the publisher is the certificate's subject: CN=...")
  let v = a.version.split('.')
  if v.len != 4: bad("the version is four numbers: 1.0.0.0")
  for n in v:
    try:
      if parseInt(n) notin 0 .. 65535: bad("each number of the version is 0 to 65535")
    except ValueError: bad("the version is four numbers: 1.0.0.0")
  if a.displayName.len == 0: bad("the app needs a display name")
  if a.publisherName.len == 0: bad("the app needs a publisher name")
  if a.exe.len == 0: bad("the app needs its program (exe)")
  var found = false
  for (p, _) in a.files:
    if p == a.exe: found = true
  if not found: bad("the program " & a.exe & " is not among the files")

# ---- the zip, as Windows' own packager writes it (zip64 end records; the sizes in the local
# headers, a data descriptor only for a file of 4 GB or more) ----------------------------------

type
  Entry = object
    name: string
    offset, csize, usize: int
    crc: uint32
    deflated: bool
    big: bool                    ## (4 GB or more: a data descriptor, zip64)
  PkgZip = object
    data: string
    entries: seq[Entry]

proc le(s: var string; v: uint64; n: int) =
  for i in 0 ..< n: s.add char((v shr (8 * i)) and 255)

proc opcName(p: string): string =
  ## A file's name in the zip (OPC: percent-encoded, / between folders).
  for c in p:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '.', '_', '~', '/', '!', '$', '&', '\'', '(', ')',
             '*', '+', ',', ';', '=', ':', '@'}: result.add c
    elif c == '\\': result.add '/'
    else: result.add "%" & toHex(ord(c), 2)

proc lfhSize(name: string): int = 30 + name.len

proc add(z: var PkgZip; name, content: string; compress: bool): seq[int] =
  ## (returns the compressed size of each 64 KB block, when deflated)
  var e = Entry(name: name, offset: z.data.len, usize: content.len,
                crc: crc32(content.toOpenArrayByte(0, content.len - 1)))
  var body: string
  e.deflated = compress and content.len > 0
  if e.deflated:
    let (stream, sizes) = deflatePieces(content.toOpenArrayByte(0, content.len - 1), BlockSize)
    body = newString(stream.len)
    if stream.len > 0: copyMem(addr body[0], unsafeAddr stream[0], stream.len)
    result = sizes
  else: body = content
  e.csize = body.len
  # (as Windows' packager writes a file under 4 GB: its sizes in the local
  # header, no data descriptor; a bigger one has them after its data)
  e.big = int64(e.csize) > MaxSmall or int64(e.usize) > MaxSmall
  if int64(e.offset) > MaxSmall: bad("the package is bigger than 4 GB")
  var h = "PK\3\4"
  h.le(if e.big: 45 else: 20, 2); h.le(if e.big: 8 else: 0, 2); h.le(if e.deflated: 8 else: 0, 2)
  h.le(0, 2); h.le(0x21, 2)                     # 1980-01-01
  if e.big:
    h.le(0, 4); h.le(0, 4); h.le(0, 4)          # (in the descriptor)
  else:
    h.le(e.crc, 4); h.le(uint64(e.csize), 4); h.le(uint64(e.usize), 4)
  h.le(uint64(name.len), 2); h.le(0, 2)
  h.add name
  z.data.add h
  z.data.add body
  if e.big:
    var d = "PK\7\8"
    d.le(e.crc, 4); d.le(uint64(e.csize), 8); d.le(uint64(e.usize), 8)
    z.data.add d
  z.entries.add e

proc central(z: PkgZip; skip = ""): tuple[cd: string; count: int] =
  for e in z.entries:
    if e.name == skip: continue
    var c = "PK\1\2"
    c.le(45, 2); c.le(if e.big: 45 else: 20, 2); c.le(if e.big: 8 else: 0, 2)
    c.le(if e.deflated: 8 else: 0, 2)
    c.le(0, 2); c.le(0x21, 2)
    c.le(e.crc, 4)
    if e.big: (c.le(0xFFFFFFFF'u32, 4); c.le(0xFFFFFFFF'u32, 4))
    else: (c.le(uint64(e.csize), 4); c.le(uint64(e.usize), 4))
    c.le(uint64(e.name.len), 2); c.le(if e.big: 20 else: 0, 2); c.le(0, 2); c.le(0, 2); c.le(0, 2)
    c.le(0, 4); c.le(uint64(e.offset), 4)
    c.add e.name
    if e.big:                                   # (zip64: the two sizes)
      c.le(1, 2); c.le(16, 2); c.le(uint64(e.usize), 8); c.le(uint64(e.csize), 8)
    result.cd.add c
    inc result.count

proc ending(count, cdSize, cdAt: int; hashed = false): string =
  ## The zip64 end records and the end record (all 0xFF.., as Windows
  ## writes it; its disk numbers 0 in the signature's digest).
  result = "PK\6\6"
  result.le(44, 8); result.le(45, 2); result.le(45, 2); result.le(0, 4); result.le(0, 4)
  result.le(uint64(count), 8); result.le(uint64(count), 8)
  result.le(uint64(cdSize), 8); result.le(uint64(cdAt), 8)
  result.add "PK\6\7"
  result.le(0, 4); result.le(uint64(cdAt + cdSize), 8); result.le(1, 4)
  result.add "PK\5\6"
  result.le(0, 2); result.le(0, 2)
  result.le(0xFFFF, 2); result.le(0xFFFF, 2); result.le(0xFFFFFFFF'u32, 4); result.le(0xFFFFFFFF'u32, 4)
  result.le(0, 2)

proc contentType(ext: string): string =
  case ext.toLowerAscii
  of "exe", "dll", "com": "application/x-msdownload"
  of "png": "image/png"
  of "jpg", "jpeg": "image/jpeg"
  of "gif": "image/gif"
  of "ico": "image/vnd.microsoft.icon"
  of "svg": "image/svg+xml"
  of "webp": "image/webp"
  of "txt": "text/plain"
  of "htm", "html": "text/html"
  of "css": "text/css"
  of "js": "application/x-javascript"
  of "json": "application/json"
  of "xml": "text/xml"
  of "ttf", "otf": "application/x-font-ttf"
  of "wav": "audio/wav"
  of "mp3": "audio/mpeg"
  of "mp4": "video/mp4"
  of "pdf": "application/pdf"
  of "zip": "application/x-zip-compressed"
  else: "application/octet-stream"

proc stored(ext: string): bool =
  ## (already compressed: kept as they are)
  ext.toLowerAscii in ["png", "jpg", "jpeg", "gif", "webp", "zip", "mp3", "mp4", "gz", "7z", "msix"]

proc unsignedMsix(a: MsixApp; files: seq[(string, string)]): tuple[z: PkgZip; ct, bm: string] =
  var z: PkgZip
  var bm = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"no\"?>\r\n" &
           "<BlockMap xmlns=\"http://schemas.microsoft.com/appx/2010/blockmap\" " &
           "HashMethod=\"http://www.w3.org/2001/04/xmlenc#sha256\">"
  var defaults: seq[(string, string)]
  var overrides: seq[(string, string)]
  proc typed(name: string; ctype: string) =
    let dot = name.rfind('.')
    let slash = name.rfind('/')
    if dot > slash and dot >= 0:
      let ext = name[dot + 1 .. ^1].toLowerAscii
      for (e, t) in defaults:
        if e == ext:
          if t != ctype: overrides.add ("/" & name, ctype)
          return
      defaults.add (ext, ctype)
    else: overrides.add ("/" & name, ctype)
  for (path, data) in files:
    let name = opcName(path)
    let ext = if '.' in path: path[path.rfind('.') + 1 .. ^1] else: ""
    let compress = not stored(ext)
    let sizes = z.add(name, data, compress)
    let ctype = if path == "AppxManifest.xml": "application/vnd.ms-appx.manifest+xml"
                else: contentType(ext)
    typed(name, ctype)
    bm.add "<File Name=\"" & xmlEsc(winPath(path)) & "\" Size=\"" & $data.len & "\" LfhSize=\"" &
           $lfhSize(name) & "\">"
    var i = 0
    var k = 0
    while i < data.len:
      let e = min(data.len, i + BlockSize)
      let h = encode(sha256(data.toOpenArrayByte(i, e - 1)))
      bm.add "<Block Hash=\"" & h & "\""
      if compress: bm.add " Size=\"" & $sizes[k] & "\""
      bm.add "/>"
      i = e
      inc k
    bm.add "</File>"
  bm.add "</BlockMap>"
  overrides.add ("/AppxBlockMap.xml", "application/vnd.ms-appx.blockmap+xml")
  overrides.add ("/AppxSignature.p7x", "application/vnd.ms-appx.signature")
  var ct = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\r\n" &
           "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
  for (e, t) in defaults: ct.add "<Default Extension=\"" & xmlEsc(e) & "\" ContentType=\"" & t & "\"/>"
  for (p, t) in overrides: ct.add "<Override PartName=\"" & xmlEsc(p) & "\" ContentType=\"" & t & "\"/>"
  ct.add "</Types>"
  discard z.add("AppxBlockMap.xml", bm, true)
  discard z.add("[Content_Types].xml", ct, true)
  (z, ct, bm)

proc payload(a: MsixApp): seq[(string, string)] =
  ## The files in the package's order: the app's, its logos, the manifest.
  var seen: seq[string]
  for (p, d) in a.files:
    let q = p.replace('\\', '/')
    if q.toLowerAscii in ["appxmanifest.xml", "appxblockmap.xml", "[content_types].xml",
                          "appxsignature.p7x"] or q.toLowerAscii.startsWith("appxmetadata/"):
      bad(p & " is a name the package keeps for itself")
    if q.toLowerAscii in seen: bad(p & " is in the package twice")
    seen.add q.toLowerAscii
    result.add (q, d)
  for (file, px) in [("Assets/Square150x150Logo.png", 150), ("Assets/Square44x44Logo.png", 44),
                     ("Assets/StoreLogo.png", 50)]:
    if file.toLowerAscii notin seen: result.add (file, logoPng(a.icon, px))
  result.add ("AppxManifest.xml", manifestOf(a))

const
  oidSpcSipInfo = "1.3.6.1.4.1.311.2.1.30"
  AppxUuid = [0x4B'u8, 0xDF, 0xC5, 0x0A, 0x07, 0xCE, 0xE2, 0x4D, 0xB7, 0x6E, 0x23, 0xC8, 0x39, 0xA0, 0x9F, 0xD1]

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc appxDigest(z: PkgZip; ct, bm: string): seq[byte] =
  ## "APPX", then the SHA-256 of the files' records (AXPC), of the central
  ## directory with its end (AXCD), of [Content_Types].xml (AXCT) and of
  ## the block map (AXBM): what an MSIX's signature signs.
  let (cd, count) = z.central()
  let records = z.data
  result = bytesOf("APPX")
  result.add bytesOf("AXPC"); result.add sha256(bytesOf(records))
  result.add bytesOf("AXCD"); result.add sha256(bytesOf(cd & ending(count, cd.len, records.len)))
  result.add bytesOf("AXCT"); result.add sha256(bytesOf(ct))
  result.add bytesOf("AXBM"); result.add sha256(bytesOf(bm))

proc msixSignature(digest: seq[byte]; key: RsaKey; cert: seq[byte]; chain: seq[seq[byte]];
                   description: string; timestamper: Timestamper): string =
  ## AppxSignature.p7x: "PKCX" and the Authenticode signature of the digest.
  let sip = derSeq(derInt(0x01010000), derOctets(AppxUuid), derInt(0), derInt(0), derInt(0),
                   derInt(0), derInt(0))
  let sig = indirectSignature(derSeq(derOid(oidSpcSipInfo), sip), digest, key, cert, description,
                              chain = chain, timestamper = timestamper)
  result = "PKCX" & newString(sig.len)
  copyMem(addr result[4], unsafeAddr sig[0], sig.len)

proc buildMsix*(a: MsixApp; key: RsaKey; cert: seq[byte]; chain: seq[seq[byte]] = @[];
                timestamper: Timestamper = nil): string =
  ## The signed .msix of `a`: its files, logos made from its icon, the
  ## manifest, the block map, the content types and the signature
  ## (`timestamper`: stamped with the time, see `retroui/sign`).
  check(a)
  var (z, ct, bm) = unsignedMsix(a, payload(a))
  let digest = appxDigest(z, ct, bm)
  let sig = msixSignature(digest, key, cert, chain, a.displayName, timestamper)
  discard z.add("AppxSignature.p7x", sig, true)
  let (cd, count) = z.central()
  result = z.data & cd & ending(count, cd.len, z.data.len)

proc buildUnsignedMsix*(a: MsixApp): string =
  ## The .msix of `a` without its signature: to sign elsewhere (signtool,
  ## a signing service, a hardware key).
  check(a)
  let (z, _, _) = unsignedMsix(a, payload(a))
  let (cd, count) = z.central()
  result = z.data & cd & ending(count, cd.len, z.data.len)

proc msixFiles*(a: MsixApp): seq[(string, string)] =
  ## The files `buildMsix` puts in the package before its own (the app's,
  ## the logos, the manifest): to look at, or to give to MakeAppx.
  check(a)
  payload(a)

## retrokit's store commands: what an app is shipped in, made and signed
## in Nim (retroui/sign, retroui/msix, retroui/macapp), on any system.
##
##   retrokit sign PROGRAM.exe     Windows' Authenticode signature
##   retrokit msix PROGRAM.exe     an MSIX for the Microsoft Store (signed)
##   retrokit mac PROGRAM          a macOS .app (signed ad hoc, or with your
##                                 Developer ID, notarized and stapled on a Mac)
##   retrokit ipa APP.app          an iOS .ipa for TestFlight and the App Store
##   retrokit aab APP.nim          an Android App Bundle (retroapk --aab)
##   retrokit model FILE           a 3D model (.blend, .gltf, .obj, .stl) as the .glb
##                                 an app carries, with its parts and clips listed
##   retrokit update-key           a key for updates inside apps (retroui/update)
##   retrokit update-sign FILE     update.json signed with it (FILE.sig)

import std/[os, osproc, strutils]
import std/json
import retroui/[sign, msix, macapp, rsa, http, view3d, gltf, update, sha2]

proc die(msg: string) {.noreturn.} =
  stderr.writeLine "retrokit: " & msg
  quit 1

proc options(args: openArray[string]): tuple[files: seq[string]; opts: seq[(string, string)]] =
  for a in args:
    if a.startsWith("-"):
      let s = a.strip(trailing = false, chars = {'-'})
      let i = s.find({':', '='})
      if i < 0: result.opts.add (s.toLowerAscii.replace("-", ""), "")
      else: result.opts.add (s[0 ..< i].toLowerAscii.replace("-", ""), s[i + 1 .. ^1])
    else: result.files.add a

proc opt(o: seq[(string, string)]; names: varargs[string]; default = ""): string =
  result = default
  for (k, v) in o:
    if k in names: result = v

proc has(o: seq[(string, string)]; names: varargs[string]): bool =
  for (k, _) in o:
    if k in names: return true

proc all(o: seq[(string, string)]; name: string): seq[string] =
  for (k, v) in o:
    if k == name: result.add v

proc bytesOf(s: string): seq[byte] =
  result = newSeq[byte](s.len)
  if s.len > 0: copyMem(addr result[0], unsafeAddr s[0], s.len)

proc keyAndCert(o: seq[(string, string)]; testDir, testSubject: string):
    tuple[key: RsaKey; cert: seq[byte]; chain: seq[seq[byte]]] =
  ## --key and --cert (PEM; the cert's file may hold its chain too), and
  ## --chain; none: a test key made once in `testDir`.
  let keyPath = o.opt("key")
  let certPath = o.opt("cert")
  if keyPath.len == 0 and certPath.len == 0:
    let (k, c) = devKey(testDir, testSubject)
    echo "Signing with a test certificate (", certSubject(c), ", in ", testDir,
         "); for people to trust it, give yours: --key:KEY.pem --cert:CERT.pem"
    return (k, c, @[])
  if keyPath.len == 0 or certPath.len == 0: die "--key and --cert go together"
  try:
    result.key = readRsaKey(readFile(keyPath))
    let certs = readCerts(readFile(certPath))
    if certs.len == 0: die "no certificate in " & certPath
    result.cert = certs[0]
    result.chain = certs[1 .. ^1]
    for c in o.all("chain"): result.chain.add readCerts(readFile(c))
  except IOError as e: die e.msg
  except RsaError as e: die "the key " & keyPath & ": " & e.msg
  except SignError as e: die e.msg

proc stamper(o: seq[(string, string)]): Timestamper =
  ## --timestamp:URL (or $RETRO_TIMESTAMP): the time-stamping authority to
  ## ask (http://timestamp.digicert.com, http://timestamp.sectigo.com,
  ## your certificate's seller's)
  let url = o.opt("timestamp", "tsa", default = getEnv("RETRO_TIMESTAMP"))
  if url.len == 0: return nil
  result = proc (query: seq[byte]): seq[byte] =
    var body = newString(query.len)
    if query.len > 0: copyMem(addr body[0], unsafeAddr query[0], query.len)
    let r = httpRequest("POST", url, [("Content-Type", "application/timestamp-query")], body,
                        timeoutSec = 30)
    if r.status != 200:
      raise newException(SignError, "the time-stamping authority " & url & " answered " &
                         (if r.status == 0: r.error else: $r.status))
    bytesOf(r.body)

proc winKeys(): string = getEnv("RETRO_KEYS", getHomeDir() / ".retro") / "windows"
proc macKeys(): string = getEnv("RETRO_KEYS", getHomeDir() / ".retro") / "mac"

# ---- Windows ---------------------------------------------------------------------------------

proc signCmd*(args: seq[string]): int =
  let (files, o) = options(args)
  if files.len != 1 or o.has("help", "h"):
    echo """retrokit sign PROGRAM.exe [options]   Windows' Authenticode signature (SHA-256)
  --key:KEY.pem --cert:CERT.pem  your code signing key and certificate (PEM;
                     from a .pfx: openssl pkcs12 -in my.pfx -nocerts -nodes -out key.pem,
                     openssl pkcs12 -in my.pfx -clcerts -nokeys -out cert.pem); none: a
                     test certificate made once in ~/.retro/windows
  --chain:CA.pem     the authority's certificates that come with yours
  --name:TEXT        what Windows shows as the program's name when it asks
  --url:URL          the app's site, shown with it
  --timestamp:URL    stamped with the time by this authority (e.g.
                     http://timestamp.digicert.com; or $RETRO_TIMESTAMP): the
                     signature stays good after the certificate expires
  -o:FILE            write the signed program there (default: in place)"""
    return (if o.has("help", "h"): 0 else: 1)
  let path = files[0]
  if not fileExists(path): die "no such file: " & path
  let (key, cert, chain) = keyAndCert(o, winKeys(), "CN=Retro Nim UI test")
  let name = o.opt("name", default = path.splitFile.name)
  try:
    let signed = authenticodeSign(readFile(path), key, cert, name, o.opt("url"), chain, stamper(o))
    let output = o.opt("o", "out", "output", default = path)
    writeFile(output, signed)
    echo "Signed ", output, " (", certSubject(cert), ")"
  except SignError as e: die path & ": " & e.msg
  except IOError as e: die e.msg

proc peArch(pe: string): string =
  if pe.len < 0x40 or pe[0 .. 1] != "MZ": return "x64"
  let at = int(uint8(pe[0x3C])) or (int(uint8(pe[0x3D])) shl 8) or (int(uint8(pe[0x3E])) shl 16)
  if at + 6 > pe.len: return "x64"
  case int(uint8(pe[at + 4])) or (int(uint8(pe[at + 5])) shl 8)
  of 0xAA64: "arm64"
  of 0x14C: "x86"
  else: "x64"

proc fourPart(v: string): string =
  var parts = v.split('.')
  while parts.len < 4: parts.add "0"
  parts[0 .. 3].join(".")

proc cnOf(subject: string): string =
  for part in subject.split(", "):
    if part.startsWith("CN="): return part[3 .. ^1].strip(chars = {'"'})
  subject

proc msixCmd*(args: seq[string]): int =
  let (files, o) = options(args)
  if files.len != 1 or o.has("help", "h"):
    echo """retrokit msix PROGRAM.exe [options]   an MSIX for the Microsoft Store, signed
  --name:Company.App   the package's name (Partner Center gives it; default
                       Retro.<program>)
  --display:TEXT       the app's name in Start (default: the program's name)
  --publisher-name:T   the publisher's name people see (default: the
                       certificate's CN); the publisher is the certificate's
                       subject itself
  --version:1.2.0.0    the version (four numbers; default 1.0.0.0)
  --description:TEXT   one line about the app
  --icon:FILE.png      the icon (square, 256 px or more; default: the 3.1 window)
  --files:DIR          the files the program needs (beside it in the package)
  --capability:NAME    internetClient, webcam, microphone... (repeatable)
  --min-windows:V      lowest Windows (default 10.0.17763.0)
  --key, --cert, --chain, --timestamp  as for `retrokit sign` (the program
                       inside is signed with them too; --no-exe-sign leaves it)
  -o:FILE.msix         output (default: <program>.msix beside it)
To install a package signed with a test certificate yourself: put the
certificate (~/.retro/windows/dev-cert.der) in the local machine's
"Trusted People", then open the .msix (or Add-AppxPackage FILE.msix)."""
    return (if o.has("help", "h"): 0 else: 1)
  let path = files[0]
  if not fileExists(path): die "no such file: " & path
  let base = path.splitFile.name
  let (key, cert, chain) = keyAndCert(o, winKeys(), "CN=Retro Nim UI test")
  let subject = try: certSubject(cert) except SignError as e: die e.msg
  var exe = readFile(path)
  if not o.has("noexesign"):
    try: exe = authenticodeSign(exe, key, cert, o.opt("display", default = base), "", chain, stamper(o))
    except SignError as e: die path & ": " & e.msg
  var clean = ""
  for c in base:
    if c.isAlphaNumeric: clean.add c
  if clean.len == 0: clean = "App"
  var a = MsixApp(name: o.opt("name", default = "Retro." & clean.capitalizeAscii),
                  publisher: subject,
                  version: fourPart(o.opt("version", default = "1.0.0.0")),
                  arch: o.opt("arch", default = peArch(exe)),
                  displayName: o.opt("display", default = base.capitalizeAscii),
                  publisherName: o.opt("publishername", default = cnOf(subject)),
                  description: o.opt("description"),
                  exe: path.extractFilename,
                  minWindows: o.opt("minwindows"),
                  capabilities: o.all("capability"))
  let icon = o.opt("icon")
  if icon.len > 0:
    try: a.icon = readFile(icon)
    except IOError: die "cannot read the icon " & icon
  a.files.add (a.exe, exe)
  let dir = o.opt("files")
  if dir.len > 0:
    if not dirExists(dir): die "no folder " & dir
    for f in walkDirRec(dir, relative = true):
      a.files.add (f.replace('\\', '/'), readFile(dir / f))
  let output = o.opt("o", "out", "output", default = path.changeFileExt("msix"))
  try:
    writeFile(output, buildMsix(a, key, cert, chain, stamper(o)))
  except MsixError as e: die e.msg
  except SignError as e: die e.msg
  echo "Built ", output, " (", getFileSize(output) div 1024, " KB, ", a.name, " ", a.version, " ",
       a.arch, ", publisher ", subject, ")"

# ---- macOS and iOS -------------------------------------------------------------------------

proc run(cmd: openArray[string]; what: string) =
  echo "+ ", quoteShellCommand(cmd)
  let p = startProcess(cmd[0], args = cmd[1 .. ^1], options = {poParentStreams, poUsePath})
  let code = p.waitForExit()
  p.close()
  if code != 0: die what & " failed (exit code " & $code & ")"

proc macCmd*(args: seq[string]): int =
  let (files, o) = options(args)
  if files.len != 1 or o.has("help", "h"):
    echo """retrokit mac PROGRAM [options]   a macOS app (.app), signed, and zipped
  PROGRAM            the app built for macOS (one architecture or universal;
                     lipo -create puts two together); on a Mac, APP.nim is
                     built here (--universal: for Apple silicon and Intel)
  --name:TEXT        the app's name (default: the program's)
  --id:BUNDLE_ID     org.me.myapp (default org.retro.<program>)
  --version:X.Y      the version (default 1.0); --build:N its build number
  --icon:FILE.png    the icon (1024 px is best; default: the 3.1 window)
  --min-macos:V      lowest macOS (default 11.0)
  --files:DIR        files for Contents/Resources
  --sign:IDENTITY    on a Mac: codesign with your "Developer ID Application:
                     ..." (the hardened runtime, a secure timestamp);
                     without it: signed ad hoc, here, on any system
  --entitlements:F   the entitlements to sign with (with --sign)
  --notarize:PROFILE on a Mac: send it to Apple (xcrun notarytool, the
                     keychain profile made by `xcrun notarytool
                     store-credentials PROFILE`), wait, staple the ticket
  -o:DIR             where (default: build/mac beside the program)"""
    return (if o.has("help", "h"): 0 else: 1)
  var program = files[0]
  if not fileExists(program): die "no such file: " & program
  let base = program.splitFile.name
  let name = o.opt("name", default = base.capitalizeAscii)
  var clean = ""
  for c in base.toLowerAscii:
    if c in {'a'..'z', '0'..'9'}: clean.add c
  let id = o.opt("id", default = "org.retro." & (if clean.len > 0: clean else: "app"))
  let outDir = o.opt("o", "out", "output", default = program.parentDir / "build" / "mac")
  createDir(outDir)
  if program.endsWith(".nim"):
    when not defined(macosx):
      die "a macOS program is built on a Mac (Xcode's SDK); build it there, or give the program"
    else:
      let work = outDir / "work"
      createDir(work)
      var built: seq[string]
      let cpus = if o.has("universal"): @["arm64", "amd64"] else: @[hostCPU]
      for cpu in cpus:
        let exe = work / base & "-" & cpu
        let arch = if cpu == "amd64": "x86_64" else: "arm64"
        run(["nim", "c", "-d:release", "--hints:off", "--cpu:" & cpu,
             "--passC:-arch " & arch, "--passL:-arch " & arch,
             "--nimcache:" & work / "nimcache-" & cpu, "-o:" & exe, program], "building for " & arch)
        built.add exe
      if built.len > 1:
        run(@["lipo", "-create"] & built & @["-output", work / base], "lipo")
        program = work / base
      else: program = built[0]
  let filesDir = o.opt("files")
  var extra: seq[(string, string)]
  if filesDir.len > 0:
    if not dirExists(filesDir): die "no folder " & filesDir
    for f in walkDirRec(filesDir, relative = true):
      extra.add (f.replace('\\', '/'), readFile(filesDir / f))
  let app = try:
      writeMacApp(outDir, program, name, id, o.opt("version", default = "1.0"), o.opt("icon"),
                  o.opt("build"), o.opt("minmacos", default = "11.0"), extra)
    except MacError as e: die e.msg
    except IOError, OSError: die getCurrentExceptionMsg()
  let identity = o.opt("sign")
  if identity.len > 0:
    when not defined(macosx): die "--sign is codesign's, on a Mac (without it: signed ad hoc here)"
    else:
      var cmd = @["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity]
      let ent = o.opt("entitlements")
      if ent.len > 0: cmd.add @["--entitlements", ent]
      cmd.add app
      run(cmd, "codesign")
      run(["codesign", "--verify", "--strict", "--verbose=2", app], "checking the signature")
  else:
    try: adhocSign(app)
    except MacError as e: die e.msg
  let zipPath = outDir / app.extractFilename.changeFileExt("zip")
  let profile = o.opt("notarize")
  if profile.len > 0:
    when not defined(macosx): die "--notarize is Apple's notarytool, on a Mac"
    else:
      if identity.len == 0: die "--notarize needs --sign (a Developer ID Application certificate)"
      run(["ditto", "-c", "-k", "--keepParent", app, zipPath], "zipping")
      run(["xcrun", "notarytool", "submit", zipPath, "--keychain-profile", profile, "--wait"],
          "notarizing")
      run(["xcrun", "stapler", "staple", app], "stapling")
  when defined(macosx):
    run(["ditto", "-c", "-k", "--keepParent", app, zipPath], "zipping")
  else:
    try: zipBundle(app, zipPath)
    except MacError as e: die e.msg
  echo "Built ", app, " and ", zipPath, " (", id, ", ",
       (if identity.len > 0: "signed by " & identity else: "signed ad hoc"),
       (if profile.len > 0: ", notarized" else: ""), ")"

proc ipaCmd*(args: seq[string]): int =
  let (files, o) = options(args)
  if files.len != 1 or o.has("help", "h"):
    echo """retrokit ipa APP.app [-o:FILE.ipa]   an iOS app as the .ipa that TestFlight and the
  App Store take (build and sign it first: retroios --sign --profile)"""
    return (if o.has("help", "h"): 0 else: 1)
  let app = files[0].strip(leading = false, chars = {'/', '\\'})
  if not dirExists(app): die "no bundle " & app
  if not fileExists(app / "_CodeSignature" / "CodeResources"):
    echo "Note: ", app, " is not signed; the App Store takes it signed with your ",
         "distribution certificate and profile (retroios --sign --profile)."
  let output = o.opt("o", "out", "output", default = app.changeFileExt("ipa"))
  try: ipaOf(app, output)
  except MacError as e: die e.msg
  echo "Built ", output, " (", getFileSize(output) div 1024, " KB)"

# ---- 3D models ---------------------------------------------------------------------------

proc modelCmd*(args: seq[string]): int =
  let (files, o) = options(args)
  if files.len != 1 or o.has("help", "h"):
    echo """retrokit model FILE [-o:OUT.glb]   a 3D model as the .glb an app carries
  FILE               a .blend (made into glTF by Blender: `blender` on the PATH, or
                     $RETRO_BLENDER), a .gltf with its files, an .obj or an .stl
  -o:OUT.glb         where (default: beside it)
It says the model's parts (nodes) and clips by name: the names an app
moves, hides, tints and plays them by (view3d's turnNode, setVisible,
tint, play)."""
    return (if o.has("help", "h"): 0 else: 1)
  let path = files[0]
  if not fileExists(path): die "no such file: " & path
  let output = o.opt("o", "out", "output", default = path.changeFileExt("glb"))
  var scene: Scene3
  try:
    if path.toLowerAscii.endsWith(".blend"):
      let glb = blendToGlb(path, output)
      if glb.len == 0: die "Blender could not export " & path &
                           " (install Blender, or put it in $RETRO_BLENDER)"
      scene = loadGltf(glb)
    else:
      scene = loadModel3(path)
      if output.absolutePath != path.absolutePath: writeFile(output, toGlb(scene))
  except GltfError as e: die e.msg
  except ValueError as e: die path & ": " & e.msg
  except IOError, OSError: die getCurrentExceptionMsg()
  var tris = 0
  for m in scene.meshes: tris += m.tris.len
  echo "Made ", output, " (", scene.meshes.len, " meshes, ", tris, " triangles, ",
       scene.materials.len, " materials)"
  let names = scene.nodeNames
  if names.len > 0: echo "Parts: ", names.join(", ")
  let clips = scene.animationNames
  if clips.len > 0: echo "Clips: ", clips.join(", ")

# ---- updates inside apps (retroui/update) --------------------------------------------------

proc updateKeyCmd*(args: seq[string]): int =
  let (files, o) = options(args)
  if o.has("help", "h") or files.len > 0:
    echo """retrokit update-key [--out:update-key.secret]   a key for updates inside apps
  Writes the secret key (keep it to yourself: never in the repository, in
  CI a secret) and prints the public key, for the app's checkForUpdate."""
    return (if o.has("help", "h"): 0 else: 1)
  let path = o.opt("out", "o", default = "update-key.secret")
  if fileExists(path): die path & " is there already (a second key would not match the apps out there)"
  let (secret, public) = newUpdateKeys()
  writeFile(path, secret & "\n")
  when not defined(windows):
    setFilePermissions(path, {fpUserRead, fpUserWrite})
  echo "the secret key: ", path, " (keep it; anyone with it can ship to your users)"
  echo "the public key, for the app:"
  echo "  const updateKey = \"", public, "\""
  0

proc updateSignCmd*(args: seq[string]): int =
  let (files, o) = options(args)
  if o.has("help", "h") or files.len != 1:
    echo """retrokit update-sign update.json [--key:update-key.secret]
  Fills in each file's "size" and "sha256" (from the files beside it, by
  the name their address ends in), writes update.json again and signs it:
  update.json.sig. Publish both where the app's checkForUpdate looks.
  --key: the secret key file (or $RETRO_UPDATE_KEY, the key itself)."""
    return (if o.has("help", "h"): 0 else: 1)
  let path = files[0]
  if not fileExists(path): die "no such file: " & path
  var secret = getEnv("RETRO_UPDATE_KEY").strip
  let keyFile = o.opt("key", "k", default = "update-key.secret")
  if secret.len == 0:
    if not fileExists(keyFile): die "no key: " & keyFile & " (retrokit update-key makes one)"
    secret = readFile(keyFile).strip
  var j: JsonNode
  try: j = parseJson(readFile(path))
  except CatchableError as e: die "not JSON: " & e.msg
  if j{"version"}.getStr.len == 0: die "update.json has no \"version\""
  let files2 = j{"files"}
  if files2 != nil and files2.kind == JObject:
    for platform, f in files2.pairs:
      let name = f{"url"}.getStr.split('?')[0].split('/')[^1]
      let local = path.parentDir / name
      if name.len > 0 and fileExists(local):
        let data = readFile(local)
        f["size"] = %data.len
        f["sha256"] = %sha256(data).toHex.toLowerAscii
        echo platform, ": ", name, " ", data.len, " bytes"
      elif f{"sha256"}.getStr.len != 64:
        die platform & ": " & name & " is not beside " & path & " and has no sha256"
  let text = j.pretty & "\n"
  writeFile(path, text)
  let sig = signUpdate(text, secret)
  if not verifyUpdate(text, sig, publicKeyOf(secret)): die "the signature does not check (a bad key?)"
  writeFile(path & ".sig", sig & "\n")
  echo "signed: ", path & ".sig", " (public key ", publicKeyOf(secret), ")"
  0


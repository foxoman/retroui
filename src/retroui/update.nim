## Updates inside the app: a small file you publish says which version is
## the newest and where its files are, signed with your key (Ed25519); the
## app asks for it, checks the signature with the public key built into it,
## downloads the file for its system, checks its SHA-256, and installs it
## (or hands it to the system's installer). Nothing comes from anyone who
## does not have your secret key.
##
## .. code-block:: nim
##   import retroui/update
##   const updateKey = "pRk1...="      # `retrokit update-key` printed it
##   let u = checkForUpdate("https://example.com/notes/update.json", updateKey, "1.2.0")
##   if u.available:
##     echo "Version ", u.version, ": ", u.notes
##     let file = downloadUpdate(u)          # (raises UpdateError)
##     if installUpdate(file): restartApp()
##
## The publisher's side, in `retrokit`:
##
##   retrokit update-key                     a key: update-key.secret (keep it,
##                                           out of the repository) and the
##                                           public key to put in the app
##   retrokit update-sign update.json        update.json.sig beside it
##
## update.json: what the app reads (its "files" by system, as
## `updatePlatform` names them: linux-x86_64, windows-x86_64, macos-arm64,
## android-arm64, web...):
##
##   { "version": "1.3.0", "notes": "Faster search.",
##     "files": { "linux-x86_64": { "url": "https://.../Notes-1.3.0.AppImage",
##                                  "size": 18200000, "sha256": "9f2c..." },
##                "windows-x86_64": { "url": "https://.../Notes-1.3.0-setup.exe", ... } } }
##
## `retrokit update-sign` fills each file's "size" and "sha256" from the
## files themselves when they are beside update.json (by the name the
## address ends in).
##
## What `installUpdate` does:
##
## - an AppImage (Linux): the running AppImage replaced by the new one
## - Windows: an installer (.exe, .msi) started, the app to end; a program
##   of its own (portable): the running .exe renamed aside, the new one put
##   in its place
## - a package (.deb, .rpm, .apk on Android, .dmg, .pkg on macOS): handed to
##   the system's installer, which asks the user
## - a web page: the page's service worker takes the newest build; the
##   page loads again (`webUpdate`)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[json, os, strutils, sysrand, base64]
import http, sha2, vault
import uirelays/services
from codec import unbase64
when not defined(wasm):
  import std/osproc

{.compile: "vendor/monocypher-ed25519.c".}

proc crypto_ed25519_key_pair(secretKey: ptr array[64, byte]; publicKey: ptr array[32, byte];
                             seed: ptr array[32, byte]) {.importc, cdecl.}
proc crypto_ed25519_sign(sig: ptr array[64, byte]; secretKey: ptr array[64, byte];
                         msg: pointer; len: csize_t) {.importc, cdecl.}
proc crypto_ed25519_check(sig: ptr array[64, byte]; publicKey: ptr array[32, byte];
                          msg: pointer; len: csize_t): cint {.importc, cdecl.}

type
  UpdateError* = object of CatchableError
    ## The update could not be had: no network, a signature that does not
    ## match, a file that is not what was signed.

  UpdateInfo* = object
    ## What `checkForUpdate` found.
    available*: bool        ## a newer version, with a file for this system
    version*: string        ## the newest version ("" when nothing came)
    notes*: string          ## what is new in it
    url*: string            ## its file for this system
    size*: int64            ## ... its size in bytes (0: not said)
    sha256*: string         ## ... its SHA-256 (hex)
    error*: string          ## why nothing could be checked ("" when it was)

# ---- signing (the publisher's side; retrokit uses these) ---------------------------------------

proc toArr[N: static int](s: string): array[N, byte] =
  if s.len != N: raise newException(UpdateError, "a key or signature of " & $s.len & " bytes, not " & $N)
  for i in 0 ..< N: result[i] = byte(s[i])

proc toStr(a: openArray[byte]): string =
  result = newString(a.len)
  for i, b in a: result[i] = char(b)

proc unb64(s: string): string =
  try: unbase64(s.strip) except ValueError: raise newException(UpdateError, "not base64: " & s.strip)

proc newUpdateKeys*(): tuple[secret, public: string] =
  ## A new key pair, both base64: keep `secret` to yourself (it signs), put
  ## `public` in the app (it checks).
  var seed: array[32, byte]
  if not urandom(seed): raise newException(UpdateError, "no random numbers")
  result.secret = encode(toStr(seed))
  var sk: array[64, byte]
  var pk: array[32, byte]
  crypto_ed25519_key_pair(addr sk, addr pk, addr seed)    # (it wipes the seed)
  result.public = encode(toStr(pk))

proc publicKeyOf*(secret: string): string =
  ## The public key (base64) of a secret key (base64).
  var seed = toArr[32](unb64(secret))
  var sk: array[64, byte]
  var pk: array[32, byte]
  crypto_ed25519_key_pair(addr sk, addr pk, addr seed)
  encode(toStr(pk))

proc signUpdate*(data, secret: string): string =
  ## The Ed25519 signature (base64) of `data` with the secret key (base64).
  var seed = toArr[32](unb64(secret))
  var sk: array[64, byte]
  var pk: array[32, byte]
  crypto_ed25519_key_pair(addr sk, addr pk, addr seed)
  var sig: array[64, byte]
  crypto_ed25519_sign(addr sig, addr sk, (if data.len > 0: unsafeAddr data[0] else: nil), csize_t(data.len))
  zeroMem(addr sk, sizeof sk)
  encode(toStr(sig))

proc verifyUpdate*(data, signature, public: string): bool =
  ## `signature` (base64) is the signature of `data` by the key whose public
  ## key (base64) is `public`.
  try:
    var sig = toArr[64](unb64(signature))
    var pk = toArr[32](unb64(public))
    crypto_ed25519_check(addr sig, addr pk, (if data.len > 0: unsafeAddr data[0] else: nil),
                         csize_t(data.len)) == 0
  except UpdateError: false

# ---- versions ------------------------------------------------------------------------------

proc newerVersion*(a, b: string): bool =
  ## Version `a` is newer than `b` ("1.10.0" > "1.9.2"; "1.0.0" > "1.0.0-beta.2").
  proc parts(v: string): (seq[int], string) =
    var s = v.strip
    if s.startsWith("v") or s.startsWith("V"): s = s[1 .. ^1]
    let dash = s.find({'-', '+'})
    let pre = if dash >= 0: s[dash + 1 .. ^1] else: ""
    if dash >= 0: s.setLen(dash)
    var nums: seq[int]
    for p in s.split('.'):
      nums.add(try: parseInt(p) except ValueError: 0)
    (nums, pre)
  let (na, pa) = parts(a)
  let (nb, pb) = parts(b)
  for i in 0 ..< max(na.len, nb.len):
    let x = if i < na.len: na[i] else: 0
    let y = if i < nb.len: nb[i] else: 0
    if x != y: return x > y
  # (the same numbers: a release is newer than its pre-releases)
  if pa.len == 0 and pb.len > 0: return true
  if pa.len > 0 and pb.len == 0: return false
  pa > pb

proc updatePlatform*(): string =
  ## This system as update.json names it: "linux-x86_64", "windows-x86_64",
  ## "windows-arm64", "macos-arm64", "macos-x86_64", "android-arm64",
  ## "ios-arm64", "web".
  when defined(wasm): return "web"
  let os = when defined(android): "android"
           elif defined(ios): "ios"
           elif defined(macosx): "macos"
           elif defined(windows): "windows"
           elif defined(freebsd): "freebsd"
           else: "linux"
  let cpu = when defined(amd64): "x86_64"
            elif defined(arm64): "arm64"
            elif defined(i386): "x86"
            elif defined(arm): "arm"
            elif defined(riscv64): "riscv64"
            else: hostCPU
  os & "-" & cpu

# ---- the app's side --------------------------------------------------------------------------

proc checkForUpdate*(manifestUrl, publicKey, current: string; platform = updatePlatform();
                     timeoutSec = 30): UpdateInfo =
  ## Reads the update file at `manifestUrl` and its signature (the same
  ## address with ".sig"), checks it with `publicKey`; `available` when it
  ## names a version newer than `current` with a file for `platform`.
  ## Never raises: `error` says what went wrong. Waits for the network: on
  ## a thread of its own, or at a moment the app may wait.
  let m = httpRequest("GET", manifestUrl, timeoutSec = timeoutSec)
  if not m.ok:
    result.error = if m.status == 0: m.error else: "the update file: HTTP " & $m.status
    return
  let s = httpRequest("GET", manifestUrl & ".sig", timeoutSec = timeoutSec)
  if not s.ok:
    result.error = "the update file has no signature (" & (if s.status == 0: s.error else: "HTTP " & $s.status) & ")"
    return
  if not verifyUpdate(m.body, s.body, publicKey):
    result.error = "the update file's signature does not match this app's key"
    return
  var j: JsonNode
  try: j = parseJson(m.body)
  except CatchableError as e:
    result.error = "the update file is not JSON: " & e.msg
    return
  result.version = j{"version"}.getStr
  result.notes = j{"notes"}.getStr
  let f = j{"files"}{platform}
  if f != nil and f.kind == JObject:
    result.url = f{"url"}.getStr
    result.size = f{"size"}.getBiggestInt
    result.sha256 = f{"sha256"}.getStr.toLowerAscii
  elif platform == "web":
    result.url = "(the page)"
  result.available = result.version.len > 0 and newerVersion(result.version, current) and result.url.len > 0

proc downloadUpdate*(u: UpdateInfo; dir = ""; timeoutSec = 600): string =
  ## Downloads `u`'s file into `dir` (a folder for updates in the temporary
  ## folder by default) and checks its size and SHA-256; its path. Raises
  ## `UpdateError` (and keeps nothing) when it is not the file that was signed.
  if not u.available or u.url.len == 0 or u.url.startsWith("("):
    raise newException(UpdateError, "no file to download")
  if u.sha256.len != 64:
    raise newException(UpdateError, "the update file gives no SHA-256 for it")
  let r = httpRequest("GET", u.url, timeoutSec = timeoutSec)
  if not r.ok:
    raise newException(UpdateError, "the download failed: " & (if r.status == 0: r.error else: "HTTP " & $r.status))
  if u.size > 0 and r.body.len != u.size:
    raise newException(UpdateError, "the download is " & $r.body.len & " bytes, not " & $u.size)
  if sha256(r.body).toHex.toLowerAscii != u.sha256:
    raise newException(UpdateError, "the download is not the file that was signed (its SHA-256 differs)")
  let d = if dir.len > 0: dir else: getTempDir() / "retro-updates"
  createDir(d)
  var name = u.url.split('?')[0].split('/')[^1]
  if name.len == 0: name = "update"
  result = d / name
  writeFile(result, r.body)

proc webUpdate*(): bool {.discardable.} =
  ## A web page: its service worker asked for the newest build, the page
  ## loaded again with it. False outside a page.
  when defined(wasm): systemCall("update.web", "") == "1"
  else: false

proc installUpdate*(path: string): bool =
  ## Puts the downloaded file in place (see the module's notes): true when
  ## the new version is in place and the app should start again
  ## (`restartApp`); false when the system's installer took it (it asks the
  ## user; the app may go on, or end so the installer can replace it).
  let ext = path.splitFile.ext.toLowerAscii
  when defined(wasm):
    discard path
    return webUpdate()
  elif defined(windows):
    if ext in [".msi"] or (ext == ".exe" and "setup" in path.extractFilename.toLowerAscii):
      discard openFile(path)
      return false
    if ext == ".exe":
      let me = getAppFilename()
      let old = me & ".old"
      try:
        if fileExists(old): removeFile(old)
        moveFile(me, old)                  # (a running program may be renamed)
        copyFile(path, me)
        return true
      except OSError, IOError:
        if not fileExists(me) and fileExists(old): moveFile(old, me)
        raise newException(UpdateError, "the program could not be replaced: " & getCurrentExceptionMsg())
    discard openFile(path)
    false
  else:
    let image = getEnv("APPIMAGE")
    if image.len > 0 and ext == ".appimage":
      # (beside the running one, then over it in one step)
      let next = image & ".new"
      try:
        copyFile(path, next)
        setFilePermissions(next, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec,
                                  fpOthersRead, fpOthersExec})
        moveFile(next, image)
        return true
      except OSError, IOError:
        raise newException(UpdateError, "the AppImage could not be replaced: " & getCurrentExceptionMsg())
    discard openFile(path)
    false

proc restartApp*() =
  ## Starts the app again (the new version) and ends this one.
  when defined(wasm):
    discard systemCall("update.reload", "")
  elif defined(android) or defined(ios):
    quit 0
  else:
    let me = if getEnv("APPIMAGE").len > 0: getEnv("APPIMAGE") else: getAppFilename()
    try:
      discard startProcess(me, args = commandLineParams(), options = {poDaemon})
    except OSError: discard
    quit 0

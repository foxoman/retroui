## retroapk -- build (and install) an Android APK from a retro app.
##
## No Gradle, no Java, no Android SDK: the manifest, the resource table,
## the icon, the zip and the signature are written by this program, and
## the small Java activity comes with it already compiled, and the APK is
## signed here too (RSA in plain Nim: no OpenSSL, no apksigner). It needs
## Nim and a C compiler for Android -- found, or fetched:
##
## * Termux on the phone or tablet itself: its clang (installed with `pkg`
##   when missing)
## * a desktop with the Android NDK ($ANDROID_NDK_HOME, the SDK's ndk/)
## * no NDK: any clang with lld (LLVM's installer on Windows, Homebrew's
##   llvm and lld on macOS, the system's on Linux and the BSDs) or zig, with
##   the Android sysroot that retroapk carries inside itself (headers, crt
##   objects, stub libraries, compiler-rt; about 1.2 MB, unpacked once into
##   ~/.retro/android-sysroot; tools/android/mksysroot.sh makes it)
## * none of these: the NDK is downloaded once into ~/.retro/ndk
##   (`--fetch-ndk` does it ahead; `RETRO_NDK_URL` points elsewhere)
##
## Usage:
##   retroapk app.nim [--name:"My App"] [--id:org.me.myapp] [--install]
##
## An app that brings Java of its own -- a service, a receiver, which
## Android starts only from a class its manifest declares -- gives it with
## `--java:DIR`: the folder's classes.dex (compiled ahead with javac and d8;
## examples/retrodns/glue/build-dex.sh) goes in as classes2.dex, and its
## manifest.txt's entries into the manifest. Nim calls the Java by
## reflection (retroui/native).
##
## Run `retroapk --help` for every option.

import std/[os, osproc, strutils, parseopt, algorithm, sequtils, tables]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import retroui/[appicon, androiddex, rsa, zip, codec, buildjobs]
from retroui/sign import jarSign, SignError

const Usage = """
retroapk -- build an Android APK from a retro app

  retroapk app.nim [options]

Options:
  --name:TEXT        app name on the launcher (default: file name)
  --id:PACKAGE       package id, e.g. org.me.myapp (default: org.retro.<file>)
  --version:X.Y      version name (default 1.0); --code:N version code (default 1)
  --icon:FILE.png    launcher icon (default: a drawn 3.1 window)
  --abi:LIST         arm64-v8a (default), x86_64; comma separated (armeabi-v7a
                     and x86, 32-bit, build with the NDK only)
  --orientation:O    any (default), portrait, landscape
  --permission:NAME  add a permission, e.g. INTERNET (repeatable); the ones
                     the app's code needs -- the camera, the microphone,
                     notifications, the place, a buzz, the network -- are
                     added by themselves (said as they are; the app asks
                     the user when the feature is first used)
  --no-auto-permissions  only the --permission ones
  --query:PACKAGE    an app this one needs to see installed (Android 11+;
                     repeatable; --storage adds com.termux)
  --storage          the app works with all the user's files (a file
                     manager): asks for "All files access"
  --java:DIR         the app's own Java: DIR/classes.dex (compiled ahead:
                     javac, then d8 or dx) goes in as classes2.dex, and the
                     entries of DIR/manifest.txt into the manifest (a
                     service, a receiver; the file says how to write them);
                     repeatable
  --manifest:FILE    entries for the manifest, as a manifest.txt is written
  --background       the app checks while it is closed (retroui/bgcheck): its
                     job service, kept across reboots
  --min-sdk:N        lowest Android API level (default 24, Android 7)
  --target-sdk:N     API level the app is made for (default 35)
  --debuggable       allow debugging (run-as, logcat of the app); its library
                     not stripped, a crash's report names the functions,
                     Nim's stack traces on
                     (without it the library in the APK is stripped and a
                     copy with its functions' names is kept beside it, in
                     APP-symbols/ABI/libmain.so: `retrokit symbolize`)
  --cc:PATH          C compiler for Android (default: found, see below)
  --toolchain:T      auto (default), ndk, clang (clang + lld, no NDK) or zig
                     (zig cc, no NDK); also $RETRO_ANDROID_TOOLCHAIN
  --fetch-ndk        download the Android NDK into ~/.retro/ndk now (it is
                     fetched by itself the first time nothing else is found)
  --key:FILE.pem --cert:FILE.der   sign with your own key (default: a
                     debug key made once in ~/.retro/android)
  --signer:S         builtin (default: signed here, nothing needed) or apksigner
  --aab              an Android App Bundle (.aab) for Google Play instead,
                     signed (JAR signature) with --key/--cert: your upload key
  -o:FILE.apk        output (default: <file>.apk, or .aab, next to the source)
  --install          install it (adb, or Termux's package installer)
  --run              start it after installing (adb)
  --nim:FLAG         pass a flag to the Nim compiler (repeatable)
  --verbose          show the commands
  --jobs:N           N C compilers at once (else one a core while the memory
                     lasts, at most 4 in Termux; or $RETRO_JOBS)
  --clean            remove the compiled pieces after (they are kept in the
                     user's cache folder, ~/.cache/retro/apk, for quick rebuilds)
  --work:DIR         keep them in DIR instead

Compilers, in this order: --cc, $RETRO_ANDROID_CC, Termux's clang (installed
with pkg when missing), the NDK in $ANDROID_NDK_HOME / $ANDROID_NDK_ROOT /
$ANDROID_HOME/ndk/* or one fetched before into ~/.retro/ndk; then, with no
NDK, a clang that has lld (on the PATH; LLVM's folder on Windows; Homebrew's
llvm on macOS) or zig (on the PATH, or pip's ziglang) with the Android sysroot
in retroapk (arm64-v8a, x86_64; unpacked once into
~/.retro/android-sysroot, or $RETRO_SYSROOT_DIR); last, the NDK downloaded into
~/.retro/ndk ($RETRO_NDK_URL, $RETRO_NDK_DIR).
"""

var verbose = false

proc permissionsOfCode*(caches: openArray[string]): seq[tuple[name, why: string]] =
  ## The permissions an app's compiled code needs, read from its C files
  ## (Nim writes C only for what the program uses): the camera's views,
  ## recording sound, notifications, the place, a buzz, the network. An app
  ## asks for them when the feature is first used; the manifest must list
  ## them, or Android refuses before asking.
  var files: seq[string]
  for c in caches:
    for f in walkFiles(c / "*.c"): files.add f
  var texts: Table[string, string]
  proc code(module: string): string =
    ## (the C of one of the kit's modules, "" when the app does not use it)
    if module in texts: return texts[module]
    result = ""
    for f in files:
      if f.endsWith("@s" & module & ".nim.c") or f.endsWith("@m" & module & ".nim.c"):
        try: result = readFile(f) except IOError: discard
        break
    texts[module] = result
  proc uses(module: string; procs: openArray[string]): bool =
    let c = code(module)
    if c.len == 0: return false
    for p in procs:
      if (p & "__") in c: return true
    false
  template need(p, why: string) =
    if result.allIt(it.name != p): result.add ("android.permission." & p, why)
  if uses("capture", ["cameraView", "cameraPhoto", "cameraFrame", "cameraRecord"]):
    need("CAMERA", "the camera (retroui/capture)")
  if uses("capture", ["recordSound", "cameraRecord"]):
    need("RECORD_AUDIO", "recording sound (retroui/capture)")
  if uses("notify", ["notify", "notifyAt", "setBadge"]) or uses("system", ["notify"]):
    need("POST_NOTIFICATIONS", "notifications (retroui/notify)")
  if uses("system", ["location"]):
    need("ACCESS_COARSE_LOCATION", "the place (retroui/system's location)")
    need("ACCESS_FINE_LOCATION", "the place, precise (retroui/system's location)")
  if uses("media", ["audioView"]):
    # (a sound plays on with the app in the background: RetroPlayback)
    need("FOREGROUND_SERVICE", "sounds playing on in the background (audioView)")
    need("FOREGROUND_SERVICE_MEDIA_PLAYBACK", "sounds playing on in the background (audioView)")
  if uses("native", ["vibrate"]) or uses("system", ["haptic"]):
    need("VIBRATE", "a buzz (vibrate, haptic)")
  # (the network: every request of the kit goes through http's, a download,
  # chat's connection, or a web view)
  if uses("http", ["httpRequest"]): need("INTERNET", "the network (retroui/http)")
  elif uses("fetch", ["downloadFile"]): need("INTERNET", "downloads (retroui/fetch)")
  elif uses("xmpp", ["xmppStart"]): need("INTERNET", "chat (retroui/xmpp)")
  elif uses("htmlview", ["webView"]): need("INTERNET", "web pages (webView)")
  elif uses("netconn", ["netOpen"]): need("INTERNET", "connections (retroui/netconn: IMAP, SMTP)")
var jobsAsked = 0         # (--jobs: C compilers at once; 0 as the memory allows)
var autoPermissions = true  # (the permissions the code needs, added: --no-auto-permissions leaves them)

proc hashOf(s: string): uint32 =
  ## FNV-1a: a short name for a source path (its own build folder).
  result = 2166136261'u32
  for c in s:
    result = (result xor uint32(ord(c))) * 16777619'u32

proc die(msg: string) {.noreturn.} =
  stderr.writeLine "retroapk: " & msg
  quit 1

proc runShown(cmd: string; what: string) =
  ## (a command whose progress the user sees: a download)
  if verbose: echo "+ ", cmd
  let code = execCmd(cmd)
  if code != 0: die what & " failed (exit code " & $code & ")"

proc run(cmd: string; what: string) =
  if verbose: echo "+ ", cmd
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    stderr.write output
    die what & " failed (exit code " & $code & ")"
  elif verbose and output.strip.len > 0:
    echo output

# ---- bytes ----------------------------------------------------------------------

proc u8(b: var Bytes; v: SomeInteger) = b.add byte(v and 0xFF)
proc u16(b: var Bytes; v: SomeInteger) =
  b.u8(v); b.u8(v shr 8)
proc u32(b: var Bytes; v: SomeInteger) =
  let x = uint32(v)
  for i in 0 .. 3: b.add byte((x shr (8 * i)) and 0xFF)
proc u64(b: var Bytes; v: SomeInteger) =
  let x = uint64(v)
  for i in 0 .. 7: b.add byte((x shr (8 * i)) and 0xFF)
proc add(b: var Bytes; s: string) =
  for c in s: b.add byte(c)
proc put32(b: var Bytes; at: int; v: SomeInteger) =
  let x = uint32(v)
  for i in 0 .. 3: b[at + i] = byte((x shr (8 * i)) and 0xFF)
proc pad4(b: var Bytes) =
  while b.len mod 4 != 0: b.add 0
proc toStr(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

# ---- SHA-256 -------------------------------------------------------------------------

const K256 = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32, 0x3956c25b'u32, 0x59f111f1'u32,
  0x923f82a4'u32, 0xab1c5ed5'u32, 0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32, 0xe49b69c1'u32, 0xefbe4786'u32,
  0x0fc19dc6'u32, 0x240ca1cc'u32, 0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32, 0xc6e00bf3'u32, 0xd5a79147'u32,
  0x06ca6351'u32, 0x14292967'u32, 0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32, 0xa2bfe8a1'u32, 0xa81a664b'u32,
  0xc24b8b70'u32, 0xc76c51a3'u32, 0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32, 0x391c0cb3'u32, 0x4ed8aa4a'u32,
  0x5b9cca4f'u32, 0x682e6ff3'u32, 0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc sha256(parts: varargs[Bytes]): Bytes =
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32, 0x510e527f'u32,
           0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var msg: Bytes
  for p in parts: msg.add p
  let bits = uint64(msg.len) * 8
  msg.add 0x80
  while msg.len mod 64 != 56: msg.add 0
  for i in countdown(7, 0): msg.add byte((bits shr (8 * i)) and 0xFF)
  template rotr(x: uint32; n: int): uint32 = (x shr n) or (x shl (32 - n))
  var w: array[64, uint32]
  for blk in countup(0, msg.len - 1, 64):
    for i in 0 .. 15:
      w[i] = (uint32(msg[blk + 4*i]) shl 24) or (uint32(msg[blk + 4*i + 1]) shl 16) or
             (uint32(msg[blk + 4*i + 2]) shl 8) or uint32(msg[blk + 4*i + 3])
    for i in 16 .. 63:
      let s0 = rotr(w[i-15], 7) xor rotr(w[i-15], 18) xor (w[i-15] shr 3)
      let s1 = rotr(w[i-2], 17) xor rotr(w[i-2], 19) xor (w[i-2] shr 10)
      w[i] = w[i-16] + s0 + w[i-7] + s1
    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
    for i in 0 .. 63:
      let S1 = rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)
      let ch = (e and f) xor ((not e) and g)
      let t1 = hh + S1 + ch + K256[i] + w[i]
      let S0 = rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)
      let maj = (a and b) xor (a and c) xor (b and c)
      let t2 = S0 + maj
      hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh
  for x in h:
    for i in countdown(3, 0): result.add byte((x shr (8 * i)) and 0xFF)

# ---- binary XML (the manifest) --------------------------------------------------------

const
  AndroidNs = "http://schemas.android.com/apk/res/android"
  TString = 0x03'u8
  TRef = 0x01'u8
  TDec = 0x10'u8
  THex = 0x11'u8
  TBool = 0x12'u8
  TDimen = 0x05'u8

proc dp(v: int): int = (v shl 8) or 1     ## a dimension in dp (complex: mantissa, unit 1)

type
  XAttr = object
    android*: bool
    name*: string
    resId*: uint32
    kind*: uint8
    str*: string
    data*: uint32
  XNode = object
    name*: string
    attrs*: seq[XAttr]
    kids*: seq[XNode]

proc sAttr(name: string; id: uint32; v: string): XAttr =
  XAttr(android: true, name: name, resId: id, kind: TString, str: v)
proc iAttr(name: string; id: uint32; v: int; kind = TDec): XAttr =
  XAttr(android: true, name: name, resId: id, kind: kind, data: uint32(v))
proc bAttr(name: string; id: uint32; v: bool): XAttr =
  XAttr(android: true, name: name, resId: id, kind: TBool,
        data: if v: 0xFFFFFFFF'u32 else: 0)

# ---- an app's own manifest entries (--java, --manifest) --------------------------------
#
# manifest.txt: one element a line, its name and then its attributes as
# name=value (no spaces in a value); two more spaces of indent put an element
# inside the one above; # starts a comment. uses-permission, uses-feature,
# permission and queries go in <manifest>, the rest in <application>:
#
#   service android:name=org.me.MyVpn android:permission=android.permission.BIND_VPN_SERVICE android:exported=false
#     intent-filter
#       action android:name=android.net.VpnService

const ManifestAttrIds = [
  ("theme", 0x01010000'u32), ("label", 0x01010001'u32), ("icon", 0x01010002'u32),
  ("name", 0x01010003'u32), ("permission", 0x01010006'u32), ("enabled", 0x0101000e'u32),
  ("exported", 0x01010010'u32), ("process", 0x01010011'u32),
  ("authorities", 0x01010018'u32), ("grantUriPermissions", 0x0101001b'u32),
  ("priority", 0x0101001c'u32), ("description", 0x01010020'u32), ("value", 0x01010024'u32),
  ("resource", 0x01010025'u32), ("maxSdkVersion", 0x01010271'u32),
  ("required", 0x0101028e'u32), ("stopWithTask", 0x0101036a'u32),
  ("directBootAware", 0x01010505'u32), ("foregroundServiceType", 0x01010599'u32)]
  ## (the android: attributes manifest.txt may use, with their resource ids)

const InManifest = ["uses-permission", "uses-feature", "permission", "queries"]
  ## (the entries that go in <manifest>; the rest go in <application>)

proc entryAttr(name, v: string; android: bool): XAttr =
  ## (an attribute of manifest.txt: true and false, @0x references, 0x and
  ## decimal numbers as Android keeps them; the rest as text)
  if not android: return XAttr(name: name, kind: TString, str: v)
  # (its id looked up before anything is made: a result half made when it
  # raises is not freed)
  var id = 0'u32
  for (n, i) in ManifestAttrIds:
    if n == name: id = i
  if id == 0:
    raise newException(ValueError, "android:" & name & " is not an attribute retroapk knows")
  if v == "true" or v == "false": bAttr(name, id, v == "true")
  elif v.startsWith("@0x") and v.len > 3 and v[3 .. ^1].allCharsInSet(HexDigits):
    iAttr(name, id, parseHexInt(v[1 .. ^1]), TRef)
  elif v.startsWith("0x") and v.len > 2 and v[2 .. ^1].allCharsInSet(HexDigits):
    iAttr(name, id, parseHexInt(v), THex)
  elif v.len > 0 and v.len < 10 and v.allCharsInSet(Digits):
    iAttr(name, id, parseInt(v))
  else: sAttr(name, id, v)

proc parseManifestEntries*(text: string): seq[XNode] =
  ## The elements of a manifest.txt, with those inside them. Raises
  ## ValueError for a line it cannot read.
  var stack: seq[(int, XNode)]                    # (indent, element)
  var tops: seq[XNode]
  proc close(downTo: int) =
    while stack.len > 0 and stack[^1][0] >= downTo:
      let (_, n) = stack.pop()
      if stack.len > 0: stack[^1][1].kids.add n
      else: tops.add n
  var n = -1
  for raw in text.splitLines:
    inc n
    let line = raw.strip(leading = false)
    let body = line.strip
    if body.len == 0 or body.startsWith("#"): continue
    let indent = line.len - line.strip(trailing = false).len
    if stack.len == 0 and indent > 0:
      raise newException(ValueError, "line " & $(n + 1) & ": indented with nothing above it")
    close(indent)
    let parts = strutils.splitWhitespace(body)
    var e = XNode(name: parts[0])
    for p in parts[1 .. ^1]:
      let eq = p.find('=')
      if eq <= 0: raise newException(ValueError, "line " & $(n + 1) & ": " & p & " is not name=value")
      var key = p[0 ..< eq]
      let android = key.startsWith("android:")
      if android: key = key[8 .. ^1]
      try: e.attrs.add entryAttr(key, p[eq + 1 .. ^1], android)
      except ValueError as x: raise newException(ValueError, "line " & $(n + 1) & ": " & x.msg)
    stack.add (indent, e)
  close(0)
  tops

proc nameOf(n: XNode): string =
  for a in n.attrs:
    if a.name == "name" and a.kind == TString: return a.str

proc mergeEntries*(manifest: var XNode; entries: openArray[XNode]): int =
  ## Puts `entries` in `manifest` (in <manifest> or its <application>),
  ## leaving out one whose kind and android:name are there already. How many
  ## went in.
  var app = -1
  for i, k in manifest.kids:
    if k.name == "application": app = i
  for e in entries:
    let inRoot = e.name in InManifest or app < 0
    var there = false
    for k in (if inRoot: manifest.kids else: manifest.kids[app].kids):
      if k.name == e.name and nameOf(k) == nameOf(e) and nameOf(e).len > 0: there = true
    if there: continue
    if inRoot and app >= 0:
      manifest.kids.insert(e, app)                # (before <application>)
      inc app
    elif inRoot: manifest.kids.add e
    else: manifest.kids[app].kids.add e
    inc result

proc stringPool(strs: openArray[string]; utf8 = false): Bytes =
  ## A ResStringPool chunk (UTF-16 strings by default).
  var data: Bytes
  var offs: seq[int]
  for s in strs:
    offs.add data.len
    if utf8:
      var n16 = 0
      for r in s.toRunes: n16 += (if int(r) >= 0x10000: 2 else: 1)
      for n in [n16, s.len]:
        if n > 0x7F: data.u8(0x80 or (n shr 8))
        data.u8(n and 0xFF)
      data.add s
      data.add 0
    else:
      let w = newWideCString(s)
      var n = 0
      while int(w[n]) != 0: inc n
      data.u16(n)
      for i in 0 ..< n: data.u16(int(w[i]))
      data.u16(0)
  data.pad4
  let header = 28
  result.u16(0x0001); result.u16(header)
  result.u32(header + 4 * strs.len + data.len)
  result.u32(strs.len); result.u32(0)
  result.u32(if utf8: 0x100 else: 0)
  result.u32(header + 4 * strs.len); result.u32(0)
  for o in offs: result.u32(o)
  result.add data

proc axml(root: XNode): Bytes =
  # The string pool starts with the attribute names that have resource
  # ids, in the order of the resource map.
  var named: seq[(uint32, string)]
  proc collect(n: XNode) =
    for a in n.attrs:
      if a.resId != 0 and (a.resId, a.name) notin named: named.add (a.resId, a.name)
    for k in n.kids: collect(k)
  collect(root)
  named.sort(proc (a, b: (uint32, string)): int = cmp(a[0], b[0]))
  var pool: seq[string]
  for (_, n) in named: pool.add n
  proc idx(s: string; attrName = false; resId = 0'u32): uint32 =
    if attrName and resId != 0:
      for i, (id, n) in named:
        if id == resId: return uint32(i)
    for i in named.len ..< pool.len:
      if pool[i] == s: return uint32(i)
    pool.add s
    uint32(pool.high)
  let nsPrefix = idx("android")
  let nsUri = idx(AndroidNs)
  var body: Bytes
  var line = 1
  proc element(n: XNode) =
    var attrs = n.attrs
    attrs.sort(proc (a, b: XAttr): int =
      if a.resId != 0 and b.resId != 0: cmp(a.resId, b.resId)
      elif a.resId != 0: -1
      elif b.resId != 0: 1
      else: cmp(a.name, b.name))
    let name = idx(n.name)
    body.u16(0x0102); body.u16(16); body.u32(36 + 20 * attrs.len)
    body.u32(line); body.u32(0xFFFFFFFF'u32)
    inc line
    body.u32(0xFFFFFFFF'u32); body.u32(name)
    body.u16(20); body.u16(20); body.u16(attrs.len)
    body.u16(0); body.u16(0); body.u16(0)
    for a in attrs:
      body.u32(if a.android: nsUri else: 0xFFFFFFFF'u32)
      body.u32(idx(a.name, true, a.resId))
      if a.kind == TString:
        let v = idx(a.str)
        body.u32(v); body.u16(8); body.u8(0); body.u8(TString); body.u32(v)
      else:
        body.u32(0xFFFFFFFF'u32); body.u16(8); body.u8(0); body.u8(a.kind)
        body.u32(a.data)
    for k in n.kids: element(k)
    body.u16(0x0103); body.u16(16); body.u32(24)
    body.u32(line); body.u32(0xFFFFFFFF'u32)
    body.u32(0xFFFFFFFF'u32); body.u32(name)
  var nsStart: Bytes
  nsStart.u16(0x0100); nsStart.u16(16); nsStart.u32(24)
  nsStart.u32(0); nsStart.u32(0xFFFFFFFF'u32); nsStart.u32(nsPrefix); nsStart.u32(nsUri)
  element(root)
  var nsEnd: Bytes
  nsEnd.u16(0x0101); nsEnd.u16(16); nsEnd.u32(24)
  nsEnd.u32(line); nsEnd.u32(0xFFFFFFFF'u32); nsEnd.u32(nsPrefix); nsEnd.u32(nsUri)
  var resMap: Bytes
  resMap.u16(0x0180); resMap.u16(8); resMap.u32(8 + 4 * named.len)
  for (id, _) in named: resMap.u32(id)
  let sp = stringPool(pool)
  result.u16(0x0003); result.u16(8)
  result.u32(8 + sp.len + resMap.len + nsStart.len + body.len + nsEnd.len)
  result.add sp
  result.add resMap
  result.add nsStart
  result.add body
  result.add nsEnd

# ---- resources.arsc: one entry, the icon -----------------------------------------------

const IconRes = 0x7f010000'u32
const IconPath = "res/drawable/icon.png"

proc resourceTable(pkg: string): Bytes =
  var p: Bytes                                    # the package chunk
  let typeStrings = stringPool(["drawable"], utf8 = true)
  let keyStrings = stringPool(["icon"], utf8 = true)
  var spec: Bytes
  spec.u16(0x0202); spec.u16(16); spec.u32(20)
  spec.u8(1); spec.u8(0); spec.u16(0); spec.u32(1)
  spec.u32(0)
  var typ: Bytes
  let hdr = 20 + 64
  typ.u16(0x0201); typ.u16(hdr); typ.u32(hdr + 4 + 16)
  typ.u8(1); typ.u8(0); typ.u16(0); typ.u32(1); typ.u32(hdr + 4)
  typ.u32(64)                                     # ResTable_config: any
  for _ in 0 ..< 60: typ.add 0
  typ.u32(0)                                      # offset of entry 0
  typ.u16(8); typ.u16(0); typ.u32(0)              # entry: key "icon"
  typ.u16(8); typ.u8(0); typ.u8(TString); typ.u32(0)
  const header = 288
  p.u16(0x0200); p.u16(header)
  p.u32(header + typeStrings.len + keyStrings.len + spec.len + typ.len)
  p.u32(0x7f)
  let w = newWideCString(pkg)
  var n = 0
  while int(w[n]) != 0 and n < 127:
    p.u16(int(w[n])); inc n
  for _ in n ..< 128: p.u16(0)
  p.u32(header); p.u32(1)
  p.u32(header + typeStrings.len); p.u32(1)
  p.u32(0)
  p.add typeStrings
  p.add keyStrings
  p.add spec
  p.add typ
  let values = stringPool([IconPath], utf8 = true)
  result.u16(0x0002); result.u16(12); result.u32(12 + values.len + p.len)
  result.u32(1)
  result.add values
  result.add p

# ---- an App Bundle's manifest and resources: protocol buffers (aapt2's) ----------------

proc pbVarint(b: var Bytes; v: uint64) =
  var x = v
  while x >= 0x80:
    b.add byte((x and 0x7F) or 0x80)
    x = x shr 7
  b.add byte(x)

proc pbInt(b: var Bytes; field: int; v: uint64) =
  b.pbVarint(uint64(field shl 3))
  b.pbVarint(v)

proc pbBytes(b: var Bytes; field: int; v: Bytes) =
  b.pbVarint(uint64((field shl 3) or 2))
  b.pbVarint(uint64(v.len))
  b.add v

proc pbStr(b: var Bytes; field: int; s: string) = b.pbBytes(field, s.toBytes)

proc protoXml(n: XNode; root = true): Bytes =
  ## A manifest in aapt2's proto XML (an App Bundle's manifest).
  var el: Bytes
  if root:
    var ns: Bytes
    ns.pbStr(1, "android"); ns.pbStr(2, AndroidNs)
    el.pbBytes(1, ns)
  el.pbStr(3, n.name)
  for a in n.attrs:
    var at: Bytes
    if a.android: at.pbStr(1, AndroidNs)
    at.pbStr(2, a.name)
    var item, inner: Bytes
    case a.kind
    of TString:
      at.pbStr(3, a.str)
      if a.android:
        inner.pbStr(1, a.str)
        item.pbBytes(2, inner)                    # String
    of TRef:
      at.pbStr(3, "@0x" & toHex(a.data, 8).toLowerAscii)
      inner.pbInt(2, uint64(a.data))
      item.pbBytes(1, inner)                      # Reference
    of TBool:
      at.pbStr(3, if a.data != 0: "true" else: "false")
      inner.pbInt(8, if a.data != 0: 1 else: 0)
      item.pbBytes(7, inner)                      # Primitive: boolean
    of THex:
      at.pbStr(3, "0x" & toHex(a.data, 8).toLowerAscii)
      inner.pbInt(7, uint64(a.data))
      item.pbBytes(7, inner)
    of TDimen:
      at.pbStr(3, $(a.data shr 8) & "dp")
      inner.pbInt(13, uint64(a.data))
      item.pbBytes(7, inner)
    else:
      at.pbStr(3, $cast[int32](a.data))
      inner.pbInt(6, cast[uint64](int64(cast[int32](a.data))))
      item.pbBytes(7, inner)                      # Primitive: decimal
    if a.resId != 0: at.pbInt(5, uint64(a.resId))
    if item.len > 0: at.pbBytes(6, item)
    el.pbBytes(4, at)
  for k in n.kids: el.pbBytes(5, protoXml(k, false))
  result.pbBytes(1, el)

proc protoResources(pkg: string): Bytes =
  ## resources.pb: the one resource, the icon (as resourceTable).
  var file, item, value, config, entry, typ, package, id: Bytes
  file.pbStr(1, IconPath); file.pbInt(2, 1)         # PNG
  item.pbBytes(5, file)
  value.pbBytes(4, item)
  config.pbBytes(1, @[])                            # (any configuration)
  config.pbBytes(2, value)
  id.pbInt(1, 0)
  entry.pbBytes(1, id); entry.pbStr(2, "icon"); entry.pbBytes(6, config)
  id = @[]; id.pbInt(1, 1)
  typ.pbBytes(1, id); typ.pbStr(2, "drawable"); typ.pbBytes(3, entry)
  id = @[]; id.pbInt(1, 0x7f)
  package.pbBytes(1, id); package.pbStr(2, pkg); package.pbBytes(3, typ)
  result.pbBytes(2, package)

proc bundleConfig(): Bytes =
  ## BundleConfig.pb: the bundletool it is made for, and the native
  ## libraries kept uncompressed in the APKs made of it, on 16 KB pages.
  var tool, opt, uncompressed: Bytes
  tool.pbStr(2, "1.15.6")
  result.pbBytes(1, tool)
  uncompressed.pbInt(1, 1)
  uncompressed.pbInt(2, 2)
  opt.pbBytes(2, uncompressed)
  result.pbBytes(2, opt)

# ---- zip -------------------------------------------------------------------------

type ZipFile = object
  data: Bytes
  central: Bytes
  count: int

proc addFile(z: var ZipFile; name: string; content: Bytes; align = 4;
             compress = true) =
  ## Deflated when that makes it smaller, else stored with its data aligned
  ## to `align` bytes (as zipalign does).
  let offset = z.data.len
  let crc = crc32(content)
  var packed = if compress: deflate(content) else: @[]
  let deflated = compress and packed.len < content.len
  if not deflated: packed = content
  let methodNo = if deflated: 8 else: 0
  var extra = 0
  if align > 1 and not deflated:
    let base = offset + 30 + name.len
    extra = 6
    while (base + extra) mod align != 0: inc extra
  var h: Bytes
  h.u32(0x04034b50); h.u16(if deflated: 20 else: 10); h.u16(0); h.u16(methodNo)
  h.u16(0); h.u16(0x21)                           # 1980-01-01 00:00
  h.u32(crc); h.u32(packed.len); h.u32(content.len)
  h.u16(name.len); h.u16(extra)
  h.add name
  if extra > 0:
    h.u16(0xd935); h.u16(extra - 4); h.u16(align)  # zipalign's own field
    for _ in 6 ..< extra: h.add 0
  z.data.add h
  z.data.add packed
  var c: Bytes
  c.u32(0x02014b50); c.u16(0x031E); c.u16(if deflated: 20 else: 10); c.u16(0)
  c.u16(methodNo); c.u16(0); c.u16(0x21)
  c.u32(crc); c.u32(packed.len); c.u32(content.len)
  c.u16(name.len); c.u16(0); c.u16(0); c.u16(0); c.u16(0)
  c.u32(0o100644 shl 16); c.u32(offset)
  c.add name
  z.central.add c
  inc z.count

proc eocd(z: ZipFile; cdOffset: int): Bytes =
  result.u32(0x06054b50); result.u16(0); result.u16(0)
  result.u16(z.count); result.u16(z.count)
  result.u32(z.central.len); result.u32(cdOffset); result.u16(0)

proc finish(z: ZipFile): Bytes =
  result = z.data
  result.add z.central
  result.add z.eocd(z.data.len)

# ---- APK signature scheme v2 ---------------------------------------------------------

proc lp(b: Bytes): Bytes =
  result.u32(b.len)
  result.add b

proc chunkedDigest(sections: openArray[Bytes]): Bytes =
  const Mb = 1 shl 20
  var digests: Bytes
  var n = 0
  for s in sections:
    var i = 0
    while i < s.len:
      let e = min(s.len, i + Mb)
      var head: Bytes = @[0xa5'u8]
      head.u32(e - i)
      digests.add sha256(head, s[i ..< e])
      inc n
      i = e
  var top: Bytes = @[0x5a'u8]
  top.u32(n)
  sha256(top, digests)

proc signV2(z: ZipFile; keyPem, certDer, work: string): Bytes =
  let entries = z.data
  let cdOffset = entries.len
  let tail = z.eocd(cdOffset)
  let digest = chunkedDigest([entries, z.central, tail])
  const Alg = 0x0103            # RSASSA-PKCS1-v1_5, SHA2-256 chunks
  var digestPair: Bytes
  digestPair.u32(Alg)
  digestPair.add lp(digest)
  let cert = readFile(certDer).toBytes
  var signedData = lp(lp(digestPair))
  signedData.add lp(lp(cert))
  signedData.add lp(@[])
  let key = try: readRsaKey(readFile(keyPem))
            except RsaError as e: die "the key " & keyPem & ": " & e.msg
            except IOError: die "cannot read the key " & keyPem
  var sigPair: Bytes
  sigPair.u32(Alg)
  sigPair.add lp(key.sign(signedData))
  var signer = lp(signedData)
  signer.add lp(lp(sigPair))
  signer.add lp(key.publicKeyDer)
  let value = lp(lp(signer))
  var pairs: Bytes
  pairs.u64(4 + value.len)
  pairs.u32(0x7109871a)
  pairs.add value
  var blk: Bytes
  let size = pairs.len + 8 + 16
  blk.u64(size)
  blk.add pairs
  blk.u64(size)
  blk.add "APK Sig Block 42"
  result = entries
  result.add blk
  result.add z.central
  result.add z.eocd(cdOffset + blk.len)

# ---- checks on the built library --------------------------------------------------------

const SystemLibs = ["libc.so", "libm.so", "libdl.so", "liblog.so", "libandroid.so",
                    "libz.so", "libEGL.so", "libGLESv2.so", "libGLESv3.so",
                    "libvulkan.so", "libjnigraphics.so", "libOpenSLES.so",
                    "libaaudio.so", "libmediandk.so", "libcamera2ndk.so",
                    "libnativewindow.so", "libstdc++.so", "libsync.so"]

proc neededLibs(path: string): seq[string] =
  ## DT_NEEDED entries of a 64- or 32-bit little-endian ELF shared library.
  let f = readFile(path)
  if f.len < 64 or f[0 .. 3] != "\x7fELF": die path & " is not an ELF file"
  let is64 = f[4] == '\x02'
  proc rd(at, n: int): int =
    for i in countdown(n - 1, 0): result = (result shl 8) or ord(f[at + i])
  let phoff = if is64: rd(0x20, 8) else: rd(0x1C, 4)
  let phsize = if is64: rd(0x36, 2) else: rd(0x2A, 2)
  let phnum = if is64: rd(0x38, 2) else: rd(0x2C, 2)
  var loads: seq[(int, int, int)]          # vaddr, offset, filesz
  var dynOff, dynSize = 0
  for i in 0 ..< phnum:
    let p = phoff + i * phsize
    let kind = rd(p, 4)
    let (off, vaddr, filesz) =
      if is64: (rd(p + 8, 8), rd(p + 16, 8), rd(p + 32, 8))
      else: (rd(p + 4, 4), rd(p + 8, 4), rd(p + 16, 4))
    if kind == 1: loads.add (vaddr, off, filesz)
    if kind == 2: (dynOff, dynSize) = (off, filesz)
  proc fileOf(vaddr: int): int =
    for (va, off, sz) in loads:
      if vaddr >= va and vaddr < va + sz: return vaddr - va + off
    -1
  let entSize = if is64: 16 else: 8
  var strtab = -1
  var needed: seq[int]
  var i = dynOff
  while i + entSize <= dynOff + dynSize:
    let tag = if is64: rd(i, 8) else: rd(i, 4)
    let val = if is64: rd(i + 8, 8) else: rd(i + 4, 4)
    if tag == 0: break
    if tag == 1: needed.add val
    if tag == 5: strtab = fileOf(val)
    i += entSize
  if strtab < 0: return
  for n in needed:
    var s = ""
    var k = strtab + n
    while k < f.len and f[k] != '\0':
      s.add f[k]
      inc k
    result.add s

# ---- toolchain ----------------------------------------------------------------------------

type
  Abi = object
    name, cpu, triple: string
    dir: string          ## its folder in a sysroot's usr/lib and usr/include
    rt: string           ## compiler-rt's name for it
    zig: string          ## zig's target (the API level is added: .24)
  Toolchain = object
    cc, ld: string       ## what Nim runs to compile, and to link
    kind: string         ## cc, termux, ndk, clang or zig: each its own nimcache
    what: string         ## (shown when compiling)

const Abis = [
  Abi(name: "arm64-v8a", cpu: "arm64", triple: "aarch64-linux-android",
      dir: "aarch64-linux-android", rt: "aarch64", zig: "aarch64-linux-android"),
  Abi(name: "armeabi-v7a", cpu: "arm", triple: "armv7a-linux-androideabi",
      dir: "arm-linux-androideabi", rt: "arm", zig: "arm-linux-androideabi"),
  Abi(name: "x86_64", cpu: "amd64", triple: "x86_64-linux-android",
      dir: "x86_64-linux-android", rt: "x86_64", zig: "x86_64-linux-android"),
  Abi(name: "x86", cpu: "i386", triple: "i686-linux-android",
      dir: "i686-linux-android", rt: "i686", zig: "x86-linux-android")]

proc inTermux(): bool =
  getEnv("PREFIX").contains("com.termux") or getEnv("TERMUX_VERSION").len > 0

proc ndkRoot(): string =
  for v in ["ANDROID_NDK_HOME", "ANDROID_NDK_ROOT", "ANDROID_NDK", "NDK_HOME"]:
    let d = getEnv(v)
    if d.len > 0 and dirExists(d): return d
  for v in ["ANDROID_HOME", "ANDROID_SDK_ROOT"]:
    let d = getEnv(v) / "ndk"
    if dirExists(d):
      var best = ""
      for kind, p in walkDir(d):
        if kind in {pcDir, pcLinkToDir} and p > best: best = p
      if best.len > 0: return best
  ""

# ---- the NDK, fetched when there is none --------------------------------------------------

const NdkVersion = "r27c"
  ## The NDK fetched (an LTS release)

proc ndkUrl(): string =
  let env = getEnv("RETRO_NDK_URL")
  if env.len > 0: return env
  let host = when defined(windows): "windows" elif defined(macosx): "darwin" else: "linux"
  let ext = when defined(macosx): ".dmg" else: ".zip"
  "https://dl.google.com/android/repository/android-ndk-" & NdkVersion & "-" & host & ext

proc fetchedNdkHome(): string =
  getEnv("RETRO_NDK_DIR", getHomeDir() / ".retro" / "ndk")

proc findNdkIn(dir: string): string =
  ## (an NDK under `dir`: the folder holding toolchains/)
  if dirExists(dir / "toolchains" / "llvm"): return dir
  if not dirExists(dir): return ""
  for kind, p in walkDir(dir):
    if kind in {pcDir, pcLinkToDir} and dirExists(p / "toolchains" / "llvm"): return p
  ""

proc download(url, file: string) =
  ## (with what the system has: curl -- Windows 10, macOS and Linux have it --,
  ## wget, or PowerShell)
  if url.startsWith("file://"):
    try: copyFile(url[7 .. ^1], file)
    except OSError as e: die "cannot copy " & url & ": " & e.msg
    return
  if findExe("curl").len > 0:
    runShown(quoteShellCommand(["curl", "-fL", "--retry", "3", "-o", file, url]), "downloading " & url)
  elif findExe("wget").len > 0:
    runShown(quoteShellCommand(["wget", "-O", file, url]), "downloading " & url)
  elif defined(windows):
    runShown("powershell -NoProfile -Command \"Invoke-WebRequest -Uri '" & url & "' -OutFile '" & file & "'\"",
             "downloading " & url)
  else:
    die "cannot download " & url & ": no curl or wget"

proc unpack(file, dest: string) =
  ## (a zip with the system's unzip or tar, else our own; a .dmg on a Mac)
  if file.toLowerAscii.endsWith(".dmg"):
    let mnt = dest / "mnt"
    createDir(mnt)
    run(quoteShellCommand(["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mnt, file]),
        "opening the NDK disk image")
    try:
      for kind, p in walkDir(mnt):
        if p.endsWith(".app") and dirExists(p / "Contents" / "NDK"):
          run(quoteShellCommand(["cp", "-R", p / "Contents" / "NDK", dest / ("android-ndk-" & NdkVersion)]),
              "copying the NDK")
    finally:
      discard execCmd(quoteShellCommand(["hdiutil", "detach", mnt]))
    return
  if findExe("unzip").len > 0 and not defined(windows):
    run(quoteShellCommand(["unzip", "-q", "-o", file, "-d", dest]), "unpacking the NDK")
  elif findExe("tar").len > 0 and (defined(windows) or defined(macosx)):
    run(quoteShellCommand(["tar", "-xf", file, "-C", dest]), "unpacking the NDK")
  else:
    try: extractZip(file, dest)
    except ZipError as e: die "unpacking the NDK: " & e.msg
    # (our unzip keeps no permissions: the tools made runnable)
    for p in walkDirRec(dest):
      if "/bin/" in p.replace('\\', '/'):
        try: setFilePermissions(p, getFilePermissions(p) + {fpUserExec, fpGroupExec, fpOthersExec})
        except OSError: discard

proc fetchNdk*(): string =
  ## The NDK fetched once into ~/.retro/ndk (or $RETRO_NDK_DIR): its root.
  let base = fetchedNdkHome()
  result = findNdkIn(base)
  if result.len > 0: return
  createDir(base)
  let url = ndkUrl()
  var name = url.extractFilename
  let q = name.find('?')
  if q >= 0: name = name[0 ..< q]
  let file = base / name
  echo "Fetching the Android NDK ", NdkVersion, " (once; about 700 MB) into ", base
  if not fileExists(file): download(url, file)
  echo "Unpacking it..."
  unpack(file, base)
  removeFile(file)
  result = findNdkIn(base)
  if result.len == 0: die "the NDK fetched from " & url & " has no toolchains/ folder"
  echo "The NDK is in ", result

# ---- no NDK: the Android sysroot in retroapk -----------------------------------------
#
# Android's headers, the crt objects, stubs of the system libraries (libc,
# libm, libdl, liblog, libandroid) and LLVM's compiler-rt builtins, for
# arm64-v8a (phones) and x86_64 (the emulator) at API 24: made by
# tools/android/mksysroot.sh from AOSP's and LLVM's sources, carried inside
# retroapk (staticRead) and unpacked once. With it any clang that has lld,
# or zig, builds an app's libmain.so as the NDK's clang does.

const
  SysrootApi = 24
    ## the API level of the sysroot's libraries (the kit's minSdk)
  SysrootAbis = ["arm64-v8a", "x86_64"]
    ## (armeabi-v7a and x86, 32-bit, need the NDK)
  SysrootFile = currentSourcePath().parentDir.parentDir / "tools" / "android" /
                "sysroot.tar.gz"
  SysrootPacked = when fileExists(SysrootFile): staticRead(SysrootFile) else: ""

proc sysrootArchive(): string =
  ## (inside retroapk; else the file, if it is where retroapk was built from)
  if SysrootPacked.len > 0: return SysrootPacked
  try: readFile(SysrootFile) except IOError: ""

proc gunzip(z: string): Bytes =
  ## The content of a gzip file (its one member).
  if z.len < 18 or ord(z[0]) != 0x1f or ord(z[1]) != 0x8b or ord(z[2]) != 8:
    raise newException(ValueError, "not a gzip file")
  let flags = ord(z[3])
  var p = 10
  if (flags and 4) != 0: p += 2 + (ord(z[p]) or (ord(z[p + 1]) shl 8))  # extra
  for bit in [8, 16]:                                                    # name, comment
    if (flags and bit) != 0:
      while p < z.len and z[p] != '\0': inc p
      inc p
  if (flags and 2) != 0: p += 2                                          # header CRC
  var used = 0
  result = inflate(z.toOpenArrayByte(0, z.high), p, addr used)
  let q = p + used
  if q + 8 > z.len: raise newException(ValueError, "the gzip file ends too soon")
  var crc = 0'u32
  for i in 0 .. 3: crc = crc or (uint32(ord(z[q + i])) shl (8 * i))
  if crc32(result) != crc: raise newException(ValueError, "the gzip file is damaged")

proc untar(t: Bytes; dest: string) =
  ## The files and folders of a tar archive (ustar) under `dest`.
  proc field(at, n: int): string =
    for i in at ..< at + n:
      if t[i] == 0: break
      result.add char(t[i])
  var p = 0
  while p + 512 <= t.len:
    let name = field(p, 100)
    if name.len == 0: break                      # the end (zero blocks)
    let prefix = if field(p + 257, 5) == "ustar": field(p + 345, 155) else: ""
    let size = parseOctInt(field(p + 124, 12).strip)
    let kind = char(t[p + 156])
    let target = safeTarget(dest, (if prefix.len > 0: prefix & "/" else: "") & name)
    p += 512
    if size < 0 or p + size > t.len: raise newException(ValueError, "the tar file ends too soon")
    case kind
    of '0', '\0':
      createDir(target.parentDir)
      writeFile(target, t.toOpenArray(p, p + size - 1))
    of '5': createDir(target)
    else: discard                                # (links: the sysroot has none)
    p += (size + 511) div 512 * 512

proc sysrootDir(): string =
  ## The sysroot, unpacked once into ~/.retro/android-sysroot/api24-<crc>
  ## (or into $RETRO_SYSROOT_DIR; a sysroot already there is used as it is).
  ## "" when retroapk carries none.
  let own = getEnv("RETRO_SYSROOT_DIR")
  if own.len > 0 and fileExists(own / "usr" / "include" / "stdio.h"): return own
  let packed = sysrootArchive()
  if packed.len == 0: return ""
  let id = "api" & $SysrootApi & "-" &
           toHex(crc32(packed.toOpenArrayByte(0, packed.high)), 8).toLowerAscii
  result = if own.len > 0: own else: getHomeDir() / ".retro" / "android-sysroot" / id
  if fileExists(result / ".retro-sysroot"): return
  echo "Unpacking the Android sysroot (", packed.len div 1024, " KB: headers and ",
       "libraries, no NDK) into ", result
  # (into a folder of its own, renamed when complete: two builds at once
  # never see half a sysroot)
  let part = if own.len > 0: own else: result & ".part" & $getCurrentProcessId()
  try:
    if part != own: removeDir(part)
    untar(gunzip(packed), part)
    writeFile(part / ".retro-sysroot", id & "\n")
  except CatchableError as e:
    die "unpacking the Android sysroot into " & part & ": " & e.msg
  if part != result:
    try: moveDir(part, result)
    except OSError:
      try: removeDir(part) except OSError: discard
      if not fileExists(result / ".retro-sysroot"): die "cannot make " & result

proc clangCandidates(): seq[tuple[clang, lld: string]] =
  ## Every clang found that has an lld to link with: next to it, on the
  ## PATH, or (macOS) Homebrew's lld. Apple's clang has none.
  var clangs: seq[string]
  proc add(p: string) =
    if p.len > 0 and fileExists(p) and p notin clangs: clangs.add p
  when defined(macosx):
    for d in ["/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"]: add(d / "clang")
  add(findExe("clang"))
  when defined(windows):
    for v in ["ProgramFiles", "ProgramW6432"]:
      if getEnv(v).len > 0: add(getEnv(v) / "LLVM" / "bin" / "clang.exe")
    add(r"C:\Program Files\LLVM\bin\clang.exe")
  for v in countdown(30, 14): add(findExe("clang-" & $v))   # (Debian's clang-18...)
  for c in clangs:
    let name = c.extractFilename.changeFileExt("")
    let ver = if name.startsWith("clang-"): name[5 .. ^1] else: ""
    var llds = @[c.parentDir / "ld.lld" & ExeExt]
    if ver.len > 0: llds.add c.parentDir / "ld.lld" & ver & ExeExt
    llds.add findExe("ld.lld")
    if ver.len > 0: llds.add findExe("ld.lld" & ver)
    when defined(macosx):
      llds.add ["/opt/homebrew/opt/lld/bin/ld.lld", "/usr/local/opt/lld/bin/ld.lld"]
    for l in llds:
      if l.len > 0 and fileExists(l):
        result.add (c, l)
        break

proc findZig(): string =
  ## zig on the PATH, or the one pip installs (pip install ziglang).
  result = findExe("zig")
  if result.len > 0: return
  for py in ["python3", "python", "py"]:
    let exe = findExe(py)
    if exe.len == 0: continue
    let (dir, code) = execCmdEx(quoteShellCommand([exe, "-c",
      "import os, sys, ziglang; sys.stdout.write(os.path.dirname(ziglang.__file__))"]))
    if code == 0 and fileExists(dir.strip / "zig" & ExeExt): result = dir.strip / "zig" & ExeExt; return

proc writeWrapper(path: string; env: openArray[(string, string)];
                  cmd, before, after: openArray[string]): bool =
  ## A script that runs `cmd before... <its own arguments> after...`: Nim
  ## runs one program to compile and one to link (a sh script; a .cmd on
  ## Windows, as the NDK's own). True when it is new or changed.
  var s = ""
  when defined(windows):
    proc q(a: string): string = "\"" & a.replace("%", "%%") & "\""
    s = "@echo off\r\nrem made by retroapk for each build (Android without the NDK)\r\n"
    for (k, v) in env: s.add "set \"" & k & "=" & v.replace("%", "%%") & "\"\r\n"
    for a in cmd: s.add q(a) & " "
    for a in before: s.add q(a) & " "
    s.add "%*"
    for a in after: s.add " " & q(a)
    s.add "\r\nif errorlevel 1 exit /b 1\r\n"
  else:
    proc q(a: string): string = "'" & a.replace("'", "'\\''") & "'"
    s = "#!/bin/sh\n# made by retroapk for each build (Android without the NDK)\n"
    for (k, v) in env: s.add k & "=" & q(v) & "; export " & k & "\n"
    s.add "exec"
    for a in cmd: s.add " " & q(a)
    for a in before: s.add " " & q(a)
    s.add " \"$@\""
    for a in after: s.add " " & q(a)
    s.add "\n"
  if fileExists(path) and readFile(path) == s: return false
  writeFile(path, s)
  when not defined(windows):
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead,
                              fpGroupExec, fpOthersRead, fpOthersExec})
  true

proc probe(t: Toolchain; dir, tag: string; changed: bool): string =
  ## "" when `t` compiles and links a small library for Android, else what
  ## went wrong (tried once for each new set of wrappers).
  let stamp = dir / tag & ".ok"
  if not changed and fileExists(stamp): return ""
  let c = dir / tag & "-probe.c"
  writeFile(c, "#include <stdio.h>\n#include <android/log.h>\n" &
               "int retro_probe(void) {\n  __android_log_print(ANDROID_LOG_INFO, \"retro\", \"probe\");\n" &
               "  return printf(\"%d\", __ANDROID_API__);\n}\n")
  let o = dir / tag & "-probe.o"
  let so = dir / tag & "-probe.so"
  removeFile(stamp)
  for cmd in [quoteShellCommand([t.cc, "-O2", "-c", c, "-o", o]),
              quoteShellCommand([t.ld, "-shared", "-o", so, o])]:
    if verbose: echo "+ ", cmd
    let (output, code) = execCmdEx(cmd)
    if code != 0: return (if output.strip.len > 0: output.strip else: "exit code " & $code)
  writeFile(stamp, "")
  ""

proc firstError(output: string): string =
  ## (the line of a compiler's output that says what is wrong)
  for l in output.splitLines:
    if "error" in l.toLowerAscii: return l.strip
  output.strip.splitLines[^1]

proc noNdkToolchain(abi: Abi; minSdk: int; work, choice: string): Toolchain =
  ## The sysroot in retroapk with a clang that has lld ("clang"), or with
  ## zig ("zig"), or the first of them that works ("auto"); kind "" when
  ## there is none.
  if abi.name notin SysrootAbis or minSdk < SysrootApi: return
  let sys = sysrootDir()
  if sys.len == 0: return
  let api = $max(minSdk, SysrootApi)
  let lib = sys / "usr" / "lib" / abi.dir / $SysrootApi
  let rt = sys / "usr" / "lib" / abi.dir / "libclang_rt.builtins-" & abi.rt & "-android.a"
  let dir = work / "toolchain"
  createDir(dir)
  let ext = when defined(windows): ".cmd" else: ""
  # as the NDK's clang: position-independent; 16 KB pages; the library's
  # own name (DT_SONAME)
  let linking = @["-Wl,-z,max-page-size=16384", "-Wl,-z,noexecstack",
                  "-Wl,-soname,libmain.so", "-L" & lib]
  # Android before 10 (API 29) has no ELF TLS: emulated TLS, also for the
  # code an LTO link makes
  let tls = if parseInt(api) < 29: @["-Wl,-plugin-opt=-emulated-tls"] else: @[]
  if choice in ["auto", "clang"]:
    for (clang, lld) in clangCandidates():
      let target = @["--target=" & abi.triple & api, "--sysroot=" & sys, "-fPIC", "-DANDROID"]
      let useLld = if lld == clang.parentDir / "ld.lld" & ExeExt: "-fuse-ld=lld"
                   else: "--ld-path=" & lld
      let t = Toolchain(cc: dir / abi.name & "-clang-cc" & ext,
                        ld: dir / abi.name & "-clang-ld" & ext, kind: "clang",
                        what: "clang + lld, no NDK: " & clang)
      var changed = writeWrapper(t.cc, [], [clang], target, [])
      # the crt objects, the stubs and compiler-rt as the NDK's clang adds
      # them; nothing of the system the build runs on
      changed = writeWrapper(t.ld, [], [clang],
        target & @[useLld, "-nostdlib"] & linking & tls & @[lib / "crtbegin_so.o"],
        [rt, "-lc", "-lm", "-ldl", "-llog", "-landroid", rt, lib / "crtend_so.o"]) or changed
      let why = probe(t, dir, abi.name & "-clang", changed)
      if why.len == 0: return t
      echo "(", clang, " cannot build for ", abi.name, ": ", firstError(why), ")"
  if choice in ["auto", "zig"]:
    let zig = findZig()
    if zig.len > 0:
      # zig cc reads the sysroot from a "libc paths" file (and adds the crt
      # objects and libc, libm, libdl itself, and its own compiler-rt)
      let libc = dir / abi.name & "-zig-libc.txt"
      let paths = "include_dir=" & sys / "usr" / "include" & "\n" &
                  "sys_include_dir=" & sys / "usr" / "include" / abi.dir & "\n" &
                  "crt_dir=" & lib & "\ngcc_dir=" & lib & "\n" &
                  "msvc_lib_dir=\nkernel32_lib_dir=\ndarwin_sdk_dir=\n"
      var changed = not fileExists(libc) or readFile(libc) != paths
      if changed: writeFile(libc, paths)
      let target = @["-target", abi.zig & "." & api, "-fno-sanitize=all", "-fPIC", "-DANDROID"]
      let t = Toolchain(cc: dir / abi.name & "-zig-cc" & ext,
                        ld: dir / abi.name & "-zig-ld" & ext, kind: "zig",
                        what: "zig cc, no NDK: " & zig)
      let env = [("ZIG_LIBC", libc)]
      # (zig's LTO link makes native TLS whatever it is told: no LTO with
      # zig below API 29, -fno-lto after Nim's -flto)
      let noLto = if tls.len > 0: @["-fno-lto"] else: @[]
      changed = writeWrapper(t.cc, env, [zig, "cc"], target, noLto) or changed
      changed = writeWrapper(t.ld, env, [zig, "cc"], target & linking,
                             noLto & @["-llog", "-landroid"]) or changed
      if changed or not fileExists(dir / abi.name & "-zig.ok"):
        echo "Trying zig for ", abi.name, " (the first time, zig builds its compiler-rt: ",
             "a minute or two)"
      let why = probe(t, dir, abi.name & "-zig", changed)
      if why.len == 0: return t
      echo "(", zig, " cannot build for ", abi.name, ": ", firstError(why), ")"

proc ndkToolchain(ndk: string; abi: Abi; minSdk: int): Toolchain =
  let host = when defined(windows): "windows-x86_64"
             elif defined(macosx): "darwin-x86_64"
             else: "linux-x86_64"
  let bin = ndk / "toolchains" / "llvm" / "prebuilt" / host / "bin"
  let ext = when defined(windows): ".cmd" else: ""
  # the NDK has a wrapper for every API level it supports; take ours, or
  # the lowest one above it
  for api in max(minSdk, 21) .. 40:
    let cc = bin / abi.triple & $api & "-clang" & ext
    if fileExists(cc): return Toolchain(cc: cc, ld: cc, kind: "ndk", what: "NDK " & ndk)
  die "no " & abi.triple & "-clang in " & bin

proc stripTool(tc: Toolchain): string =
  ## (llvm-strip: the NDK's, beside the compiler, on the PATH or LLVM's own
  ## folder; "" when there is none -- the library is then linked stripped
  ## and its names are not kept)
  if tc.kind == "ndk":
    let s = tc.cc.parentDir / "llvm-strip" & ExeExt
    if fileExists(s): return s
  result = findExe("llvm-strip")
  if result.len > 0: return
  for v in countdown(30, 14):
    for dir in ["/usr/lib/llvm-" & $v & "/bin", "/opt/homebrew/opt/llvm/bin", "/usr/local/opt/llvm/bin"]:
      if fileExists(dir / "llvm-strip"):
        result = dir / "llvm-strip"
        return
    result = findExe("llvm-strip-" & $v)
    if result.len > 0: return

proc compilerFor(abi: Abi; minSdk: int; explicit, choice, work: string): Toolchain =
  ## The C compiler for `abi`: --cc, $RETRO_ANDROID_CC, Termux's clang, an
  ## NDK that is there, the sysroot in retroapk with clang + lld or zig,
  ## else the NDK fetched.
  if explicit.len > 0: return Toolchain(cc: explicit, ld: explicit, kind: "cc", what: explicit)
  let env = getEnv("RETRO_ANDROID_CC")
  if env.len > 0: return Toolchain(cc: env, ld: env, kind: "cc", what: env)
  if choice notin ["auto", "ndk", "clang", "zig"]:
    die "unknown toolchain " & choice & " (auto, ndk, clang or zig)"
  if choice == "auto" and inTermux():
    let hostAbi = when defined(arm64): "arm64-v8a"
                  elif defined(arm): "armeabi-v7a"
                  elif defined(amd64): "x86_64"
                  else: "x86"
    if abi.name != hostAbi:
      # (Termux's clang and lld, with the sysroot in retroapk)
      let t = noNdkToolchain(abi, minSdk, work, "auto")
      if t.kind.len > 0: return t
      die "Termux's clang builds for this device only (" & hostAbi &
          "); for " & abi.name & " install lld (pkg install lld) or use the Android NDK"
    var cc = findExe("clang")
    if cc.len == 0 or not dirExists(getEnv("PREFIX") / "lib" / "android"):
      # (Termux: its clang and the NDK's headers, installed here)
      echo "Installing clang and the NDK's headers (pkg install clang ndk-sysroot)..."
      runShown("pkg install -y clang ndk-sysroot", "pkg install")
      cc = findExe("clang")
    if cc.len == 0: die "no clang: pkg install clang ndk-sysroot"
    return Toolchain(cc: cc, ld: cc, kind: "termux", what: "Termux's clang")
  if choice in ["auto", "ndk"]:
    var ndk = ndkRoot()
    if ndk.len == 0: ndk = findNdkIn(fetchedNdkHome())
    if ndk.len > 0: return ndkToolchain(ndk, abi, minSdk)
  if choice != "ndk":
    let t = noNdkToolchain(abi, minSdk, work, choice)
    if t.kind.len > 0: return t
    let why =
      if abi.name notin SysrootAbis: "the sysroot in retroapk has no " & abi.name
      elif minSdk < SysrootApi: "the sysroot in retroapk starts at API " & $SysrootApi &
                                " (--min-sdk:" & $minSdk & ")"
      elif sysrootArchive().len == 0 and getEnv("RETRO_SYSROOT_DIR").len == 0:
        "this retroapk was built without tools/android/sysroot.tar.gz"
      elif choice == "zig": "no zig found (pip install ziglang, or zig on the PATH)"
      elif choice == "clang": "no clang with lld found"
      else: "no clang with lld and no zig found"
    if choice != "auto": die "no NDK-less build for " & abi.name & ": " & why
    echo "No Android NDK found, and ", why, ": fetching the NDK instead.",
         (if why.startsWith("no "): " (To build without it: install clang and lld, " &
                                    "or zig -- see BUILDING.md.)" else: "")
  ndkToolchain(fetchNdk(), abi, minSdk)

# ---- keys -------------------------------------------------------------------------------

proc debugKey(): tuple[key, cert: string] =
  let dir = getEnv("RETRO_KEYS", getHomeDir() / ".retro" / "android")
  result = (dir / "debug-key.pem", dir / "debug-cert.der")
  if fileExists(result.key) and fileExists(result.cert): return
  createDir(dir)
  echo "Making a debug signing key in ", dir
  let key = newRsaKey()
  writeFile(result.key, key.pem)
  writeFile(result.cert, key.selfSignedCert("CN=retro debug, O=retro").toStr)

# ---- main ---------------------------------------------------------------------------------

proc main() =
  var
    src, name, id, outPath, iconPath, cc, keyPem, certDer = ""
    version = "1.0"
    code = 1
    minSdk = 24
    targetSdk = 35
    abiList = @["arm64-v8a"]
    orientation = "any"
    permissions: seq[string]
    queries: seq[string]
    nimFlags: seq[string]
    javaDirs, manifestFiles: seq[string]
    debuggable, install, runIt, storage, background, clean, aab = false
    signer = "auto"
    workDir = ""
    toolchain = getEnv("RETRO_ANDROID_TOOLCHAIN", "auto").toLowerAscii
  for kind, key, val in getopt(commandLineParams()):
    case kind
    of cmdArgument: src = key
    of cmdLongOption, cmdShortOption:
      case key.normalize.replace("-", "")   # (--min-sdk, --fetch-ndk: as minsdk, fetchndk)
      of "name": name = val
      of "id": id = val
      of "version": version = val
      of "code": code = parseInt(val)
      of "icon": iconPath = val
      of "abi": abiList = val.split(',')
      of "orientation": orientation = val.toLowerAscii
      of "permission":
        permissions.add(if '.' in val: val else: "android.permission." & val)
      of "query": queries.add val
      of "storage": storage = true
      of "background": background = true
      of "java": javaDirs.add val
      of "manifest": manifestFiles.add val
      of "minsdk": minSdk = parseInt(val)
      of "targetsdk": targetSdk = parseInt(val)
      of "debuggable": debuggable = true
      of "cc": cc = val
      of "toolchain": toolchain = val.toLowerAscii
      of "key": keyPem = val
      of "cert": certDer = val
      of "signer": signer = val
      of "aab", "bundle": aab = true
      of "o", "out", "output": outPath = val
      of "install": install = true
      of "run": install = true; runIt = true
      of "nim": nimFlags.add val
      of "verbose", "v": verbose = true
      of "jobs": jobsAsked = (try: max(1, parseInt(val)) except ValueError: 0)
      of "noautopermissions": autoPermissions = false
      of "clean": clean = true
      of "work": workDir = val
      of "help", "h": echo Usage; quit 0
      of "fetchndk":
        echo "The NDK: ", fetchNdk()
        quit 0
      else: die "unknown option --" & key & " (see --help)"
    of cmdEnd: discard
  if src.len == 0: (echo Usage; quit 1)
  if not fileExists(src): die "no such file: " & src
  let base = src.splitFile.name
  if name.len == 0: name = base.capitalizeAscii
  if id.len == 0:
    var clean = ""
    for c in base.toLowerAscii:
      if c in {'a'..'z', '0'..'9'}: clean.add c
    id = "org.retro." & (if clean.len > 0 and clean[0] in {'a'..'z'}: clean
                           else: "app" & clean)
  if outPath.len == 0: outPath = src.changeFileExt(if aab: "aab" else: "apk")
  if aab and install:
    die "an App Bundle is for Google Play, not to install; leave out --aab to install an APK"
  # (the compiled pieces: kept for quick rebuilds -- out of the source
  # folder, in the user's cache; --clean removes them after)
  let work = if workDir.len > 0: workDir
             else: getCacheDir("retro") / "apk" / base & "-" & toHex(hashOf(src.absolutePath), 8)
  createDir(work)
  let nim = findExe("nim")
  if nim.len == 0: die "nim is not on the PATH"

  # 1. compile libmain.so for every ABI
  var libs: seq[(string, string)]
  var caches: seq[string]
  var symbolsKept = ""            ## (where the libraries with their names went)
  for an in abiList:
    var abi: Abi
    var found = false
    for a in Abis:
      if a.name == an.strip: (abi = a; found = true)
    if not found: die "unknown ABI " & an
    let tc = compilerFor(abi, minSdk, cc, toolchain, work)
    # (the library is linked with its functions' names, kept beside the
    # package -- <app>-symbols/<abi>/libmain.so, for `retrokit symbolize` --
    # and stripped in it; --debuggable keeps them in it)
    let strip = if debuggable: "" else: stripTool(tc)
    let ltoLink =
      if nimFlags.anyIt(it.toLowerAscii.endsWith(":lto_incremental")): " -flto=thin"
      elif nimFlags.anyIt(it.toLowerAscii.endsWith(":lto")): " -flto"
      else: ""
    let lib = work / "lib" / abi.name / "libmain.so"
    createDir(lib.parentDir)
    echo "Compiling ", src, " for ", abi.name, " (", tc.what, ") ..."
    var args = @[nim, "c", "--os:android", "--cpu:" & abi.cpu, "--app:lib",
                 "--noMain", "-d:noSignalHandler", "-d:release", "--cc:clang",
                 "--clang.exe:" & tc.cc, "--clang.linkerexe:" & tc.ld,
                 # replaces Termux's "-landroid-glob" (an app cannot load
                 # Termux's libraries), strips the library and aligns it for
                 # phones with 16 KB memory pages -- and keeps the -flto that
                 # Nim's -d:lto puts there: without it lld still links the
                 # LTO objects, but with native TLS, which Android before 10
                 # cannot load (emulated TLS below API 29)
                 # (--debuggable: not stripped, its functions' names exported,
                 # so a crash's report names them; Nim's stack traces on)
                 "--clang.options.linker:" & (if debuggable: "-Wl,--export-dynamic"
                                              elif strip.len > 0: "" else: "-s") &
                   " -Wl,-z,max-page-size=16384" & ltoLink,
                 # (a nimcache for each compiler: Nim reuses an object whose
                 # C is unchanged, whatever made it -- zig's LTO objects are
                 # not clang 18's)
                 "--nimcache:" & work / "nimcache-" & abi.name & "-" & tc.kind,
                 # (C compilers at once as the memory allows: in Termux a
                 # build with too many is stopped by Android -- "signal 9")
                 "--parallelBuild:" & $buildJobs(jobsAsked),
                 "--hints:off", "-o:" & lib]
    # (the system's malloc, unless the program asks for Nim's allocator:
    # with it the app's memory would only grow -- see retroui/memwatch)
    if not nimFlags.anyIt("retroNimAlloc" in it): args.add "-d:useMalloc"
    if debuggable: args.add ["--stackTrace:on", "--lineTrace:on"]
    args.add nimFlags
    args.add src
    let cache = work / "nimcache-" & abi.name & "-" & tc.kind
    caches.add cache
    if lastBuildCut(cache): echo cutNote(buildJobs(jobsAsked))
    buildStarted(cache)
    # (linked again, whatever changed: the last build's copy is stripped)
    if strip.len > 0: removeFile(lib)
    run(quoteShellCommand(args), "compiling for " & abi.name)
    buildEnded(cache)
    for n in neededLibs(lib):
      if n notin SystemLibs:
        die abi.name & ": libmain.so needs " & n & ", which is not part of " &
            "Android; an app cannot load it (on Termux, libraries in $PREFIX " &
            "are not visible to apps)"
    if strip.len > 0:
      let keep = outPath.changeFileExt("") & "-symbols" / abi.name
      createDir(keep)
      copyFile(lib, keep / "libmain.so")
      run(quoteShellCommand([strip, "--strip-all", lib]), "stripping the library")
      symbolsKept = outPath.changeFileExt("") & "-symbols"
    libs.add ("lib/" & abi.name & "/libmain.so", lib)
  # (what the code uses asks for its permission when it is first used: the
  # manifest lists them, or Android refuses at once)
  if autoPermissions:
    for (p, why) in permissionsOfCode(caches):
      if p notin permissions:
        permissions.add p
        echo "  ", p.replace("android.permission.", ""), ": ", why

  # 2. manifest, resources, icon
  let orient = case orientation
    of "portrait": 7         # sensorPortrait
    of "landscape": 6        # sensorLandscape
    else: -1
  var activity = XNode(name: "activity", attrs: @[
    sAttr("name", 0x01010003, "org.retro.RetroActivity"),
    sAttr("label", 0x01010001, name),
    # every configuration change is the app's (rotation, size, language,
    # font size, dark mode...): the activity is never recreated
    iAttr("configChanges", 0x0101001f, 0x5000FFFF, THex),
    # one activity, the task's: started again (its icon, an intent, adb's
    # am start) it is brought back as it is -- never a second one beside it,
    # whose start would run the app's again in the same process
    iAttr("launchMode", 0x0101001d, 2),          # singleTask
    iAttr("windowSoftInputMode", 0x0101022b, 0x10, THex),
    # a window the user sizes with the mouse (DeX, desktop windowing,
    # split screen) -- the app follows every size
    bAttr("resizeableActivity", 0x010104f6, true),
    bAttr("exported", 0x01010010, true)],
    kids: @[
      # (a free window's first and smallest sizes)
      XNode(name: "layout", attrs: @[
        iAttr("defaultWidth", 0x010104f4, dp(1280), TDimen),
        iAttr("defaultHeight", 0x010104f5, dp(800), TDimen),
        iAttr("gravity", 0x010100af, 0x11, THex),        # center
        iAttr("minWidth", 0x0101013f, dp(480), TDimen),
        iAttr("minHeight", 0x01010140, dp(360), TDimen)]),
      XNode(name: "meta-data", attrs: @[
        sAttr("name", 0x01010003, "android.app.lib_name"),
        sAttr("value", 0x01010024, "main")]),
      XNode(name: "intent-filter", kids: @[
        XNode(name: "action", attrs: @[
          sAttr("name", 0x01010003, "android.intent.action.MAIN")]),
        XNode(name: "category", attrs: @[
          sAttr("name", 0x01010003, "android.intent.category.LAUNCHER")])])])
  if orient >= 0:
    activity.attrs.add iAttr("screenOrientation", 0x0101001e, orient)
  var app = XNode(name: "application", attrs: @[
    sAttr("label", 0x01010001, name),
    iAttr("icon", 0x01010002, int(IconRes), TRef),
    bAttr("hasCode", 0x0101000c, true),     # classes.dex: RetroActivity
    bAttr("largeHeap", 0x0101035a, true),   # room to decode big photos
    iAttr("theme", 0x01010000, 0x0103012c, TRef)],   # DeviceDefault.Light.NoActionBar
    kids: @[activity,
      # hands files to other apps for "Open" and "Share" (read only)
      XNode(name: "provider", attrs: @[
        sAttr("name", 0x01010003, "org.retro.RetroFiles"),
        sAttr("authorities", 0x01010018, id & ".files"),
        bAttr("exported", 0x01010010, false),
        bAttr("grantUriPermissions", 0x0101001b, true)])])
  if background:
    # the background check: a job only the system may start (JobScheduler);
    # kept across reboots (RECEIVE_BOOT_COMPLETED), with a network
    # (ACCESS_NETWORK_STATE: Android 14+ refuses such a job without it)
    app.kids.add XNode(name: "service", attrs: @[
      sAttr("name", 0x01010003, "org.retro.RetroBackground"),
      sAttr("permission", 0x01010006, "android.permission.BIND_JOB_SERVICE"),
      bAttr("exported", 0x01010010, true)])
    for p in ["android.permission.RECEIVE_BOOT_COMPLETED",
              "android.permission.ACCESS_NETWORK_STATE"]:
      if p notin permissions: permissions.add p
  if "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK" in permissions:
    # a sound playing on in the background (audioView): a foreground
    # service of the media playback kind while it plays
    app.kids.add XNode(name: "service", attrs: @[
      sAttr("name", 0x01010003, "org.retro.RetroPlayback"),
      iAttr("foregroundServiceType", 0x01010599, 2, THex),     # mediaPlayback
      bAttr("exported", 0x01010010, false)])
  if debuggable: app.attrs.add bAttr("debuggable", 0x0101000f, true)
  var manifest = XNode(name: "manifest", attrs: @[
    XAttr(name: "package", kind: TString, str: id),
    iAttr("versionCode", 0x0101021b, code),
    sAttr("versionName", 0x0101021c, version)],
    kids: @[XNode(name: "uses-sdk", attrs: @[
      iAttr("minSdkVersion", 0x0101020c, minSdk),
      iAttr("targetSdkVersion", 0x01010270, targetSdk)])])
  if storage:
    # all files: the settings switch on Android 11+, the dialog before
    manifest.kids.add XNode(name: "uses-permission", attrs: @[
      sAttr("name", 0x01010003, "android.permission.READ_EXTERNAL_STORAGE"),
      iAttr("maxSdkVersion", 0x01010271, 32)])
    manifest.kids.add XNode(name: "uses-permission", attrs: @[
      sAttr("name", 0x01010003, "android.permission.WRITE_EXTERNAL_STORAGE"),
      iAttr("maxSdkVersion", 0x01010271, 29)])
    permissions.add "android.permission.MANAGE_EXTERNAL_STORAGE"
    if "com.termux" notin queries: queries.add "com.termux"   # its files, through SAF
  for p in permissions:
    manifest.kids.add XNode(name: "uses-permission",
                            attrs: @[sAttr("name", 0x01010003, p)])
  # (a permission implies the hardware: not required, so the app installs
  # on a device without a camera, a microphone, GPS -- it asks and goes on)
  var features: seq[string]
  for p in permissions:
    case p.replace("android.permission.", "")
    of "CAMERA": features.add ["android.hardware.camera", "android.hardware.camera.autofocus"]
    of "RECORD_AUDIO": features.add "android.hardware.microphone"
    of "ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION":
      features.add ["android.hardware.location", "android.hardware.location.gps",
                    "android.hardware.location.network"]
    else: discard
  for f in features.deduplicate:
    manifest.kids.add XNode(name: "uses-feature", attrs: @[sAttr("name", 0x01010003, f),
                                                           bAttr("required", 0x0101028e, false)])
  if queries.len > 0:
    var q = XNode(name: "queries")
    for pkg in queries:
      q.kids.add XNode(name: "package", attrs: @[sAttr("name", 0x01010003, pkg)])
    manifest.kids.add q
  manifest.kids.add app
  # the app's own Java (--java) and manifest entries (--java, --manifest)
  var dexes: seq[string]                    ## (classes2.dex, classes3.dex...)
  for d in javaDirs:
    if not dirExists(d): die "--java:" & d & " is not a folder"
    let dexPath = d / "classes.dex"
    if fileExists(dexPath):
      let dex = readFile(dexPath)
      if not dex.startsWith("dex\n"): die dexPath & " is not a dex file"
      dexes.add dex
    if fileExists(d / "manifest.txt"): manifestFiles.add d / "manifest.txt"
    elif not fileExists(dexPath): die "--java:" & d & " has no classes.dex and no manifest.txt"
  for f in manifestFiles:
    let text = try: readFile(f) except IOError: die "cannot read " & f
    let entries = try: parseManifestEntries(text)
                  except ValueError as e: die f & ": " & e.msg
    let n = manifest.mergeEntries(entries)
    echo "  ", f, ": ", n, " manifest entr", (if n == 1: "y" else: "ies")
  let icon = if iconPath.len > 0: readFile(iconPath).toBytes else: iconPng(192)
  if icon.len < 8 or icon[1] != byte('P') or icon[2] != byte('N'):
    die "the icon must be a PNG file"

  if aab:
    # 3. the bundle: Google Play makes the APKs of it (bundletool's layout,
    # aapt2's proto formats), signed here with the upload key
    if keyPem.len == 0:
      (keyPem, certDer) = debugKey()
      echo "Signing with the debug key: Google Play wants your upload key (--key, --cert)"
    let key = try: readRsaKey(readFile(keyPem))
              except RsaError as e: die "the key " & keyPem & ": " & e.msg
              except IOError: die "cannot read the key " & keyPem
    let cert = try: readFile(certDer).toBytes
               except IOError: die "cannot read the certificate " & certDer
    var files = @[("BundleConfig.pb", bundleConfig().toStr),
                  ("base/manifest/AndroidManifest.xml", protoXml(manifest).toStr),
                  ("base/resources.pb", protoResources(id).toStr),
                  ("base/dex/classes.dex", classesDex)]
    for i, dex in dexes: files.add ("base/dex/classes" & $(i + 2) & ".dex", dex)
    files.add ("base/" & IconPath, icon.toStr)
    for (inZip, path) in libs: files.add ("base/" & inZip, readFile(path))
    let meta = try: jarSign(files, key, cert)
               except SignError as e: die "signing the bundle: " & e.msg
    var z: ZipFile
    for (n, data) in meta & files: z.addFile(n, data.toBytes, 1)
    writeFile(outPath, z.finish.toStr)
    echo "Built ", outPath, " (", getFileSize(outPath) div 1024, " KB, ", id, ", for Google Play)"
    if symbolsKept.len > 0:
      echo "  its functions' names: ", symbolsKept, " (retrokit symbolize report.txt ", symbolsKept, ")"
    if clean:
      try: removeDir(work) except OSError: discard
    return

  # 3. the zip; Android unpacks the (deflated) libraries when installing
  var z: ZipFile
  z.addFile("AndroidManifest.xml", axml(manifest))
  z.addFile("classes.dex", classesDex.toBytes)
  for i, dex in dexes: z.addFile("classes" & $(i + 2) & ".dex", dex.toBytes)
  z.addFile("resources.arsc", resourceTable(id), compress = false)  # Android 11+
  z.addFile(IconPath, icon, compress = false)
  for (inZip, path) in libs: z.addFile(inZip, readFile(path).toBytes, 16384)

  # 4. sign
  let unsigned = work / "unsigned.apk"
  writeFile(unsigned, z.finish.toStr)
  if keyPem.len == 0: (keyPem, certDer) = debugKey()
  let apksigner = findExe("apksigner")
  let useApksigner = signer == "apksigner"     # (else signed here: nothing else needed)
  if useApksigner:
    if apksigner.len == 0: die "apksigner is not on the PATH"
    let pk8 = work / "key.pk8"
    try: writeFile(pk8, readRsaKey(readFile(keyPem)).pkcs8Der.toStr)
    except RsaError as e: die "the key " & keyPem & ": " & e.msg
    run(quoteShellCommand([apksigner, "sign", "--key", pk8, "--cert", certDer,
                           "--min-sdk-version", $minSdk, "--out", outPath,
                           unsigned]), "apksigner")
    removeFile(pk8)
  else:
    writeFile(outPath, signV2(z, keyPem, certDer, work).toStr)
  echo "Built ", outPath, " (", getFileSize(outPath) div 1024, " KB, ", id, ")"
  if symbolsKept.len > 0:
    echo "  its functions' names: ", symbolsKept, " (retrokit symbolize report.txt ", symbolsKept, ")"
  if clean:
    try: removeDir(work) except OSError: discard

  # 5. install
  if install:
    let adb = findExe("adb")
    if adb.len > 0:
      run(quoteShellCommand([adb, "install", "-r", outPath]), "adb install")
      echo "Installed."
      if runIt:
        run(quoteShellCommand([adb, "shell", "am", "start", "-n",
                               id & "/org.retro.RetroActivity"]), "starting it")
    elif inTermux():
      # Android's package installer asks the user; Termux hands the file over
      let opener = findExe("termux-open")
      if opener.len == 0: die "termux-open is missing (pkg install termux-tools)"
      run(quoteShellCommand([opener, "--view", "--content-type",
                             "application/vnd.android.package-archive",
                             outPath]), "opening the installer")
      echo "Confirm the installation on the screen."
    else:
      die "to install, connect a device and put adb on the PATH"

when isMainModule: main()

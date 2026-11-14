## retrokit -- start, check and build Retro Nim UI apps.
##
##   retrokit new myapp [--kind:hello|form|business|files|charts]
##   retrokit doctor                  what this machine has, what is missing
##   retrokit run app.nim [options]   build (release) and run it
##       --window      on a screen with no window manager (Termux:X11): the
##                     app as a window of its own size, in its 3.1 frame, in
##                     the middle of a desktop, scaled to the screen
##       --scale:N     everything N percent of its normal size (and the window)
##       --size:WxH    the window this many design pixels (to try layouts)
##       --theme:NAME  a built-in theme ("Dark", "OLED Black"...)
##       --touch       as on a touch screen: finger-sized controls, no hover
##       --controls:K  control sizes: touch, desktop or auto
##       --watch       built again and started again on every save, in the
##                     same place (with --window); --live is both
##       other options go to the Nim compiler
##       --web         as a web page: built (`retrokit web`), served on
##                     localhost and opened in the browser (with --watch,
##                     built again on every save and the page reloaded)
##   retrokit small app.nim           the smallest build (optimized for size, stripped)
##   retrokit web app.nim [options]   a web page: WebAssembly made by clang
##                                    alone (no Emscripten), installable
##                                    and working offline (see retroweb)
##   retrokit apk app.nim [options]   an Android APK (the retroapk tool)
##   retrokit aab app.nim [options]   an Android App Bundle for Google Play
##   retrokit sign PROGRAM.exe        Windows' Authenticode signature, made here
##   retrokit msix PROGRAM.exe        an MSIX for the Microsoft Store, signed
##   retrokit mac PROGRAM             a macOS .app: signed ad hoc here, or with
##                                    your Developer ID, notarized and stapled
##                                    on a Mac; zipped
##   retrokit update-key              a key for updates inside apps
##   retrokit update-sign update.json the update file signed (retroui/update)
##   retrokit linux PROGRAM           Linux packages: .deb, .rpm, a .tar.gz with
##                                    install.sh (no administrator), a PKGBUILD
##   retrokit ipa APP.app             an iOS .ipa for TestFlight and the App Store
##   retrokit model FILE              a 3D model (.blend, .gltf, .obj, .stl) as .glb
##   retrokit designer [app.nim]      Retro Designer: the app's windows, designed
##                                    (built once for this machine, then run)
##   retrokit symbolize REPORT [SYMBOLS]  a crash report's frames named
##   retrokit drive PORT COMMAND...   an app started with RETRO_DRIVE=PORT,
##                                    driven: click, type, key, wait, tree
##
## No dependencies but Nim and a C compiler.

import std/[os, osproc, strutils, sequtils, times, hashes]
when not defined(windows):
  import std/dynlib
import retroweb, retrostore
import retroui/[buildjobs, symbolize, driveclient, uistrings]
import std/json

const usage = """
retrokit -- start, check and build Retro Nim UI apps

  retrokit new NAME [--kind:hello|form|business|files|charts]
      a folder NAME with NAME.nim, NAME.nimble (tasks: run, small, apk)
      and an icon
  retrokit strings APP.nim [--lang:LL] [--out:FILE]
      the app's texts -- its labels, buttons, menus, titles, tr and trn --
      into APP-LL.txt for a translator ("English = translation" a line;
      what is translated there is kept); setUiLanguage("LL",
      loadUiStrings("APP-LL.txt")) shows the app in that language
  retrokit doctor
      checks Nim, the C compiler, the screen libraries and the Android tools
      (clang + lld or zig: APKs without the NDK)
  retrokit run APP.nim [options]
      build it (release) and run it; options:
        --window      on a screen with no window manager (Termux:X11): the
                      app as a window of its own size, in its 3.1 frame, in
                      the middle of a desktop, scaled to the screen
        --scale:N     everything N percent of its normal size (the window too)
        --size:WxH    the window W x H design pixels, to try layouts
        --theme:NAME  a built-in theme ("Dark", "OLED Black"...)
        --touch       as on a touch screen: finger-sized controls, no hover
        --controls:K  control sizes only: touch, desktop or auto
        --watch       on every save of a .nim file in the app's folder, built
                      again and started again where the window was; the old
                      one runs on while the code does not build
        --live        --window and --watch together
        --web         as a web page, served on localhost and opened in the
                      browser (with --watch: built again on every save, the
                      page reloading itself)
      anything else goes to the Nim compiler (-d:..., --opt:...)
  retrokit small APP.nim       the smallest build: optimized for size, stripped
  retrokit web APP.nim [options]
      the app as a web page in build/web (index.html, app.wasm, retro.js,
      the manifest, icons and a service worker: installable, offline):
      WebAssembly from clang and wasm-ld alone, no Emscripten. Options:
        --out:DIR  --files:DIR (the app's files, in /app)  --icon:FILE.png
        --name:TEXT  --small  --debug
        --threads[:N]  a second build with threads, taken where the browser
                       allows them (Web Workers on one memory)
        --threads-only with threads alone (an app that needs them)
        --jobs:N       N C compilers at once (else as the memory allows; at
                       most 4 in Termux, where Android stops builds with
                       too many: "signal 9")
        --lto:K        full, thin (much less memory: Termux's default) or none
  retrokit apk APP.nim [...]   an Android APK (same options as retroapk)
  retrokit aab APP.nim [...]   an Android App Bundle (.aab) for Google Play,
      signed with your upload key (--key, --cert)
  retrokit sign PROGRAM.exe [--key:K.pem --cert:C.pem] [--name:TEXT]
      Windows' Authenticode signature (SHA-256), made here on any system
  retrokit msix PROGRAM.exe [--name:Company.App --version:1.0.0.0 --icon:F.png]
      an MSIX for the Microsoft Store and Windows' installer, signed
  retrokit mac PROGRAM [--name --id --version --icon] [--sign:ID --notarize:P]
      a macOS .app, zipped: signed ad hoc here (any system), or on a Mac with
      your Developer ID, notarized and stapled
  retrokit linux PROGRAM [--name --id --version --icon --summary --depends]
      Linux packages, made here: .deb, .rpm, a .tar.gz with install.sh (for
      the user alone, no administrator) and Arch's PKGBUILD
  retrokit ipa APP.app         an iOS app (built by retroios) as an .ipa
  retrokit model FILE          a 3D model (.blend through Blender, .gltf, .obj, .stl)
      as the .glb an app carries; says its parts and clips by name
  retrokit update-key          a key for updates inside apps (retroui/update):
      update-key.secret (yours alone), the public key printed for the app
  retrokit update-sign update.json [--key:update-key.secret]
      the update file's sizes and SHA-256s filled in, signed (update.json.sig)
  (each with --help for all its options)
  retrokit designer [APP.nim] [--rebuild]
      Retro Designer: the file's windows drawn with the real controls, to
      design by dragging and setting properties; every change written into
      the same file. Built once for this machine (it needs Nim's compiler
      sources: a normal Nim has them; else `nimble install compiler`)
  retrokit symbolize REPORT.txt [SYMBOLS]
      an app's crash report (the "stopped" screen's Copy, or Android's
      logcat) with each frame in its library named: SYMBOLS is the folder
      retroapk kept beside the APK (APP-symbols), or a libmain.so with its
      names; without it, the APP-symbols folders here and in build/
  retrokit drive PORT COMMAND [ARGS] [--role R] [--nth N] [--json]
      an app started with RETRO_DRIVE=PORT, driven as a person would, by its
      controls' names (as the inspector, F12, shows them):
        tree | info | find NAME | focused NAME (it has the focus)
        click NAME (or X,Y; --right, --double, --finger, --hold MS)
        press NAME | focus NAME | set NAME VALUE | move NAME
        scroll NAME LINES | key ctrl+s | type TEXT | quit
        wait MS | wait --frames N | wait NAME [--gone] [--timeout MS]
      each answered once the app has done it; exit 1 when it could not.
      `retrokit drive PORT -` takes one command a line from stdin (words or
      JSON), stopping at the first that fails
"""

const templates = [
  ("hello", """import retroui

var name = "World"
var greeted = ""

app "$1", 360, 160:
  row([50, -1]):
    label "&Name:"
    edit name
  row:
    if button("&Greet", isDefault = true):
      greeted = "Hello, " & name & "!"
    if button("E&xit"): quitApp()
  label greeted
"""),
  ("form", """import retroui

var name, email, phone = ""
var birthday = today()
var plan = 0
var news = true
var saved = ""

app "$1", 520, 360:
  form 0:
    field "&Name:": edit name
    field "&E-mail:": edit email
    field "&Phone:": maskedEdit(phone, "+### #### ####")
    field "&Birthday:": datePicker birthday
    field "Pl&an:": combo(["Free", "Pro", "Business"], plan)
    field "": checkbox("Send me &news", news)
  row:
    spring()
    if button("&Save", isDefault = true, enabled = name.len > 0):
      saved = "Saved " & name & "."
    if button("Cancel"): quitApp()
  label saved
"""),
  ("business", """import retroui

type Order = object
  customer: string
  amount: float
  paid: bool
  status: string

var orders = @[
  Order(customer: "Al Noor Trading", amount: 1250.5, paid: true, status: "green"),
  Order(customer: "Gulf Print House", amount: 830.0, paid: false, status: "orange"),
  Order(customer: "Sohar Steel", amount: 4200.75, paid: false, status: "red")]
var cols = @[column("Customer", 200), numberColumn("Amount", 100),
             checkColumn("Paid", 50), colorColumn("Status", 60)]
var sel = 0
var pos = 0

app "$1", 640, 420:
  menubar:
    menu "&File":
      if menuItem("E&xit"): quitApp()
  let ev = grid(cols, orders.len, proc (r, c: int): string =
      case c
      of 0: orders[r].customer
      of 1: formatNumber(orders[r].amount)
      of 2: (if orders[r].paid: "1" else: "0")
      else: orders[r].status,
    sel, height = -1, rowHeaders = true,
    footer = proc (c: int): string =
      if c == 0: "Total"
      elif c == 1:
        var t = 0.0
        for o in orders: t += o.amount
        formatNumber(t)
      else: "")
  if ev.toggled: orders[ev.row].paid = ev.text == "1"
  pos = sel
  if recordNav(pos, orders.len) != raNone: sel = pos
  statusbar($orders.len & " orders")
"""),
  ("files", """import std/os
import retroui

var folder = newFolderModel(getHomeDir())
var paneW = 280          # the details pane's width (beside) and height (under)
var paneH = 200

app "$1", 900, 600:
  let pb = pathBar(folder.dir)
  if pb.go.len > 0: folder.open(pb.go)
  sidePane(true, paneW, paneH):
    let ev = fileList(folder, fvIcons)
    if ev.activated:
      if ev.item.isDir: folder.open(ev.item.path)
      else: discard openFile(ev.item.path)
  do:
    discard filePreview(folder)
"""),
  ("charts", """import retroui

let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]

app "$1", 800, 520:
  chart("Sales and costs (thousands)", chCombo, months,
        [series("Sales", [12.0, 15.5, 14.2, 18.9, 21.3, 24.0]),
         lineSeries("Costs", [8.0, 9.1, 9.8, 11.0, 12.4, 13.0])],
        height = -1)
"""),
]

proc nimbleFor(name: string): string =
  "# Package\n\nversion       = \"0.1.0\"\nauthor        = \"You\"\n" &
  "description   = \"" & name & ", made with Retro Nim UI\"\nlicense       = \"MIT\"\n" &
  "bin           = @[\"" & name & "\"]\n\n# Dependencies\n\nrequires \"nim >= 2.0.0\"\n" &
  "requires \"retroui\"\n\n# Tasks\n\n" &
  "task run, \"Build and run\":\n  exec \"nim c -r -d:release " & name & ".nim\"\n\n" &
  "task small, \"The smallest build\":\n  exec \"nim c -d:release -d:useMalloc --opt:size -d:lto --passL:-s " &
  name & ".nim\"\n\n" &
  "task apk, \"An Android APK\":\n  exec \"retroapk " & name & ".nim --name:\\\"" & name &
  "\\\" --icon:icon.png\"\n"

proc tinyIcon(): string =
  ## A 32x32 PNG: a 3.1 window (navy title, gray frame, white inside).
  ## Written without the kit, so the tool stays small.
  proc crc32(s: string): uint32 =
    var c = 0xFFFFFFFF'u32
    for ch in s:
      c = c xor uint32(ord(ch))
      for _ in 0 ..< 8: c = if (c and 1) != 0: (c shr 1) xor 0xEDB88320'u32 else: c shr 1
    not c
  proc be32(v: uint32): string =
    result = newString(4)
    result[0] = char((v shr 24) and 255)
    result[1] = char((v shr 16) and 255)
    result[2] = char((v shr 8) and 255)
    result[3] = char(v and 255)
  proc chunk(kind, data: string): string =
    be32(uint32(data.len)) & kind & data & be32(crc32(kind & data))
  proc adler(s: string): uint32 =
    var a = 1'u32
    var b = 0'u32
    for ch in s:
      a = (a + uint32(ord(ch))) mod 65521
      b = (b + a) mod 65521
    (b shl 16) or a
  var raw = ""
  for y in 0 ..< 32:
    raw.add '\0'
    for x in 0 ..< 32:
      let edge = x == 0 or y == 0 or x == 31 or y == 31
      let (r, g, b) =
        if edge: (0, 0, 0)
        elif y < 8: (0, 0, 128)
        elif x < 2 or x > 29 or y > 29: (192, 192, 192)
        else: (255, 255, 255)
      raw.add char(r)
      raw.add char(g)
      raw.add char(b)
  # stored (uncompressed) deflate blocks
  var z = "\x78\x01"
  var i = 0
  while i < raw.len:
    let n = min(65535, raw.len - i)
    z.add(if i + n >= raw.len: '\1' else: '\0')
    z.add char(n and 255)
    z.add char(n shr 8)
    z.add char((not n) and 255)
    z.add char(((not n) shr 8) and 255)
    z.add raw[i ..< i + n]
    i += n
  z.add be32(adler(raw))
  "\x89PNG\r\n\x1a\n" & chunk("IHDR", be32(32) & be32(32) & "\x08\x02\x00\x00\x00") &
    chunk("IDAT", z) & chunk("IEND", "")

proc newApp(name, kind: string) =
  if name.len == 0 or not name.validIdentifier:
    quit "retrokit: the name must be a Nim identifier (letters, digits, _): " & name
  if dirExists(name): quit "retrokit: " & name & " already exists"
  var body = ""
  for (k, t) in templates:
    if k == kind: body = t.replace("$1", name)
  if body.len == 0:
    quit "retrokit: no kind " & kind & " (hello, form, business, files, charts)"
  createDir(name)
  writeFile(name / name & ".nim", body)
  writeFile(name / name & ".nimble", nimbleFor(name))
  writeFile(name / "icon.png", tinyIcon())
  writeFile(name / "config.nims",
    "# where the retroui package is when it is not installed with nimble:\n" &
    "# switch(\"path\", \"/path/to/retroui/src\")\n" &
    "# (the system's malloc: memory let go of goes back to the system)\n" &
    "switch(\"define\", \"useMalloc\")\n" &
    "when defined(windows): switch(\"app\", \"gui\")\n")
  echo "Made ", name, "/ (", kind, "):"
  echo "  cd ", name, " && nimble run        # build and run"
  echo "  nimble small                         # the smallest build"
  echo "  nimble apk                           # an Android APK"

proc found(cmd: string): string =
  let p = findExe(cmd)
  if p.len > 0: p else: ""

proc sourceRoots(): seq[string]
proc parserBuilds(root: string; why: var string): bool
proc distMissing(root: string): seq[string]

proc stringsCmd(args: seq[string]): int =
  ## retrokit strings APP.nim [--lang:LL] [--out:FILE]: the app's texts into
  ## a strings file for a translator (its translations kept when it is there)
  var app, lang, outFile = ""
  lang = "xx"
  for a in args:
    if a.startsWith("--lang:"): lang = a[7 .. ^1]
    elif a.startsWith("--out:"): outFile = a[6 .. ^1]
    elif app.len == 0: app = a
  if app.len == 0 or not fileExists(app):
    echo "retrokit strings APP.nim [--lang:LL] [--out:FILE]"
    return 2
  if outFile.len == 0: outFile = app.changeFileExt("") & "-" & lang & ".txt"
  let keys = collectUiStrings(appSources(app))
  let kept = loadUiStrings(outFile)
  writeFile(outFile, writeUiStrings(keys, kept, lang))
  var done = 0
  for (k, v) in kept:
    if v.len > 0 and k in keys: inc done
  echo outFile, ": ", keys.len, " texts, ", done, " translated"
  0

proc doctor() =
  var ok = true
  proc line(good: bool; what, detail: string; fix = "") =
    echo (if good: "  ok    " else: "  MISS  "), what, (if detail.len > 0: ": " & detail else: "")
    if not good and fix.len > 0: echo "        -> ", fix
  echo "Retro Nim UI doctor (", hostOS, " ", hostCPU, ")"
  let nimV = try: execProcess("nim --version").splitLines[0] except CatchableError: ""
  line(nimV.len > 0, "Nim", nimV, "install Nim 2.x: https://nim-lang.org/install.html")
  if nimV.len == 0: ok = false
  var cc = ""
  for c in ["gcc", "clang", "cc", "cl"]:
    if found(c).len > 0:
      cc = c
      break
  line(cc.len > 0, "C compiler", cc,
       when defined(windows): "install MinGW-w64 (choosenim installs it) or Visual Studio Build Tools"
       elif defined(macosx): "xcode-select --install"
       else: "install gcc or clang (apt install gcc, pkg install clang in Termux)")
  if cc.len == 0: ok = false
  when defined(linux) or defined(bsd):
    if existsEnv("TERMUX_VERSION") and not existsEnv("DISPLAY"):
      line(false, "screen", "no DISPLAY",
           "start Termux:X11 (or a VNC server) and export DISPLAY=:0; or build an APK")
    for lib in ["libX11.so.6", "libXft.so.2"]:
      let h = loadLib(lib)
      line(h != nil, lib, (if h != nil: "found" else: "not found"),
           "install the X11 client libraries (apt install libx11-6 libxft2)")
      if h != nil: unloadLib(h)
    line(existsEnv("DISPLAY") or existsEnv("WAYLAND_DISPLAY"), "display",
         getEnv("DISPLAY", getEnv("WAYLAND_DISPLAY")),
         "run inside a desktop session (Wayland works through XWayland)")
  # Android: Termux's clang, an NDK, or -- no NDK -- a clang that has lld,
  # or zig, with the sysroot retroapk carries; with none of them retroapk
  # fetches the NDK
  let termuxCC = existsEnv("TERMUX_VERSION") and found("clang").len > 0
  let ndk = getEnv("ANDROID_NDK_HOME", getEnv("ANDROID_NDK_ROOT"))
  let fetched = getEnv("RETRO_NDK_DIR", getHomeDir() / ".retro" / "ndk")
  var have = ""
  if termuxCC: have = "Termux clang"
  elif existsEnv("RETRO_ANDROID_CC"): have = getEnv("RETRO_ANDROID_CC")
  elif ndk.len > 0 and dirExists(ndk): have = "NDK " & ndk
  elif dirExists(fetched):
    for kind, p in walkDir(fetched):
      if kind == pcDir and p.extractFilename.startsWith("android-ndk"): have = "NDK " & p
  # (the same search as retroapk's: clang with ld.lld beside it or on the
  # PATH -- Apple's clang has none --, then zig or pip's ziglang)
  var clangs: seq[string]
  when defined(macosx):
    clangs.add ["/opt/homebrew/opt/llvm/bin/clang", "/usr/local/opt/llvm/bin/clang"]
  clangs.add found("clang")
  when defined(windows):
    clangs.add getEnv("ProgramFiles", r"C:\Program Files") / "LLVM" / "bin" / "clang.exe"
  for v in countdown(30, 14): clangs.add found("clang-" & $v)
  var noNdk = ""
  for c in clangs:
    if c.len == 0 or not fileExists(c): continue
    let ver = c.extractFilename.changeFileExt("").substr(5)    # "-18" of clang-18
    var llds = @[c.parentDir / "ld.lld" & ExeExt, found("ld.lld"), found("ld.lld" & ver)]
    when defined(macosx):
      llds.add ["/opt/homebrew/opt/lld/bin/ld.lld", "/usr/local/opt/lld/bin/ld.lld"]
    if llds.anyIt(it.len > 0 and fileExists(it)):
      noNdk = "clang + lld (no NDK needed): " & c
      break
  if noNdk.len == 0 and found("zig").len > 0: noNdk = "zig (no NDK needed): " & found("zig")
  if noNdk.len == 0:
    for py in ["python3", "python", "py"]:
      if found(py).len > 0 and execCmdEx(quoteShellCommand([found(py), "-c",
                                         "import ziglang"])).exitCode == 0:
        noNdk = "zig from pip's ziglang (no NDK needed)"
        break
  if have.len > 0 or noNdk.len > 0:
    line(true, "Android APKs", (if have.len > 0: have else: noNdk))
  elif existsEnv("TERMUX_VERSION"):
    line(true, "Android APKs", "retroapk installs clang with pkg on first use")
  else:
    line(false, "Android APKs", "no clang with lld, no zig, no NDK",
         (when defined(windows): "winget install LLVM.LLVM (or zig.zig)"
          elif defined(macosx): "brew install llvm lld (or zig)"
          elif defined(bsd): "clang and lld from packages or ports (or zig)"
          else: "install clang and lld (apt install clang lld) or zig") &
         "; without them retroapk fetches the NDK once (about 700 MB; nimble ndk: now)")
  line(true, "APK signing", "built in (no apksigner, no OpenSSL, no Java)")
  line(found("adb").len > 0 or existsEnv("TERMUX_VERSION"), "installing on a device",
       (if found("adb").len > 0: "adb" elif existsEnv("TERMUX_VERSION"): "Termux's installer" else: "no adb"),
       "optional: install adb to put the APK on a phone from here")
  when defined(macosx):
    line(found("xcrun").len > 0, "iOS", "xcrun", "install Xcode for retroios")
  # Retro Designer: Nim's parser, from the compiler's sources
  let roots = sourceRoots()
  var why = ""
  if roots.len == 0:
    line(false, "Retro Designer", "Nim's compiler sources not found",
         "optional: retrokit designer installs them the first time (nimble install compiler)")
  elif parserBuilds(roots[0], why):
    line(true, "Retro Designer", "Nim's compiler sources: " & roots[0])
  elif distMissing(roots[0]).len > 0:
    let what = distMissing(roots[0]).mapIt("dist/" & it).join(" and ")
    line(found("git").len > 0, "Retro Designer",
         "the compiler's sources come without " & what & (if found("git").len > 0:
           ": retrokit designer fetches them with git the first time" else: ""),
         "optional: install git (" & (if existsEnv("TERMUX_VERSION"): "pkg install git" else: "your package manager") &
         "): retrokit designer fetches them with it")
  else:
    line(false, "Retro Designer", "Nim's parser does not build: " & why,
         "optional: nimble install compiler")
  echo(if ok: "Ready to build Retro apps." else: "Fix what is missing above, then run retrokit doctor again.")
  if not ok: quit(1)

proc build(app: string; extra: openArray[string]; run: bool): int =
  if not fileExists(app): quit "retrokit: no file " & app
  var args = @["c", "-d:release", "-d:useMalloc", "--hints:off"]
  # (C compilers at once as the memory allows -- in Termux a build with too
  # many is stopped by Android, "signal 9" -- unless the call says)
  var asked = 0
  for e in extra:
    if e.startsWith("--jobs:"):
      asked = (try: parseInt(e[7 .. ^1]) except ValueError: 0)
  let jobs = buildJobs(asked)
  if not extra.anyIt(it.startsWith("--parallelBuild")): args.add "--parallelBuild:" & $jobs
  for e in extra:
    if not e.startsWith("--jobs:"): args.add e
  if run: args.add "-r"
  args.add app
  # (Nim's own cache for the program: where a build stopped half way shows)
  let cache = getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / "nim" / (app.splitFile.name & "_r")
  if lastBuildCut(cache): echo "retrokit: ", cutNote(jobs)
  echo "nim ", args.join(" ")
  buildStarted(cache)
  let p = startProcess(findExe("nim"), args = args, options = {poParentStreams})
  result = p.waitForExit()
  p.close()
  buildEnded(cache)

# ---- run --watch: built again on every save ------------------------------------------------
#
# The app is built to one of two files in turn (a running program's file
# cannot be written over), the new one is started, and the one before is
# ended once the new one is up: the window is never gone in between, and
# with --window it opens where the last one was ($RETRO_WINDOW_STATE). The
# compiler's cache is the usual one, so only what changed is compiled again.
# Closing the window ends it; an app that crashes is started again with the
# next save.

var watching = false

proc sourcesStamp(dir: string): Hash =
  ## (the sources in the app's folder and two levels below it, and when each
  ## was written: hidden folders, caches and links to folders -- Termux's
  ## ~/storage -- left out, so an app in the home folder is cheap to watch)
  var h: Hash = 0
  var todo = @[(dir, 0)]
  while todo.len > 0:
    let (d, depth) = todo.pop()
    for kind, f in walkDir(d):
      let n = f.extractFilename
      if n.startsWith("."): continue
      case kind
      of pcFile:
        if n.endsWith(".nim") or n.endsWith(".nims") or n == "nim.cfg":
          try: h = h !& hash(f) !& hash(getLastModificationTime(f).toUnixFloat)
          except OSError: discard
      of pcDir:
        if depth < 2 and n notin ["nimcache", "build", "node_modules", "storage"]:
          todo.add (f, depth + 1)
      else: discard
  !$h

proc watchRun(app: string; extra: seq[string]): int =
  let name = app.splitFile.name
  let dir = app.absolutePath.parentDir
  let work = getTempDir() / "retrokit-" & name & "-" & $getCurrentProcessId()
  createDir(work)
  putEnv("RETRO_WINDOW_STATE", work / "window")
  var running: Process = nil
  var slot = 0
  var builds = 0

  proc buildOnce(): string =
    ## The app built again; its file, or "" when it does not build.
    slot = 1 - slot
    let exe = work / (name & $slot & ExeExt)
    var args = @["c", "-d:release", "-d:useMalloc", "--hints:off", "-o:" & exe]
    for e in extra: args.add e
    args.add app
    if builds == 0: echo "nim ", args.join(" ")
    inc builds
    let t0 = epochTime()
    let p = startProcess(findExe("nim"), args = args, options = {poParentStreams})
    let code = p.waitForExit()
    p.close()
    if code != 0: return ""
    echo "retrokit: built in ", formatFloat(epochTime() - t0, ffDecimal, 1), " s"
    exe

  proc start(exe: string) =
    let p = startProcess(exe, workingDir = getCurrentDir(), options = {poParentStreams})
    # (the one before goes once the new one is up: no blank screen between)
    sleep(700)
    if running != nil:
      running.terminate()
      if running.waitForExit(2000) == -1 or running.running: running.kill()
      running.close()
    running = p

  var stamp = sourcesStamp(dir)
  let first = buildOnce()
  if first.len > 0: start(first)
  echo "retrokit: watching ", dir, " -- save to see the change; close the window or Ctrl+C to stop"
  while true:
    sleep(300)
    if running != nil and not running.running:
      let code = running.peekExitCode
      running.close()
      running = nil
      if code == 0:
        removeDir(work)
        return 0                                  # (the window was closed)
      echo "retrokit: the app ended (", code, "); save a fix to start it again"
    let now = sourcesStamp(dir)
    if now != stamp:
      sleep(150)                                  # (an editor may write in steps)
      stamp = sourcesStamp(dir)
      let exe = buildOnce()
      if exe.len > 0: start(exe)
      elif running != nil: echo "retrokit: the window keeps the code before; fix it and save"

# ---- designer: Retro Designer, built for this machine and run ---------------------------------

const RetroVersion = block:
  # (read from the toolkit beside retrokit: one version for both)
  let here = currentSourcePath()
  let core = staticRead(here[0 ..< here.rfind({'/', '\\'})] & "/retroui/core.nim")
  let k = core.find("RetroVersion* = \"")
  if k < 0: "0" else: core[k + 17 ..< core.find('"', k + 17)]

proc designerSource(): string =
  ## Retro Designer's sources: beside retrokit's (in the repository and where
  ## nimble installs Retro Nim UI), else where nimble says retroui is.
  let here = currentSourcePath().parentDir / "retrodesigner" / "retrodesigner.nim"
  if fileExists(here): return here
  try:
    let (o, code) = execCmdEx("nimble path retroui")
    if code == 0:
      for l in o.splitLines:
        let f = l.strip / "retrodesigner" / "retrodesigner.nim"
        if l.strip.len > 0 and fileExists(f): return f
  except OSError: discard
  ""

proc nimVersionNumber(): string =
  ## The version of the Nim that builds ("2.4.1"), "" when it does not say.
  try:
    let l = execCmdEx("nim --version")[0].splitLines[0]
    for w in l.splitWhitespace:
      if w.len > 2 and w[0] in Digits and '.' in w: return w
  except OSError: discard
  ""

proc parserBuilds(root: string; why: var string): bool =
  ## Nim's parser builds from `root` (its `compiler` folder and what that
  ## imports); else `why` has the compiler's first error.
  let dir = getCacheDir("retroui") / "probe"
  try:
    createDir(dir)
    writeFile(dir / "probe.nim",
              "import compiler/[parser, ast, idents, options, lineinfos, llstream, pathutils]\n")
    let (o, code) = execCmdEx(quoteShellCommand([findExe("nim"), "check", "--hints:off",
                                                 "--warnings:off", "--path:" & root,
                                                 dir / "probe.nim"]))
    if code != 0:
      why = ""
      for l in o.splitLines:
        if "Error:" in l:
          why = l.strip
          break
    code == 0
  except OSError, IOError:
    false

proc distImports(root: string): seq[string] =
  ## The folders of Nim's `dist` the compiler's sources import (nimony,
  ## checksums).
  for f in walkDirRec(root / "compiler"):
    if not f.endsWith(".nim"): continue
    let t = try: readFile(f) except IOError: ""
    var k = t.find("../dist/")
    while k >= 0:
      var b = k + 8
      while b < t.len and t[b] in IdentChars: inc b
      let name = t[k + 8 ..< b]
      if name.len > 0 and name notin result: result.add name
      k = t.find("../dist/", b)

proc distMissing(root: string): seq[string] =
  ## The folders of Nim's `dist` the compiler's sources import that are not
  ## beside them.
  for name in distImports(root):
    if not dirExists(root / "dist" / name): result.add name

proc gitRun(args: varargs[string]): bool =
  try: execCmdEx(quoteShellCommand(@[findExe("git")] & @args)).exitCode == 0
  except OSError: false

proc kochOf(ver: string): string =
  ## The koch.nim of Nim `ver` (its release on GitHub, else its branch, else
  ## devel): the commits of `dist` that version pins. "" when it cannot be had.
  let tmp = getCacheDir("retroui") / ".nim-koch"
  let parts = ver.split('.')
  var refs: seq[string]
  if ver.len > 0: refs.add "v" & ver
  if parts.len >= 2: refs.add "version-" & parts[0] & "-" & parts[1]
  refs.add "devel"
  for r in refs:
    removeDir(tmp)
    if gitRun("clone", "-q", "--depth", "1", "--filter=blob:none", "--no-checkout", "--branch", r,
              "https://github.com/nim-lang/Nim", tmp):
      try:
        let (o, code) = execCmdEx(quoteShellCommand([findExe("git"), "-C", tmp, "show",
                                                     "HEAD:koch.nim"]))
        if code == 0:
          result = o
          break
      except OSError: discard
  removeDir(tmp)

proc fetchDist(dest, name, koch: string): bool =
  ## `dist/name` fetched into `dest` with git, at the commit `koch` pins
  ## (`NameStableCommit`), else at its newest.
  var commit = "HEAD"
  let key = name[0].toUpperAscii & name.substr(1) & "StableCommit"
  let k = koch.find(key)
  if k >= 0:
    let a = koch.find('"', k)
    let b = koch.find('"', a + 1)
    if a > 0 and b > a: commit = koch[a + 1 ..< b]
  let d = dest / "dist" / name
  removeDir(d)
  createDir(d)
  result = gitRun("init", "-q", d) and
           gitRun("-C", d, "fetch", "-q", "--depth", "1", "https://github.com/nim-lang/" & name,
                  commit) and
           gitRun("-C", d, "checkout", "-q", "FETCH_HEAD")
  if not result: echo "retrokit: could not fetch ", name, " from github.com/nim-lang/", name

proc completeSources(root: string): string =
  ## A copy of `root`'s compiler sources with the folders of `dist` they
  ## import, in the cache: what the system has of them copied, what it has
  ## not fetched with git at the commits this Nim's version pins (its
  ## koch.nim). Nim 2.4 and later as some systems package it (Termux's) has
  ## the compiler's sources without them, or without some. "" when they
  ## cannot be had.
  let ver = nimVersionNumber()
  let dest = getCacheDir("retroui") / ("nim-" & (if ver.len > 0: ver else: "sources"))
  var why = ""
  if dirExists(dest / "compiler") and parserBuilds(dest, why): return dest
  let wanted = distImports(root)
  if wanted.len == 0: return ""
  let missing = distMissing(root)
  let what = (if missing.len > 0: missing else: wanted).mapIt("dist/" & it).join(" and ")
  if findExe("git").len == 0:
    echo "retrokit: this Nim's compiler sources come without ", what, "; git fetches them:"
    echo "          ", (if existsEnv("TERMUX_VERSION"): "pkg install git"
                        else: "install git"), ", then retrokit designer again"
    return ""
  echo "retrokit: this Nim's compiler sources come without ", what, "; fetching them (once)..."
  try:
    removeDir(dest)
    createDir(dest)
    copyDir(root / "compiler", dest / "compiler")
    for name in wanted:
      if dirExists(root / "dist" / name): copyDir(root / "dist" / name, dest / "dist" / name)
  except OSError, IOError:
    echo "retrokit: could not copy the compiler's sources into ", dest
    return ""
  let koch = kochOf(ver)
  var fetched: seq[string]
  for name in missing:
    if not fetchDist(dest, name, koch): return ""
    fetched.add name
  # (a folder the system has only part of: the file the parser misses names it)
  for round in 0 ..< wanted.len + 1:
    if parserBuilds(dest, why): return dest
    let k = why.find("../dist/")
    if k < 0: break
    var b = k + 8
    while b < why.len and why[b] in IdentChars: inc b
    let name = why[k + 8 ..< b]
    if name.len == 0 or name in fetched: break
    echo "retrokit: its dist/", name, " is not whole; fetching it too..."
    if not fetchDist(dest, name, koch): return ""
    fetched.add name
  echo "retrokit: Nim's parser does not build from the sources fetched: ", why
  ""

proc sourceRoots(): seq[string] =
  ## Where Nim's compiler sources are: beside the `lib` of the Nim that
  ## builds, and nimble's `compiler` package.
  try:
    let (o, code) = execCmdEx("nim dump --hints:off --dump.format:json dummy")
    if code == 0:
      let k = o.find("\"libpath\"")
      if k >= 0:
        let a = o.find('"', k + 10)
        let b = o.find('"', a + 1)
        if a > 0 and b > a:
          let root = o[a + 1 ..< b].replace("\\\\", "\\").parentDir
          if fileExists(root / "compiler" / "parser.nim"): result.add root
  except OSError: discard
  try:
    let (o, code) = execCmdEx("nimble path compiler")
    if code == 0:
      for l in o.splitLines:
        let d = l.strip
        if d.len == 0: continue
        if fileExists(d / "compiler" / "parser.nim"): result.add d
        elif fileExists(d / "parser.nim"): result.add d.parentDir
  except OSError: discard

proc compilerSources(): string =
  ## The folder to put on the path so that `import compiler/parser` finds
  ## Nim's own parser, checked by building it: the Nim that builds (its
  ## `compiler` beside its `lib`), else nimble's `compiler` package -- each
  ## completed with the folders of `dist` it imports when they are not
  ## there; "" when there is none.
  let roots = sourceRoots()
  var why = ""
  for root in roots:
    if parserBuilds(root, why): return root
    if distMissing(root).len > 0:
      let done = completeSources(root)
      if done.len > 0: return done
  if roots.len > 0 and why.len > 0:
    echo "retrokit: Nim's parser does not build from ", roots[0], ": ", why
  ""

proc designer(args: seq[string]): int =
  let src = designerSource()
  if src.len == 0: quit "retrokit: Retro Designer's sources are not here (nimble install retroui)"
  let nimVer = block:
    try: execCmdEx("nim --version")[0].splitLines[0] except OSError: ""
  var h = hash(nimVer & src)
  for f in walkDirRec(src.parentDir.parentDir):    # (its sources and the toolkit's: a
    if f.endsWith(".nim"):                         #  changed file is built again)
      try: h = h !& hash(f) !& hash(getLastModificationTime(f).toUnixFloat)
      except OSError: discard
  let dir = getCacheDir("retroui") / ("designer-" & RetroVersion & "-" & $(!$h and 0xffffff))
  let exe = dir / ("retrodesigner" & ExeExt)
  let rebuild = "--rebuild" in args
  if rebuild or not fileExists(exe):
    # (Nim's parser, which it reads your files with: the compiler's sources)
    var nimSrc = compilerSources()
    if nimSrc.len == 0 and sourceRoots().len == 0:
      echo "retrokit: Retro Designer reads your files with Nim's own parser; this Nim has no"
      echo "          compiler sources, so the `compiler` package is installed (once):"
      echo "          nimble install -y compiler"
      try:
        let p = startProcess(findExe("nimble"), args = ["install", "-y", "compiler"],
                             options = {poParentStreams})
        discard p.waitForExit()
        p.close()
      except OSError: discard
      nimSrc = compilerSources()
    if nimSrc.len == 0:
      quit "retrokit: Retro Designer needs Nim's compiler sources (see above; docs/designer.md)"
    createDir(dir)
    echo "retrokit: building Retro Designer for this machine (once; a minute or two)..."
    var b = @["c", "-d:release", "-d:useMalloc", "--hints:off", "--warnings:off",
              "--path:" & nimSrc, "--path:" & src.parentDir.parentDir, "--nimcache:" & dir / "cache", "-o:" & exe]
    when defined(windows): b.add "--app:gui"
    b.add src
    let p = startProcess(findExe("nim"), args = b, options = {poParentStreams})
    let code = p.waitForExit()
    p.close()
    if code != 0: quit "retrokit: Retro Designer did not build (see above)"
    removeDir(dir / "cache")
  var files: seq[string]
  for a in args:
    if a != "--rebuild": files.add a
  let p = startProcess(exe, args = files, workingDir = getCurrentDir(), options = {poParentStreams})
  result = p.waitForExit()
  p.close()

proc runOptions(args: openArray[string]): seq[string] =
  ## `run`'s own options, put in the environment the app starts with; what
  ## is left goes to the compiler.
  for a in args:
    let (key, value) =
      if a.startsWith("--") and (':' in a or '=' in a):
        let i = a.find({':', '='})
        (a[2 ..< i], a[i + 1 .. ^1])
      else: (a.strip(chars = {'-'}), "")
    case key
    of "window", "w": putEnv("RETRO_WINDOW", "1")
    of "scale":
      try: putEnv("RETRO_SCALE", $clamp(parseInt(value.strip(chars = {'%'})), 50, 300))
      except ValueError: quit "retrokit: --scale wants a percent, like --scale:150"
    of "size":
      if 'x' notin value: quit "retrokit: --size wants a width and a height, like --size:420x840"
      putEnv("RETRO_SIZE", value)
    of "theme": putEnv("RETRO_THEME", value)
    of "touch": putEnv("RETRO_TOUCH", "1")
    of "controls":
      if value.toLowerAscii notin ["touch", "desktop", "auto"]:
        quit "retrokit: --controls wants touch, desktop or auto"
      putEnv("RETRO_CONTROLS", value)
    of "watch": watching = true
    of "live":
      putEnv("RETRO_WINDOW", "1")
      watching = true
    else: result.add a

proc driveCmd(args: seq[string]): int =
  ## `retrokit drive PORT COMMAND...`: one command (or one a line from
  ## stdin, `-`), its answer printed: a node or the tree as lines, or the
  ## JSON with --json.
  if args.len < 2:
    echo usage
    return 2
  let port = try: parseInt(args[0]) except ValueError: -1
  if port notin 1 .. 65535:
    echo "retrokit: not a port: ", args[0]
    return 2
  let raw = "--json" in args
  let words = args[1 .. ^1].filterIt(it != "--json")
  var app: DriveClient
  try: app = driveConnect(port, timeoutMs = 5000, probe = true)   # (through adb forward too)
  except DriveError as e:
    echo "retrokit: ", e.msg
    return 1
  defer: app.close()
  proc one(w: seq[string]): int =
    var req: JsonNode
    try: req = request(w)
    except CatchableError as e:
      echo "retrokit: ", e.msg
      return 2
    var r: JsonNode
    try: r = app.ask(req, timeoutMs = 60000)
    except DriveError as e:
      echo "retrokit: ", e.msg
      return 1
    if raw: echo r
    elif not r{"ok"}.getBool: echo "retrokit: ", r{"error"}.getStr
    elif r.hasKey("nodes"):
      var depth = newSeq[int]()
      for n in r{"nodes"}.getElems:
        let p = n{"parent"}.getInt(-1)
        depth.add(if p >= 0 and p < depth.len: depth[p] + 1 else: 0)
        echo repeat("  ", depth[^1]), describe(n)
    elif r.hasKey("node"): echo describe(r["node"])
    elif r.hasKey("title"):
      echo "\"", r["title"].getStr, "\" ", r["w"].getInt, " x ", r["h"].getInt,
           " (zoom ", r["zoom"].getInt, (if r["rtl"].getBool: ", right to left" else: ""),
           "), ", r["frames"].getInt, " frames"
      if r.hasKey("focused"): echo "focused: ", describe(r["focused"])
    if r{"ok"}.getBool: 0 else: 1
  if words == @["-"]:
    for line in stdin.lines:
      let l = line.strip
      if l.len == 0 or l.startsWith("#"): continue
      let w = if l.startsWith("{"): @[l] else: parseCmdLine(l)
      let code = one(w)
      if code != 0: return code
    0
  else: one(words)

proc main() =
  let args = commandLineParams()
  if args.len == 0 or args[0] in ["-h", "--help", "help"]:
    echo usage
    return
  case args[0]
  of "new":
    var name, kind = ""
    kind = "hello"
    for a in args[1 .. ^1]:
      if a.startsWith("--kind:"): kind = a[7 .. ^1]
      elif name.len == 0: name = a
    newApp(name, kind)
  of "doctor": doctor()
  of "strings": quit stringsCmd(args[1 .. ^1])
  of "web":
    var app = ""
    let o = parseWebOptions(args[1 .. ^1], app)
    if app.len == 0: quit usage
    quit buildWeb(app, o)
  of "run":
    # (the file may come before or after the options)
    if "--web" in args:
      var app = ""
      let o = parseWebOptions(args[1 .. ^1].filterIt(it notin ["--watch", "--live"]), app)
      if app.len == 0: quit usage
      quit runWeb(app, o, "--watch" in args or "--live" in args)
    let rest = runOptions(args[1 .. ^1])
    let app = rest.filterIt(it.endsWith(".nim"))
    if app.len == 0: quit usage
    if not fileExists(app[0]): quit "retrokit: no file " & app[0]
    if watching: quit watchRun(app[0], rest.filterIt(it != app[0]))
    quit build(app[0], rest.filterIt(it != app[0]), true)
  of "small":
    if args.len < 2: quit usage
    let code = build(args[1], @["--opt:size", "-d:lto", "--passL:-s"] & args[2 .. ^1], false)
    let exe = args[1].changeFileExt(ExeExt)
    if code == 0 and fileExists(exe):
      echo exe, ": ", getFileSize(exe) div 1024, " KB"
    quit code
  of "designer":
    quit designer(args[1 .. ^1])
  of "apk", "aab":
    let tool = findExe("retroapk")
    if tool.len == 0: quit "retrokit: retroapk is not installed (nimble install retroui)"
    let more = if args[0] == "aab": @["--aab"] else: @[]
    let p = startProcess(tool, args = args[1 .. ^1] & more, options = {poParentStreams})
    let code = p.waitForExit()
    p.close()
    quit code
  of "sign": quit signCmd(args[1 .. ^1])
  of "msix": quit msixCmd(args[1 .. ^1])
  of "mac": quit macCmd(args[1 .. ^1])
  of "linux": quit linuxCmd(args[1 .. ^1])
  of "ipa": quit ipaCmd(args[1 .. ^1])
  of "model": quit modelCmd(args[1 .. ^1])
  of "update-key": quit updateKeyCmd(args[1 .. ^1])
  of "update-sign": quit updateSignCmd(args[1 .. ^1])
  of "drive": quit driveCmd(args[1 .. ^1])
  of "symbolize":
    if args.len < 2 or not fileExists(args[1]): quit usage
    var syms = if args.len >= 3: args[2] else: ""
    if syms.len == 0:
      for d in walkDirs("*-symbols") : syms = d
      for d in walkDirs("build" / "*-symbols"): (if syms.len == 0: syms = d)
    if syms.len == 0: quit "retrokit: no APP-symbols folder here; give it after the report"
    echo symbolizeReport(readFile(args[1]), syms)
  else:
    quit usage

when isMainModule: main()

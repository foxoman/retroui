## retroweb -- a Retro Nim UI app as a web page: WebAssembly made from Nim's
## C by clang and wasm-ld alone (no Emscripten, no WASI SDK, no other
## tool), with the kit's own C library (`retroui/web/libc`) and page side
## (`retroui/web/retro.js`), both carried inside this program. The page is
## an installable web app (a manifest, icons, a service worker that keeps
## it working offline).
##
##   retroweb app.nim [options]          the page, in build/web
##   retrokit web app.nim [options]      the same
##   retrokit run --web app.nim          built, served, opened in a browser
##
## Options:
##   --out:DIR        where the page goes (build/web)
##   --files:DIR      the app's own files: in /app when it runs, and at
##                    app/... beside the page (`webAppUrl`)
##   --icon:FILE.png  the app's icon (a square PNG; a 3.1 window else)
##   --name:TEXT      the name the browser installs it under
##   --small          optimized for size instead of speed (-Oz)
##   --threads[:N]    threads too: a second build with them (app-threads.wasm)
##                    the page takes where the browser allows them -- the
##                    kit's drawing, pictures and maps on every core, the
##                    app's own `createThread` -- N Web Workers started with
##                    the page (the computer's cores, at most 8, else)
##   --threads-only   with threads alone: no build without them (an app that
##                    cannot do without, Retro Mail); a browser that will not
##                    keep the page apart from other sites gets a message
##   --debug          checks and stack traces kept (slower, bigger)
##   --serve, --watch built and served (and built again on every save)
##   --port:N         served on port N (8765 or the next free one else)
##   --no-open        served without opening the browser
##   anything else goes to the Nim compiler (-d:..., --path:...)
##
## Needs: Nim, and clang with the WebAssembly target and wasm-ld (LLVM's
## lld): `apt install clang lld`, `brew install llvm lld`, LLVM's
## installer on Windows.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, osproc, strutils, hashes, times, asynchttpserver, asyncdispatch, uri, streams]
import retroui/codec

const
  # (joined with "/": read while compiling, on this system, whatever system
  # the tool is built for)
  srcDir = block:
    let p = currentSourcePath()
    p[0 ..< p.rfind({'/', '\\'})]
  webDir = srcDir & "/retroui/web"
  libcSources = ["alloc.c", "string.c", "strconv.c", "printf.c", "stdio.c", "math.c",
                 "sys.c", "threads.c", "more.c", "retrolibc.c"]
  libcHeaders = ["_rl.h", "arpa/inet.h", "assert.h", "ctype.h", "dirent.h", "dlfcn.h",
    "errno.h", "fcntl.h", "grp.h", "iconv.h", "inttypes.h", "limits.h", "locale.h", "malloc.h",
    "math.h", "net/if.h", "netdb.h", "netinet/in.h", "netinet/tcp.h", "poll.h",
    "pthread.h", "pwd.h", "sched.h", "setjmp.h", "signal.h", "spawn.h", "stdio.h",
    "stdlib.h", "string.h", "strings.h", "sys/ioctl.h", "sys/mman.h", "sys/resource.h",
    "sys/select.h", "sys/socket.h", "sys/stat.h", "sys/statvfs.h", "sys/syscall.h",
    "sys/time.h", "sys/types.h", "sys/uio.h", "sys/un.h", "sys/utsname.h", "sys/wait.h",
    "termios.h", "time.h", "unistd.h", "wchar.h"]

const cflags = ["--target=wasm32", "-mbulk-memory", "-mnontrapping-fptoint", "-msign-ext",
                "-mmutable-globals", "-mno-atomics", "-msimd128", "-ffunction-sections",
                "-fdata-sections"]
  ## (SIMD: every browser since 2021 -- Chrome 91, Firefox 89, Safari 16.4;
  ## the drawing's loops and the decoders use it as clang finds them)

const kitFonts = ["FreeSans.ttf.z", "FreeSansBold.ttf.z", "FreeSansOblique.ttf.z",
  "FreeSansBoldOblique.ttf.z", "FreeSerif.ttf.z", "FreeSerifBold.ttf.z", "FreeSerifItalic.ttf.z",
  "FreeSerifBoldItalic.ttf.z", "FreeMono.ttf.z", "FreeMonoBold.ttf.z", "FreeMonoOblique.ttf.z",
  "FreeMonoBoldOblique.ttf.z", "LICENSE-FreeFont.txt"]

proc embedded(): seq[(string, string)] {.compileTime.} =
  for f in libcSources: result.add ("libc" / f, staticRead(webDir & "/libc/" & f))
  for f in libcHeaders: result.add ("libc/include" / f, staticRead(webDir & "/libc/include/" & f))
  result.add ("retro.js", staticRead(webDir & "/retro.js"))
  # (the kit's fonts beside the page: fetched when a face is first used)
  for f in kitFonts: result.add ("kit/fonts/" & f, staticRead(srcDir & "/retroui/fonts/" & f))

const files = embedded()

proc kitHash(): string =
  var h: Hash = 0
  for (n, d) in files: h = h !& hash(n) !& hash(d)
  for f in cflags: h = h !& hash(f)
  toHex(cast[uint32](!$h))

proc cacheDir(): string =
  ## Where the C library is written and compiled once (per version of it).
  result = getEnv("RETROWEB_CACHE")
  if result.len == 0:
    result = (when defined(windows): getEnv("LOCALAPPDATA", getHomeDir())
              else: getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache")) / "retroui" / "web-" & kitHash()

proc say(s: string) = stderr.writeLine "retroweb: ", s

proc clang(): string =
  for name in ["clang", "clang-19", "clang-18", "clang-17", "clang-16"]:
    let p = findExe(name)
    if p.len > 0: return p
  ""

proc run(exe: string; args: openArray[string]; quiet = false): (string, int) =
  try:
    let p = startProcess(exe, args = args, options = {poStdErrToStdOut, poUsePath})
    let outp = p.outputStream.readAll()
    let code = p.waitForExit()
    p.close()
    (outp, code)
  except OSError as e:
    (e.msg, -1)

proc cflagsFor(threads: bool): seq[string] =
  ## (with threads: WebAssembly's atomics, a memory shared by the workers)
  for f in cflags: result.add(if threads and f == "-mno-atomics": "-matomics" else: f)

proc prepare(cc: string; threads = false): string =
  ## The C library, its headers and the empty libraries Nim asks for, in the
  ## cache; the library compiled (once with threads, once without). The
  ## cache folder.
  let dir = cacheDir()
  let obj = dir / (if threads: "retrolibc-threads.o" else: "retrolibc.o")
  if fileExists(obj): return dir
  createDir(dir)
  for (n, d) in files:
    createDir((dir / n).parentDir)
    writeFile(dir / n, d)
  createDir(dir / "lib")
  for l in ["m", "dl", "pthread", "rt"]: writeFile(dir / "lib" / "lib" & l & ".a", "!<arch>\n")
  let (res, _) = run(cc, ["-print-resource-dir"])
  let args = cflagsFor(threads) & @["-O2", "-fno-builtin", "-nostdinc", "-isystem", dir / "libc" / "include",
             "-isystem", res.strip / "include", "-c", dir / "libc" / "retrolibc.c", "-o", obj]
  let (o, code) = run(cc, args)
  if code != 0:
    removeFile(obj)
    say "the C library did not compile:\n" & o
    if "wasm32" in o or "target" in o:
      say "this clang has no WebAssembly target (install clang from LLVM)"
    quit 1
  dir

proc pngIcon(size: int; png: string): string =
  ## A PNG of `size` x `size`: a window of Windows 3.1 (navy title, gray
  ## frame, white inside) -- or the app's own icon.
  if png.len > 0: return png
  proc crc32(s: string): uint32 =
    var c = 0xFFFFFFFF'u32
    for ch in s:
      c = c xor uint32(ord(ch))
      for _ in 0 ..< 8: c = if (c and 1) != 0: (c shr 1) xor 0xEDB88320'u32 else: c shr 1
    not c
  proc be32(v: uint32): string =
    result = newString(4)
    for i in 0 .. 3: result[i] = char((v shr (24 - 8 * i)) and 255)
  proc chunk(kind, data: string): string = be32(uint32(data.len)) & kind & data & be32(crc32(kind & data))
  let k = size / 32
  var raw = newSeqOfCap[byte](size * (size * 3 + 1))
  for y in 0 ..< size:
    raw.add 0
    let yy = int(y.float / k)
    for x in 0 ..< size:
      let xx = int(x.float / k)
      let edge = xx == 0 or yy == 0 or xx == 31 or yy == 31
      let (r, g, b) =
        if edge: (0, 0, 0)
        elif yy < 8: (0, 0, 128)
        elif xx < 2 or xx > 29 or yy > 29: (192, 192, 192)
        else: (255, 255, 255)
      raw.add byte(r)
      raw.add byte(g)
      raw.add byte(b)
  let z = zlibCompress(raw)
  var zs = newString(z.len)
  for i, c in z: zs[i] = char(c)
  "\x89PNG\r\n\x1a\n" & chunk("IHDR", be32(uint32(size)) & be32(uint32(size)) & "\x08\x02\x00\x00\x00") &
    chunk("IDAT", zs) & chunk("IEND", "")

proc gzipOf(data: string): string =
  ## `data` as a gzip file (RFC 1952): what a server hands a browser that
  ## takes gzip (Content-Encoding), a third of the size of WebAssembly.
  let z = deflateLevel(data.toOpenArrayByte(0, data.high), 9)
  result = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff"
  for b in z: result.add char(b)
  let c = crc32(data.toOpenArrayByte(0, data.high))
  let n = uint32(data.len and 0xFFFFFFFF)
  for v in [c, n]:
    for i in 0 .. 3: result.add char((v shr (8 * i)) and 255)

proc jsonStr(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\0' .. '\x09', '\x0b' .. '\x1f': result.add "\\u" & toHex(ord(c), 4)
    else: result.add c
  result.add '"'

proc htmlEsc(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

template mapIt2(s, op: untyped): untyped =
  var r: seq[string]
  for it {.inject.} in s: r.add op(it)
  r

const webThreadsMaxMemory = 1 shl 30
  ## (with threads the memory is made at its largest size up front: 1 GB)

type WebOptions* = object
  outDir*, filesDir*, icon*, name*: string
  small*, debug*, dev*, noOpen*, threadsOnly*: bool
  threads*: int             ## -1: one thread; 0: threads, as many workers as cores; N: N workers
  port*: int                ## (serving it) 0: 8765 or the next free one
  extra*: seq[string]

proc parseWebOptions*(args: openArray[string]; app: var string): WebOptions =
  result.threads = -1
  for a in args:
    let (key, value) =
      if a.startsWith("--") and (':' in a or '=' in a):
        let i = a.find({':', '='})
        (a[2 ..< i], a[i + 1 .. ^1])
      else: (a.strip(leading = true, trailing = false, chars = {'-'}), "")
    case key
    of "out": result.outDir = value
    of "files": result.filesDir = value
    of "icon": result.icon = value
    of "name": result.name = value
    of "small": result.small = true
    of "threads": result.threads = (if value.len == 0: 0 else: (try: max(1, parseInt(value)) except ValueError: 0))
    of "threads-only":
      result.threadsOnly = true
      if result.threads < 0: result.threads = 0
    of "debug": result.debug = true
    of "port": result.port = (try: parseInt(value) except ValueError: 0)
    of "no-open": result.noOpen = true
    of "web": discard
    else:
      if a.endsWith(".nim") and app.len == 0: app = a
      else: result.extra.add a

proc buildWeb*(app: string; o: WebOptions): int =
  ## The page of `app` in `o.outDir` (build/web): index.html, retro.js,
  ## app.wasm, the manifest, the icons, the service worker, app/... .
  if not fileExists(app):
    say "no file " & app
    return 1
  let cc = clang()
  if cc.len == 0:
    say "clang is needed (with wasm-ld: apt install clang lld; brew install llvm lld)"
    return 1
  if findExe("wasm-ld").len == 0 and findExe("wasm-ld-18").len == 0 and
     findExe("wasm-ld-19").len == 0 and findExe("ld.lld").len == 0:
    say "wasm-ld is needed (LLVM's lld: apt install lld; brew install lld)"
    return 1
  let outDir = if o.outDir.len > 0: o.outDir else: app.parentDir / "build" / "web"
  createDir(outDir)
  let (res, _) = run(cc, ["-print-resource-dir"])

  proc compile(threads: bool; wasmName: string): int =
    let kit = prepare(cc, threads)
    var passC = cflagsFor(threads) & @["-nostdinc", "-isystem", kit / "libc" / "include",
                                       "-isystem", res.strip / "include"]
    if not o.debug: passC.add "-flto"
    if o.small: passC.add "-Oz"
    var exports = @["NimMain", "retro_frame", "retro_audio", "malloc", "free"]
    var passL = @["--target=wasm32", "-nostdlib", "-L" & kit / "lib", "-Wl,--no-entry",
                  "-Wl,--gc-sections", "-Wl,-z,stack-size=2097152", "-Wl,--allow-undefined",
                  "-Wl,--initial-memory=33554432"]
    if threads:
      # (one memory for the page and its workers, made by the page; each
      # worker its own stack and thread-local storage)
      passL.add ["-Wl,--shared-memory", "-Wl,--import-memory", "-Wl,--max-memory=" & $webThreadsMaxMemory]
      exports.add ["__stack_pointer", "__wasm_init_tls", "__tls_size", "__tls_align",
                   "retro_thread_entry", "retro_thread_reap"]
    for e in exports: passL.add "-Wl,--export-if-defined=" & e
    if not o.debug:
      # (link-time optimization: the program as one, its unused parts gone;
      # the names section left out -- a release needs no function names)
      passL.add ["-flto", "-Wl,--strip-all", (if o.small: "-Wl,--lto-O2" else: "-Wl,--lto-O3")]
    passL.add kit / (if threads: "retrolibc-threads.o" else: "retrolibc.o")
    var args = @["c", "--cpu:wasm32", "--os:linux", "-d:wasm", "-d:useMalloc",
                 (if threads: "--threads:on" else: "--threads:off"),
                 "--mm:orc", "--noMain", "--cc:clang", "--clang.exe:" & cc, "--clang.linkerexe:" & cc,
                 "--hints:off",
                 # (one for each app and each build: several built at once in one folder)
                 "--nimcache:" & (app.parentDir / "build" / ("web-nimcache-" & app.splitFile.name &
                                                             (if threads: "-threads" else: ""))),
                 "--passC:" & passC.mapIt2(quoteShell).join(" "), "--passL:" & passL.mapIt2(quoteShell).join(" "),
                 "-o:" & (outDir / wasmName)]
    if not o.debug: args.add "-d:release"
    if o.small: args.add "--opt:size"
    args.add o.extra
    args.add app
    say "building " & app & " for the web" & (if threads: " (with threads)" else: "")
    let p = startProcess(findExe("nim"), args = args, options = {poParentStreams})
    result = p.waitForExit()
    p.close()

  if o.threadsOnly:
    removeFile(outDir / "app.wasm")
    removeFile(outDir / "app.wasm.gz")
  else:
    result = compile(false, "app.wasm")
    if result != 0: return
  if o.threads >= 0:
    result = compile(true, "app-threads.wasm")
    if result != 0: return
  else:
    removeFile(outDir / "app-threads.wasm")
    removeFile(outDir / "app-threads.wasm.gz")
  # the page
  let name = if o.name.len > 0: o.name else: app.splitFile.name
  let iconPng = if o.icon.len > 0 and fileExists(o.icon): readFile(o.icon) else: ""
  writeFile(outDir / "icon-192.png", pngIcon(192, iconPng))
  writeFile(outDir / "icon-512.png", pngIcon(512, iconPng))
  var kitList = ""
  for (n, d) in files:
    if n == "retro.js": writeFile(outDir / "retro.js", d)
    elif n.startsWith("kit/"):
      createDir((outDir / n).parentDir)
      writeFile(outDir / n, d)
      kitList.add (if kitList.len > 0: ", " else: "") & "[" & jsonStr(n) & ", " & $d.len & "]"
  var appFiles: seq[string]
  var fileList = ""
  if o.filesDir.len > 0 and dirExists(o.filesDir):
    for f in walkDirRec(o.filesDir, relative = true):
      let rel = f.replace('\\', '/')
      createDir((outDir / "app" / rel).parentDir)
      copyFile(o.filesDir / f, outDir / "app" / rel)
      appFiles.add "app/" & rel
      fileList.add (if fileList.len > 0: ", " else: "") & "[" & jsonStr("app/" & rel) & ", " &
                   $getFileSize(o.filesDir / f) & "]"
  let stamp = $toUnix(getTime())
  writeFile(outDir / "manifest.webmanifest", """{
  "name": $1,
  "short_name": $1,
  "start_url": ".",
  "display": "standalone",
  "background_color": "#c0c0c0",
  "theme_color": "#000080",
  "icons": [
    { "src": "icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "icon-512.png", "sizes": "512x512", "type": "image/png", "purpose": "any maskable" }
  ]
}
""" % jsonStr(name))
  var cached = @["./", "index.html", "retro.js", "manifest.webmanifest", "icon-192.png", "icon-512.png"]
  if not o.threadsOnly: cached.add "app.wasm"
  if o.threads >= 0: cached.add "app-threads.wasm"
  for f in appFiles:
    if getFileSize(outDir / f) <= 1 shl 20: cached.add f
  var cacheList = ""
  for f in cached: cacheList.add (if cacheList.len > 0: ", " else: "") & jsonStr(f)
  writeFile(outDir / "sw.js", """// (written by retroweb) the page kept for working offline: what it is made
// of is taken from the cache, a newer build replaces it; the app's bigger
// files are kept once they were used
const CACHE = "retro-$1-$2";
const FILES = [$3];
self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(FILES)));
  self.skipWaiting();
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((keys) =>
    Promise.all(keys.filter((k) => k.startsWith("retro-") && k !== CACHE).map((k) => caches.delete(k)))));
  self.clients.claim();
});
const ISOLATE = $4;
// (threads: the page kept apart from other sites -- COOP and COEP, which
// is what lets a browser share memory with workers -- whatever the server)
const isolated = (res) => {
  if (!ISOLATE || res.status === 0 || res.type === "opaque") return res;
  const h = new Headers(res.headers);
  h.set("Cross-Origin-Opener-Policy", "same-origin");
  h.set("Cross-Origin-Embedder-Policy", "require-corp");
  h.set("Cross-Origin-Resource-Policy", "same-origin");
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers: h });
};
self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET" || new URL(req.url).origin !== location.origin) return;
  if (req.headers.has("range")) return;
  e.respondWith(caches.match(req).then((r) => r || fetch(req).then((res) => {
    if (res.ok && res.status === 200 && /\/(app|kit)\//.test(new URL(req.url).pathname)) {
      const copy = res.clone();
      caches.open(CACHE).then((c) => c.put(req, copy));
    }
    return res;
  })).then(isolated));
});
""" % [name.multiReplace((" ", "-")), stamp, cacheList, (if o.threads >= 0: "true" else: "false")])
  # (where a sign-in comes back to, `retroui/oauth`: it hands the address's
  # answer to the app's page and closes)
  writeFile(outDir / "oauth.html", """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Signing in</title>
<style>body{font:15px system-ui,sans-serif;margin:3em;color:#222}</style></head>
<body><p>Signed in. This window closes by itself.</p>
<script>
(function () {
  var q = location.search || location.hash;
  try { if (window.opener) window.opener.postMessage({ retroSignIn: q }, location.origin); } catch (e) {}
  try { new BroadcastChannel("retro-signin").postMessage(q); } catch (e) {}
  setTimeout(function () { window.close(); }, 400);
})();
</script></body></html>
""")
  let devPoll = if o.dev: """
<script>(function(){let v=null;setInterval(async()=>{try{const r=await fetch("__retro_version");const t=await r.text();if(v!==null&&t!==v)location.reload();v=t;}catch(e){}},700);})();</script>""" else: ""
  writeFile(outDir / "index.html", """<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="theme-color" content="#000080">
<title>$1</title>
<link rel="manifest" href="manifest.webmanifest">
<link rel="icon" href="icon-192.png">
<link rel="apple-touch-icon" href="icon-192.png">
<style>html,body{margin:0;height:100%;overflow:hidden;background:#c0c0c0}#retro{position:fixed;inset:0}</style>
</head><body>
<div id="retro"></div>
<noscript>This app needs JavaScript and WebAssembly.</noscript>
<script src="retro.js"></script>
<script>Retro.boot({ wasm: "app.wasm", name: $2, files: [$3], kit: [$6]$4$7 }).catch((e) => console.error(e));</script>$5
</body></html>
""" % [htmlEsc(name), jsonStr(app.splitFile.name), fileList,
       (if o.dev: "" else: ", serviceWorker: \"sw.js\""), devPoll, kitList,
       (if o.threads < 0: "" else: ", threads: { wasm: \"app-threads.wasm\", workers: " & $o.threads &
          ", memory: [" & $(33554432 div 65536) & ", " & $(webThreadsMaxMemory div 65536) & "]" &
          (if o.threadsOnly: ", only: true" else: "") & " }")])
  # (beside it, gzipped: for servers that hand out such copies -- nginx's
  # gzip_static, `retrokit run --web`; GitHub Pages and the like compress
  # by themselves)
  for w in ["app.wasm", "app-threads.wasm"]:
    if not fileExists(outDir / w): continue
    let wasm = readFile(outDir / w)
    let gz = gzipOf(wasm)
    writeFile(outDir / w & ".gz", gz)
    say outDir & ": " & w & " " & $(wasm.len div 1024) & " KB (" & $(gz.len div 1024) & " KB gzipped)"
  result = 0

# ---- serving it: retrokit run --web ----------------------------------------------------------

proc mimeOf(path: string): string =
  case path.splitFile.ext.toLowerAscii
  of ".html": "text/html; charset=utf-8"
  of ".js": "text/javascript"
  of ".wasm": "application/wasm"
  of ".webmanifest": "application/manifest+json"
  of ".json": "application/json"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".svg": "image/svg+xml"
  of ".css": "text/css"
  of ".txt", ".md": "text/plain; charset=utf-8"
  of ".mp4": "video/mp4"
  of ".webm": "video/webm"
  of ".mp3": "audio/mpeg"
  of ".wav": "audio/wav"
  else: "application/octet-stream"

var serveVersion = "0"

proc serve*(dir: string; port: int) {.async.} =
  ## The page's folder over HTTP on `port` (localhost only).
  var server = newAsyncHttpServer()
  proc handle(req: Request) {.async, gcsafe.} =
    var path = decodeUrl(req.url.path)
    if path == "/__retro_version":
      {.cast(gcsafe).}:
        await req.respond(Http200, serveVersion, newHttpHeaders({"Cache-Control": "no-store"}))
      return
    if path.endsWith("/"): path.add "index.html"
    if ".." in path:
      await req.respond(Http403, "no")
      return
    let file = dir / path
    if fileExists(file):
      let gzipped = "gzip" in req.headers.getOrDefault("accept-encoding") and
                    fileExists(file & ".gz") and not req.headers.hasKey("range")
      let data = readFile(if gzipped: file & ".gz" else: file)
      let headers = newHttpHeaders({"Content-Type": mimeOf(file), "Cache-Control": "no-store",
                                    "Accept-Ranges": "bytes"})
      if fileExists(dir / "app-threads.wasm"):
        # (a page with threads: kept apart from other sites, so it may share
        # its memory with its workers)
        headers["Cross-Origin-Opener-Policy"] = "same-origin"
        headers["Cross-Origin-Embedder-Policy"] = "require-corp"
      if gzipped: headers["Content-Encoding"] = "gzip"
      let range = req.headers.getOrDefault("range")
      if range.startsWith("bytes=") and data.len > 0:
        # (a part: a video seeking)
        let spec = range[6 .. ^1].split(',')[0].strip
        let dash = spec.find('-')
        var a, b = -1
        try:
          if dash > 0: a = parseInt(spec[0 ..< dash])
          if dash >= 0 and dash < spec.high: b = parseInt(spec[dash + 1 .. ^1])
        except ValueError: discard
        if a < 0 and b >= 0: (a = max(0, data.len - b); b = data.high)
        if b < 0 or b > data.high: b = data.high
        if a < 0 or a > b:
          headers["Content-Range"] = "bytes */" & $data.len
          await req.respond(Http416, "", headers)
        else:
          headers["Content-Range"] = "bytes " & $a & "-" & $b & "/" & $data.len
          await req.respond(Http206, data[a .. b], headers)
      else:
        await req.respond(Http200, data, headers)
    else:
      await req.respond(Http404, "not found")
  server.listen(Port(port), "127.0.0.1")
  while true:
    if server.shouldAcceptRequest(): await server.acceptRequest(handle)
    else: await sleepAsync(10)

proc openBrowser(url: string) =
  let opener = when defined(windows): "cmd" elif defined(macosx): "open" else: "xdg-open"
  let args = when defined(windows): @["/c", "start", "", url] else: @[url]
  if findExe(opener).len > 0:
    try: discard startProcess(opener, args = args, options = {poUsePath, poDaemon})
    except OSError: discard

proc sourcesStamp(dir: string): Hash =
  for f in walkDirRec(dir, relative = true):
    if f.endsWith(".nim") and not f.startsWith("build"):
      result = result !& hash(f) !& hash(getLastModificationTime(dir / f).toUnix)
  result = !$result

proc runWeb*(app: string; o: WebOptions; watch: bool): int =
  ## Built, served on http://localhost:8765 (the next free port), opened;
  ## with `watch` built again on every save, the page reloading itself.
  var o = o
  o.dev = true
  if o.outDir.len == 0: o.outDir = app.parentDir / "build" / "web-dev"
  result = buildWeb(app, o)
  if result != 0 and not watch: return
  var port = if o.port > 0: o.port else: 8765
  while o.port == 0 and port < 8800:
    try:
      let s = newAsyncHttpServer()
      s.listen(Port(port), "127.0.0.1")
      s.close()
      break
    except OSError: inc port
  let url = "http://localhost:" & $port & "/"
  say "serving " & o.outDir & " at " & url & " (Ctrl+C ends it)"
  asyncCheck serve(o.outDir, port)
  if not o.noOpen: openBrowser(url)
  var stamp = sourcesStamp(app.parentDir)
  while true:
    poll(500)
    if watch:
      let now = sourcesStamp(app.parentDir)
      if now != stamp:
        stamp = now
        if buildWeb(app, o) == 0: serveVersion = $toUnix(getTime())

when isMainModule:
  var app = ""
  let args = commandLineParams()
  if args.len == 0 or args[0] in ["-h", "--help"]:
    echo "retroweb APP.nim [--out:DIR] [--files:DIR] [--icon:FILE.png] [--name:TEXT] [--small] [--threads[:N]] [--debug]"
    echo "         [--serve] [--watch] [--port:N] [--no-open]   (built, served, opened in a browser)"
    quit 0
  var serveIt, watchIt = false
  var rest: seq[string]
  for a in args:
    if a == "--serve": serveIt = true
    elif a == "--watch": (serveIt = true; watchIt = true)
    else: rest.add a
  let o = parseWebOptions(rest, app)
  if app.len == 0: quit "retroweb: which app? (an APP.nim)"
  quit(if serveIt: runWeb(app, o, watchIt) else: buildWeb(app, o))

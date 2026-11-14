## Web requests for the web APIs an app talks to (Microsoft Graph, the
## Gmail API...): any method (GET, POST, PUT, PATCH, DELETE...), headers
## both ways, binary bodies. A request blocks until its answer is there,
## and any number of threads may make requests at once (a mail sync runs
## many on its worker threads; the screen should not wait for one).
##
## Each system's own HTTP does the work, so TLS, certificates and proxies
## are the system's, with nothing to install:
##
## - **Windows:** WinHTTP (the system's proxy settings and TLS; answers
##   are unpacked where the system can).
## - **Linux, macOS, BSD, Termux:** libcurl, loaded when the first request
##   goes (`libcurl.so.4`, `libcurl.4.dylib`...); where it is not there,
##   the curl command (a process per request).
## - **Android:** Java's HttpURLConnection (tools/android/RetroNet.java);
##   the APK needs the INTERNET permission: `retroapk --permission:INTERNET`.
## - **iOS:** NSURLSession (the system's TLS, proxies and cookies; redirects
##   are always followed there).
##
## .. code-block:: nim
##   let r = httpRequest("GET", "https://graph.microsoft.com/v1.0/me",
##                       {"Authorization": "Bearer " & token})
##   if r.ok: echo parseJson(r.body)["displayName"].getStr
##   elif r.status == 0: echo "no answer: ", r.error
##   else: echo "the server answered ", r.status, ": ", r.body
##
## Redirects are followed (up to 10) unless asked not to; the
## "Authorization" and "Cookie" headers are not sent on to another host.
## `timeoutSec` is the longest the server may keep the request waiting --
## to connect, or for the next bytes -- not the length of a whole download.

import std/[strutils, uri]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
when defined(windows):
  import std/[locks, widestrs]
elif defined(wasm):
  discard
elif defined(ios):
  import native
else:
  import std/[dynlib, locks, os, sysrand]
  when androidApp:
    import uirelays/services
  else:
    import std/[osproc, posix, streams]

type
  HttpResponse* = object
    ## What a request brought back.
    status*: int                      ## the HTTP status; 0 when no answer came (`error` says why)
    headers*: seq[(string, string)]   ## names in lower case, in order
    body*: string                     ## the answer's bytes
    error*: string                    ## why no answer came ("" when one did)

const
  defaultAgent = block:
    # ("RetroNimUI/" and the kit's version, read from core.nim: this module
    # stays without the rest of the kit)
    let core = staticRead("core.nim")
    let k = core.find("RetroVersion* = \"") + len("RetroVersion* = \"")
    "RetroNimUI/" & core[k ..< core.find('"', k)]
  maxRedirects = 10

proc header*(r: HttpResponse; name: string): string =
  ## The value of the answer's header `name` (any case); "" when it has
  ## none. Of a header that came more than once, the first.
  for (k, v) in r.headers:
    if cmpIgnoreCase(k, name) == 0: return v
  ""

proc ok*(r: HttpResponse): bool =
  ## The server answered with a success (200..299).
  r.status >= 200 and r.status <= 299

proc urlEncode*(s: string): string =
  ## `s` for an address or a form (RFC 3986): letters, digits and `-._~`
  ## stay, every other byte becomes %XX.
  const hex = "0123456789ABCDEF"
  result = newStringOfCap(s.len + s.len div 2)
  for c in s:
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'}: result.add c
    else:
      result.add '%'
      result.add hex[ord(c) shr 4]
      result.add hex[ord(c) and 15]

proc formEncode*(fields: openArray[(string, string)]): string =
  ## A body of type application/x-www-form-urlencoded: `name=value` pairs,
  ## each part `urlEncode`d, joined by `&`.
  for i, (k, v) in fields:
    if i > 0: result.add '&'
    result.add urlEncode(k)
    result.add '='
    result.add urlEncode(v)

proc urlDecode*(s: string): string =
  ## Undoes `urlEncode` (and a form's `+` for a space).
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len and s[i+1] in HexDigits and s[i+2] in HexDigits:
      result.add char(parseHexInt(s[i+1 .. i+2]))
      i += 3
    else:
      result.add(if s[i] == '+': ' ' else: s[i])
      inc i

proc formDecode*(s: string): seq[(string, string)] =
  ## The `name=value` pairs of a form body or of an address's query
  ## (`a=1&b=x%20y`), decoded.
  for part in s.split('&'):
    if part.len == 0: continue
    let eq = part.find('=')
    if eq < 0: result.add (urlDecode(part), "")
    else: result.add (urlDecode(part[0 ..< eq]), urlDecode(part[eq + 1 .. ^1]))

# ---- shared by the ways of sending ----------------------------------------------------

proc cleanUrl(url: string): string =
  ## `url` as it goes on the wire: what may not be in an address (spaces,
  ## other scripts' letters, quotes) as %XX, without its #fragment.
  const hex = "0123456789ABCDEF"
  for c in url:
    if c == '#': break
    if ord(c) <= 32 or ord(c) >= 127 or c in {'"', '<', '>', '\\', '^', '`', '{', '|', '}'}:
      result.add '%'
      result.add hex[ord(c) shr 4]
      result.add hex[ord(c) and 15]
    else: result.add c

proc failed(msg: string): HttpResponse = HttpResponse(status: 0, error: msg)

proc headerLines(r: var HttpResponse; text: string) =
  ## Adds the headers of `text` (lines of "Name: value") to `r.headers`; a
  ## status line ("HTTP/1.1 200 OK": another answer, after a redirect or a
  ## "100 Continue") drops those before it.
  for raw in text.splitLines:
    let line = raw.strip(leading = false, chars = {'\r', '\n'})
    if line.len == 0: continue
    if line.startsWith("HTTP/"):
      r.headers.setLen(0)
      continue
    if line[0] in {' ', '\t'} and r.headers.len > 0:     # (a folded line)
      r.headers[^1][1].add " " & line.strip
      continue
    let c = line.find(':')
    if c > 0: r.headers.add (line[0 ..< c].strip.toLowerAscii, line[c + 1 .. ^1].strip)

proc headerOk(k, v: string): bool =
  ## A header that can be sent: a name, no line breaks (and not the
  ## length, which the system sets).
  k.len > 0 and not k.contains({'\r', '\n', ':', '\t', '\0'}) and not v.contains({'\r', '\n', '\0'}) and
    cmpIgnoreCase(k, "Content-Length") != 0

when not defined(windows) and not defined(ios) and not defined(wasm):
  proc randomName(): string =
    ## A name for a file of this request alone.
    var b: array[8, byte]
    discard urandom(b)
    for x in b: result.add toHex(x, 2).toLowerAscii

# ---- Windows: WinHTTP -------------------------------------------------------------------

when defined(windows):
  type HInternet = pointer

  proc WinHttpOpen(agent: WideCString; access: uint32; proxy, bypass: WideCString;
                   flags: uint32): HInternet {.stdcall, dynlib: "winhttp.dll", importc.}
  proc WinHttpConnect(s: HInternet; server: WideCString; port: uint16;
                      reserved: uint32): HInternet {.stdcall, dynlib: "winhttp.dll", importc.}
  proc WinHttpOpenRequest(c: HInternet; verb, obj, version, referrer: WideCString;
                          accept: pointer; flags: uint32): HInternet {.
                          stdcall, dynlib: "winhttp.dll", importc.}
  proc WinHttpSetTimeouts(h: HInternet; resolve, connect, send, receive: int32): int32 {.
                          stdcall, dynlib: "winhttp.dll", importc.}
  proc WinHttpSetOption(h: HInternet; option: uint32; buf: pointer; len: uint32): int32 {.
                        stdcall, dynlib: "winhttp.dll", importc.}
  proc WinHttpAddRequestHeaders(h: HInternet; headers: WideCString; len: uint32;
                                modifiers: uint32): int32 {.stdcall, dynlib: "winhttp.dll", importc.}
  proc WinHttpSendRequest(h: HInternet; headers: WideCString; headersLen: uint32;
                          data: pointer; dataLen, totalLen: uint32; context: uint): int32 {.
                          stdcall, dynlib: "winhttp.dll", importc.}
  proc WinHttpReceiveResponse(h: HInternet; reserved: pointer): int32 {.
                              stdcall, dynlib: "winhttp.dll", importc.}
  proc WinHttpQueryHeaders(h: HInternet; level: uint32; name: WideCString; buf: pointer;
                           len: ptr uint32; index: ptr uint32): int32 {.
                           stdcall, dynlib: "winhttp.dll", importc.}
  proc WinHttpReadData(h: HInternet; buf: pointer; toRead: uint32; read: ptr uint32): int32 {.
                       stdcall, dynlib: "winhttp.dll", importc.}
  proc WinHttpCloseHandle(h: HInternet): int32 {.stdcall, dynlib: "winhttp.dll", importc.}
  proc GetLastError(): uint32 {.stdcall, dynlib: "kernel32.dll", importc.}
  proc GetModuleHandleW(name: WideCString): pointer {.stdcall, dynlib: "kernel32.dll", importc.}
  proc FormatMessageW(flags: uint32; source: pointer; id, lang: uint32; buf: pointer;
                      size: uint32; args: pointer): uint32 {.stdcall, dynlib: "kernel32.dll", importc.}

  const
    accessAutomatic = 4'u32           # WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY (8.1 and newer)
    accessDefault = 0'u32
    flagSecure = 0x00800000'u32
    flagEscapeDisable = 0x40'u32 or 0x80'u32   # the address goes as it is (cleanUrl did it)
    optDisableFeature = 63'u32
    disableRedirects = 2'u32
    optDecompression = 118'u32
    optSecureProtocols = 84'u32
    optRedirectPolicy = 88'u32
    optReceiveResponseTimeout = 7'u32
    queryStatus = 19'u32 or 0x20000000'u32     # WINHTTP_QUERY_STATUS_CODE | FLAG_NUMBER
    queryRawHeaders = 22'u32                   # WINHTTP_QUERY_RAW_HEADERS_CRLF
    addHeader = 0x20000000'u32
    replaceHeader = 0x80000000'u32

  var
    winLock: Lock
    session: HInternet

  initLock(winLock)

  proc winError(code: uint32): string =
    case code
    of 12002, 10060: "no answer from the server in time"
    of 12007: "the server's name was not found"
    of 12029, 10061: "could not connect to the server"
    of 12030: "the connection was cut"
    of 12152: "the server's answer was not HTTP"
    of 12175, 12157: "the secure connection failed (TLS)"
    of 12037, 12038, 12044, 12045, 12169: "the server's certificate was refused"
    of 12156: "too many redirects"
    else:
      var buf: array[512, Utf16Char]
      let n = FormatMessageW(0x800 or 0x1000 or 0x200, GetModuleHandleW(newWideCString("winhttp.dll")),
                             code, 0, addr buf[0], 512, nil)
      if n > 0: ($cast[WideCString](addr buf[0])).strip & " (" & $code & ")"
      else: "WinHTTP error " & $code

  proc getSession(): HInternet =
    withLock winLock:
      if session == nil:
        let agent = newWideCString(defaultAgent)
        session = WinHttpOpen(agent, accessAutomatic, nil, nil, 0)
        if session == nil: session = WinHttpOpen(agent, accessDefault, nil, nil, 0)
        if session != nil:
          # TLS 1.2 and 1.3 also where they are not on by themselves (7, 8)
          var protocols = 0x800'u32 or 0x2000'u32
          if WinHttpSetOption(session, optSecureProtocols, addr protocols, 4) == 0:
            protocols = 0x200'u32 or 0x800'u32
            discard WinHttpSetOption(session, optSecureProtocols, addr protocols, 4)
      result = session

  proc winOnce(meth, url: string; headers: openArray[(string, string)]; body: string;
               timeoutSec: int): HttpResponse =
    ## One request, one answer (`httpRequest` follows the redirects).
    let u = try: parseUri(url) except UriParseError: Uri()
    let scheme = u.scheme.toLowerAscii
    if scheme notin ["http", "https"] or u.hostname.len == 0:
      return failed("not a web address: " & url)
    let port = if u.port.len > 0: (try: parseInt(u.port) except ValueError: -1)
               elif scheme == "https": 443 else: 80
    if port <= 0 or port > 65535: return failed("bad port in " & url)
    var target = (if u.path.len > 0: u.path else: "/")
    if u.query.len > 0: target.add "?" & u.query
    let s = getSession()
    if s == nil: return failed(winError(GetLastError()))
    let conn = WinHttpConnect(s, newWideCString(u.hostname), uint16(port), 0)
    if conn == nil: return failed(winError(GetLastError()))
    defer: discard WinHttpCloseHandle(conn)
    let req = WinHttpOpenRequest(conn, newWideCString(meth), newWideCString(target), nil, nil, nil,
                                 flagEscapeDisable or (if scheme == "https": flagSecure else: 0))
    if req == nil: return failed(winError(GetLastError()))
    defer: discard WinHttpCloseHandle(req)
    let ms = int32(max(1, timeoutSec) * 1000)
    discard WinHttpSetTimeouts(req, ms, ms, ms, ms)
    var wait = uint32(ms)                # (the wait for the answer's headers is apart)
    discard WinHttpSetOption(req, optReceiveResponseTimeout, addr wait, 4)
    var opt = disableRedirects
    discard WinHttpSetOption(req, optDisableFeature, addr opt, 4)
    var never = 0'u32
    discard WinHttpSetOption(req, optRedirectPolicy, addr never, 4)
    var all = 3'u32                     # gzip and deflate (8.1 and newer)
    discard WinHttpSetOption(req, optDecompression, addr all, 4)
    for (k, v) in headers:
      let line = newWideCString(k & ": " & v)
      let how = addHeader or (if cmpIgnoreCase(k, "User-Agent") == 0: replaceHeader else: 0'u32)
      if WinHttpAddRequestHeaders(req, line, uint32.high, how) == 0:
        return failed("the header " & k & " was refused (" & winError(GetLastError()) & ")")
    let data = if body.len > 0: cast[pointer](unsafeAddr body[0]) else: nil
    if WinHttpSendRequest(req, nil, 0, data, uint32(body.len), uint32(body.len), 0) == 0 or
        WinHttpReceiveResponse(req, nil) == 0:
      return failed(winError(GetLastError()))
    var status = 0'u32
    var size = 4'u32
    if WinHttpQueryHeaders(req, queryStatus, nil, addr status, addr size, nil) == 0:
      return failed(winError(GetLastError()))
    result.status = int(status)
    size = 0
    discard WinHttpQueryHeaders(req, queryRawHeaders, nil, nil, addr size, nil)
    if size > 0:
      var buf = newSeq[Utf16Char](int(size) div 2 + 1)
      if WinHttpQueryHeaders(req, queryRawHeaders, nil, addr buf[0], addr size, nil) != 0:
        result.headerLines($cast[WideCString](addr buf[0]))
    if meth == "HEAD": return
    var chunk = newString(65536)
    while true:
      var got = 0'u32
      if WinHttpReadData(req, addr chunk[0], uint32(chunk.len), addr got) == 0:
        let e = GetLastError()
        result = HttpResponse(status: 0, error: "the answer was cut off: " & winError(e)); return
      if got == 0: break
      let at = result.body.len
      result.body.setLen(at + int(got))
      copyMem(addr result.body[at], addr chunk[0], int(got))

# ---- Android: Java's HttpURLConnection (tools/android/RetroNet.java) ---------------------

when androidApp:
  proc javaRequest(meth, url: string; headers: openArray[(string, string)]; body: string;
                   timeoutSec: int; follow: bool; there: var bool): HttpResponse =
    ## Through the app's Java part; `there` false when it has none (not an
    ## APK: Termux).
    there = true
    var dir: string
    {.cast(gcsafe).}:
      dir = services.dataDir("") / ".http"
    try: createDir(dir) except OSError: return failed("cannot make " & dir)
    let base = dir / randomName()
    let inPath = if body.len > 0: base & ".in" else: ""
    let outPath = base & ".out"
    if inPath.len > 0:
      try: writeFile(inPath, body)
      except IOError as e: return failed(e.msg)
    var hs: seq[string]
    for (k, v) in headers: hs.add k & ": " & v.replace('\t', ' ')
    let r = systemCall("net.request", [meth, url, hs.join("\r"), $(max(1, timeoutSec) * 1000),
                                       inPath, outPath, (if follow: "1" else: "0")].join("\t"))
    if inPath.len > 0:
      try: removeFile(inPath) except OSError: discard
    defer:
      try: removeFile(outPath) except OSError: discard
    if r == "\0":
      there = false
      return failed("no HTTP here")
    if r.len == 0: return failed("no answer")
    if r[0] == 'e': return failed(r[1 .. ^1])
    let nl = r.find('\n')
    let first = if nl < 0: r else: r[0 ..< nl]
    result.status = try: parseInt(first.strip) except ValueError: 0
    if result.status == 0: result = failed("a strange answer from Java: " & first); return
    if nl >= 0: result.headerLines(r[nl + 1 .. ^1])
    try: result.body = readFile(outPath)
    except IOError: discard

# ---- iOS: the system's NSURLSession ----------------------------------------------------------

when defined(ios):
  # (its completion handler is a block: made here by hand -- a global block,
  # which the system never copies -- its invoke noting what came and waking
  # the thread that waits; that thread reads the answer and lets it go)
  type
    BlockDescriptor = object
      reserved, size: culong
    Pending = object
      sem: pointer
      data, response, error: ObjcId
    CompletionBlock = object
      isa: pointer
      flags, reserved: int32
      invoke: pointer
      descriptor: ptr BlockDescriptor
      pending: ptr Pending               # (what the block "captured")

  var concreteGlobalBlock {.importc: "_NSConcreteGlobalBlock".}: array[32, pointer]
  proc dispatch_semaphore_create(value: clong): pointer {.importc, cdecl.}
  proc dispatch_semaphore_wait(sem: pointer; timeout: uint64): clong {.importc, cdecl.}
  proc dispatch_semaphore_signal(sem: pointer): clong {.importc, cdecl.}
  proc dispatch_time(base: uint64; delta: int64): uint64 {.importc, cdecl.}
  proc dispatch_release(o: pointer) {.importc, cdecl.}
  proc objc_retain(o: ObjcId): ObjcId {.importc, cdecl.}
  proc objc_release(o: ObjcId) {.importc, cdecl.}

  var blockDescriptor = BlockDescriptor(size: culong(sizeof(CompletionBlock)))

  proc onDone(b: ptr CompletionBlock; data, response, error: ObjcId) {.cdecl.} =
    ## (on the session's own thread: nothing of Nim's made here)
    let p = b.pending
    if data != nil: p.data = objc_retain(data)
    if response != nil: p.response = objc_retain(response)
    if error != nil: p.error = objc_retain(error)
    discard dispatch_semaphore_signal(p.sem)

  proc iosRequest(meth, url: string; headers: openArray[(string, string)]; body: string;
                  timeoutSec: int): HttpResponse =
    ## Through NSURLSession's shared session (its redirects followed; the
    ## system's TLS, proxies and cookies), the thread waiting for it.
    result = HttpResponse()
    let pending = cast[ptr Pending](allocShared0(sizeof(Pending)))
    let blk = cast[ptr CompletionBlock](allocShared0(sizeof(CompletionBlock)))
    pending.sem = dispatch_semaphore_create(0)
    blk.isa = addr concreteGlobalBlock
    blk.flags = 1'i32 shl 28                      # BLOCK_IS_GLOBAL
    blk.invoke = cast[pointer](onDone)
    blk.descriptor = addr blockDescriptor
    blk.pending = pending
    var started = false
    autoreleasePool:
      let u = objcSend(ObjcId, objcClass("NSURL"), "URLWithString:", nsString(url))
      if u == nil:
        result = failed("bad address: " & url)
      else:
        let req = objcSend(ObjcId, objcClass("NSMutableURLRequest"), "requestWithURL:cachePolicy:timeoutInterval:",
                           u, 1, float(max(1, timeoutSec)))   # (reload, ignoring the cache)
        objcSend(void, req, "setHTTPMethod:", nsString(meth))
        var agent = false
        for (k, v) in headers:
          if cmpIgnoreCase(k, "User-Agent") == 0: agent = true
          objcSend(void, req, "setValue:forHTTPHeaderField:", nsString(v), nsString(k))
        if not agent:
          objcSend(void, req, "setValue:forHTTPHeaderField:", nsString(defaultAgent), nsString("User-Agent"))
        if body.len > 0:
          let d = objcSend(ObjcId, objcClass("NSData"), "dataWithBytes:length:",
                           cast[pointer](unsafeAddr body[0]), body.len)
          objcSend(void, req, "setHTTPBody:", d)
        let session = objcSend(ObjcId, objcClass("NSURLSession"), "sharedSession")
        let task = objcSend(ObjcId, session, "dataTaskWithRequest:completionHandler:", req,
                            cast[pointer](blk))
        if task != nil:
          objcSend(void, task, "resume")
          started = true
        else:
          result = failed("the system made no request")
    if started:
      # (the session's own timeout ends it; a little more here, never forever)
      let until = dispatch_time(0, int64(max(1, timeoutSec) + 10) * 1_000_000_000)
      if dispatch_semaphore_wait(pending.sem, until) != 0:
        result = failed("no answer in " & $timeoutSec & " s")
        # (the block may still come: its memory is left to it)
        return
      autoreleasePool:
        if pending.error != nil and pending.response == nil:
          result = failed(toNim(objcSend(ObjcId, pending.error, "localizedDescription")))
        else:
          if pending.response != nil and respondsTo(pending.response, "statusCode"):
            result.status = objcSend(int, pending.response, "statusCode")
            let fields = objcSend(ObjcId, pending.response, "allHeaderFields")
            let keys = objcSend(ObjcId, fields, "allKeys")
            for i in 0 ..< objcSend(int, keys, "count"):
              let k = objcSend(ObjcId, keys, "objectAtIndex:", i)
              result.headers.add (toNim(k).toLowerAscii,
                                  toNim(objcSend(ObjcId, fields, "objectForKey:", k)))
          if pending.data != nil:
            let n = objcSend(int, pending.data, "length")
            if n > 0:
              result.body = newString(n)
              copyMem(addr result.body[0], objcSend(pointer, pending.data, "bytes"), n)
          if result.status == 0: result.error = "no answer"
        for o in [pending.data, pending.response, pending.error]:
          if o != nil: objc_release(o)
    dispatch_release(pending.sem)
    deallocShared(pending)
    deallocShared(blk)

# ---- a browser page: the page's own requests ---------------------------------------------

when defined(wasm):
  proc rwHttp(meth, url, headers: cstring; body: pointer; bodyLen, timeoutMs, follow: cint): cint {.importc: "rw_http", cdecl.}
  proc rwHttpPart(h, part: cint; buf: pointer; cap: cint): cint {.importc: "rw_http_part", cdecl.}
  proc rwHttpFree(h: cint) {.importc: "rw_http_free", cdecl.}
  proc rwPageUrl(s: cstring; buf: pointer; cap: cint): cint {.importc: "rw_page_url", cdecl.}

  proc pageUrl(s: string): string =
    ## An address of the page's own site ("data/x.json", "/api") made whole.
    let n = rwPageUrl(cstring(s), nil, 0)
    if n <= 0: return s
    result = newString(n)
    discard rwPageUrl(cstring(s), addr result[0], cint(n + 1))

  proc webRequest(meth, url: string; headers: openArray[(string, string)]; body: string;
                  timeoutSec: int; follow: bool): HttpResponse =
    ## Through the page (the site must allow it: CORS); it waits for the
    ## answer, as everywhere.
    var hs = ""
    for (k, v) in headers: hs.add k & ": " & v & "\r\n"
    let h = rwHttp(cstring(meth), cstring(url), cstring(hs),
                   if body.len > 0: unsafeAddr body[0] else: nil, cint(body.len),
                   cint(max(1, timeoutSec) * 1000), cint(follow))
    if h <= 0: return failed("the page could not send it")
    defer: rwHttpFree(h)
    proc part(h, which: cint): string =
      let n = rwHttpPart(h, which, nil, 0)
      if n <= 0: return ""
      result = newString(n)
      discard rwHttpPart(h, which, addr result[0], cint(n))
    result.status = rwHttpPart(h, 0, nil, 0)
    if result.status == 0:
      let why = part(h, 3)
      result = failed(if why.len > 0: why else: "no answer (no network, or the site does not allow pages of other sites: CORS)"); return
    result.headerLines(part(h, 1))
    result.body = part(h, 2)

# ---- Linux, macOS, BSD (and Termux): libcurl, or the curl command ------------------------

when not defined(windows) and not defined(ios) and not defined(wasm):
  type
    CurlInit = proc (): pointer {.cdecl, gcsafe.}
    CurlSetopt = proc (h: pointer; opt: cint): cint {.cdecl, varargs, gcsafe.}
    CurlGetinfo = proc (h: pointer; info: cint): cint {.cdecl, varargs, gcsafe.}
    CurlHandleProc = proc (h: pointer) {.cdecl, gcsafe.}
    CurlPerform = proc (h: pointer): cint {.cdecl, gcsafe.}
    CurlAppend = proc (list: pointer; s: cstring): pointer {.cdecl, gcsafe.}
    CurlStrerror = proc (code: cint): cstring {.cdecl, gcsafe.}
    CurlGlobalInit = proc (flags: clong): cint {.cdecl, gcsafe.}
    WriteCallback = proc (p: ptr char; size, n: csize_t; user: pointer): csize_t {.cdecl, gcsafe.}

  const
    optWriteData = 10001.cint
    optUrl = 10002.cint
    optErrorBuffer = 10010.cint
    optPostFields = 10015.cint
    optUserAgent = 10018.cint
    optLowSpeedLimit = 19.cint
    optLowSpeedTime = 20.cint
    optHttpHeader = 10023.cint
    optHeaderData = 10029.cint
    optCustomRequest = 10036.cint
    optNoBody = 44.cint
    optFollow = 52.cint
    optMaxRedirs = 68.cint
    optConnectTimeout = 78.cint
    optHttpGet = 80.cint
    optNoSignal = 99.cint
    optAcceptEncoding = 10102.cint
    optWriteFunction = 20011.cint
    optHeaderFunction = 20079.cint
    optPostFieldSizeLarge = 30120.cint
    infoResponseCode = 0x200002.cint
    poolSize = 16

  type CurlApi = object
    init: CurlInit
    setopt: CurlSetopt
    getinfo: CurlGetinfo
    perform: CurlPerform
    cleanup, reset: CurlHandleProc
    append: CurlAppend
    freeList: CurlHandleProc
    strerror: CurlStrerror

  var
    curlLock: Lock
    curlTried = false                 # guarded by curlLock
    curl: CurlApi                     # set once, under curlLock; read-only after
    pool: array[poolSize, pointer]    # easy handles not in use (their connections stay open)
    pooled = 0

  initLock(curlLock)

  proc loadCurl(): bool =
    ## libcurl's functions, loaded the first time; false when there is none.
    withLock curlLock:
      if not curlTried:
        curlTried = true
        var lib: LibHandle
        for name in ["libcurl.so.4", "libcurl.so", "libcurl.4.dylib", "/usr/lib/libcurl.4.dylib",
                     "libcurl.dylib", "libcurl-gnutls.so.4"]:
          lib = loadLib(name)
          if lib != nil: break
        if lib != nil:
          let api = CurlApi(
            init: cast[CurlInit](lib.symAddr("curl_easy_init")),
            setopt: cast[CurlSetopt](lib.symAddr("curl_easy_setopt")),
            getinfo: cast[CurlGetinfo](lib.symAddr("curl_easy_getinfo")),
            perform: cast[CurlPerform](lib.symAddr("curl_easy_perform")),
            cleanup: cast[CurlHandleProc](lib.symAddr("curl_easy_cleanup")),
            reset: cast[CurlHandleProc](lib.symAddr("curl_easy_reset")),
            append: cast[CurlAppend](lib.symAddr("curl_slist_append")),
            freeList: cast[CurlHandleProc](lib.symAddr("curl_slist_free_all")),
            strerror: cast[CurlStrerror](lib.symAddr("curl_easy_strerror")))
          let globalInit = cast[CurlGlobalInit](lib.symAddr("curl_global_init"))
          if api.init != nil and api.setopt != nil and api.getinfo != nil and api.perform != nil and
              api.cleanup != nil and api.reset != nil and api.append != nil and
              api.freeList != nil and api.strerror != nil and globalInit != nil and
              globalInit(3) == 0:                       # CURL_GLOBAL_ALL
            curl = api
          else:
            unloadLib(lib)
      result = curl.init != nil

  proc takeHandle(): pointer =
    withLock curlLock:
      if pooled > 0:
        dec pooled
        result = pool[pooled]
    if result == nil: result = curl.init()

  proc giveBack(h: pointer) =
    var keep = false
    withLock curlLock:
      if pooled < poolSize:
        pool[pooled] = h
        inc pooled
        keep = true
    if not keep: curl.cleanup(h)

  proc onBody(p: ptr char; size, n: csize_t; user: pointer): csize_t {.cdecl, gcsafe.} =
    let s = cast[ptr string](user)
    let len = int(size * n)
    if len > 0:
      let at = s[].len
      s[].setLen(at + len)
      copyMem(addr s[][at], p, len)
    csize_t(len)

  proc onHeader(p: ptr char; size, n: csize_t; user: pointer): csize_t {.cdecl, gcsafe.} =
    let r = cast[ptr HttpResponse](user)
    let len = int(size * n)
    if len > 0:
      var line = newString(len)
      copyMem(addr line[0], p, len)
      r[].headerLines(line)
    csize_t(len)

  proc curlRequest(meth, url: string; headers: openArray[(string, string)]; body: string;
                   timeoutSec: int; follow: bool): HttpResponse =
    let h = takeHandle()
    if h == nil: return failed("libcurl could not start")
    var errBuf: array[256, char]
    var list: pointer = nil
    for (k, v) in headers: list = curl.append(list, cstring(k & ": " & v))
    list = curl.append(list, "Expect:")      # (no waiting for "100 Continue")
    let c = curl.setopt
    discard c(h, optUrl, cstring(url))
    discard c(h, optNoSignal, clong(1))
    discard c(h, optUserAgent, cstring(defaultAgent))
    discard c(h, optAcceptEncoding, cstring(""))
    discard c(h, optFollow, clong(ord(follow)))
    discard c(h, optMaxRedirs, clong(maxRedirects))
    discard c(h, optConnectTimeout, clong(max(1, timeoutSec)))
    discard c(h, optLowSpeedLimit, clong(1))
    discard c(h, optLowSpeedTime, clong(max(1, timeoutSec)))
    discard c(h, optErrorBuffer, addr errBuf[0])
    discard c(h, optHttpHeader, list)
    discard c(h, optWriteFunction, cast[pointer](WriteCallback(onBody)))
    discard c(h, optWriteData, addr result.body)
    discard c(h, optHeaderFunction, cast[pointer](WriteCallback(onHeader)))
    discard c(h, optHeaderData, addr result)
    let empty: cstring = ""
    if meth == "GET" and body.len == 0:
      discard c(h, optHttpGet, clong(1))
    elif meth == "HEAD":
      discard c(h, optNoBody, clong(1))
    else:
      if body.len > 0 or meth in ["POST", "PUT", "PATCH"]:
        discard c(h, optPostFields, (if body.len > 0: cast[pointer](unsafeAddr body[0]) else: cast[pointer](empty)))
        discard c(h, optPostFieldSizeLarge, int64(body.len))
      if meth != "POST": discard c(h, optCustomRequest, cstring(meth))
    let code = curl.perform(h)
    var status: clong = 0
    discard curl.getinfo(h, infoResponseCode, addr status)
    curl.reset(h)                         # (lets go of `list`, `result`)
    curl.freeList(list)
    giveBack(h)
    if code == 28: result = failed("no answer from the server in " & $max(1, timeoutSec) & " s"); return
    if code != 0:
      let msg = $cast[cstring](addr errBuf[0])
      result = failed(if msg.len > 0: msg else: $curl.strerror(code)); return
    result.status = int(status)

  when not androidApp:
    proc writePrivate(path, data: string): bool =
      ## A new file only this user may read (it can hold a token).
      let fd = posix.open(path.cstring, O_WRONLY or O_CREAT or O_EXCL, Mode(0o600))
      if fd < 0: return false
      var at = 0
      while at < data.len:
        let n = posix.write(fd, unsafeAddr data[at], data.len - at)
        if n <= 0:
          discard posix.close(fd)
          return false
        at += n
      posix.close(fd) == 0

    proc configQuote(s: string): string =
      ## A value of curl's config file (`-K`), in double quotes.
      result = "\""
      for c in s:
        case c
        of '"': result.add "\\\""
        of '\\': result.add "\\\\"
        of '\t': result.add "\\t"
        else: result.add c
      result.add '"'

    proc commandRequest(meth, url: string; headers: openArray[(string, string)]; body: string;
                        timeoutSec: int; follow: bool): HttpResponse =
      ## With the curl command: the address and the headers go in a config
      ## file (not on the command line, which others can see), the body in
      ## a file.
      let tool = findExe("curl")
      if tool.len == 0: return failed("neither libcurl nor the curl command is installed")
      let base = getTempDir() / "retro-http-" & randomName()
      var cfg = "url = " & configQuote(url) & "\n"
      cfg.add "user-agent = " & configQuote(defaultAgent) & "\n"
      cfg.add "header = \"Expect:\"\n"
      for (k, v) in headers: cfg.add "header = " & configQuote(k & ": " & v) & "\n"
      var args = @["-sS", "-K", base & ".cfg", "-D", base & ".head", "-o", base & ".body",
                   "-w", "\n%{http_code}", "--compressed",
                   "--connect-timeout", $max(1, timeoutSec),
                   "--speed-limit", "1", "--speed-time", $max(1, timeoutSec)]
      if follow: args.add ["-L", "--max-redirs", $maxRedirects]
      if meth == "HEAD": args.add "-I"
      elif meth != "GET" and meth != "POST": args.add ["-X", meth]
      elif meth == "GET" and body.len > 0: args.add ["-X", "GET"]
      if body.len > 0 or meth in ["POST", "PUT", "PATCH"]:
        args.add ["--data-binary", "@" & base & ".in"]
      defer:
        for ext in [".cfg", ".head", ".body", ".in"]:
          try: removeFile(base & ext) except OSError: discard
      if not writePrivate(base & ".cfg", cfg) or not writePrivate(base & ".in", body):
        return failed("cannot write in " & getTempDir())
      var output = ""
      var exitCode = -1
      try:
        let p = startProcess(tool, args = args, options = {poStdErrToStdOut})
        output = p.outputStream.readAll()
        exitCode = p.waitForExit()
        p.close()
      except OSError, IOError:
        return failed("the curl command did not run: " & getCurrentExceptionMsg())
      let lines = output.strip.splitLines
      let status = if lines.len > 0: (try: parseInt(lines[^1].strip) except ValueError: 0) else: 0
      if exitCode == 28: return failed("no answer from the server in " & $max(1, timeoutSec) & " s")
      if exitCode != 0:
        var msg = (if lines.len > 1: lines[0 .. ^2].join(" ").strip else: "")
        if msg.startsWith("curl: "): msg = msg[6 .. ^1]
        if msg.startsWith("(") and ") " in msg: msg = msg[msg.find(") ") + 2 .. ^1]
        return failed(if msg.len > 0: msg else: "curl failed (" & $exitCode & ")")
      result.status = status
      try: result.headerLines(readFile(base & ".head"))
      except IOError: discard
      if meth != "HEAD":
        try: result.body = readFile(base & ".body")
        except IOError: discard

# ---- the request -------------------------------------------------------------------------

proc sameHost(a, b: string): bool =
  let x = try: parseUri(a) except UriParseError: Uri()
  let y = try: parseUri(b) except UriParseError: Uri()
  cmpIgnoreCase(x.hostname, y.hostname) == 0

proc httpRequest*(meth, url: string; headers: openArray[(string, string)] = [];
                  body = ""; timeoutSec = 60; followRedirects = true): HttpResponse {.gcsafe.} =
  ## Sends a `meth` request ("GET", "POST", "PATCH"...) for `url` with
  ## `headers` and `body` (any bytes) and waits for the answer. `status` is
  ## 0 when none came (no network, no such server, `timeoutSec` passed with
  ## no word from the server...) and `error` says why; an HTTP error such
  ## as 404 or 500 is an answer: its status, headers and body are there.
  ## In a web page (`retrokit web`) an address of the page's own site can be
  ## short ("data/prices.json"), and another site must allow the page (CORS).
  ## With `followRedirects` off a redirect (301, 302...) comes back as it
  ## is. Any thread may call it, many at once.
  result = HttpResponse()         # (a value at once: see tools/writecheck.py)
  var meth = meth.toUpperAscii
  if meth.len == 0 or not meth.allCharsInSet({'A'..'Z', '-', '_'}):
    result = failed("bad method: " & meth); return
  var url = cleanUrl(url)
  when defined(wasm):
    # (in a web page an address of its own site may be short: "data/x.json")
    if "://" notin url and url.len > 0: url = pageUrl(url)
  let lower = url.toLowerAscii
  if not (lower.startsWith("http://") or lower.startsWith("https://")):
    result = failed("not a web address: " & url); return
  var hs: seq[(string, string)]
  for (k, v) in headers:
    if headerOk(k, v): hs.add (k, v)
    elif cmpIgnoreCase(k, "Content-Length") != 0:
      result = failed("bad header: " & k); return
  when defined(windows):
    # redirects by hand: WinHTTP would send the Authorization on to any host
    var body = body
    for hop in 0 .. maxRedirects:
      {.cast(gcsafe).}:
        result = winOnce(meth, url, hs, body, timeoutSec)
      if not followRedirects or result.status notin [301, 302, 303, 307, 308]: return
      let loc = result.header("location")
      if loc.len == 0: return
      let next = try: $combine(parseUri(url), parseUri(loc)) except UriParseError: ""
      if next.len == 0: return
      if not sameHost(url, next):
        var kept: seq[(string, string)]
        for (k, v) in hs:
          if cmpIgnoreCase(k, "Authorization") != 0 and cmpIgnoreCase(k, "Cookie") != 0:
            kept.add (k, v)
        hs = kept
      if result.status == 303 and meth != "HEAD" or result.status in [301, 302] and meth == "POST":
        meth = "GET"
        body = ""
        var kept: seq[(string, string)]
        for (k, v) in hs:
          if cmpIgnoreCase(k, "Content-Type") != 0: kept.add (k, v)
        hs = kept
      url = cleanUrl(next)
    result = failed("too many redirects")
  elif defined(ios):
    {.cast(gcsafe).}:
      result = iosRequest(meth, url, hs, body, timeoutSec)
  elif defined(wasm):
    {.cast(gcsafe).}:
      result = webRequest(meth, url, hs, body, timeoutSec, followRedirects)
  else:
    {.cast(gcsafe).}:
      when androidApp:
        var there = true
        result = javaRequest(meth, url, hs, body, timeoutSec, followRedirects, there)
        if not there:                  # (Termux: not an APK)
          result = if loadCurl(): curlRequest(meth, url, hs, body, timeoutSec, followRedirects)
                   else: failed("no HTTP here (not an Android app, and no libcurl)")
      else:
        if getEnv("RETRO_HTTP_CURL_COMMAND").len == 0 and loadCurl():
          result = curlRequest(meth, url, hs, body, timeoutSec, followRedirects)
        else:
          result = commandRequest(meth, url, hs, body, timeoutSec, followRedirects)

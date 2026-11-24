## Tests of retroui/http against a small HTTP server of their own (threads
## on std/net): the methods, headers both ways, a binary body of 1 MB,
## errors, redirects followed and not, a timeout, and requests from many
## threads at once. On Linux it runs twice: with libcurl, and with the
## curl command (as where libcurl is missing).
##
## For WinHTTP the test runs under Wine against the server on the Linux
## side:
##
## .. code-block:: sh
##   nim c --hints:off tests/test_http.nim && tests/test_http serve 18080 &
##   nim c --hints:off -d:mingw --cpu:amd64 -o:/tmp/test_http.exe tests/test_http.nim
##   RETRO_TEST_SERVER=http://127.0.0.1:18080 WINEDEBUG=-all wine /tmp/test_http.exe

import std/[net, os, strutils, times, typedthreads, nativesockets]
import retroui/http

# ---- the server ------------------------------------------------------------------------

const gzipped = "\x1f\x8b\x08\x00\x00\x00\x00\x00\x02\xff\xcb\x48\xcd\xc9\xc9\x57\x48\xaf\xca" &
                "\x2c\x50\xc8\x18\x6e\x4c\x00\xd9\x94\xfb\xac\xdc\x00\x00\x00"   # "hello gzip " * 20

type Request = object
  meth, path, query: string
  headers: seq[(string, string)]
  body: string

proc get(r: Request; name: string): string =
  for (k, v) in r.headers:
    if cmpIgnoreCase(k, name) == 0: return v

proc param(r: Request; name: string): string =
  for (k, v) in formDecode(r.query):
    if k == name: return v

proc answer(c: Socket; meth: string; status: int; headers: openArray[(string, string)];
            body: string) =
  var head = "HTTP/1.1 " & $status & " " & (if status < 400: "OK" else: "Error") & "\r\n"
  for (k, v) in headers: head.add k & ": " & v & "\r\n"
  head.add "Content-Length: " & $body.len & "\r\nConnection: close\r\n\r\n"
  c.send(head)
  if meth != "HEAD" and body.len > 0: c.send(body)

var slowNow, slowMost: int     ## (the server's slow answers at once, the most of them)

proc handle(c: Socket; port: int) =
  var r: Request
  let first = c.recvLine(timeout = 10_000).split(' ')
  if first.len < 3: return
  r.meth = first[0]
  let q = first[1].find('?')
  r.path = if q < 0: first[1] else: first[1][0 ..< q]
  r.query = if q < 0: "" else: first[1][q + 1 .. ^1]
  while true:
    let line = c.recvLine(timeout = 10_000)
    if line.len == 0 or line == "\r\n": break
    let k = line.find(':')
    if k > 0: r.headers.add (line[0 ..< k].strip, line[k + 1 .. ^1].strip)
  let n = try: parseInt(r.get("Content-Length")) except ValueError: 0
  if n > 0: r.body = c.recv(n, timeout = 10_000)
  if r.path == "/echo":
    c.answer(r.meth, 200, {"Content-Type": "application/octet-stream", "X-Method": r.meth,
                           "X-Got-Test": r.get("X-Test"), "X-Got-Type": r.get("Content-Type"),
                           "X-Got-Agent": r.get("User-Agent"), "X-Got-Auth": r.get("Authorization"),
                           "X-Multi": "one", "X-Multi": "two", "X-Id": r.param("id")}, r.body)
  elif r.path.startsWith("/status/"):
    let s = parseInt(r.path[8 .. ^1])
    c.answer(r.meth, s, {"Content-Type": "text/plain"}, "status " & $s)
  elif r.path.startsWith("/redirect/"):
    var to = r.param("to")
    if to.startsWith("/"): to = "http://127.0.0.1:" & $port & to
    c.answer(r.meth, parseInt(r.path[10 .. ^1]), {"Location": to}, "moved")
  elif r.path == "/slow":
    # (how many of the threads' ones -- they have an id -- are being answered at once, and the
    # most: requests from threads overlap)
    let counted = r.param("id").len > 0
    if counted:
      let now = atomicInc(slowNow)
      if now > slowMost: slowMost = now
    sleep(parseInt(r.param("ms")))
    if counted: discard atomicDec(slowNow)
    c.answer(r.meth, 200, {"X-Id": r.param("id")}, "slow " & r.param("id"))
  elif r.path == "/gzip":
    if "gzip" in r.get("Accept-Encoding"):
      c.answer(r.meth, 200, {"Content-Encoding": "gzip", "Content-Type": "text/plain"}, gzipped)
    else:
      c.answer(r.meth, 200, {"Content-Type": "text/plain"}, "hello gzip ".repeat(20))
  else:
    c.answer(r.meth, 404, {"Content-Type": "text/plain"}, "no " & r.path)

proc worker(a: tuple[fd: SocketHandle; port: int]) {.thread.} =
  let server = newSocket(a.fd, AF_INET, SOCK_STREAM, IPPROTO_TCP)
  while true:
    var c: Socket
    try:
      server.accept(c)
    except OSError:
      continue
    try:
      handle(c, a.port)
    except CatchableError:
      discard
    c.close()

var workers: array[12, Thread[tuple[fd: SocketHandle; port: int]]]

proc startServer(port = 0): int =
  ## The server on 127.0.0.1 (its worker threads); its port.
  let s = newSocket()
  s.setSockOpt(OptReuseAddr, true)
  s.bindAddr(Port(port), "127.0.0.1")
  s.listen()
  result = int(s.getLocalAddr()[1])
  for w in workers.mitems: createThread(w, worker, (s.getFd, result))

# ---- the checks -------------------------------------------------------------------------

proc bodyOf(n: int): string =
  ## n bytes with every value 0..255.
  result = newString(n)
  for i in 0 ..< n: result[i] = char((i * 7 + i div 256) and 255)

var threadOk: array[8, bool]

proc client(a: tuple[base: string; first: int]) {.thread.} =
  for i in a.first .. a.first + 1:
    let body = "request " & $i & " " & bodyOf(1000 + i)
    let r = httpRequest("POST", a.base & "/echo?id=" & $i, {"Content-Type": "application/x-test"},
                        body = body)
    let s = httpRequest("GET", a.base & "/slow?ms=600&id=" & $i)
    threadOk[i] = r.status == 200 and r.body == body and r.header("x-id") == $i and
                  s.status == 200 and s.body == "slow " & $i

proc checks(base, mode: string) =
  let port = base.split(':')[^1]

  block methods:
    let r = httpRequest("GET", base & "/echo", {"X-Test": "hello there", "User-Agent": "RetroTest/1"})
    doAssert r.ok and r.status == 200 and r.error == "", mode & ": " & r.error
    doAssert r.header("X-Method") == "GET" and r.header("x-got-test") == "hello there"
    doAssert r.header("x-got-agent") == "RetroTest/1", r.header("x-got-agent")
    doAssert r.header("CONTENT-TYPE") == "application/octet-stream" and r.body == ""
    var multi: seq[string]
    for (k, v) in r.headers:
      doAssert k == k.toLowerAscii
      if k == "x-multi": multi.add v
    doAssert multi == @["one", "two"], $multi
    doAssert r.header("x-none") == ""
    let form = formEncode({"grant_type": "authorization_code", "code": "a b&c=d/é"})
    let p = httpRequest("POST", base & "/echo",
                        {"Content-Type": "application/x-www-form-urlencoded"}, body = form)
    doAssert p.status == 200 and p.header("x-method") == "POST" and p.body == form
    doAssert p.header("x-got-type") == "application/x-www-form-urlencoded"
    let json = """{"isRead": true, "subject": "Hello"}"""
    let pa = httpRequest("PATCH", base & "/echo", {"Content-Type": "application/json"}, body = json)
    doAssert pa.status == 200 and pa.header("x-method") == "PATCH" and pa.body == json, pa.header("x-method")
    let pu = httpRequest("PUT", base & "/echo", body = "put")
    doAssert pu.status == 200 and pu.header("x-method") == "PUT" and pu.body == "put"
    let d = httpRequest("DELETE", base & "/echo", {"Authorization": "Bearer t0ken"})
    doAssert d.status == 200 and d.header("x-method") == "DELETE" and d.body == ""
    doAssert d.header("x-got-auth") == "Bearer t0ken"
    let e = httpRequest("POST", base & "/echo")            # an empty POST
    doAssert e.status == 200 and e.header("x-method") == "POST" and e.body == ""
    let h = httpRequest("HEAD", base & "/echo")
    doAssert h.status == 200 and h.header("x-method") == "HEAD" and h.body == ""
    let lower = httpRequest("get", base & "/echo?id=a%20b c")   # (the space is sent as %20)
    doAssert lower.status == 200 and lower.header("x-method") == "GET" and lower.header("x-id") == "a b c"

  block binary:
    let big = bodyOf(1 shl 20)
    var seen: array[256, bool]
    for c in big: seen[ord(c)] = true
    for b in seen: doAssert b
    let t0 = epochTime()
    let r = httpRequest("POST", base & "/echo", {"Content-Type": "application/octet-stream"}, body = big)
    doAssert r.status == 200 and r.body.len == big.len and r.body == big, mode & ": " & $r.body.len
    let z = httpRequest("PUT", base & "/echo", body = "\0\1\2\0\xff")
    doAssert z.body == "\0\1\2\0\xff"
    echo "  ", mode, ": 1 MB both ways in ", formatFloat(epochTime() - t0, ffDecimal, 2), " s"

  block errors:
    let n = httpRequest("GET", base & "/status/404")
    doAssert n.status == 404 and not n.ok and n.body == "status 404" and n.error == ""
    let s = httpRequest("POST", base & "/status/500", body = "x")
    doAssert s.status == 500 and s.body == "status 500"
    let missing = httpRequest("GET", base & "/nothing/here")
    doAssert missing.status == 404 and missing.body == "no /nothing/here"
    let refused = httpRequest("GET", "http://127.0.0.1:1/", timeoutSec = 5)
    doAssert refused.status == 0 and refused.error.len > 0 and not refused.ok
    let notWeb = httpRequest("GET", "ftp://example.com/x")
    doAssert notWeb.status == 0 and "not a web address" in notWeb.error
    let badHeader = httpRequest("GET", base & "/echo", {"X-Bad": "a\r\nInjected: yes"})
    doAssert badHeader.status == 0 and "bad header" in badHeader.error

  block redirects:
    let f = httpRequest("GET", base & "/redirect/302?to=/echo%3Fid%3D7")
    doAssert f.status == 200 and f.header("x-method") == "GET" and f.header("x-id") == "7", $f.status
    let n = httpRequest("GET", base & "/redirect/302?to=/echo", followRedirects = false)
    doAssert n.status == 302 and n.header("location").endsWith("/echo") and n.body == "moved"
    let keep = httpRequest("POST", base & "/redirect/307?to=/echo", {"Content-Type": "text/plain"},
                           body = "kept")
    doAssert keep.status == 200 and keep.header("x-method") == "POST" and keep.body == "kept"
    let see = httpRequest("POST", base & "/redirect/303?to=/echo", body = "dropped")
    doAssert see.status == 200 and see.header("x-method") == "GET" and see.body == ""
    let p308 = httpRequest("PATCH", base & "/redirect/308?to=/echo", body = "patch")
    doAssert p308.status == 200 and p308.header("x-method") == "PATCH" and p308.body == "patch"
    # the token goes along on the same host, not to another one
    let same = httpRequest("GET", base & "/redirect/302?to=/echo", {"Authorization": "Bearer abc"})
    doAssert same.header("x-got-auth") == "Bearer abc"
    let other = httpRequest("GET", base & "/redirect/302?to=" &
                            urlEncode("http://localhost:" & port & "/echo"),
                            {"Authorization": "Bearer abc", "X-Test": "on"})
    doAssert other.status == 200 and other.header("x-got-auth") == "" and
             other.header("x-got-test") == "on", other.header("x-got-auth")
    let loop = httpRequest("GET", base & "/redirect/302?to=/redirect/302%3Fto%3D%2Fecho")
    doAssert loop.status == 200

  block compressed:
    let g = httpRequest("GET", base & "/gzip")
    doAssert g.status == 200 and g.body == "hello gzip ".repeat(20), mode & ": " & $g.body.len

  block timeout:
    # (an answer 8 s away, a second's patience: given up well before -- with room for a machine
    # busy with other tests)
    let t0 = epochTime()
    let r = httpRequest("GET", base & "/slow?ms=8000", timeoutSec = 1)
    let took = epochTime() - t0
    doAssert r.status == 0 and r.error.len > 0, $r.status
    doAssert took < 6.0, $took
    echo "  ", mode, ": timed out after ", formatFloat(took, ffDecimal, 1), " s: ", r.error

  block threads:
    # 8 requests (and 8 slow ones) from 4 threads at once: the slow ones answered side by side
    # (the server says how many at once; the time, with the machine busy with other tests, can
    # come near one after another's)
    for i in 0 ..< 8: threadOk[i] = false
    slowMost = 0
    let t0 = epochTime()
    var ts: array[4, Thread[tuple[base: string; first: int]]]
    for i in 0 ..< 4: createThread(ts[i], client, (base, i * 2))
    joinThreads(ts)
    let took = epochTime() - t0
    for i in 0 ..< 8: doAssert threadOk[i], mode & ": thread request " & $i
    if getEnv("RETRO_TEST_SERVER").len == 0:
      doAssert slowMost >= 2, mode & ": the slow requests one after another: " & $slowMost
    else:
      doAssert took < 2.4 * 1.5, $took          # one after another: 4.8 s and more
    echo "  ", mode, ": 16 requests from 4 threads in ", formatFloat(took, ffDecimal, 2), " s"

block encoding:
  doAssert urlEncode("") == ""
  doAssert urlEncode("AZaz09-._~") == "AZaz09-._~"
  doAssert urlEncode("a b+c/d?e=f&g") == "a%20b%2Bc%2Fd%3Fe%3Df%26g"
  doAssert urlEncode("é") == "%C3%A9" and urlEncode("\0\xff") == "%00%FF"
  doAssert formEncode({"a": "1", "b c": "x y", "e": ""}) == "a=1&b%20c=x%20y&e="
  doAssert formEncode([]) == ""
  doAssert urlDecode("a%20b+c%2Fd%zz%4") == "a b c/d%zz%4"
  doAssert formDecode("code=a%2Fb&state=x+y&flag&=v") ==
           @[("code", "a/b"), ("state", "x y"), ("flag", ""), ("", "v")]
  var all = ""
  for i in 0 .. 255: all.add char(i)
  doAssert urlDecode(urlEncode(all)) == all

if paramCount() >= 1 and paramStr(1) == "serve":
  let port = startServer(if paramCount() >= 2: parseInt(paramStr(2)) else: 18080)
  echo "serving on http://127.0.0.1:", port
  while true: sleep(1000)

let given = getEnv("RETRO_TEST_SERVER")
let base = if given.len > 0: given else: "http://127.0.0.1:" & $startServer()
when defined(windows):
  checks(base, "WinHTTP")
else:
  checks(base, "libcurl")
  putEnv("RETRO_HTTP_CURL_COMMAND", "1")
  checks(base, "curl command")
  delEnv("RETRO_HTTP_CURL_COMMAND")
echo "http: ok"

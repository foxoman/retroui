## Speed tests on worker threads, so the window never waits: the time to
## open a TCP connection to the server where the VPN would send lookups
## (the DoH host's 443, else the DNS-over-TLS port 853; plain-only servers:
## port 53). Two threads, there only while tests run: they come with the
## first test and end once every answer is in.

import std/uri

type
  TestJob* = object
    key*: string        ## the server's key ("" ends a worker)
    host*: string
    port*: int
  TestDone* = object
    key*: string
    ms*: int            ## the best connect, -1 none

proc urlHost*(url: string): string =
  ## "https://dns.example/dns-query" -> "dns.example"
  try: parseUri(url).hostname except CatchableError: ""

when defined(wasm) or defined(js):
  # (a web page opens no connections of its own: every test fails at once)
  var
    testsPending* = 0
    webDone: seq[TestDone]
  proc submitTest*(j: TestJob) = webDone.add TestDone(key: j.key, ms: -1)
  proc finishedTests*(): seq[TestDone] =
    result = webDone
    webDone.setLen(0)
else:
  import std/[net, nativesockets, monotimes, times, typedthreads]

  const Workers = 2

  var
    jobs: Channel[TestJob]
    done: Channel[TestDone]
    threads: array[Workers, Thread[void]]
    opened = false             ## the channels are open
    running = false            ## the workers are there
    testsPending* = 0          ## jobs sent and not answered yet

  proc connectMs(host: string; port: int): int =
    ## The best of two TCP connects to `host`:`port` (IPv4, then IPv6).
    result = -1
    for domain in [AF_INET, AF_INET6]:
      for i in 0 ..< 2:
        var s: Socket = nil
        try:
          s = newSocket(domain, SOCK_STREAM, IPPROTO_TCP, buffered = false)
          let t0 = getMonoTime()
          s.connect(host, Port(port), timeout = 3000)
          let ms = int((getMonoTime() - t0).inMilliseconds)
          if result < 0 or ms < result: result = ms
        except CatchableError:
          discard
        finally:
          if s != nil: s.close()
      if result >= 0: return

  proc worker() {.thread.} =
    while true:
      let j = jobs.recv()
      if j.key.len == 0: break
      done.send(TestDone(key: j.key, ms: connectMs(j.host, j.port)))

  proc submitTest*(j: TestJob) =
    ## Starts the test `j` (and the workers, when they are not there).
    if not opened:
      jobs.open()
      done.open()
      opened = true
    if not running:
      running = true
      for t in threads.mitems: createThread(t, worker)
    jobs.send(j)
    inc testsPending

  proc finishedTests*(): seq[TestDone] =
    ## The answers that came since the last call (call it every frame). The
    ## workers end once every answer is in.
    if not opened: return
    while true:
      let (got, d) = done.tryRecv()
      if not got: break
      dec testsPending
      result.add d
    if running and testsPending == 0:
      for i in 0 ..< Workers: jobs.send(TestJob())
      for t in threads.mitems: joinThread(t)
      running = false

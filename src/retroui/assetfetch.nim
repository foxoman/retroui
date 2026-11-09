## Downloads in the background, for the asset browser (`retroui/assetstore`):
## a few worker threads fetch web addresses into a cache folder, so the
## screen never waits for the network. Ask for an address, keep drawing,
## and take the files when they are there; what is in the cache (and young
## enough) comes back at once.
##
## .. code-block:: nim
##   assetCacheDir = dataDir("Retro Photo") / "Asset Cache"
##   let t = fetchAsync(item.thumbUrl, group = 1)
##   # every frame:
##   for r in fetchDone():
##     if r.ticket == t and r.path.len > 0: thumb = loadPicture(r.path, 160, 160)
##
## While downloads are waiting or running, the toolkit keeps the frames
## coming (a frame every 30 ms), so results show up without input.
## Requests can be put in a `group` and dropped together (`cancelFetches`):
## the thumbnails of a page that is no longer shown. The same address asked
## twice is downloaded once.
##
## Desktops download with curl (or wget), see `retroui/fetch`; Android with
## Java's own HTTP (tools/android/RetroNet.java, which any thread may call;
## the APK needs the INTERNET permission).

import std/[os, strutils, times, locks, algorithm, sequtils]
when compileOption("threads"):
  import std/typedthreads
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import core
when androidApp:
  import uirelays/services
elif not defined(ios):
  import fetch

var
  assetCacheDir*: string
    ## Where downloads are kept; the app sets it (`dataDir(app) / "Asset
    ## Cache"`). Created as needed. "": a folder in the system's temp folder.
  assetUserAgent* = "RetroPhoto/4.5 (https://github.com/foxoman)"
    ## Sent with every request: Wikimedia and Poly Haven ask for a name that
    ## says which program asks (and how to reach its maker).
  assetFetchThreads* = 2
    ## How many downloads run at once (1 to 4); read when the first download
    ## starts.
  assetFetchTimeoutSec* = 300
    ## The longest a background download may take (curl counts the whole
    ## download; Android's Java the wait for each piece).

type
  FetchResult* = object
    ## A finished download (`fetchDone`): where the file is, or why it
    ## is not there.
    ticket*: int             ## what `fetchAsync` returned
    url*, path*: string      ## path: the file in the cache ("" on failure)
    error*: string           ## why it failed ("" when it did not)
    group*: int              ## the group it was asked in
    cached*: bool            ## it was in the cache: nothing was downloaded
    stale*: bool             ## the download failed, `path` is an older copy

  Waiter = tuple[ticket, group: int]
  Job = object
    id: int
    url, base, agent: string # base: the cache file without its extension
    priority: int
    timeoutSec: int
    waiters: seq[Waiter]     # who wants it (the same address asked again joins)

when compileOption("threads"):
  var workers: seq[Thread[void]]
var
  lock: Lock
  cond: Cond
  todo: seq[Job]                   # guarded by lock
  active: seq[Job]                 # guarded by lock: being downloaded
  done: seq[FetchResult]           # guarded by lock
  paused = false                   # guarded by lock
  started = false
  # UI thread only:
  ready: seq[FetchResult]          # handed over by the next `fetchDone`
  pendingCount = 0                 # asked, and not yet handed over
  nextTicket = 1
  nextJob = 1

# ---- the cache -------------------------------------------------------------------

const
  knownExts = ["jpg", "png", "webp", "gif", "svg", "json", "zip", "psd", "abr", "pat",
               "aco", "ase", "grd", "rpd", "asl", "hdr", "exr", "tif", "tiff", "bmp",
               "txt", "csv", "xml", "heic", "avif", "pdf", "ttf", "otf"]
  sniffedExts = ["jpg", "png", "webp", "gif", "svg", "json", "zip", "psd", "pdf", "bin"]

proc fnv64(s: string): uint64 =
  result = 0xcbf29ce484222325'u64
  for c in s:
    result = (result xor uint64(ord(c))) * 0x100000001b3'u64

proc withHeaders*(url: string; headers: openArray[(string, string)]): string =
  ## `url` with request headers to send with it (an API key: Pexels'
  ## "Authorization"): for `fetchAsync` and `fetchNow`, which send them --
  ## on every system, Android too -- and keep the answer in the cache under
  ## the whole of it. (They follow the address after a line break, which no
  ## address has.)
  result = url
  for (k, v) in headers:
    if k.len > 0 and '\n' notin k and '\n' notin v and '\r' notin k and '\r' notin v:
      result.add "\n" & k & ": " & v

proc splitHeaders*(url: string): tuple[url: string; headers: seq[(string, string)]] =
  ## The address and the headers `withHeaders` put after it.
  let parts = url.split('\n')
  result.url = parts[0]
  for i in 1 ..< parts.len:
    let c = parts[i].find(':')
    if c > 0: result.headers.add (parts[i][0 ..< c].strip, parts[i][c + 1 .. ^1].strip)

proc extOfUrl*(url: string): string =
  ## The kind of file an address names, by its extension, lower case
  ## ("jpeg" -> "jpg"); a `format=` in its query wins (Poly Haven's
  ## thumbnails: `x.png?format=webp`), and an address without one takes it
  ## from a `file=` (ambientCG's `get?file=X_2K-JPG.zip`). "" when none.
  var path = url
  let nl = path.find('\n')
  if nl >= 0: path.setLen(nl)                  # (the headers: `withHeaders`)
  var query = ""
  let h = path.find('#')
  if h >= 0: path.setLen(h)
  let q = path.find('?')
  if q >= 0:
    query = path[q + 1 .. ^1]
    path.setLen(q)
  var fromQuery, fromFile = ""
  for pair in query.split('&'):
    let eq = pair.find('=')
    if eq <= 0: continue
    let (k, v) = (pair[0 ..< eq].toLowerAscii, pair[eq + 1 .. ^1])
    if k == "format": fromQuery = v.toLowerAscii
    elif k == "file": fromFile = v
  proc extIn(p: string): string =
    let slash = max(p.rfind('/'), p.rfind("%2F"))
    let dot = p.rfind('.')
    if dot > slash and dot < p.len - 1: p[dot + 1 .. ^1].toLowerAscii else: ""
  result = if fromQuery.len > 0: fromQuery else: extIn(path)
  if result.len == 0 and fromFile.len > 0: result = extIn(fromFile)
  if result == "jpeg": result = "jpg"
  for c in result:
    if c notin {'a'..'z', '0'..'9'}: result = ""; return
  if result.len > 5: result = ""

proc cacheDir(): string =
  if assetCacheDir.len > 0: assetCacheDir else: getTempDir() / "retro-asset-cache"

proc cacheBase(url: string): string =
  ## The cache file of `url`, without its extension.
  cacheDir() / toHex(fnv64(url), 16).toLowerAscii

proc candidates(url: string): seq[string] =
  let e = extOfUrl(url)
  if e.len > 0: result.add e
  for x in sniffedExts:
    if x != e: result.add x

proc sniffExt(path, urlExt: string): string {.gcsafe.} =
  ## The kind of file `path` holds, by its first bytes (a JSON answer, an
  ## SVG, a WebP sent for a .png address...); else what the address says.
  var head = newString(512)
  var n = 0
  try:
    var f = open(path)
    n = f.readBuffer(addr head[0], head.len)
    f.close()
  except IOError, OSError: discard
  head.setLen(max(n, 0))
  if head.startsWith("\xFF\xD8\xFF"): return "jpg"
  if head.startsWith("\x89PNG"): return "png"
  if head.startsWith("GIF8"): return "gif"
  if head.len >= 12 and head.startsWith("RIFF") and head[8 .. 11] == "WEBP": return "webp"
  if head.startsWith("PK\x03\x04") or head.startsWith("PK\x05\x06"): return "zip"
  if head.startsWith("8BPS"): return "psd"
  if head.startsWith("%PDF"): return "pdf"
  let t = head.strip(trailing = false)
  if t.startsWith("{") or t.startsWith("["): return "json"
  if t.startsWith("<") and "<svg" in head: return "svg"
  if urlExt in knownExts: return urlExt
  "bin"

proc cachedPath*(url: string; maxAgeSec = 7 * 24 * 3600): string =
  ## The file in the cache for `url` when there is one no older than
  ## `maxAgeSec` (negative: of any age); "" when not.
  if url.len == 0: return ""
  let base = cacheBase(url)
  for e in candidates(url):
    let p = base & "." & e
    if fileExists(p):
      if maxAgeSec < 0: return p
      let age = try: (getTime() - getLastModificationTime(p)).inSeconds except OSError: high(int64)
      return (if age <= maxAgeSec: p else: "")
  ""

proc trimAssetCache*(maxBytes: int64) =
  ## Deletes the least recently downloaded files of the cache until it holds
  ## no more than `maxBytes`.
  var files: seq[tuple[t: Time; size: int64; path: string]]
  var total = 0'i64
  try:
    for kind, p in walkDir(cacheDir()):
      if kind != pcFile: continue
      let n = p.extractFilename
      if n.endsWith(".part") or n.endsWith(".download"): continue
      let size = try: getFileSize(p) except OSError: 0'i64
      let t = try: getLastModificationTime(p) except OSError: fromUnix(0)
      files.add (t, size, p)
      total += size
  except OSError: return
  files.sort(proc (a, b: tuple[t: Time; size: int64; path: string]): int = cmp(a.t, b.t))
  for f in files:
    if total <= maxBytes: break
    try:
      removeFile(f.path)
      total -= f.size
    except OSError: discard

# ---- downloading ------------------------------------------------------------------

proc downloadTo(whole, dest, agent: string; timeoutSec: int): string {.gcsafe.} =
  ## `whole` (an address, with headers: `withHeaders`) into the file `dest`
  ## (whole or not at all): "" when it worked, else what went wrong. Safe
  ## on any thread.
  let (url, headers) = splitHeaders(whole)
  if url.len == 0: return "no address"
  when androidApp:
    if '\t' in url or '\t' in dest: return "bad address"
    try: createDir(dest.parentDir) except OSError: discard
    var hs: seq[string]
    for (k, v) in headers:
      if '\t' notin k and '\t' notin v: hs.add k & ": " & v
    let r = systemCall("net.download", url & "\t" & dest & "\t" &
                       agent.replace('\t', ' ') & "\t" & $(max(1, timeoutSec) * 1000) & "\t" &
                       hs.join("\r"))
    if r == "1": ""
    elif r.len > 1 and r[0] == 'e': r[1 .. ^1]
    elif r == "\0": "downloading is not available (the app's Java part is older than this program)"
    else: "the download failed"
  elif defined(ios):
    "downloading is not done on iOS yet"
  else:
    {.cast(gcsafe).}:
      downloadFile(url, dest, agent, timeoutSec, headers)

proc fetchNow*(url: string; dest: string; timeoutSec = 120): string =
  ## Downloads `url` into the file `dest` and waits for it (for the
  ## full-size file the user picked; a busy box can show meanwhile): "" when
  ## it worked, else what went wrong. A fresh copy in the cache is copied.
  let hit = cachedPath(url)
  if hit.len > 0:
    try:
      createDir(dest.parentDir)
      copyFile(hit, dest)
      return ""
    except OSError, IOError: discard
  downloadTo(url, dest, assetUserAgent, timeoutSec)

proc workOne(waitForOne: bool): bool {.gcsafe.} =
  ## One download (the most urgent): false when there was none to do
  ## (`waitForOne`: waits for one, on a worker thread).
  var job: Job
  {.cast(gcsafe).}:
    acquire(lock)
    if waitForOne:
      while todo.len == 0 or paused: wait(cond, lock)
    elif todo.len == 0 or paused:
      release(lock)
      return false
    # the most urgent, and of those the newest (what the user looks at now)
    var best = todo.high
    for i in countdown(todo.high, 0):
      if todo[i].priority > todo[best].priority: best = i
    job = move todo[best]
    todo.delete(best)
    # (its waiters stay where `fetchAsync` and `cancelFetches` see them)
    active.add Job(id: job.id, url: job.url, waiters: move job.waiters)
    release(lock)
  let tmp = job.base & ".download"
  let urlExt = extOfUrl(job.url)
  var err = downloadTo(job.url, tmp, job.agent, job.timeoutSec)
  var path = ""
  var stale = false
  if err.len == 0:
    let final = job.base & "." & sniffExt(tmp, urlExt)
    for e in @knownExts & @sniffedExts:            # an older copy of another kind
      let old = job.base & "." & e
      if old != final and fileExists(old):
        try: removeFile(old) except OSError: discard
    try:
      moveFile(tmp, final)
      path = final
    except OSError as e:
      err = e.msg
  if path.len == 0:
    try: removeFile(tmp) except OSError: discard
    # offline: an older copy is better than nothing
    for e in (if urlExt.len > 0: @[urlExt] else: @[]) & @knownExts & @sniffedExts:
      if fileExists(job.base & "." & e):
        path = job.base & "." & e
        stale = true
        err = ""
        break
  {.cast(gcsafe).}:
    acquire(lock)
    var waiters: seq[Waiter]
    for i in 0 ..< active.len:
      if active[i].id == job.id:
        waiters = move active[i].waiters
        active.delete(i)
        break
    for w in waiters:
      done.add FetchResult(ticket: w.ticket, group: w.group, url: job.url, path: path,
                           error: err, stale: stale)
    release(lock)
  true

when compileOption("threads"):
  proc work() {.thread.} =
    while true: discard workOne(true)

proc start() =
  if started: return
  started = true
  initLock(lock)
  initCond(cond)
  when compileOption("threads"):
    let n = clamp(assetFetchThreads, 1, 4)
    workers.setLen(n)
    for i in 0 ..< n: createThread(workers[i], work)

proc pump() =
  ## Moves what the workers finished to the UI thread's side and keeps the
  ## frames coming while downloads wait or run.
  if not started: return
  when not compileOption("threads"):
    # (a web page without threads: one download a frame, here)
    discard workOne(false)
  var got: seq[FetchResult]
  var busy = false
  withLock lock:
    got = move done
    done = @[]
    busy = todo.len > 0 or active.len > 0
  if busy: wakeIn(30)
  if got.len > 0:
    ui.redraw = true
    ready.add got

proc fetchAsync*(url: string; group = 0; priority = 0; maxAgeSec = 7 * 24 * 3600): int =
  ## Downloads `url` into the cache on a worker thread; returns the ticket
  ## its `FetchResult` will carry (see `fetchDone`). A cached file no older
  ## than `maxAgeSec` comes back at once (still through `fetchDone`), as
  ## does an empty address (failed). Higher `priority` goes first; of the
  ## same priority the newest goes first.
  result = nextTicket
  inc nextTicket
  inc pendingCount
  let hit = if url.len > 0: cachedPath(url, maxAgeSec) else: ""
  if url.len == 0 or hit.len > 0:
    ready.add FetchResult(ticket: result, group: group, url: url, path: hit, cached: hit.len > 0,
                          error: (if hit.len > 0: "" else: "no address"))
    wakeIn(1)
    return
  start()
  try: createDir(cacheDir()) except OSError: discard
  var joined = false
  withLock lock:
    for j in todo.mitems:
      if j.url == url:
        j.waiters.add (result, group)
        j.priority = max(j.priority, priority)
        joined = true
        break
    if not joined:
      for j in active.mitems:
        if j.url == url:
          j.waiters.add (result, group)
          joined = true
          break
    if not joined:
      todo.add Job(id: nextJob, url: url, base: cacheBase(url), agent: assetUserAgent,
                   priority: priority, timeoutSec: assetFetchTimeoutSec, waiters: @[(result, group)])
      inc nextJob
  signal(cond)
  wakeIn(30)

proc fetchDone*(): seq[FetchResult] =
  ## The results that came in since the last call (call it on the UI
  ## thread, every frame the results are wanted).
  pump()
  result = move ready
  ready = @[]
  pendingCount -= result.len

proc fetchPending*(): int =
  ## How many requests are not handed over yet (waiting, downloading, or
  ## done and not taken by `fetchDone`).
  pendingCount

proc cancelFetches*(group: int) =
  ## Drops the requests of `group`: those not started are not downloaded,
  ## and no result comes for any of them. (A download already running
  ## finishes into the cache.)
  var dropped = 0
  if started:
    withLock lock:
      var i = 0
      while i < todo.len:
        let before = todo[i].waiters.len
        todo[i].waiters.keepItIf(it.group != group)
        dropped += before - todo[i].waiters.len
        if todo[i].waiters.len == 0: todo.delete(i) else: inc i
      for j in active.mitems:
        let before = j.waiters.len
        j.waiters.keepItIf(it.group != group)
        dropped += before - j.waiters.len
      let before = done.len
      done.keepItIf(it.group != group)
      dropped += before - done.len
  let before = ready.len
  ready.keepItIf(it.group != group)
  dropped += before - ready.len
  pendingCount -= dropped

proc pauseFetches*(pause: bool) =
  ## Holds the downloads that have not started (a metered network, a test),
  ## or lets them go again.
  start()
  withLock lock:
    paused = pause
  if not pause: broadcast(cond)

beginFrameHooks.add pump

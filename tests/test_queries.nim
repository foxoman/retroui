## Tests of retroui/queries on a clock of the test's own: an entry asked for by two pages is
## loaded once; its value is kept while it is loaded again (out of date, too old); a failed load
## is tried again later, then told; a change put in at once; an entry nobody asks for let go of;
## another type under a key is another entry.

import std/[atomics, strutils]
from std/os import nil
import retroui, retroui/[headless, queries]
import retroui/uirelays/input

useHeadless(300, 200)
startApp("Queries", 300, 200)
var clock = 1000
inputRelays.getTicks = proc (): int = clock

var loads: Atomic[int]
var failNext: Atomic[int]          ## (the next loads to fail)

proc loadList(): seq[string] {.gcsafe.} =
  let n = loads.fetchAdd(1) + 1
  if failNext.load > 0:
    discard failNext.fetchSub(1)
    raise newException(IOError, "the server is down")
  os.sleep(5)
  @["one", "two", "load " & $n]

template frame(ms: int; body: untyped) =
  clock += ms
  discard beginFrame()
  body
  endFrame()

proc until(key: string; cond: proc (q: Query[seq[string]]): bool; maxAge = 0; retries = 1;
           limit = 400): Query[seq[string]] =
  ## (frames until `cond`: the jobs end on their threads in real time)
  for i in 0 ..< limit:
    frame(16): result = query(key, loadList, maxAge = maxAge, retries = retries)
    if cond(result): return
    os.sleep(2)
  doAssert false, "never: " & key & " " & $result.state

block loadedOnceForEveryPage:
  loads.store(0)
  var a, b: Query[seq[string]]
  frame(16):
    a = query("list", loadList)          # (one page)
    b = query("list", loadList)          # (another, the same frame)
  doAssert a.loading and not a.has and b.loading
  let q = until("list", proc (q: Query[seq[string]]): bool = q.ready)
  doAssert q.value == @["one", "two", "load 1"] and q.has and q.loadedAt > 0
  doAssert loads.load == 1, "loaded once: " & $loads.load
  frame(16): b = query("list", loadList)
  doAssert b.ready and b.value == q.value and loads.load == 1

block keptWhileLoadedAgain:
  invalidate("li")                        # (every key starting so)
  var q: Query[seq[string]]
  frame(16): q = query("list", loadList)
  doAssert q.loading and q.has and q.value[2] == "load 1", "the old value shown meanwhile"
  q = until("list", proc (q: Query[seq[string]]): bool = q.ready)
  doAssert q.value[2] == "load 2" and loads.load == 2

block tooOld:
  var q = until("aged", proc (q: Query[seq[string]]): bool = q.ready, maxAge = 60_000)
  let n = loads.load
  frame(30_000): q = query("aged", loadList, maxAge = 60_000)
  doAssert q.ready and loads.load == n, "not old yet"
  frame(31_000): q = query("aged", loadList, maxAge = 60_000)
  doAssert q.loading and q.has, "too old: loaded again, its value kept"
  q = until("aged", proc (q: Query[seq[string]]): bool = q.ready, maxAge = 60_000)
  doAssert loads.load == n + 1

block failedTriedAgainThenTold:
  failNext.store(1)
  var q = until("flaky", proc (q: Query[seq[string]]): bool = loads.load >= 1 and q.loading, retries = 1,
                limit = 5)
  # the first load fails: still loading, tried again a second later
  for i in 0 ..< 20:
    frame(16): q = query("flaky", loadList, retries = 1)
    os.sleep(2)
  doAssert q.loading and not q.failed, "waiting to try again"
  frame(1100): q = query("flaky", loadList, retries = 1)
  q = until("flaky", proc (q: Query[seq[string]]): bool = q.ready, retries = 1)
  doAssert q.value.len == 3 and q.error == ""
  # no tries left: told
  failNext.store(5)
  q = until("down", proc (q: Query[seq[string]]): bool = q.failed, retries = 0)
  doAssert not q.has and "server is down" in q.error, q.error
  # a value had, a load again fails: the value kept, the error told
  failNext.store(0)
  invalidate("down")
  q = until("down", proc (q: Query[seq[string]]): bool = q.ready, retries = 0)
  failNext.store(1)
  invalidate("down")
  q = until("down", proc (q: Query[seq[string]]): bool = q.failed, retries = 0)
  doAssert q.has and q.value.len == 3 and q.error.len > 0
  failNext.store(0)

block putInAtOnce:
  setQuery("list", @["mine"])
  var q: Query[seq[string]]
  frame(16): q = query("list", loadList)
  doAssert q.ready and q.value == @["mine"], $q.value
  setQuery("fresh", @["new"])            # (not asked for yet)
  frame(16): q = query("fresh", loadList)
  doAssert q.ready and q.value == @["new"]

block anotherTypeAnotherEntry:
  var n: Query[int]
  frame(16): n = query("list", proc (): int {.gcsafe.} = 42)
  for i in 0 ..< 400:
    frame(16): n = query("list", proc (): int {.gcsafe.} = 42)
    if n.ready: break
    os.sleep(2)
  doAssert n.ready and n.value == 42

block letGoOf:
  let before = queriesHeld()
  doAssert before >= 4
  var q: Query[seq[string]]
  frame(400_000): q = query("kept", loadList, keepFor = 1_000_000)
  frame(16): discard
  doAssert queriesHeld() <= 2, "the others nobody asked for, let go of: " & $queriesHeld()
  forgetQueries()
  doAssert queriesHeld() == 0

stopApp()
echo "test_queries: ok"

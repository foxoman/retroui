## How the persistent collections (retroui/persist) do against copying seqs and tables: making
## one, reading it, keeping every version for undo, finding what changed. `nim c -r -d:release
## tests/bench_persist.nim`; the numbers in docs/benchmarks.md.

import std/[tables, monotimes, times, random, strutils]
import retroui/persist

proc rss(): int =
  ## (the memory in use: resident, from /proc on Linux; 0 elsewhere)
  try: parseInt(readFile("/proc/self/statm").split(' ')[1]) * 4096
  except CatchableError, IOError: 0

const N = 100_000
const Steps = 1_000

template timed(what: string; body: untyped) =
  let t0 = getMonoTime()
  body
  let ms = (getMonoTime() - t0).inNanoseconds.float / 1e6
  echo alignLeft(what, 52), formatFloat(ms, ffDecimal, 2).align(10), " ms"


randomize(1)
var keys = newSeq[int](Steps)
for i in 0 ..< Steps: keys[i] = rand(N - 1)

echo "== a map of ", N, " ints"
var t: Table[int, int]
timed "Table: made": (for i in 0 ..< N: t[i] = i)
var m: PMap[int, int]
timed "PMap: made, one put at a time": (for i in 0 ..< N: m = m.put(i, i))
var s1 = 0
timed "Table: read all": (for i in 0 ..< N: s1 += t[i])
var s2 = 0
timed "PMap: read all": (for i in 0 ..< N: s2 += m[i])
doAssert s1 == s2

echo "== ", Steps, " edits, every version kept (undo)"
GC_fullCollect()
let base = rss()
var tv: seq[Table[int, int]]
timed "Table: copied for each (the first 100 only)": (for k in keys[0 ..< 100]: (var c = (if tv.len > 0: tv[^1] else: t); c[k] = -1; tv.add c))
echo "  kept for 100: ", (rss() - base) div (1024 * 1024), " MB (for 1000: ten times that)"

GC_fullCollect()
let base2 = rss()
var mv: seq[PMap[int, int]]
timed "PMap: a new version for each": (for k in keys: (let next = (if mv.len > 0: mv[^1] else: m).put(k, -1); mv.add next))
echo "  kept: ", (rss() - base2) div 1024, " KB"

echo "== what changed between two versions (", 10, " keys apart)"
var b = mv[^1]
for i in 0 ..< 10: b = b.put(N + i, i)
var found = 0
timed "Table: every key compared": (block:
  let ta = t
  var tb = t
  for i in 0 ..< 10: tb[N + i] = i
  for k, x in tb:
    if k notin ta or ta[k] != x: inc found)
doAssert found == 10
timed "PMap: diff": (found = diff(mv[^1], b).len)
doAssert found == 10

echo "== a vector of ", N, " ints"
var sq: seq[int]
timed "seq: made": (for i in 0 ..< N: sq.add i)
var pv = initPVec[int]()
timed "PVec: made, one add at a time": (for i in 0 ..< N: pv = pv.add(i))
var bv: PVec[int]
timed "PVec: made with a builder": (block:
  var bb = vecBuilder[int](N)
  for i in 0 ..< N: bb.add i
  bv = freeze(bb))
var r1, r2 = 0
timed "seq: read all": (for i in 0 ..< N: r1 += sq[i])
timed "PVec: read all": (for i in 0 ..< N: r2 += pv[i])
doAssert r1 == r2
GC_fullCollect()
let base3 = rss()
var sv: seq[seq[int]]
timed "seq: copied for each of the edits (the first 100)": (for k in keys[0 ..< 100]: (var c = (if sv.len > 0: sv[^1] else: sq); c[k] = -1; sv.add c))
echo "  kept for 100: ", (rss() - base3) div (1024 * 1024), " MB (for 1000: ten times that)"

GC_fullCollect()
let base4 = rss()
var pvs: seq[PVec[int]]
timed "PVec: a new version for each of the edits": (for k in keys: (let next = (if pvs.len > 0: pvs[^1] else: pv).set(k, -1); pvs.add next))
echo "  kept: ", (rss() - base4) div 1024, " KB"

echo "== a text of 1 MB, 1000 edits kept"
var text = newString(1_000_000)
for i in 0 ..< text.len: text[i] = char(ord('a') + i mod 26)
var rope = toRope(text)
var ropes: seq[Rope]
GC_fullCollect()
let base6 = rss()
timed "Rope: an insert each, every version kept": (for k in keys: (rope = rope.insert(k * 7, "x"); ropes.add rope))
echo "  kept for 1000: ", (rss() - base6) div 1024, " KB"
var strs: seq[string]
GC_fullCollect()
let base5 = rss()
timed "string: an insert each, every version kept (100)": (for k in keys[0 ..< 100]: (text.insert("x", k * 7); strs.add text))
echo "  kept for 100: ", (rss() - base5) div (1024 * 1024), " MB (for 1000: ten times that)"

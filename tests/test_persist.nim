## The persistent collections (retroui/persist) against seqs and tables, old versions kept as they
## were; diff; the rope; NIF (retroui/nif) of values and of them; an app's state kept
## (retroui/appstate) as it is paused and read back.

import std/[tables, random, sequtils, sets, algorithm, strutils]
import std/os
import retroui, retroui/persist
import retroui/uirelays/input
import harness
randomize(7)
# vector against a seq
var v = initPVec[int]()
var s: seq[int]
var olds: seq[(PVec[int], seq[int])]
for step in 0 ..< 20000:
  let r = rand(99)
  if r < 60 or s.len == 0:
    v = v.add(step); s.add step
  elif r < 80:
    let i = rand(s.high); v = v.set(i, -step); s[i] = -step
  else:
    v = v.pop(); s.setLen(s.len - 1)
  if step mod 997 == 0: olds.add (v, s)
  doAssert v.len == s.len
doAssert v.toSeq == s
for (ov, os) in olds: doAssert ov.toSeq == os, "an old version changed"
let big = toPVec(toSeq(0 ..< 100000))
doAssert big.len == 100000 and big[99999] == 99999 and big[31] == 31 and big[32] == 32 and big[1056] == 1056
# map against a table
var m = initPMap[int, int]()
var t: Table[int, int]
var oldm: seq[(PMap[int, int], Table[int, int])]
for step in 0 ..< 30000:
  let k = rand(3000)
  if rand(9) < 7:
    m = m.put(k, step); t[k] = step
  else:
    m = m.del(k); t.del(k)
  if step mod 1499 == 0: oldm.add (m, t)
doAssert m.len == t.len
for k, x in t: doAssert m[k] == x
var c = 0
for k, x in m: (doAssert t[k] == x; inc c)
doAssert c == t.len
for (om, ot) in oldm:
  doAssert om.len == ot.len
  for k, x in ot: doAssert om[k] == x
# diff
let a = m
var b = m
var expect: seq[(ChangeKind, int)]
b = b.put(100001, 1); expect.add (ckAdded, 100001)
for k in a.keys:
  b = b.del(k); expect.add (ckRemoved, k); break
var changedK = -1
for k in a.keys:
  if k notin expect.mapIt(it[1]): (b = b.put(k, -9); changedK = k; expect.add (ckChanged, k); break)
var got = diff(a, b).mapIt((it.kind, it.key))
doAssert got.sorted == expect.sorted, $got & " vs " & $expect
doAssert diff(a, a).len == 0
# rope
var rs = ""
var rope = toRope("")
for step in 0 ..< 3000:
  let i = rand(rs.len)
  if rand(9) < 7 or rs.len < 10:
    let piece = $step & "-"
    rope = rope.insert(i, piece); rs.insert(piece, i)
  else:
    let j = min(rs.len, i + rand(20))
    rope = rope.delete(i, j); rs = rs[0 ..< i] & rs[j .. ^1]
doAssert $rope == rs and rope.len == rs.len
doAssert rope.substr(10, 50) == rs[10 ..< 50]
doAssert rope[rs.len div 2] == rs[rs.len div 2]
# NIF
type St = object
  v: PVec[string]
  m: PMap[string, int]
  s: PSet[int]
  r: Rope
  b: Box[seq[int]]
let st = St(v: toPVec(@["a", "b"]), m: toPMap({"x": 1, "y": 2}), s: toPSet([3, 4]), r: toRope("hello"), b: box(@[1, 2]))
let txt = toNif(st)
let st2 = fromNif(txt, St)
doAssert st2.v == st.v and st2.m == st.m and st2.s == st.s and st2.r == st.r and st2.b == st.b

# NIF of the usual types
type
  Kind = enum kA, kB
  Song = object
    title: string
    seconds: int
    rating: float
    tags: seq[string]
    kind: Kind
    pos: tuple[x, y: int]
    marks: set[char]
let songs = @[Song(title: "In \"(tro)\"\n", seconds: 74, rating: 4.5, tags: @["a b"], kind: kB, pos: (1, -2), marks: {'a', '#'})]
doAssert fromNif(toNif(songs), seq[Song]) == songs
doAssert fromNif(toNif(-0.001), float) == -0.001 and fromNif(toNif(Inf), float) == Inf
doAssert parseNif("(.nif27)\n(x 1 \"a\" 2u 'c' . 1.5E2)").kids.len == 6
try:
  discard fromNif("(list 1 2", seq[int])
  doAssert false, "a tree not closed: an error"
except NifError: discard
echo "  ok   NIF"
# an app's state, kept as it is paused
let home = getTempDir() / "retro-appstate"
removeDir(home)
stateFolder = home
fakeDriver()
startApp("State", W, H)
type Page = object
  tab: int
  scroll: int
  draft: string
var page = restoreState("main", Page(tab: 1))
doAssert page.tab == 1, "the first time: the default"
view = proc () =
  keepState("main", page)
  label "x"
run(2)
page.tab = 3
page.draft = "Dear Sultan,"
harness.queue.add Event(kind: AppPauseEvent)
run(2)
doAssert fileExists(statePath("main")), "paused: written"
let back = restoreState("main", Page())
doAssert back == page, $back
echo "  ok   the state kept as the app was paused, read back"
echo "persist ok"

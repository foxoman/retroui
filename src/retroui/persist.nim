## Persistent collections: values that are never changed in place -- a change makes a new value
## that shares all it didn't change with the old one. Keeping the state of a screen before and
## after an edit, a hundred undo steps of a big document, the last frame's list to compare with
## this one's: each costs only what changed, and telling two of them apart skips all they share
## (`diff`). (Their counts are not atomic: a version handed to another thread goes as a copy --
## `toSeq`, or NIF.)
##
## - `PVec[T]`: a vector -- index, add, set, pop -- a tree of 32-wide nodes with its last ones
##   apart: `add` and `[]` in near constant time, a change copying a path of a few nodes.
## - `PMap[K, V]`, `PSet[K]`: a map and a set, a hash trie (CHAMP: its nodes kept in one
##   canonical shape, so equal maps are built alike and `diff` goes straight to what differs).
## - `Rope`: a long text as a balanced tree of pieces: insert, delete and cut in log time, its
##   pieces shared by every version (an editor's undo, a log that grows).
## - `Box[T]`: one value shared by reference, never changed (a big picture, a parsed file).
##
## Builders (`vecBuilder`, `mapBuilder`) make a large one at once without the copies, and the
## collections are written to and read from NIF (`retroui/nif`), so an app's state kept with
## them is saved as it is (`keepState`).
##
## ```nim
## import retroui/persist                 # (not brought by `import retroui`: Box, Rope, diff...)
## var songs = toPVec(@["Intro", "Song 2"])
## let before = songs                    # (nothing copied)
## songs = songs.add("Outro")
## doAssert before.len == 2 and songs.len == 3
## var tags = initPMap[string, int]()
## tags = tags.put("rock", 3)
## for change in diff(oldTags, tags): echo change   # added, removed, changed keys only
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[hashes, bitops]
import nif

const
  Bits = 5
  Width = 1 shl Bits            # 32
  Mask = Width - 1

# ---- Box ----------------------------------------------------------------------------------------

type
  BoxObj[T] = object
    val: T
  Box*[T] = object
    ## One value shared by reference, never changed.
    p: ref BoxObj[T]

proc box*[T](v: sink T): Box[T] =
  ## `v` in a box: copies of the box share it.
  result.p = (ref BoxObj[T])(val: v)

proc `[]`*[T](b: Box[T]): lent T =
  ## The value in the box.
  b.p.val

proc isNil*[T](b: Box[T]): bool = b.p == nil
  ## An empty box (`default(Box[T])`).

proc `==`*[T](a, b: Box[T]): bool =
  ## The same box, or boxes of equal values.
  a.p == b.p or (a.p != nil and b.p != nil and a.p.val == b.p.val)

proc same*[T](a, b: Box[T]): bool = a.p == b.p
  ## The very same box (not only equal values): a change between them is sure to be none.

# ---- PVec ---------------------------------------------------------------------------------------

type
  VNode[T] = ref object
    kids: seq[VNode[T]]   # (inner nodes)
    vals: seq[T]          # (leaves)

  PVec*[T] = object
    ## A persistent vector (see the module's notes).
    cnt: int
    shift: int = Bits
    root: VNode[T]
    tail: seq[T]

proc len*[T](v: PVec[T]): int {.inline.} = v.cnt
  ## How many items it has.

proc tailOff[T](v: PVec[T]): int {.inline.} =
  if v.cnt < Width: 0 else: ((v.cnt - 1) shr Bits) shl Bits

proc leafFor[T](v: PVec[T]; i: int): ptr seq[T] =
  if i >= v.tailOff: return unsafeAddr v.tail
  var node = v.root
  var level = v.shift
  while level > 0:
    node = node.kids[(i shr level) and Mask]
    level -= Bits
  unsafeAddr node.vals

proc `[]`*[T](v: PVec[T]; i: int): lent T =
  ## The item at `i` (0 the first); `IndexDefect` outside `0 ..< len`.
  if i < 0 or i >= v.cnt: raise newException(IndexDefect, "index " & $i & " not in 0 .. " & $(v.cnt - 1))
  v.leafFor(i)[][i and Mask]

proc `[]`*[T](v: PVec[T]; i: BackwardsIndex): lent T = v[v.cnt - int(i)]
  ## `v[^1]`: the last.

proc newPath[T](level: int; node: VNode[T]): VNode[T] =
  if level == 0: return node
  result = VNode[T](kids: @[newPath(level - Bits, node)])

proc pushTail[T](v: PVec[T]; level: int; parent: VNode[T]; tailNode: VNode[T]): VNode[T] =
  let sub = ((v.cnt - 1) shr level) and Mask
  result = VNode[T](kids: if parent == nil: @[] else: parent.kids)
  if level == Bits:
    if sub < result.kids.len: result.kids[sub] = tailNode
    else: result.kids.add tailNode
  else:
    if sub < result.kids.len:
      result.kids[sub] = v.pushTail(level - Bits, result.kids[sub], tailNode)
    else:
      result.kids.add newPath(level - Bits, tailNode)

proc add*[T](v: PVec[T]; x: T): PVec[T] =
  ## A vector of `v`'s items and `x` after them (`v` stays as it was).
  result = v
  if v.cnt - v.tailOff < Width:
    result.tail = v.tail
    result.tail.add x
    inc result.cnt
    return
  let tailNode = VNode[T](vals: v.tail)
  if (v.cnt shr Bits) > (1 shl v.shift):
    result.root = VNode[T](kids: @[v.root, newPath(v.shift, tailNode)])
    result.shift = v.shift + Bits
  else:
    result.root = v.pushTail(v.shift, v.root, tailNode)
  result.tail = @[x]
  inc result.cnt

proc doSet[T](level: int; node: VNode[T]; i: int; x: T): VNode[T] =
  result = VNode[T](kids: node.kids, vals: node.vals)
  if level == 0: result.vals[i and Mask] = x
  else:
    let sub = (i shr level) and Mask
    result.kids[sub] = doSet(level - Bits, node.kids[sub], i, x)

proc set*[T](v: PVec[T]; i: int; x: T): PVec[T] =
  ## A vector like `v` with `x` at `i` (`i` = `len`: added after).
  if i == v.cnt: return v.add(x)
  if i < 0 or i > v.cnt: raise newException(IndexDefect, "index " & $i & " not in 0 .. " & $v.cnt)
  result = v
  if i >= v.tailOff:
    result.tail = v.tail
    result.tail[i and Mask] = x
  else:
    result.root = doSet(v.shift, v.root, i, x)

proc popTail[T](v: PVec[T]; level: int; node: VNode[T]): VNode[T] =
  let sub = ((v.cnt - 2) shr level) and Mask
  if level > Bits:
    let child = v.popTail(level - Bits, node.kids[sub])
    if child == nil and sub == 0: return nil
    let c = VNode[T](kids: node.kids)
    if child == nil: c.kids.setLen(sub)
    else: c.kids[sub] = child
    c
  elif sub == 0: nil
  else: VNode[T](kids: node.kids[0 ..< sub])

proc pop*[T](v: PVec[T]): PVec[T] =
  ## A vector of `v`'s items but its last.
  if v.cnt == 0: raise newException(IndexDefect, "pop of an empty vector")
  if v.cnt == 1: return PVec[T]()
  result = v
  if v.cnt - v.tailOff > 1:
    result.tail = v.tail[0 ..< v.tail.len - 1]
    dec result.cnt
    return
  result.tail = v.leafFor(v.cnt - 2)[]
  var root = v.popTail(v.shift, v.root)
  var shift = v.shift
  if root == nil: root = VNode[T]()
  if shift > Bits and root.kids.len == 1:
    root = root.kids[0]
    shift -= Bits
  result.root = root
  result.shift = shift
  dec result.cnt

iterator items*[T](v: PVec[T]): lent T =
  ## Its items in order.
  var i = 0
  while i < v.cnt:
    let leaf = v.leafFor(i)
    let n = min(Width, v.cnt - i)
    for k in 0 ..< n: yield leaf[][k]
    i += n

iterator pairs*[T](v: PVec[T]): (int, T) =
  ## Its items with their indexes.
  var i = 0
  for x in v:
    yield (i, x)
    inc i

proc toSeq*[T](v: PVec[T]): seq[T] =
  ## Its items in a seq.
  result = newSeqOfCap[T](v.cnt)
  for x in v: result.add x

proc `==`*[T](a, b: PVec[T]): bool =
  ## The same items in the same order.
  if a.cnt != b.cnt: return false
  if a.root == b.root and a.tail == b.tail: return true
  var i = 0
  for x in a:
    if x != b[i]: return false
    inc i
  true

proc `$`*[T](v: PVec[T]): string = "pvec" & $v.toSeq
  ## (for debugging)

type VecBuilder*[T] = object
  ## A vector being made at once (`vecBuilder`): its items gathered, then made into one.
  items: seq[T]

proc vecBuilder*[T](cap = 0): VecBuilder[T] = VecBuilder[T](items: newSeqOfCap[T](cap))
  ## A builder for a large vector made at once, without a vector made for each item.

proc add*[T](b: var VecBuilder[T]; x: sink T) = b.items.add x
  ## `x` after what the builder has.

proc freeze*[T](b: sink VecBuilder[T]): PVec[T] =
  ## The vector of the builder's items: its leaves filled 32 at a time, the tree over them built
  ## once.
  let n = b.items.len
  result.cnt = n
  result.shift = Bits
  if n <= Width:
    result.tail = move b.items
    result.root = VNode[T]()
    return
  let tailStart = ((n - 1) shr Bits) shl Bits
  var level: seq[VNode[T]]
  var i = 0
  while i < tailStart:
    level.add VNode[T](vals: b.items[i ..< i + Width])
    i += Width
  result.tail = b.items[tailStart ..< n]
  var shift = Bits
  while level.len > Width:
    var up: seq[VNode[T]]
    var k = 0
    while k < level.len:
      up.add VNode[T](kids: level[k ..< min(level.len, k + Width)])
      k += Width
    level = up
    shift += Bits
  result.root = VNode[T](kids: level)
  result.shift = shift

proc toPVec*[T](s: openArray[T]): PVec[T] =
  ## A vector of `s`'s items.
  var b = vecBuilder[T](s.len)
  for x in s: b.add x
  freeze(b)

proc initPVec*[T](): PVec[T] = PVec[T](shift: Bits, root: VNode[T]())
  ## An empty vector.

# ---- PMap and PSet (CHAMP) ----------------------------------------------------------------------

type
  MNode[K, V] = ref object
    datamap, nodemap: uint32
    keys: seq[K]
    vals: seq[V]
    nodes: seq[MNode[K, V]]
    collide: bool             # (at the bottom: keys of one hash, side by side)

  PMap*[K, V] = object
    ## A persistent map (see the module's notes).
    root: MNode[K, V]
    cnt: int

  PSet*[K] = object
    ## A persistent set.
    m: PMap[K, bool]

  ChangeKind* = enum
    ## What `diff` found of a key.
    ckAdded, ckRemoved, ckChanged

  Change*[K] = tuple[kind: ChangeKind; key: K]
    ## A key added, removed or whose value changed.

const MaxShift = 30               # (below it, keys of one hash: a node of them)

proc h32[K](k: K): uint32 {.inline.} = cast[uint32](hash(k))

proc slot(h: uint32; shift: int): uint32 {.inline.} = 1'u32 shl ((h shr shift) and Mask)

proc index(map, bit: uint32): int {.inline.} = countSetBits(map and (bit - 1))

proc len*[K, V](m: PMap[K, V]): int {.inline.} = m.cnt
  ## How many keys it has.

proc initPMap*[K, V](): PMap[K, V] = PMap[K, V]()
  ## An empty map.

proc getPtr[K, V](n: MNode[K, V]; k: K; h: uint32; shift: int): ptr V =
  var n = n
  var shift = shift
  while n != nil:
    if n.collide:
      for i, x in n.keys:
        if x == k: return addr n.vals[i]
      return nil
    let bit = slot(h, shift)
    if (n.datamap and bit) != 0:
      let i = index(n.datamap, bit)
      return if n.keys[i] == k: addr n.vals[i] else: nil
    if (n.nodemap and bit) == 0: return nil
    n = n.nodes[index(n.nodemap, bit)]
    shift += Bits
  nil

proc contains*[K, V](m: PMap[K, V]; k: K): bool =
  ## `k` is a key of it.
  m.root.getPtr(k, h32(k), 0) != nil

proc `[]`*[K, V](m: PMap[K, V]; k: K): V =
  ## The value of `k`; `KeyError` when it isn't a key.
  let p = m.root.getPtr(k, h32(k), 0)
  if p == nil: raise newException(KeyError, "not a key of the map")
  p[]

proc getOrDefault*[K, V](m: PMap[K, V]; k: K; default: V = default(V)): V =
  ## The value of `k`, or `default`.
  let p = m.root.getPtr(k, h32(k), 0)
  if p == nil: default else: p[]

proc pair[K, V](k1: K; v1: V; h1: uint32; k2: K; v2: V; h2: uint32; shift: int): MNode[K, V] =
  ## (a node of two keys, as deep as their hashes first differ)
  if shift > MaxShift:
    return MNode[K, V](collide: true, keys: @[k1, k2], vals: @[v1, v2])
  let b1 = slot(h1, shift)
  let b2 = slot(h2, shift)
  if b1 == b2:
    result = MNode[K, V](nodemap: b1, nodes: @[pair(k1, v1, h1, k2, v2, h2, shift + Bits)])
  elif b1 < b2:
    result = MNode[K, V](datamap: b1 or b2, keys: @[k1, k2], vals: @[v1, v2])
  else:
    result = MNode[K, V](datamap: b1 or b2, keys: @[k2, k1], vals: @[v2, v1])

proc copyNode[K, V](n: MNode[K, V]): MNode[K, V] =
  MNode[K, V](datamap: n.datamap, nodemap: n.nodemap, keys: n.keys, vals: n.vals, nodes: n.nodes,
              collide: n.collide)

proc putIn[K, V](n: MNode[K, V]; k: K; v: V; h: uint32; shift: int; added: var bool): MNode[K, V] =
  if n == nil:
    added = true
    return MNode[K, V](datamap: slot(h, shift), keys: @[k], vals: @[v])
  if n.collide:
    for i, x in n.keys:
      if x == k:
        if n.vals[i] == v: return n
        let c = copyNode(n)
        c.vals[i] = v
        return c
    added = true
    let c = copyNode(n)
    c.keys.add k
    c.vals.add v
    return c
  let bit = slot(h, shift)
  if (n.datamap and bit) != 0:
    let i = index(n.datamap, bit)
    if n.keys[i] == k:
      if n.vals[i] == v: return n
      let c = copyNode(n)
      c.vals[i] = v
      return c
    # (another key there: the two go down a level together)
    added = true
    let sub = pair(n.keys[i], n.vals[i], h32(n.keys[i]), k, v, h, shift + Bits)
    let c = copyNode(n)
    c.datamap = n.datamap xor bit
    c.keys.delete(i)
    c.vals.delete(i)
    c.nodemap = n.nodemap or bit
    c.nodes.insert(sub, index(c.nodemap, bit))
    c
  elif (n.nodemap and bit) != 0:
    let j = index(n.nodemap, bit)
    let sub = n.nodes[j].putIn(k, v, h, shift + Bits, added)
    if sub == n.nodes[j]: return n
    let c = copyNode(n)
    c.nodes[j] = sub
    c
  else:
    added = true
    let c = copyNode(n)
    let i = index(n.datamap, bit)
    c.datamap = n.datamap or bit
    c.keys.insert(k, i)
    c.vals.insert(v, i)
    c

proc put*[K, V](m: PMap[K, V]; k: K; v: V): PMap[K, V] =
  ## A map like `m` with `k` mapped to `v` (`m` stays as it was; the same `m` when it already
  ## was so).
  var added = false
  result.root = m.root.putIn(k, v, h32(k), 0, added)
  result.cnt = m.cnt + ord(added)

proc single[K, V](n: MNode[K, V]): bool {.inline.} =
  ## (a node of one key and nothing under it: taken up into its parent)
  not n.collide and n.nodemap == 0 and n.keys.len == 1

proc delIn[K, V](n: MNode[K, V]; k: K; h: uint32; shift: int; removed: var bool): MNode[K, V] =
  if n == nil: return nil
  if n.collide:
    for i, x in n.keys:
      if x == k:
        removed = true
        let c = copyNode(n)
        c.keys.delete(i)
        c.vals.delete(i)
        if c.keys.len == 1:
          # (one left: an ordinary node of it, so it can rise)
          return MNode[K, V](datamap: slot(h32(c.keys[0]), shift), keys: c.keys, vals: c.vals)
        return c
    return n
  let bit = slot(h, shift)
  if (n.datamap and bit) != 0:
    let i = index(n.datamap, bit)
    if n.keys[i] != k: return n
    removed = true
    let c = copyNode(n)
    c.datamap = n.datamap xor bit
    c.keys.delete(i)
    c.vals.delete(i)
    c
  elif (n.nodemap and bit) != 0:
    let j = index(n.nodemap, bit)
    let sub = n.nodes[j].delIn(k, h, shift + Bits, removed)
    if not removed: return n
    let c = copyNode(n)
    if sub.single:
      # (its one key back up here: the canonical shape)
      c.nodemap = n.nodemap xor bit
      c.nodes.delete(j)
      let i = index(c.datamap, bit)
      c.datamap = c.datamap or bit
      c.keys.insert(sub.keys[0], i)
      c.vals.insert(sub.vals[0], i)
    else:
      c.nodes[j] = sub
    c
  else: n

proc del*[K, V](m: PMap[K, V]; k: K): PMap[K, V] =
  ## A map like `m` without `k` (`m` itself when it has no `k`).
  var removed = false
  let r = m.root.delIn(k, h32(k), 0, removed)
  if not removed: return m
  result.root = if r != nil and r.keys.len == 0 and r.nodes.len == 0: nil else: r
  result.cnt = m.cnt - 1

iterator walk[K, V](n: MNode[K, V]): (K, V) =
  var stack: seq[MNode[K, V]]
  if n != nil: stack.add n
  while stack.len > 0:
    let x = stack.pop()
    for i in 0 ..< x.keys.len: yield (x.keys[i], x.vals[i])
    for c in countdown(x.nodes.high, 0): stack.add x.nodes[c]

iterator pairs*[K, V](m: PMap[K, V]): (K, V) =
  ## Its keys and values (in the order of their hashes).
  for kv in walk(m.root): yield kv

iterator keys*[K, V](m: PMap[K, V]): K =
  ## Its keys.
  for (k, _) in walk(m.root): yield k

iterator values*[K, V](m: PMap[K, V]): V =
  ## Its values.
  for (_, v) in walk(m.root): yield v

proc `==`*[K, V](a, b: PMap[K, V]): bool =
  ## The same keys with the same values (built alike, the shared parts not compared).
  if a.cnt != b.cnt: return false
  if a.root == b.root: return true
  for k, v in a:
    let p = b.root.getPtr(k, h32(k), 0)
    if p == nil or p[] != v: return false
  true

proc diffIn[K, V](a, b: MNode[K, V]; ma, mb: PMap[K, V]; shift: int; res: var seq[Change[K]]) =
  if a == b: return                      # (shared: nothing differs under it)
  if a == nil or b == nil or a.collide or b.collide:
    for k, v in walk(a):
      let p = mb.root.getPtr(k, h32(k), 0)
      if p == nil: res.add (ckRemoved, k)
      elif p[] != v: res.add (ckChanged, k)
    for k, _ in walk(b):
      if ma.root.getPtr(k, h32(k), 0) == nil: res.add (ckAdded, k)
    return
  for p in 0 ..< Width:
    let bit = 1'u32 shl p
    let an = (a.nodemap and bit) != 0
    let bn = (b.nodemap and bit) != 0
    let ad = (a.datamap and bit) != 0
    let bd = (b.datamap and bit) != 0
    if not (an or bn or ad or bd): continue
    if an and bn:
      diffIn(a.nodes[index(a.nodemap, bit)], b.nodes[index(b.nodemap, bit)], ma, mb, shift + Bits, res)
    elif ad and bd:
      let i = index(a.datamap, bit)
      let j = index(b.datamap, bit)
      if a.keys[i] == b.keys[j]:
        if a.vals[i] != b.vals[j]: res.add (ckChanged, a.keys[i])
      else:
        res.add (ckRemoved, a.keys[i])
        res.add (ckAdded, b.keys[j])
    else:
      # (a key on one side, a node -- or nothing -- on the other: the few keys there compared)
      let sa = if an: a.nodes[index(a.nodemap, bit)]
               elif ad: MNode[K, V](keys: @[a.keys[index(a.datamap, bit)]], vals: @[a.vals[index(a.datamap, bit)]],
                                    collide: true)
               else: nil
      let sb = if bn: b.nodes[index(b.nodemap, bit)]
               elif bd: MNode[K, V](keys: @[b.keys[index(b.datamap, bit)]], vals: @[b.vals[index(b.datamap, bit)]],
                                    collide: true)
               else: nil
      for k, v in walk(sa):
        let q = mb.root.getPtr(k, h32(k), 0)
        if q == nil: res.add (ckRemoved, k)
        elif q[] != v: res.add (ckChanged, k)
      for k, _ in walk(sb):
        if ma.root.getPtr(k, h32(k), 0) == nil: res.add (ckAdded, k)

proc diff*[K, V](a, b: PMap[K, V]): seq[Change[K]] =
  ## What changed from `a` to `b`: the keys added, removed and those whose value changed. What the
  ## two share -- all but what was changed since one was made from the other -- is skipped
  ## without a look: a change of a few keys in a map of a million is found in a few steps.
  diffIn(a.root, b.root, a, b, 0, result)

proc `$`*[K, V](m: PMap[K, V]): string =
  result = "pmap{"
  var first = true
  for k, v in m:
    if not first: result.add ", "
    first = false
    result.add $k & ": " & $v
  result.add "}"

type MapBuilder*[K, V] = object
  ## A map being made at once (`mapBuilder`).
  m: PMap[K, V]

proc mapBuilder*[K, V](): MapBuilder[K, V] = MapBuilder[K, V]()
  ## A builder for a map made at once.

proc putOwned[K, V](n: var MNode[K, V]; k: K; v: V; h: uint32; shift: int): bool =
  ## (as `putIn`, changing the nodes in place: they are the builder's own, no other map has them)
  if n == nil:
    n = MNode[K, V](datamap: slot(h, shift), keys: @[k], vals: @[v])
    return true
  if n.collide:
    for i, x in n.keys:
      if x == k:
        n.vals[i] = v
        return false
    n.keys.add k
    n.vals.add v
    return true
  let bit = slot(h, shift)
  if (n.datamap and bit) != 0:
    let i = index(n.datamap, bit)
    if n.keys[i] == k:
      n.vals[i] = v
      return false
    let sub = pair(n.keys[i], n.vals[i], h32(n.keys[i]), k, v, h, shift + Bits)
    n.datamap = n.datamap xor bit
    n.keys.delete(i)
    n.vals.delete(i)
    n.nodemap = n.nodemap or bit
    n.nodes.insert(sub, index(n.nodemap, bit))
    true
  elif (n.nodemap and bit) != 0:
    putOwned(n.nodes[index(n.nodemap, bit)], k, v, h, shift + Bits)
  else:
    let i = index(n.datamap, bit)
    n.datamap = n.datamap or bit
    n.keys.insert(k, i)
    n.vals.insert(v, i)
    true

proc put*[K, V](b: var MapBuilder[K, V]; k: K; v: V) =
  ## `k` mapped to `v` in the builder's map (its nodes changed in place: no copies).
  if putOwned(b.m.root, k, v, h32(k), 0): inc b.m.cnt

proc freeze*[K, V](b: sink MapBuilder[K, V]): PMap[K, V] = b.m
  ## The map made.

proc toPMap*[K, V](pairs: openArray[(K, V)]): PMap[K, V] =
  ## A map of `pairs` (made with a builder).
  var b = mapBuilder[K, V]()
  for (k, v) in pairs: b.put(k, v)
  freeze(b)

proc len*[K](s: PSet[K]): int {.inline.} = s.m.cnt
  ## How many keys it has.

proc initPSet*[K](): PSet[K] = PSet[K]()
  ## An empty set.

proc contains*[K](s: PSet[K]; k: K): bool = k in s.m
  ## `k` is in it.

proc incl*[K](s: PSet[K]; k: K): PSet[K] = PSet[K](m: s.m.put(k, true))
  ## A set like `s` with `k` in it.

proc excl*[K](s: PSet[K]; k: K): PSet[K] = PSet[K](m: s.m.del(k))
  ## A set like `s` without `k`.

iterator items*[K](s: PSet[K]): K =
  ## Its keys.
  for k in s.m.keys: yield k

proc `==`*[K](a, b: PSet[K]): bool = a.m == b.m
  ## The same keys.

proc diff*[K](a, b: PSet[K]): seq[Change[K]] = diff(a.m, b.m)
  ## The keys added and removed from `a` to `b`.

proc toPSet*[K](keys: openArray[K]): PSet[K] =
  ## A set of `keys`.
  for k in keys: result = result.incl(k)

# ---- Rope ---------------------------------------------------------------------------------------

const LeafMax = 512             # (a piece's longest)

type
  RNode = ref object
    left, right: RNode
    s: string                   # (a leaf's text)
    len, height: int
  Rope* = object
    ## A long text as a balanced tree of pieces (see the module's notes).
    root: RNode

proc rlen(n: RNode): int {.inline.} = (if n == nil: 0 else: n.len)
proc rh(n: RNode): int {.inline.} = (if n == nil: 0 else: n.height)

proc leaf(s: string): RNode = RNode(s: s, len: s.len, height: 1)

proc join(a, b: RNode): RNode =
  RNode(left: a, right: b, len: rlen(a) + rlen(b), height: max(rh(a), rh(b)) + 1)

proc balance(a, b: RNode): RNode =
  ## (`a` then `b`, as one tree kept balanced -- AVL-like, by their heights)
  if a == nil: return b
  if b == nil: return a
  if a.left == nil and b.left == nil and a.len + b.len <= LeafMax:
    return leaf(a.s & b.s)            # (two small pieces: one)
  let d = rh(a) - rh(b)
  if d > 1:
    let r = balance(a.right, b)
    if rh(r) > rh(a.left) + 1: return join(join(a.left, r.left), r.right)
    return join(a.left, r)
  if d < -1:
    let l = balance(a, b.left)
    if rh(l) > rh(b.right) + 1: return join(l.left, join(l.right, b.right))
    return join(l, b.right)
  join(a, b)

proc fromString(s: string): RNode =
  if s.len <= LeafMax: return (if s.len == 0: nil else: leaf(s))
  let mid = s.len div 2
  join(fromString(s[0 ..< mid]), fromString(s[mid .. ^1]))

proc toRope*(s: string): Rope = Rope(root: fromString(s))
  ## A rope of the text `s`.

proc len*(r: Rope): int {.inline.} = rlen(r.root)
  ## How many bytes of text it has.

proc `&`*(a, b: Rope): Rope = Rope(root: balance(a.root, b.root))
  ## `a`'s text then `b`'s (both kept as they are, their pieces shared).

proc split(n: RNode; i: int): (RNode, RNode) =
  if n == nil: return (nil, nil)
  if n.left == nil:
    if i <= 0: return (nil, n)
    if i >= n.len: return (n, nil)
    return (leaf(n.s[0 ..< i]), leaf(n.s[i .. ^1]))
  let ll = rlen(n.left)
  if i < ll:
    let (a, b) = split(n.left, i)
    return (a, balance(b, n.right))
  if i > ll:
    let (a, b) = split(n.right, i - ll)
    return (balance(n.left, a), b)
  (n.left, n.right)

proc split*(r: Rope; i: int): (Rope, Rope) =
  ## The text before byte `i` and from it on.
  let (a, b) = split(r.root, clamp(i, 0, r.len))
  (Rope(root: a), Rope(root: b))

proc insert*(r: Rope; i: int; s: string): Rope =
  ## A rope like `r` with `s` put in at byte `i`.
  let (a, b) = r.split(i)
  a & toRope(s) & b

proc delete*(r: Rope; a, b: int): Rope =
  ## A rope like `r` without bytes `a ..< b`.
  let (x, rest) = r.split(a)
  let (_, y) = rest.split(b - a)
  x & y

proc `[]`*(r: Rope; i: int): char =
  ## The byte at `i`.
  var n = r.root
  var i = i
  if i < 0 or i >= rlen(n): raise newException(IndexDefect, "index " & $i & " not in the rope")
  while n.left != nil:
    if i < rlen(n.left): n = n.left
    else:
      i -= rlen(n.left)
      n = n.right
  n.s[i]

iterator pieces*(r: Rope): lent string =
  ## Its text, piece by piece, in order (no copy of it all).
  var stack: seq[RNode]
  var n = r.root
  while n != nil or stack.len > 0:
    while n != nil:
      stack.add n
      n = n.left
    n = stack.pop()
    if n.left == nil and n.right == nil: yield n.s
    n = n.right

proc `$`*(r: Rope): string =
  ## Its whole text.
  result = newStringOfCap(r.len)
  for p in r.pieces: result.add p

proc substr*(r: Rope; a, b: int): string =
  ## Bytes `a ..< b` of its text.
  let (_, rest) = r.split(a)
  let (mid, _) = rest.split(b - a)
  $mid

proc `==`*(a, b: Rope): bool = a.root == b.root or (a.len == b.len and $a == $b)
  ## The same text.

# ---- to NIF and back ----------------------------------------------------------------------------

proc writeNifOf*[T](w: var NifWriter; v: PVec[T]) =
  w.open("pvec")
  for x in v: w.writeNif(x)
  w.close()

proc readNifOf*[T](n: NifNode; v: var PVec[T]) =
  if n.kind != nifTree: raise newException(NifError, "NIF: (pvec ...) expected")
  var b = vecBuilder[T](n.kids.len)
  for k in n.kids:
    var x: T
    readNif(k, x)
    b.add x
  v = freeze(b)

proc writeNifOf*[K, V](w: var NifWriter; m: PMap[K, V]) =
  w.open("pmap")
  for k, v in m:
    w.open("kv")
    w.writeNif(k)
    w.writeNif(v)
    w.close()
  w.close()

proc readNifOf*[K, V](n: NifNode; m: var PMap[K, V]) =
  if n.kind != nifTree: raise newException(NifError, "NIF: (pmap ...) expected")
  m = PMap[K, V]()
  for kv in n.kids:
    if kv.kind != nifTree or kv.kids.len < 2: raise newException(NifError, "NIF: (kv key value) expected")
    var k: K
    var v: V
    readNif(kv.kids[0], k)
    readNif(kv.kids[1], v)
    m = m.put(k, v)

proc writeNifOf*[K](w: var NifWriter; s: PSet[K]) =
  w.open("pset")
  for k in s: w.writeNif(k)
  w.close()

proc readNifOf*[K](n: NifNode; s: var PSet[K]) =
  if n.kind != nifTree: raise newException(NifError, "NIF: (pset ...) expected")
  s = PSet[K]()
  for kn in n.kids:
    var k: K
    readNif(kn, k)
    s = s.incl(k)

proc writeNifOf*(w: var NifWriter; r: Rope) = w.strLit($r)

proc readNifOf*(n: NifNode; r: var Rope) =
  if n.kind != nifStr: raise newException(NifError, "NIF: a string expected")
  r = toRope(n.s)

proc writeNifOf*[T](w: var NifWriter; b: Box[T]) =
  if b.p == nil: w.emptyLit()
  else: w.writeNif(b.p.val)

proc readNifOf*[T](n: NifNode; b: var Box[T]) =
  if n.kind == nifEmpty: b = Box[T]()
  else:
    var v: T
    readNif(n, v)
    b = box(v)

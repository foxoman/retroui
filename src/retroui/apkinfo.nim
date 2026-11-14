## An Android app's package (.apk) described without Android: its name,
## package, version, the Android versions it runs on, the permissions it
## asks for, its icon and the processors its native code is for -- read
## from its binary AndroidManifest.xml and resources.arsc (in the APK's
## zip). A damaged or cut file gives what could be read, never a crash,
## never a read past an end.
##
## .. code-block:: nim
##   let a = readApk("Notes.apk")
##   if a.ok: echo a.label, " ", a.versionName, " (", a.package, ")"
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, unicode, tables]
import zip

type
  ApkInfo* = object
    ## What an APK says of itself (`readApk`).
    ok*: bool                  ## its manifest was read
    error*: string             ## why not (not a zip, no manifest)
    package*: string           ## "org.retro.files"
    label*: string             ## the app's name ("" when only a resource no table has)
    versionName*: string       ## "3.4.1"
    versionCode*: int64
    minSdk*, targetSdk*: int   ## Android API levels (0: not said)
    permissions*: seq[string]  ## "android.permission.CAMERA"...
    abis*: seq[string]         ## its native code's processors (arm64-v8a, x86_64...)
    activities*, services*: int
    icon*: string              ## the icon's picture (PNG or WebP), the largest
                               ## found; "" when there is none (a drawing in XML)

const
  ResLabel = 0x01010001'u32
  ResIcon = 0x01010002'u32
  ResName = 0x01010003'u32
  ResMinSdk = 0x0101020c'u32
  ResVersionCode = 0x0101021b'u32
  ResVersionName = 0x0101021c'u32
  ResTargetSdk = 0x01010270'u32
  ResDrawable = 0x01010199'u32
  TRef = 0x01'u8
  TString = 0x03'u8

# ---- reading, every place checked ------------------------------------------

proc u8(s: string; at: int): int {.inline.} =
  if at >= 0 and at < s.len: int(s[at].byte) else: 0

proc u16(s: string; at: int): int {.inline.} = s.u8(at) or (s.u8(at + 1) shl 8)

proc u32(s: string; at: int): uint32 {.inline.} =
  uint32(s.u16(at)) or (uint32(s.u16(at + 2)) shl 16)

proc i32(s: string; at: int): int {.inline.} =
  ## (a 32-bit size, count or offset as an int: past 512 MB -- in a file
  ## read whole, of 64 MB at most, only a damaged one -- -1, which every
  ## check refuses; sums of them stay in a 32-bit int)
  let v = s.u32(at)
  if v > 0x1FFF_FFFF'u32: -1 else: int(v)

proc pool(s: string; at: int): seq[string] =
  ## The strings of the ResStringPool chunk at `at` (UTF-8 or UTF-16).
  let count = s.i32(at + 8)
  let utf8 = (s.u32(at + 16) and 0x100) != 0
  let start = at + s.i32(at + 20)
  let chunkEnd = min(s.len, at + s.i32(at + 4))
  let offs = at + s.u16(at + 2)
  if count < 0 or count > 200_000 or offs + 4 * count > chunkEnd: return
  for i in 0 ..< count:
    var p = start + s.i32(offs + 4 * i)
    var str = ""
    if p >= 0 and p < chunkEnd:
      if utf8:
        # (its length in UTF-16 units, then in bytes; each 1 or 2 bytes)
        if (s.u8(p) and 0x80) != 0: p += 2 else: p += 1
        var n = s.u8(p)
        if (n and 0x80) != 0:
          n = ((n and 0x7F) shl 8) or s.u8(p + 1)
          p += 2
        else: p += 1
        if p + n <= chunkEnd: str = s[p ..< p + n]
      else:
        var n = s.u16(p)
        if (n and 0x8000) != 0:
          n = ((n and 0x7FFF) shl 16) or s.u16(p + 2)
          p += 4
        else: p += 2
        if n >= 0 and n <= (chunkEnd - p) div 2:
          var w: seq[int]
          var k = 0
          while k < n:
            var c = s.u16(p + 2 * k)
            if c >= 0xD800 and c < 0xDC00 and k + 1 < n:
              let lo = s.u16(p + 2 * k + 2)
              if lo >= 0xDC00 and lo < 0xE000:
                c = 0x10000 + ((c - 0xD800) shl 10) + (lo - 0xDC00)
                inc k
            w.add c
            inc k
          for c in w: str.add Rune(c).toUTF8
    result.add str

# ---- the binary XML: AndroidManifest.xml --------------------------------------

type
  XAttr = object
    name: string
    resId: uint32
    kind: uint8
    data: uint32
    str: string
  XElement = object
    name: string
    depth: int
    attrs: seq[XAttr]

proc elements(x: string): seq[XElement] =
  ## Every element of a binary XML file, in order, with its attributes.
  if x.u16(0) != 0x0003: return
  var strs: seq[string]
  var resIds: seq[uint32]
  var at = x.u16(2)
  var depth = 0
  var guard = 0
  while at + 8 <= x.len and guard < 1_000_000:
    inc guard
    let kind = x.u16(at)
    let size = x.i32(at + 4)
    if size < 8: break
    case kind
    of 0x0001: strs = pool(x, at)
    of 0x0180:
      for i in 0 ..< min((size - 8) div 4, 10_000): resIds.add x.u32(at + 8 + 4 * i)
    of 0x0102:
      let ext = at + x.u16(at + 2)
      var e = XElement(depth: depth)
      let ni = x.i32(ext + 4)
      if ni >= 0 and ni < strs.len: e.name = strs[ni]
      let first = ext + x.u16(ext + 8)
      let each = max(20, x.u16(ext + 10))
      for i in 0 ..< min(x.u16(ext + 12), 500):
        let a = first + i * each
        if a + 20 > x.len: break
        var t = XAttr()
        let n = x.i32(a + 4)
        if n >= 0 and n < strs.len: t.name = strs[n]
        if n >= 0 and n < resIds.len: t.resId = resIds[n]
        t.kind = uint8(x.u8(a + 15))
        t.data = x.u32(a + 16)
        let raw = x.i32(a + 8)
        if t.kind == TString and t.data < uint32(strs.len): t.str = strs[int(t.data)]
        elif raw >= 0 and raw < strs.len: t.str = strs[raw]
        e.attrs.add t
      result.add e
      inc depth
    of 0x0103: dec depth
    else: discard
    at += size

proc attr(e: XElement; id: uint32; name: string): XAttr =
  ## (by its resource id, else by its name: shrunk APKs drop the names)
  for a in e.attrs:
    if a.resId == id and id != 0: return a
  for a in e.attrs:
    if a.name == name: return a

proc intOf(a: XAttr): int64 =
  if a.kind in {0x10'u8, 0x11'u8}: int64(cast[int32](a.data))
  elif a.str.len > 0: (try: parseBiggestInt(a.str) except ValueError: 0'i64)
  else: 0

# ---- resources.arsc: a reference's value --------------------------------------

type ResValue = object
  kind: uint8
  data: uint32
  density: int
  language: string

proc resources(t: string): (seq[string], Table[uint32, seq[ResValue]]) =
  ## The table's global strings and each resource's plain values.
  if t.u16(0) != 0x0002: return
  var values: seq[string]
  var res: Table[uint32, seq[ResValue]]
  var at = t.u16(2)
  var guard = 0
  while at + 8 <= t.len and guard < 10_000:
    inc guard
    let kind = t.u16(at)
    let size = t.i32(at + 4)
    if size < 8: break
    if kind == 0x0001: values = pool(t, at)
    elif kind == 0x0200:
      let pkg = t.u32(at + 8) and 0xFF
      var c = at + t.u16(at + 2)
      let pkgEnd = min(t.len, at + size)
      var g2 = 0
      while c + 8 <= pkgEnd and g2 < 100_000:
        inc g2
        let ck = t.u16(c)
        let cs = t.i32(c + 4)
        if cs < 8: break
        if ck == 0x0201:
          let typeId = uint32(t.u8(c + 8))
          let sparse = (t.u8(c + 9) and 1) != 0
          let count = t.i32(c + 12)
          let entries = c + t.i32(c + 16)
          let cfg = c + 20
          let density = t.u16(cfg + 14)
          var lang = ""
          if t.u8(cfg + 8) != 0: lang = $char(t.u8(cfg + 8)) & $char(t.u8(cfg + 9))
          let offs = c + t.u16(c + 2)
          for i in 0 ..< min(count, 65536):
            var idx = i
            var off: int
            if sparse:
              idx = t.u16(offs + 4 * i)
              off = t.u16(offs + 4 * i + 2) * 4
            else:
              let o = t.u32(offs + 4 * i)
              if o == 0xFFFFFFFF'u32: continue
              off = (if o > 0x1FFF_FFFF'u32: -1 else: int(o))
            let e = entries + off
            if e + 8 > c + cs: continue
            let flags = t.u16(e + 2)
            var v = ResValue()
            if (flags and 0x0008) != 0:            # (compact: Android 14's)
              v = ResValue(kind: uint8(flags shr 8), data: t.u32(e + 4))
            elif (flags and 0x0001) != 0: continue # (a map: a style, not a value)
            else:
              let vs = e + t.u16(e)
              v = ResValue(kind: uint8(t.u8(vs + 3)), data: t.u32(vs + 4))
            v.density = density
            v.language = lang
            let id = (pkg shl 24) or (typeId shl 16) or uint32(idx)
            res.mgetOrPut(id, @[]).add v
        c += cs
    at += size
  (values, res)

proc labelOf(id: uint32; values: seq[string]; res: Table[uint32, seq[ResValue]]): string =
  ## (a string resource: the default language's, else English's, else any)
  var depth = 0
  var id = id
  while depth < 4:
    inc depth
    let vs = res.getOrDefault(id)
    if vs.len == 0: return ""
    proc rank(v: ResValue): int =
      if v.language == "": 3 elif v.language == "en": 2 else: 1
    var best = 0
    for i, v in vs:
      if rank(v) > rank(vs[best]): best = i
    let v = vs[best]
    if v.kind == TString and v.data < uint32(values.len): return values[int(v.data)]
    if v.kind == TRef: id = v.data else: return ""

proc pathsOf(id: uint32; values: seq[string]; res: Table[uint32, seq[ResValue]]): seq[string] =
  ## (a file resource's files, the densest first)
  var vs = res.getOrDefault(id)
  var sorted: seq[(int, string)]
  for v in vs:
    if v.kind == TString and v.data < uint32(values.len):
      # (density 0 is "any"; 0xFFFF "no density", a drawing for every size)
      let d = if v.density == 0xFFFF: 0 elif v.density == 0: 1 else: v.density
      sorted.add (d, values[int(v.data)])
  for i in 1 ..< sorted.len:
    var j = i
    while j > 0 and sorted[j - 1][0] < sorted[j][0]:
      swap(sorted[j - 1], sorted[j])
      dec j
  for (_, p) in sorted: result.add p

# ---- the APK ------------------------------------------------------------------

proc apkFrom*(manifest, table: string; entries: openArray[string] = [];
              readFile: proc (name: string): string = nil): ApkInfo =
  ## What a binary `manifest` (AndroidManifest.xml's bytes) and resource
  ## `table` (resources.arsc's, or "") say; `entries`, the zip's names (for
  ## the processors); `readFile`, the zip's file of a name (for the icon).
  let els = elements(manifest)
  if els.len == 0 or els[0].name != "manifest":
    result.error = "no Android manifest"
    return
  result.ok = true
  let (values, res) = resources(table)
  var iconRef = 0'u32
  for e in els:
    case e.name
    of "manifest":
      result.package = e.attr(0, "package").str
      result.versionCode = e.attr(ResVersionCode, "versionCode").intOf
      let vn = e.attr(ResVersionName, "versionName")
      result.versionName = if vn.kind == TRef: labelOf(vn.data, values, res) else: vn.str
    of "uses-sdk":
      result.minSdk = int(clamp(e.attr(ResMinSdk, "minSdkVersion").intOf, 0, 10_000))
      result.targetSdk = int(clamp(e.attr(ResTargetSdk, "targetSdkVersion").intOf, 0, 10_000))
    of "uses-permission", "uses-permission-sdk-23":
      let n = e.attr(ResName, "name").str
      if n.len > 0 and n notin result.permissions: result.permissions.add n
    of "application":
      let l = e.attr(ResLabel, "label")
      result.label = if l.kind == TRef: labelOf(l.data, values, res) else: l.str
      let i = e.attr(ResIcon, "icon")
      if i.kind == TRef: iconRef = i.data
    of "activity", "activity-alias": inc result.activities
    of "service": inc result.services
    else: discard
  for n in entries:
    if n.startsWith("lib/") and n.count('/') >= 2:
      let abi = n.split('/')[1]
      if abi.len > 0 and abi notin result.abis: result.abis.add abi
  if iconRef != 0 and readFile != nil:
    # the icon: a picture; an adaptive icon (XML) leads to its foreground
    var refs = @[iconRef]
    var tries = 0
    while refs.len > 0 and tries < 6 and result.icon.len == 0:
      inc tries
      let r = refs[0]
      refs.delete(0)
      for p in pathsOf(r, values, res):
        let l = p.toLowerAscii
        if l.endsWith(".png") or l.endsWith(".webp"):
          let b = readFile(p)
          if b.len > 8:
            result.icon = b
            break
        elif l.endsWith(".xml"):
          for e in elements(readFile(p)):
            if e.name == "foreground":
              let d = e.attr(ResDrawable, "drawable")
              if d.kind == TRef and d.data notin refs: refs.add d.data

proc readApk*(path: string): ApkInfo =
  ## What the APK at `path` says of itself (`ApkInfo`); `ok` false with an
  ## `error` when it is not an APK or cannot be read.
  try:
    let es = zipEntries(path)
    var names: seq[string]
    var manifest, table = ""
    for e in es:
      names.add e.name
      if e.name == "AndroidManifest.xml" and e.size < 16_000_000: manifest = readEntry(path, e)
      elif e.name == "resources.arsc" and e.size < 64_000_000: table = readEntry(path, e)
    if manifest.len == 0:
      result.error = "no AndroidManifest.xml: not an Android app"
      return
    let read = proc (name: string): string =
      for e in es:
        if e.name == name:
          if e.size <= 8_000_000:
            try: result = readEntry(path, e)
            except CatchableError: result = ""
          break
    result = apkFrom(manifest, table, names, read)
  except CatchableError as e:
    result.error = e.msg

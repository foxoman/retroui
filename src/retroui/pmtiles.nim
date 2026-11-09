## Map tiles in one file: PMTiles (version 3) -- a whole map, raster or
## vector, read from the disk or from a web address a piece at a time (an
## HTTP range request: a static file on any web server or bucket, no tile
## server), and MBTiles (SQLite: what MapTiler, TileMill and the tile
## tools write).
##
## .. code-block:: nim
##   let pm = openPmtiles("oman.pmtiles")          # or "https://.../oman.pmtiles"
##   if pm.ok:
##     echo pm.minZoom, "..", pm.maxZoom, " ", pm.tileType
##     let data = pm.tile(10, 663, 448)             # the tile's bytes ("" none there)
##
## The map view (`tilemap`) opens these itself: `pmtilesSource`,
## `mbtilesSource`. A tile comes as it is stored (a vector tile unpacked
## from gzip when it was packed; Brotli and Zstandard are not read).

import std/[strutils, tables, json]
import http, codec, db

type
  PmCompression* = enum pcUnknown, pcNone, pcGzip, pcBrotli, pcZstd
  PmTileType* = enum ptUnknown = "unknown", ptMvt = "mvt", ptPng = "png", ptJpeg = "jpeg",
                     ptWebp = "webp", ptAvif = "avif"

  PmEntry = object
    tileId, offset: uint64
    length, runLength: uint32

  Pmtiles* = ref object
    ## An open PMTiles archive.
    ok*: bool
    error*: string
    path*: string                   ## the file or the address
    minZoom*, maxZoom*: int
    centerZoom*: int
    west*, south*, east*, north*: float  ## what it covers (degrees)
    centerLat*, centerLon*: float
    tileType*: PmTileType
    tileCompression*: PmCompression
    internalCompression: PmCompression
    rootOffset, rootLength, metaOffset, metaLength, leafOffset, leafLength, dataOffset: uint64
    root: seq[PmEntry]
    leaves: Table[uint64, seq[PmEntry]]      # (leaf directories read, by offset)
    remote: bool
    file: File
    headers*: seq[(string, string)]          ## sent with each request (a key, a token)

proc u64le(s: string; at: int): uint64 =
  for k in 0 .. 7: result = result or (uint64(uint8(s[at + k])) shl (8 * k))

proc i32le(s: string; at: int): int32 =
  var v = 0'u32
  for k in 0 .. 3: v = v or (uint32(uint8(s[at + k])) shl (8 * k))
  cast[int32](v)

proc readRange(p: Pmtiles; offset, length: uint64): string =
  ## `length` bytes from `offset` ("" when they cannot be had).
  if length == 0: return ""
  if length > 64'u64 shl 20: return ""
  if offset > uint64(high(int32)) * 1024 - length: return ""     # (past any archive)
  if p.remote:
    let r = httpRequest("GET", p.path, p.headers & @[("Range", "bytes=" & $offset & "-" & $(offset + length - 1))],
                        timeoutSec = 30)
    if r.status == 206: return r.body
    if r.status == 200 and uint64(r.body.len) >= offset + length and offset + length <= uint64(high(int)):
      # (a server that sends it all: the part of it)
      return r.body[int(offset) ..< int(offset + length)]
    return ""
  if p.file == nil: return ""
  try:
    p.file.setFilePos(int64(offset))
    result = newString(int(length))
    let n = p.file.readBuffer(addr result[0], int(length))
    result.setLen(n)
  except IOError, OSError:
    result = ""

proc gunzipped(data: string): string =
  if data.len < 18 or data[0] != '\x1f' or data[1] != '\x8b': return data
  let flags = uint8(data[3])
  var at = 10
  if (flags and 4) != 0: at += 2 + (ord(data[at]) or (ord(data[at + 1]) shl 8))
  if (flags and 8) != 0:
    while at < data.len and data[at] != '\0': inc at
    inc at
  if (flags and 16) != 0:
    while at < data.len and data[at] != '\0': inc at
    inc at
  if (flags and 2) != 0: at += 2
  if at >= data.len: return ""
  let o = try: inflate(toOpenArrayByte(data, 0, data.high), at, maxOut = 256 shl 20)
          except CatchableError: return ""
  result = newString(o.len)
  if o.len > 0: copyMem(addr result[0], unsafeAddr o[0], o.len)

proc unpack(c: PmCompression; data: string): string =
  case c
  of pcGzip: gunzipped(data)
  of pcNone, pcUnknown: data
  else: ""

proc readDirectory(data: string): seq[PmEntry] =
  var at = 0
  proc v(): uint64 =
    var shift = 0
    while true:
      if at >= data.len: raise newException(ValueError, "cut short")
      let b = uint8(data[at])
      inc at
      result = result or (uint64(b and 0x7F) shl shift)
      if (b and 0x80) == 0: return
      shift += 7
      if shift > 63: raise newException(ValueError, "too long")
  try:
    let n = int(min(v(), 1_000_000'u64))
    result.setLen(n)
    var last = 0'u64
    for i in 0 ..< n:
      last += v()
      result[i].tileId = last
    for i in 0 ..< n: result[i].runLength = uint32(min(v(), uint64(high(uint32))))
    for i in 0 ..< n: result[i].length = uint32(min(v(), uint64(high(uint32))))
    for i in 0 ..< n:
      let o = v()
      result[i].offset = if o == 0 and i > 0: result[i - 1].offset + result[i - 1].length else: o - 1
  except ValueError:
    result.setLen(0)

proc tileId*(z, x, y: int): uint64 =
  ## A tile's number in a PMTiles archive (along a Hilbert curve, zoom by zoom).
  if z < 0 or z > 31: return 0
  var acc = 0'u64
  for i in 0 ..< z: acc += 1'u64 shl (2 * i)
  let n = 1'u64 shl z
  var tx = uint64(x)
  var ty = uint64(y)
  var d = 0'u64
  var s = n shr 1
  while s > 0:
    let rx = if (tx and s) > 0: 1'u64 else: 0'u64
    let ry = if (ty and s) > 0: 1'u64 else: 0'u64
    d += s * s * ((3'u64 * rx) xor ry)
    if ry == 0:
      if rx == 1:
        tx = n - 1 - tx
        ty = n - 1 - ty
      swap(tx, ty)
    s = s shr 1
  acc + d

proc openPmtiles*(path: string; headers: openArray[(string, string)] = []): Pmtiles =
  ## The archive at `path` (a file, or an http(s) address); `ok` false and
  ## `error` why when it cannot be read.
  result = Pmtiles(path: path, headers: @headers)
  result.remote = path.startsWith("http://") or path.startsWith("https://")
  if not result.remote:
    if not open(result.file, path):
      result.error = "it cannot be opened"
      return
  let head = result.readRange(0, 127)
  if head.len < 127 or head[0 .. 6] != "PMTiles":
    result.error = "it is not a PMTiles archive"
    return
  if ord(head[7]) != 3:
    result.error = "PMTiles version " & $ord(head[7]) & " (3 is read)"
    return
  let p = result
  p.rootOffset = u64le(head, 8)
  p.rootLength = u64le(head, 16)
  p.metaOffset = u64le(head, 24)
  p.metaLength = u64le(head, 32)
  p.leafOffset = u64le(head, 40)
  p.leafLength = u64le(head, 48)
  p.dataOffset = u64le(head, 56)
  p.internalCompression = PmCompression(min(4, ord(head[97])))
  p.tileCompression = PmCompression(min(4, ord(head[98])))
  p.tileType = PmTileType(min(5, ord(head[99])))
  p.minZoom = ord(head[100])
  p.maxZoom = ord(head[101])
  p.west = float(i32le(head, 102)) / 1e7
  p.south = float(i32le(head, 106)) / 1e7
  p.east = float(i32le(head, 110)) / 1e7
  p.north = float(i32le(head, 114)) / 1e7
  p.centerZoom = ord(head[118])
  p.centerLon = float(i32le(head, 119)) / 1e7
  p.centerLat = float(i32le(head, 123)) / 1e7
  if p.internalCompression notin {pcNone, pcGzip, pcUnknown}:
    p.error = "its directories are packed with " & $p.internalCompression & " (gzip is read)"
    return
  p.root = readDirectory(unpack(p.internalCompression, p.readRange(p.rootOffset, p.rootLength)))
  if p.root.len == 0:
    p.error = "its directory cannot be read"
    return
  p.ok = true

proc close*(p: Pmtiles) =
  if p != nil and p.file != nil:
    p.file.close()
    p.file = nil

proc find(entries: seq[PmEntry]; id: uint64): int =
  ## The entry with the greatest tile number not past `id` (-1: none).
  var lo = 0
  var hi = entries.high
  result = -1
  while lo <= hi:
    let m = (lo + hi) div 2
    if entries[m].tileId <= id:
      result = m
      lo = m + 1
    else:
      hi = m - 1

proc metadata*(p: Pmtiles): JsonNode =
  ## The archive's JSON metadata (its name, attribution, vector layers...).
  if p == nil or not p.ok or p.metaLength == 0: return newJObject()
  try: parseJson(unpack(p.internalCompression, p.readRange(p.metaOffset, p.metaLength)))
  except CatchableError: newJObject()

proc tile*(p: Pmtiles; z, x, y: int): string =
  ## The bytes of tile `z`/`x`/`y` ("" when the archive has none there).
  if p == nil or not p.ok or z < p.minZoom or z > p.maxZoom or z > 31: return ""
  if x < 0 or y < 0 or x >= (1 shl z) or y >= (1 shl z): return ""
  let id = tileId(z, x, y)
  var dir = p.root
  for depth in 0 .. 3:
    let i = dir.find(id)
    if i < 0: return ""
    let e = dir[i]
    if e.runLength > 0:
      if id >= e.tileId + uint64(e.runLength): return ""
      let raw = p.readRange(p.dataOffset + e.offset, uint64(e.length))
      return if p.tileCompression == pcGzip: gunzipped(raw) else: raw
    # a leaf directory
    let at = e.offset
    if at notin p.leaves:
      if p.leaves.len > 64: p.leaves.clear()
      p.leaves[at] = readDirectory(unpack(p.internalCompression,
                                          p.readRange(p.leafOffset + at, uint64(e.length))))
    dir = p.leaves[at]
  ""

# ---- writing (an app's own tiles; the tests) ------------------------------------------

proc writePmtiles*(path: string; tiles: openArray[(int, int, int, string)]; tileType: PmTileType;
                   metadata = "{}"; gzipTiles = false): bool =
  ## A PMTiles archive of `tiles` (z, x, y, bytes) with one root directory
  ## (fine for a few thousand tiles); the tiles stored as given.
  type T = tuple[id: uint64; data: string]
  var ts: seq[T]
  for (z, x, y, d) in tiles: ts.add (tileId(z, x, y), d)
  for i in 1 ..< ts.len:
    var j = i
    while j > 0 and ts[j - 1].id > ts[j].id:
      swap(ts[j - 1], ts[j])
      dec j
  proc putVar(o: var string; v: uint64) =
    var v = v
    while v >= 0x80:
      o.add char((v and 0x7F) or 0x80)
      v = v shr 7
    o.add char(v)
  var data = ""
  var dir = ""
  dir.putVar(uint64(ts.len))
  var last = 0'u64
  for t in ts:
    dir.putVar(t.id - last)
    last = t.id
  for t in ts: dir.putVar(1)
  for t in ts: dir.putVar(uint64(t.data.len))
  for t in ts:
    dir.putVar(uint64(data.len) + 1)
    data.add t.data
  var minZ = 99
  var maxZ = 0
  for (z, x, y, d) in tiles:
    minZ = min(minZ, z)
    maxZ = max(maxZ, z)
  if tiles.len == 0: minZ = 0
  var head = newString(127)
  proc put64(at: int; v: uint64) =
    for k in 0 .. 7: head[at + k] = char((v shr (8 * k)) and 255)
  proc put32(at: int; v: int32) =
    for k in 0 .. 3: head[at + k] = char((cast[uint32](v) shr (8 * k)) and 255)
  head[0 .. 6] = "PMTiles"
  head[7] = '\3'
  put64(8, 127)
  put64(16, uint64(dir.len))
  put64(24, uint64(127 + dir.len))
  put64(32, uint64(metadata.len))
  put64(40, uint64(127 + dir.len + metadata.len))
  put64(48, 0)
  put64(56, uint64(127 + dir.len + metadata.len))
  put64(64, uint64(data.len))
  put64(72, uint64(ts.len))
  put64(80, uint64(ts.len))
  put64(88, uint64(ts.len))
  head[96] = '\0'
  head[97] = '\1'                      # directories not packed
  head[98] = if gzipTiles: '\2' else: '\1'
  head[99] = char(ord(tileType))
  head[100] = char(minZ)
  head[101] = char(maxZ)
  put32(102, -1800000000)
  put32(106, -850000000)
  put32(110, 1800000000)
  put32(114, 850000000)
  head[118] = char(minZ)
  put32(119, 0)
  put32(123, 0)
  try:
    writeFile(path, head & dir & metadata & data)
    true
  except IOError, OSError:
    false

# ---- MBTiles ------------------------------------------------------------------------

type
  Mbtiles* = ref object
    ## An open MBTiles file.
    ok*: bool
    error*: string
    db: Db
    meta*: Table[string, string]     ## its metadata (name, format, minzoom, bounds...)
    format*: string                  ## "png", "jpg", "webp", "pbf"

proc openMbtiles*(path: string): Mbtiles =
  ## The MBTiles file `path`.
  result = Mbtiles()
  try:
    result.db = openDb(path, readOnly = true)
    for r in result.db.rows("SELECT name, value FROM metadata"):
      result.meta[r[0].str] = r[1].str
    result.format = result.meta.getOrDefault("format", "png")
    result.ok = true
  except CatchableError as e:
    result.error = e.msg

proc tile*(m: Mbtiles; z, x, y: int): string =
  ## The bytes of tile `z`/`x`/`y` ("" none); MBTiles numbers its rows from
  ## the south (TMS): turned here.
  if m == nil or not m.ok: return ""
  let row = (1 shl z) - 1 - y
  try:
    for r in m.db.rows("SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?",
                       z, x, row):
      return gunzipped(r[0].str)
  except CatchableError:
    discard
  ""

proc close*(m: Mbtiles) =
  if m != nil and m.ok:
    m.db.close()
    m.ok = false

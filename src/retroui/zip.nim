## ZIP archives in plain Nim: list, extract and create them (stored and
## deflated entries, UTF-8 names). ZIP64 archives are read (MSIX packages,
## files over 4 GB); the archives made here are up to 4 GB.
##
## .. code-block:: nim
##   var z = newZipWriter()
##   z.addFile("notes.txt", readFile("notes.txt"))
##   writeFile("notes.zip", z.finish())
##
##   for e in zipEntries("notes.zip"): echo e.name, " ", e.size
##   extractZip("notes.zip", "out")

import std/[os, times, strutils]
import codec

export codec.Bytes, codec.toBytes

type
  ZipError* = object of CatchableError
    ## An archive that cannot be read (not a zip, damaged, a method other
    ## than stored or deflated), or an entry that would land outside the
    ## folder it is extracted to.
  ZipEntry* = object
    ## A file or folder in an archive (`zipEntries`).
    name*: string            ## path inside the archive, '/' separated
    size*, packed*: int      ## uncompressed and stored sizes
    crc*: uint32             ## the CRC-32 of its contents
    compression*: int        ## 0 stored, 8 deflated
    time*: Time              ## when it last changed
    isDir*: bool             ## a folder
    offset: int              ## of the local header
  ZipWriter* = object
    ## An archive being made in memory (`newZipWriter`, `addFile`, `finish`).
    data: Bytes
    central: Bytes
    count: int

proc toStr(b: openArray[byte]): string =
  result = newString(b.len)
  if b.len > 0: copyMem(addr result[0], unsafeAddr b[0], b.len)

proc u16(b: var Bytes; v: int) =
  b.add byte(v and 0xFF); b.add byte((v shr 8) and 0xFF)
proc u32(b: var Bytes; v: SomeInteger) =
  let x = uint32(v)
  for i in 0 .. 3: b.add byte((x shr (8 * i)) and 0xFF)
proc rd16(s: string; i: int): int = ord(s[i]) or (ord(s[i+1]) shl 8)
proc rd32(s: string; i: int): int =
  ord(s[i]) or (ord(s[i+1]) shl 8) or (ord(s[i+2]) shl 16) or (ord(s[i+3]) shl 24)
proc rd64(s: string; i: int): int64 =
  for k in countdown(7, 0): result = (result shl 8) or int64(ord(s[i + k]))

proc dosTime(t: Time): tuple[time, date: int] =
  let d = t.local
  let y = max(1980, d.year)
  ((d.hour shl 11) or (d.minute shl 5) or (d.second div 2),
   ((y - 1980) shl 9) or (ord(d.month) shl 5) or d.monthday)

proc fromDos(time, date: int): Time =
  ## A DOS date and time (1980-01-01 when they are not a real date).
  let year = 1980 + ((date shr 9) and 127)
  let month = (date shr 5) and 15
  let day = date and 31
  let hour = (time shr 11) and 31
  let minute = (time shr 5) and 63
  let second = (time and 31) * 2
  if month notin 1 .. 12 or day notin 1 .. getDaysInMonth(Month(month), year) or
     hour > 23 or minute > 59 or second > 59:
    return fromUnix(315532800)
  try:
    dateTime(year, Month(month), MonthdayRange(day), HourRange(hour),
             MinuteRange(minute), SecondRange(second), 0, local()).toTime
  except ValueError:
    fromUnix(315532800)

# ---- reading ------------------------------------------------------------------

proc zipEntries*(archive: string): seq[ZipEntry] =
  ## The entries of the zip file `archive` (read from its central
  ## directory: only the end of the file is read, however big it is).
  var f: File
  if not open(f, archive): raise newException(ZipError, "cannot open " & archive)
  defer: f.close()
  let size = getFileSize(f)
  let tailLen = int(min(size, 22 + 65535))
  var tail = newString(tailLen)
  f.setFilePos(size - tailLen)
  if tailLen > 0 and f.readBuffer(addr tail[0], tailLen) != tailLen:
    raise newException(ZipError, "cannot read " & archive)
  var e = -1
  var i = tail.len - 22
  while i >= 0:
    if tail.rd32(i) == 0x06054b50:
      e = i
      break
    dec i
  if e < 0: raise newException(ZipError, archive & " is not a zip file")
  var n = int64(tail.rd16(e + 10))
  var cdSize = int64(uint32(tail.rd32(e + 12)))
  var cdAt = int64(uint32(tail.rd32(e + 16)))
  if cdAt == 0xFFFFFFFF'i64 or n == 0xFFFF or cdSize == 0xFFFFFFFF'i64:
    # ZIP64: the locator just before the end record, then its own end record
    if e < 20 or tail.rd32(e - 20) != 0x07064b50:
      raise newException(ZipError, "the zip directory is damaged")
    let at = tail.rd64(e - 20 + 8)
    if at < 0 or at + 56 > size: raise newException(ZipError, "the zip directory is damaged")
    var rec = newString(56)
    f.setFilePos(at)
    if f.readBuffer(addr rec[0], 56) != 56 or rec.rd32(0) != 0x06064b50:
      raise newException(ZipError, "the zip directory is damaged")
    n = rec.rd64(32)
    cdSize = rec.rd64(40)
    cdAt = rec.rd64(48)
  if cdAt < 0 or cdSize < 0 or n < 0 or cdAt + cdSize > size or cdSize > high(int) or
     n > cdSize div 46 + 1:
    raise newException(ZipError, "the zip directory is damaged")
  var s = newString(int(cdSize))
  f.setFilePos(cdAt)
  if cdSize > 0 and f.readBuffer(addr s[0], int(cdSize)) != int(cdSize):
    raise newException(ZipError, "cannot read the zip directory")
  var p = 0
  for _ in 0 ..< n:
    if p + 46 > s.len or s.rd32(p) != 0x02014b50:
      raise newException(ZipError, "the zip directory is damaged")
    let nameLen = s.rd16(p + 28)
    let extraLen = s.rd16(p + 30)
    let commentLen = s.rd16(p + 32)
    if p + 46 + nameLen > s.len:
      raise newException(ZipError, "the zip directory is damaged")
    if p + 46 + nameLen + extraLen > s.len:
      raise newException(ZipError, "the zip directory is damaged")
    var packed = int64(uint32(s.rd32(p + 20)))
    var usize = int64(uint32(s.rd32(p + 24)))
    var offset = int64(uint32(s.rd32(p + 42)))
    # (ZIP64: the sizes and offset that did not fit, in its extra field)
    var x = p + 46 + nameLen
    let xEnd = x + extraLen
    while x + 4 <= xEnd:
      let id = s.rd16(x)
      let len = s.rd16(x + 2)
      if id == 1:
        var q = x + 4
        for v in [addr usize, addr packed, addr offset]:
          if v[] == 0xFFFFFFFF'i64 and q + 8 <= x + 4 + len and q + 8 <= xEnd:
            v[] = s.rd64(q)
            q += 8
      x += 4 + len
    if packed < 0 or usize < 0 or offset < 0 or packed > high(int) or usize > high(int) or
       offset > high(int):
      raise newException(ZipError, "the zip directory is damaged")
    var en = ZipEntry(compression: s.rd16(p + 10),
                      time: fromDos(s.rd16(p + 12), s.rd16(p + 14)),
                      crc: uint32(s.rd32(p + 16)), packed: int(packed),
                      size: int(usize), offset: int(offset),
                      name: s[p + 46 ..< p + 46 + nameLen].replace('\\', '/'))
    en.isDir = en.name.endsWith("/")
    result.add en
    p += 46 + nameLen + extraLen + commentLen

proc readEntry*(archive: string; e: ZipEntry): string =
  ## The uncompressed content of entry `e` of `archive`.
  var f = open(archive)
  defer: f.close()
  var head = newString(30)
  f.setFilePos(e.offset)
  if f.readBuffer(addr head[0], 30) != 30 or head.rd32(0) != 0x04034b50:
    raise newException(ZipError, "damaged entry: " & e.name)
  let skip = head.rd16(26) + head.rd16(28)
  if e.packed < 0 or e.size < 0 or e.offset + 30 + skip + e.packed > getFileSize(f):
    raise newException(ZipError, "damaged entry: " & e.name)
  var packed = newString(e.packed)
  f.setFilePos(e.offset + 30 + skip)
  if e.packed > 0 and f.readBuffer(addr packed[0], e.packed) != e.packed:
    raise newException(ZipError, "the archive ends too soon: " & e.name)
  # (made in a local, `result` given it once it is good: Nim 2.2 does not
  # free a `result` the proc then raises past -- every damaged entry read
  # leaked its content)
  var data: string
  case e.compression
  of 0: data = move packed
  of 8:
    # no more than the directory says it holds (a "zip bomb" stops there)
    try: data = inflate(packed.toBytes, maxOut = e.size).toStr
    except InflateError as x: raise newException(ZipError, e.name & ": " & x.msg)
  else:
    raise newException(ZipError, e.name & ": compression method " &
                       $e.compression & " is not supported")
  if crc32(data.toBytes) != e.crc:
    raise newException(ZipError, e.name & ": checksum does not match")
  result = move data

proc safeTarget*(dest, name: string): string =
  ## Where entry `name` goes under `dest`; refuses names that would
  ## climb out of it ("../", absolute paths).
  var parts: seq[string]
  for p in name.split('/'):
    if p.len == 0 or p == ".": continue
    if p == ".." or ':' in p or '\\' in p:
      raise newException(ZipError, "unsafe name in the archive: " & name)
    parts.add p
  result = dest
  for p in parts: result = result / p

proc extractEntry*(archive: string; e: ZipEntry; dest: string) =
  ## Writes entry `e` under the folder `dest` (folders are created).
  let target = safeTarget(dest, e.name)
  if e.isDir:
    createDir(target)
  else:
    createDir(target.parentDir)
    writeFile(target, readEntry(archive, e))
    try: setLastModificationTime(target, e.time) except OSError: discard

proc extractZip*(archive, dest: string) =
  ## Every entry of `archive` under the folder `dest`.
  for e in zipEntries(archive): extractEntry(archive, e, dest)

# ---- writing ------------------------------------------------------------------

proc newZipWriter*(): ZipWriter = ZipWriter()
  ## An empty archive to add files to.

const storedKinds = [".zip", ".jpg", ".jpeg", ".png", ".gif", ".webp", ".mp3",
                     ".mp4", ".m4a", ".mkv", ".avi", ".mov", ".apk", ".jar",
                     ".gz", ".xz", ".bz2", ".7z", ".rar", ".heic", ".ogg", ".opus"]

proc addFile*(z: var ZipWriter; name, content: string; time = getTime();
              compress = true; executable = false) =
  ## Adds a file `name` ('/' separated) with `content`. Content that is
  ## already compressed (pictures, music, archives) is stored as it is.
  ## `executable`: marked as a program (for Unix, macOS and iOS).
  let raw = content.toBytes
  let crc = crc32(raw)
  var packed: Bytes
  var methodNo = 0
  if compress and name.toLowerAscii.splitFile.ext notin storedKinds and raw.len > 0:
    packed = deflate(raw)
    if packed.len < raw.len: methodNo = 8
  if methodNo == 0: packed = raw
  let (t, d) = dosTime(time)
  var flags = 0
  for c in name:
    if ord(c) >= 0x80: flags = 0x800        # UTF-8 name
  let offset = z.data.len
  var h: Bytes
  h.u32(0x04034b50); h.u16(20); h.u16(flags); h.u16(methodNo)
  h.u16(t); h.u16(d); h.u32(crc); h.u32(packed.len); h.u32(raw.len)
  h.u16(name.len); h.u16(0)
  for c in name: h.add byte(c)
  z.data.add h
  z.data.add packed
  var c: Bytes
  c.u32(0x02014b50); c.u16(0x031E); c.u16(20); c.u16(flags); c.u16(methodNo)
  c.u16(t); c.u16(d); c.u32(crc); c.u32(packed.len); c.u32(raw.len)
  c.u16(name.len); c.u16(0); c.u16(0); c.u16(0); c.u16(0)
  c.u32((if name.endsWith("/"): 0o40755 elif executable: 0o100755 else: 0o100644) shl 16)
  c.u32(offset)
  for ch in name: c.add byte(ch)
  z.central.add c
  inc z.count

proc addDir*(z: var ZipWriter; name: string; time = getTime()) =
  ## Adds an (empty) folder entry.
  z.addFile(if name.endsWith("/"): name else: name & "/", "", time, false)

proc finish*(z: ZipWriter): string =
  ## The archive's bytes.
  if z.count > 0xFFFF or z.data.len > 0x7FFFFFFF:
    raise newException(ZipError, "too large for a zip file without ZIP64")
  var b = z.data
  b.add z.central
  b.u32(0x06054b50); b.u16(0); b.u16(0); b.u16(z.count); b.u16(z.count)
  b.u32(z.central.len); b.u32(z.data.len); b.u16(0)
  b.toStr

proc zipFolder*(folder, archive: string) =
  ## Zips `folder` (its name becomes the top folder in the archive).
  var z = newZipWriter()
  let base = folder.parentDir
  z.addDir(folder.extractFilename, getLastModificationTime(folder))
  for p in walkDirRec(folder, {pcFile, pcDir}, relative = false):
    let rel = p.relativePath(base).replace('\\', '/')
    if dirExists(p): z.addDir(rel, getLastModificationTime(p))
    else: z.addFile(rel, readFile(p), getLastModificationTime(p))
  writeFile(archive, z.finish())

## Tar archives (.tar), and gzip'd ones (.tar.gz, .tgz) -- the archives
## of Linux and of source code: their entries listed and their files read,
## as `retroui/zip` does for zips. POSIX ustar with GNU's long names and
## pax's long paths; links and devices are listed but not extracted. A
## damaged or cut archive gives the entries before the damage.
##
## .. code-block:: nim
##   let t = readTar("src.tar.gz")
##   for e in t.entries:
##     if not e.isDir: echo e.name, " ", e.size
##   writeFile("README", t.fileOf(t.entries[0]))
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, times, os]
import codec

type
  TarEntry* = object
    ## A file, a folder or a link of a tar archive (`readTar`).
    name*: string            ## its path inside the archive, '/' separated
    size*: int64
    time*: Time              ## when it last changed
    isDir*: bool
    isLink*: bool            ## a link (or a device): listed, not extracted
    offset: int              ## (of its bytes in the archive)
  Tar* = object
    ## An archive read: its bytes (unpacked when gzip'd) and its entries.
    entries*: seq[TarEntry]
    data: string

const MaxTarBytes* = 2'i64 * 1024 * 1024 * 1024
  ## The most an archive may unpack to (a "tar bomb" stops there).

proc isTarName*(name: string): bool =
  ## A tar archive by its name: .tar, .tar.gz, .tgz.
  let n = name.toLowerAscii
  n.endsWith(".tar") or n.endsWith(".tar.gz") or n.endsWith(".tgz")

proc gunzip*(data: string; maxOut = MaxTarBytes): string =
  ## The bytes of a gzip file (RFC 1952; its members one after another);
  ## `ValueError` when it is not one or is damaged.
  if data.len < 18 or data[0] != '\x1f' or data[1] != '\x8b' or data[2] != '\x08':
    raise newException(ValueError, "not gzip")
  # (into a string of its own, `result` given at the end: a `result` filled
  # and then a raise is never freed -- docs/nim-bugs.md)
  var o = ""
  var at = 0
  while at + 18 <= data.len and data[at] == '\x1f' and data[at + 1] == '\x8b':
    let flags = int(data[at + 3].byte)
    var p = at + 10
    if (flags and 4) != 0 and p + 2 <= data.len:                  # FEXTRA
      p += 2 + (int(data[p].byte) or (int(data[p + 1].byte) shl 8))
    for bit in [8, 16]:                                           # FNAME, FCOMMENT
      if (flags and bit) != 0:
        while p < data.len and data[p] != '\0': inc p
        inc p
    if (flags and 2) != 0: p += 2                                 # FHCRC
    if p >= data.len: raise newException(ValueError, "gzip cut short")
    var used = 0
    let b = inflate(data.toOpenArrayByte(0, data.high), p, addr used,
                    maxOut = int(min(maxOut, int64(high(int) div 2))) - o.len)
    let n = o.len
    o.setLen(n + b.len)
    if b.len > 0: copyMem(addr o[n], unsafeAddr b[0], b.len)
    at = p + used + 8                                             # (CRC-32, size)
  result = move o

proc octal(s: string; a, n: int): int64 =
  ## (a header's number: octal digits, or GNU's big-endian binary)
  if a >= s.len: return 0
  if (s[a].byte and 0x80) != 0:
    for i in a + 1 ..< min(s.len, a + n): result = (result shl 8) or int64(s[i].byte)
    return
  for i in a ..< min(s.len, a + n):
    let c = s[i]
    if c in {'0' .. '7'}: result = result * 8 + int64(ord(c) - ord('0'))
    elif result > 0 or c notin {' ', '\0'}: break

proc field(s: string; a, n: int): string =
  ## (a header's text: up to its first zero)
  var e = a
  while e < min(s.len, a + n) and s[e] != '\0': inc e
  if a < e: s[a ..< e] else: ""

proc entriesOf(d: string): seq[TarEntry] =
  var at = 0
  var longName = ""
  while at + 512 <= d.len:
    if d[at] == '\0' and d[at ..< at + 512].count('\0') == 512: break   # (the end)
    var sum = 0'i64
    for i in 0 ..< 512: sum += (if i in 148 ..< 156: 32'i64 else: int64(d[at + i].byte))
    if sum != octal(d, at + 148, 8): break                               # (damaged)
    let size = octal(d, at + 124, 12)
    if size < 0 or size > int64(d.len): break
    let kind = d[at + 156]
    let body = at + 512
    let next = body + int((size + 511) div 512 * 512)
    var name = field(d, at, 100)
    if field(d, at + 257, 6) == "ustar":
      let prefix = field(d, at + 345, 155)
      if prefix.len > 0: name = prefix & "/" & name
    case kind
    of 'L':                                    # GNU: the next one's long name
      if body + int(size) <= d.len: longName = field(d, body, int(size))
    of 'x':                                    # pax: the next one's path
      if body + int(size) <= d.len:
        for line in d[body ..< body + int(size)].splitLines:
          let sp = line.find(' ')
          if sp > 0 and line.continuesWith("path=", sp + 1): longName = line[sp + 6 .. ^1]
    of 'g': discard                            # (pax's global header)
    else:
      if longName.len > 0:
        name = longName
        longName = ""
      var e = TarEntry(name: name, size: size, offset: body,
                       time: fromUnix(octal(d, at + 136, 12)))
      e.isDir = kind == '5' or name.endsWith("/")
      e.isLink = kind in {'1', '2', '3', '4', '6'}
      if e.isDir or e.isLink: e.size = 0
      if name.len > 0 and name != "./": result.add e
    at = next

proc tarFrom*(data: string): Tar =
  ## The archive whose bytes are `data` (gzip'd or not).
  result.data = if data.len > 2 and data[0] == '\x1f' and data[1] == '\x8b': gunzip(data) else: data
  result.entries = entriesOf(result.data)

proc readTar*(path: string): Tar =
  ## The archive at `path` (.tar, .tar.gz, .tgz) read whole; `IOError` when
  ## it cannot be read, `ValueError` when its gzip is damaged.
  if getFileSize(path) > MaxTarBytes: raise newException(IOError, "the archive is too big")
  tarFrom(readFile(path))

proc fileOf*(t: Tar; e: TarEntry): string =
  ## The bytes of file `e` of archive `t`.
  if e.isDir or e.isLink or e.offset + int(e.size) > t.data.len: return ""
  t.data[e.offset ..< e.offset + int(e.size)]

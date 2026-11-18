## Files of any size, read a window at a time: `TextFile` finds the lines
## of a text (in slices, so a 1 GB log opens at once and its lines are
## counted while you read the first ones), `HexFile` shows any file as
## hex dump lines. Both feed `lineView`. A file that cannot be read on
## (a disk failing, a share gone, some of the system's own files) shows what
## was read; why, in `error`.
##
## .. code-block:: nim
##   var t = openTextFile("big.log")
##   # every frame:
##   t.index()                          # a few milliseconds more of counting
##   lineView(t.lineCount, proc (i: int): string = t.line(i), sel)

import std/[monotimes, times, strutils]

const
  Window = 256 * 1024          ## bytes read at once around what is shown
  MaxLine = 4000               ## longer lines are cut (for showing)

type
  BlockFile = object
    f: File
    size: int64
    buf: string                ## a window of the file ...
    bufAt: int64               ## ... starting here
    open: bool
    error: string              ## why the file could be read no further ("": it could)

  TextFile* = ref object
    ## A text file open for reading by lines (`openTextFile`); its lines are
    ## found a little at a time (`index`).
    path*: string              ## the file
    data: BlockFile
    starts: seq[int64]         ## where each line starts
    scanned: int64             ## bytes looked at for line ends
    done*: bool                ## every line is known

  HexFile* = ref object
    ## A file open for showing as hex, 16 bytes a line (`openHexFile`).
    path*: string              ## the file
    data: BlockFile

proc openBlocks(path: string): BlockFile =
  if not open(result.f, path): raise newException(IOError, "cannot open " & path)
  result.open = true
  result.size = getFileSize(result.f)
  result.bufAt = -1

proc closeBlocks(b: var BlockFile) =
  if b.open:
    b.f.close()
    b.open = false

proc fetch(b: var BlockFile; at, n: int64): string =
  ## Bytes `at ..< at + n` (fewer at the end of the file).
  let n = min(n, b.size - at)
  if n <= 0 or at < 0: return ""
  if b.bufAt < 0 or at < b.bufAt or at + n > b.bufAt + b.buf.len:
    let start = max(0'i64, at - Window div 4)
    let len = int(min(int64(max(Window, int(n) + Window div 4)), b.size - start))
    b.buf.setLen(max(1, len))
    var got = 0
    try:
      b.f.setFilePos(start)
      got = if len > 0: b.f.readBuffer(addr b.buf[0], len) else: 0
    except IOError as e:
      # (read no further: the file ends here for what shows it)
      b.error = e.msg
      b.size = start
      got = 0
    b.buf.setLen(max(0, got))
    b.bufAt = start
  # (the file may have become shorter since it was opened: a log rotated)
  let o = at - b.bufAt
  if o < 0 or o >= b.buf.len: return ""
  b.buf[int(o) ..< int(min(int64(b.buf.len), o + n))]

# ---- text ------------------------------------------------------------------------------

proc openTextFile*(path: string): TextFile =
  ## Opens `path`; its lines are found by `index` (raises IOError).
  result = TextFile(path: path, data: openBlocks(path))
  result.starts = @[0'i64]
  result.done = result.data.size == 0

proc size*(t: TextFile): int64 = t.data.size
  ## The file's size in bytes.

proc index*(t: TextFile; budgetMs = 8) =
  ## Counts more lines, for about `budgetMs` milliseconds.
  if t.done: return
  let deadline = getMonoTime() + initDuration(milliseconds = budgetMs)
  var chunk = newString(1024 * 1024)
  while not t.done and getMonoTime() < deadline:
    var got = 0
    try:
      t.data.f.setFilePos(t.scanned)
      got = t.data.f.readBuffer(addr chunk[0], chunk.len)
    except IOError as e:
      # (the lines found so far are all it has)
      t.data.error = e.msg
      t.data.size = t.scanned
      got = 0
    if got <= 0:
      t.done = true
      break
    var i = 0
    while i < got:
      let k = chunk.find('\n', i, got - 1)
      if k < 0: break
      t.starts.add t.scanned + k + 1
      i = k + 1
    t.scanned += got
    if t.scanned >= t.data.size: t.done = true
  # the last line has no line end
  if t.done and t.starts.len > 1 and t.starts[^1] >= t.data.size:
    t.starts.setLen(t.starts.len - 1)

proc error*(t: TextFile): string = t.data.error
  ## Why the file could be read no further ("": it could).

proc progress*(t: TextFile): float =
  ## How much of the file has been looked at (0..1).
  if t.data.size == 0: 1.0 else: t.scanned.float / t.data.size.float

proc lineCount*(t: TextFile): int =
  ## The lines known so far (all of them once `done`).
  if t.done: t.starts.len else: max(0, t.starts.len - 1)

proc line*(t: TextFile; i: int): string =
  ## Line `i`, without its line end (long lines are cut).
  if i < 0 or i >= t.starts.len: return ""
  let a = t.starts[i]
  let b = if i + 1 < t.starts.len: t.starts[i + 1] else: t.data.size
  result = t.data.fetch(a, min(b - a, MaxLine))
  if result.endsWith('\n'): result.setLen(result.len - 1)
  if result.endsWith('\r'): result.setLen(result.len - 1)
  result = result.replace("\t", "    ")

proc close*(t: TextFile) =
  ## Closes the file.
  if t != nil: t.data.closeBlocks()

# ---- hex -------------------------------------------------------------------------------

proc openHexFile*(path: string): HexFile =
  ## Opens `path` to show as hex, 16 bytes a line (raises IOError).
  HexFile(path: path, data: openBlocks(path))

proc size*(h: HexFile): int64 = h.data.size
  ## The file's size in bytes.

proc error*(h: HexFile): string = h.data.error
  ## Why the file could be read no further ("": it could).

proc lineCount*(h: HexFile): int = int((h.data.size + 15) div 16)
  ## How many lines of 16 bytes it shows.

proc line*(h: HexFile; i: int): string =
  ## "00000010  48 65 6C 6C 6F ...  Hello..." for bytes 16 i ..< 16 i + 16.
  let at = int64(i) * 16
  let bytes = h.data.fetch(at, 16)
  result = toHex(at, 8) & "  "
  var chars = ""
  for k in 0 ..< 16:
    if k < bytes.len:
      result.add toHex(ord(bytes[k]), 2) & " "
      chars.add(if bytes[k] in {' '..'~'}: bytes[k] else: '.')
    else: result.add "   "
    if k == 7: result.add " "
  result.add " " & chars

proc close*(h: HexFile) =
  ## Closes the file.
  if h != nil: h.data.closeBlocks()

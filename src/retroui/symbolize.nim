## A crash's addresses named: an app's report of a native crash (the
## "stopped" screen's, `libmain.so+0x386786`) or Android's (logcat's
## tombstone, `#00 pc 0000000000386786 .../libmain.so`), each frame in the
## app's library looked up in that library's symbol table -- the copy kept
## with its names (`retroapk` puts it in `<app>-symbols/<abi>/`; a
## `--debuggable` APK's own is not stripped). ELF, 64 bits (every Android
## ABI the kit builds); no tool but this.
##
## .. code-block:: nim
##   import retroui/symbolize
##   echo symbolizeReport(readFile("report.txt"), "build/RetroPhoto-symbols")
##
## `retrokit symbolize report.txt build/RetroPhoto-symbols` does it from the
## command line.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, algorithm, parseutils]

type
  ElfSymbol* = object
    start*, size*: uint64
    name*: string
  ElfSymbols* = object
    ## A library's functions, by where they start.
    ok*: bool
    error*: string
    syms*: seq[ElfSymbol]

proc u16(s: string; at: int): uint64 =
  if at + 2 > s.len: return 0
  uint64(uint8(s[at])) or (uint64(uint8(s[at + 1])) shl 8)
proc u32(s: string; at: int): uint64 =
  if at + 4 > s.len: return 0
  for k in 0 .. 3: result = result or (uint64(uint8(s[at + k])) shl (8 * k))
proc u64(s: string; at: int): uint64 =
  if at + 8 > s.len: return 0
  for k in 0 .. 7: result = result or (uint64(uint8(s[at + k])) shl (8 * k))

proc cstrAt(s: string; at: int): string =
  if at < 0 or at >= s.len: return ""
  let e = s.find('\0', at)
  s[at ..< (if e < 0: s.len else: e)]

proc readElfSymbols*(data: string): ElfSymbols =
  ## The functions of an ELF file (64 bits, little-endian): from its symbol
  ## table, else the dynamic one (what a stripped library still has).
  if data.len < 64 or data[0 .. 3] != "\x7fELF":
    result.error = "not an ELF file"
    return
  if data[4] != '\x02' or data[5] != '\x01':
    result.error = "not a 64-bit little-endian ELF file"
    return
  let shoff = int(u64(data, 0x28))
  let shentsize = int(u16(data, 0x3A))
  let shnum = int(u16(data, 0x3C))
  if shoff <= 0 or shentsize < 64 or shnum <= 0 or shoff + shnum * shentsize > data.len:
    result.error = "its section headers cannot be read"
    return
  proc sec(i: int): tuple[kind, off, size, link, entsize: int] =
    let b = shoff + i * shentsize
    (int(u32(data, b + 4)), int(u64(data, b + 24)), int(u64(data, b + 32)),
     int(u32(data, b + 40)), int(u64(data, b + 56)))
  # SHT_SYMTAB (2) when it is there, else SHT_DYNSYM (11)
  for want in [2, 11]:
    for i in 0 ..< shnum:
      let s = sec(i)
      if s.kind != want or s.entsize < 24 or s.link >= shnum: continue
      let strs = sec(s.link)
      if s.off + s.size > data.len or strs.off + strs.size > data.len: continue
      for k in 0 ..< s.size div s.entsize:
        let b = s.off + k * s.entsize
        let info = uint8(data[b + 4])
        if (info and 0xF) != 2: continue                      # STT_FUNC
        let value = u64(data, b + 8)
        if value == 0: continue
        let name = cstrAt(data, strs.off + int(u32(data, b)))
        if name.len > 0:
          result.syms.add ElfSymbol(start: value, size: u64(data, b + 16), name: name)
    if result.syms.len > 0: break
  result.syms.sort(proc (a, b: ElfSymbol): int = cmp(a.start, b.start))
  result.ok = result.syms.len > 0
  if not result.ok: result.error = "it has no functions' names (stripped)"

proc nimName*(mangled: string): string =
  ## A Nim function's C name made readable: "beginFrame__OOZsrcZretrouiZcore_u12585"
  ## -> "beginFrame (src/retroui/core)"; another name as it is.
  let at = mangled.find("__")
  if at <= 0: return mangled
  var module = mangled[at + 2 .. ^1]
  let u = module.rfind("_u")
  if u > 0 and module[u + 2 .. ^1].allCharsInSet(Digits): module = module[0 ..< u]
  module = module.replace("OO", "..").replace('Z', '/')
  while module.startsWith("../"): module = module[3 .. ^1]
  if module.len == 0: return mangled
  mangled[0 ..< at] & " (" & module & ")"

proc lookup*(e: ElfSymbols; offset: uint64): tuple[name: string; delta: uint64] =
  ## The function `offset` (in the library) is in, and how far into it;
  ## "" when none.
  var lo = 0
  var hi = e.syms.high
  var best = -1
  while lo <= hi:
    let m = (lo + hi) div 2
    if e.syms[m].start <= offset:
      best = m
      lo = m + 1
    else: hi = m - 1
  if best < 0: return ("", 0)
  let s = e.syms[best]
  if s.size > 0 and offset >= s.start + s.size and offset - s.start > 0x10000: return ("", 0)
  (s.name, offset - s.start)

proc frameOffset(line: string): uint64 =
  ## (a frame's offset in libmain.so, from either form; 0 when the line has none)
  if "libmain.so" notin line: return 0
  let plus = line.find("libmain.so+0x")
  if plus >= 0:
    var v: BiggestUInt
    if parseHex(line, v, plus + "libmain.so+0x".len) > 0: return uint64(v)
  let pc = line.find(" pc ")
  if pc >= 0:
    var v: BiggestUInt
    if parseHex(line, v, pc + 4) > 0: return uint64(v)

proc abiOf(report: string): string =
  for (k, abi) in [("arm64", "arm64-v8a"), ("x86_64", "x86_64"), ("aarch64", "arm64-v8a")]:
    if "/lib/" & k & "/" in report or abi in report: return abi

proc symbolizeReport*(report, symbols: string): string =
  ## `report` with each frame in libmain.so followed by its function's name.
  ## `symbols`: the library kept with its names, or the folder of them (one
  ## for each ABI: the report's is taken, else arm64-v8a, else the one there).
  var lib = symbols
  if dirExists(symbols):
    let abi = abiOf(report)
    lib = ""
    for a in [abi, "arm64-v8a", "x86_64"]:
      if a.len > 0 and fileExists(symbols / a / "libmain.so"):
        lib = symbols / a / "libmain.so"
        break
    if lib.len == 0:
      for f in walkDirRec(symbols):
        if f.extractFilename == "libmain.so":
          lib = f
          break
  if lib.len == 0 or not fileExists(lib):
    return report & "\n(no libmain.so in " & symbols & ")"
  let e = readElfSymbols(try: readFile(lib) except IOError: "")
  if not e.ok: return report & "\n(" & lib & ": " & e.error & ")"
  var lines: seq[string]
  for line in report.splitLines:
    let off = frameOffset(line)
    if off == 0:
      lines.add line
      continue
    let (name, delta) = e.lookup(off)
    lines.add(if name.len > 0: line & "  -- " & nimName(name) & " +0x" & toHex(delta).strip(trailing = false, chars = {'0'})
              else: line & "  -- ?")
  lines.join("\n")

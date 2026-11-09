## Memory: how much the device has and has free, how much this program
## uses -- and budgets for caches that follow them, so a program keeps what
## makes it fast (decoded pictures, pages, thumbnails) while there is room
## and lets it go when the device runs short or the program is sent to the
## background.
##
## - `deviceMemory`, `freeMemory`, `programMemory`: the numbers, in bytes
##   (0 when the system does not say).
## - `cacheBudget`: a share of the device's memory, between two limits --
##   what one cache may keep.
## - `memoryPressure`: `mpNone`, `mpLow` or `mpCritical`, measured at most
##   every two seconds (call it as often as you like).
## - `onMemoryPressure`: procs called when memory runs short (when the
##   level rises, and again every ten seconds while it stays up) and when
##   the program goes to the background (`mpLow` at least: a phone ends the
##   programs in the background that keep the most). The toolkit's picture
##   cache (`retroui/filewidgets`) is one of them.
## - `memoryReport`: the numbers as a line of text (an About box, a status
##   bar).
## - `trimHeap`: the memory the program let go of given back to the system
##   (malloc_trim, Android's M_PURGE). It is done by itself after the caches
##   let go, when the program goes to the background, and now and then while
##   it waits for input after its memory grew -- what the system shows as the
##   program's memory follows what it really keeps.
## - `programBudget`: how much the program may hold before its caches are
##   told to let go even with the device far from short (a share of the
##   device's memory, 384 MB to 1.5 GB).
##
## Build programs with `-d:useMalloc` (the examples' config.nims and
## `retroapk` do): Nim's own allocator keeps every page it ever took, on
## each thread, and never gives them back -- a program that decodes many
## pictures on worker threads grows and grows. The toolkit warns at compile
## time without it (`-d:retroNimAlloc` keeps Nim's allocator, quietly).
##
## Linux, Android: /proc. Windows: GlobalMemoryStatusEx and the process's
## working set. macOS, iOS: the device's memory and the program's peak.
##
## .. code-block:: nim
##   import retroui, retroui/memwatch
##   onMemoryPressure(proc (level: MemoryPressure) =
##     if level == mpCritical: myCache.clear() else: myCache.trimHalf())

import std/[strutils, monotimes, times]
import core

when not defined(useMalloc) and not defined(retroNimAlloc) and not defined(nimscript):
  {.warning: "retroui: build with -d:useMalloc (the program's memory otherwise only grows: Nim's " &
             "allocator never gives pages back); -d:retroNimAlloc keeps Nim's allocator".}

when defined(useMalloc) and defined(android):
  # (mallopt came with Android 8: looked up as the program runs, so the
  # program still starts on Android 7)
  var RTLD_DEFAULT {.importc, header: "<dlfcn.h>".}: pointer
  proc dlsym(h: pointer; name: cstring): pointer {.importc, header: "<dlfcn.h>".}
  type MalloptFn = proc (param, value: cint): cint {.cdecl, gcsafe.}
  proc c_mallopt(param, value: cint): cint =
    let f = cast[MalloptFn](dlsym(RTLD_DEFAULT, "mallopt"))
    if f != nil: f(param, value) else: 0
elif defined(useMalloc) and defined(linux):
  proc c_mallopt(param, value: cint): cint {.importc: "mallopt", header: "<malloc.h>".}
when defined(useMalloc) and defined(linux) and not defined(android):
  proc c_malloc_trim(pad: csize_t): cint {.importc: "malloc_trim", header: "<malloc.h>".}
  # (big blocks -- pictures -- always mapped on their own, so freeing one
  # gives it back at once; glibc's threshold would otherwise rise to 32 MB
  # and keep them in its heap)
  discard c_mallopt(-3, 4 * 1024 * 1024)      # M_MMAP_THRESHOLD

type
  MemoryPressure* = enum
    ## How short the device is of memory (`memoryPressure`, `onMemoryPressure`).
    mpNone = "plenty"          ## room enough
    mpLow = "low"              ## caches should keep only what is on screen
    mpCritical = "critical"    ## let everything go that can be made again

  MemoryNumbers* = object
    ## Bytes; 0 when the system does not say.
    device*: int64             ## the device's memory
    free*: int64               ## ... free for programs (with what the system can give back)
    program*: int64            ## this program's (resident)

const MB = 1024'i64 * 1024

# ---- the numbers ------------------------------------------------------------------------------

when defined(windows):
  type
    MemStatusEx {.pure.} = object
      dwLength, dwMemoryLoad: uint32
      totalPhys, availPhys, totalPageFile, availPageFile, totalVirtual, availVirtual,
        availExtendedVirtual: uint64
    ProcessCounters {.pure.} = object
      cb, pageFaultCount: uint32
      peakWorkingSetSize, workingSetSize, quotaPeakPagedPoolUsage, quotaPagedPoolUsage,
        quotaPeakNonPagedPoolUsage, quotaNonPagedPoolUsage, pagefileUsage, peakPagefileUsage: uint
  proc globalMemoryStatusEx(p: ptr MemStatusEx): int32 {.stdcall, dynlib: "kernel32",
    importc: "GlobalMemoryStatusEx".}
  proc getCurrentProcess(): int {.stdcall, dynlib: "kernel32", importc: "GetCurrentProcess".}
  proc k32GetProcessMemoryInfo(h: int; p: ptr ProcessCounters; cb: uint32): int32 {.stdcall,
    dynlib: "kernel32", importc: "K32GetProcessMemoryInfo".}
elif defined(macosx) or defined(ios):
  proc sysctlbyname(name: cstring; oldp: pointer; oldlenp: ptr csize_t; newp: pointer;
                    newlen: csize_t): cint {.importc, header: "<sys/sysctl.h>".}
  type RUsage {.importc: "struct rusage", header: "<sys/resource.h>".} = object
    ru_maxrss: clong
  proc getrusage(who: cint; usage: ptr RUsage): cint {.importc, header: "<sys/resource.h>".}
else:
  proc sysconf(name: cint): clong {.importc, header: "<unistd.h>".}
  var SC_PAGESIZE {.importc: "_SC_PAGESIZE", header: "<unistd.h>".}: cint

proc measure(): MemoryNumbers =
  when defined(windows):
    var s = MemStatusEx(dwLength: uint32(sizeof(MemStatusEx)))
    if globalMemoryStatusEx(addr s) != 0:
      result.device = int64(s.totalPhys)
      result.free = int64(s.availPhys)
    var c = ProcessCounters(cb: uint32(sizeof(ProcessCounters)))
    try:
      if k32GetProcessMemoryInfo(getCurrentProcess(), addr c, c.cb) != 0:
        result.program = int64(c.workingSetSize)
    except CatchableError: discard
  elif defined(macosx) or defined(ios):
    var mem: uint64
    var n = csize_t(sizeof(mem))
    if sysctlbyname("hw.memsize", addr mem, addr n, nil, 0) == 0: result.device = int64(mem)
    var u: RUsage
    if getrusage(0, addr u) == 0: result.program = int64(u.ru_maxrss)   # (bytes there)
  else:
    try:
      for line in lines("/proc/meminfo"):
        let kb = if line.endsWith(" kB"): 1024'i64 else: 1
        proc num(l: string): int64 =
          try: parseBiggestInt(l.split(':')[1].strip.split(' ')[0]) except ValueError: 0
        if line.startsWith("MemTotal:"): result.device = num(line) * kb
        elif line.startsWith("MemAvailable:"): result.free = num(line) * kb
        if result.device > 0 and result.free > 0: break
    except CatchableError: discard
    try:
      let f = readFile("/proc/self/statm").split(' ')
      if f.len > 1:
        var page = int64(sysconf(SC_PAGESIZE))
        if page <= 0: page = 4096
        result.program = parseBiggestInt(f[1]) * page
    except CatchableError: discard

var
  last: MemoryNumbers
  lastAt = MonoTime()
  measured = false
  testLevel = -1                  # (`pretendMemoryPressure`)

proc memoryNumbers*(): MemoryNumbers =
  ## The device's memory, what is free, what this program uses (measured
  ## at most every two seconds).
  let now = getMonoTime()
  if not measured or (now - lastAt).inMilliseconds >= 2000:
    last = measure()
    lastAt = now
    measured = true
  last

proc deviceMemory*(): int64 = memoryNumbers().device
  ## The device's memory in bytes (0: not known).

proc freeMemory*(): int64 = memoryNumbers().free
  ## The memory free for programs in bytes, with what the system can give
  ## back at once (0: not known).

proc programMemory*(): int64 = memoryNumbers().program
  ## The memory this program uses in bytes (resident; on macOS its peak; 0:
  ## not known).

proc cacheBudget*(share = 0.03; lo = 16 * MB; hi = 192 * MB): int64 =
  ## What a cache may keep: `share` of the device's memory, no less than
  ## `lo` and no more than `hi` (bytes). Not known: 64 MB.
  let d = deviceMemory()
  if d <= 0: return clamp(64 * MB, lo, hi)
  clamp(int64(float(d) * share), lo, hi)

proc programBudget*(): int64 =
  ## How much the program may hold before its caches let go (`mpLow`)
  ## while the device still has room: a tenth of the device's memory, 384
  ## MB to 1.5 GB (1 GB when not known).
  let d = memoryNumbers().device
  if d <= 0: 1024 * MB else: clamp(d div 10, 384 * MB, 1536 * MB)

proc trimHeap*() =
  ## Gives the memory the program let go of back to the system (glibc's
  ## malloc_trim, Android's M_PURGE); a few milliseconds.
  when defined(useMalloc) and defined(android):
    discard c_mallopt(-101, 0)                   # M_PURGE (Android 9+; ignored before)
  elif defined(useMalloc) and defined(linux):
    discard c_malloc_trim(0)
  measured = false

proc pressureOf(n: MemoryNumbers): MemoryPressure =
  if n.device <= 0: return mpNone
  if n.free > 0:
    let f = n.free.float / n.device.float
    if f < 0.04 or n.free < 64 * MB: return mpCritical
    if f < 0.08 or n.free < 160 * MB: result = mpLow
  if n.program > 0:
    let p = n.program.float / n.device.float
    if p > 0.6: result = mpCritical; return
    if p > 0.4: result = mpLow

proc memoryPressure*(): MemoryPressure =
  ## How short the device is of memory now.
  if testLevel >= 0: return MemoryPressure(testLevel)
  pressureOf(memoryNumbers())

proc pretendMemoryPressure*(level: MemoryPressure; on = true) =
  ## For tests: `memoryPressure` says `level` until called with `on = false`.
  testLevel = if on: ord(level) else: -1
  measured = false

proc mb(b: int64): string =
  if b >= 1024 * MB: formatFloat(b.float / float(1024 * MB), ffDecimal, 1) & " GB"
  else: $(b div MB) & " MB"

proc memoryReport*(prefix = true): string =
  ## "Memory: 212 MB used by the program, 6.5 GB of 7.8 GB free" (what is
  ## known of it; without "Memory: " unless `prefix`).
  let n = memoryNumbers()
  var parts: seq[string]
  if n.program > 0: parts.add mb(n.program) & tr(" used by the program")
  if n.device > 0:
    parts.add(if n.free > 0: mb(n.free) & tr(" of ") & mb(n.device) & tr(" free")
              else: mb(n.device) & tr(" in the device"))
  if parts.len == 0: "" elif prefix: tr("Memory: ") & parts.join(tr(", ")) else: parts.join(tr(", "))

# ---- telling the caches -----------------------------------------------------------------------

var
  watchers: seq[proc (level: MemoryPressure) {.closure.}]
  told = mpNone
  toldAt = MonoTime()
  wasPaused = false

var
  trimmedAt = MonoTime()
  trimmedSize = 0'i64
  lastInput = MonoTime()
  overToldAt = 0'i64                # (the program's size when told it was over its budget)

proc tell(level: MemoryPressure) =
  told = level
  toldAt = getMonoTime()
  for w in watchers: w(level)
  # (short of memory, or in the background: the drawing's own caches too --
  # glyphs, icons, buffers -- made again when they are needed)
  if level == mpCritical or ui.paused: dropDrawingCaches()
  trimHeap()                                # (what they let go of: back to the system)
  trimmedAt = getMonoTime()
  trimmedSize = memoryNumbers().program

proc watchTick() {.nimcall.} =
  # (every frame: cheap -- the numbers are measured every two seconds)
  let now = getMonoTime()
  if ui.pressed or ui.key != KeyNone or ui.wheel != 0 or ui.mouseMoved: lastInput = now
  if ui.paused and not wasPaused:
    wasPaused = true
    tell(max(mpLow, memoryPressure()))     # (in the background: keep little)
    return
  if not ui.paused: wasPaused = false
  let level = memoryPressure()
  if level == mpNone:
    told = mpNone
    # (the program over its budget, the device not short: the caches told
    # once, and again only when it grew by a quarter more)
    let prog = memoryNumbers().program
    if testLevel < 0 and prog > programBudget() and prog > overToldAt + overToldAt div 4:
      overToldAt = prog
      for w in watchers: w(mpLow)
      trimHeap()
      trimmedAt = now
      trimmedSize = memoryNumbers().program
      return
    if prog < programBudget() * 3 div 4: overToldAt = 0
    # (resting: what was let go of given back, when the program grew since)
    if memoryNumbers().program > trimmedSize + 32 * MB:
      if (now - lastInput).inMilliseconds >= 1500 and (now - trimmedAt).inSeconds >= 15:
        trimHeap()
        trimmedAt = now
        trimmedSize = memoryNumbers().program
      else:
        wakeIn(1600)                        # (a frame when it rests, to give it back then)
    return
  if level > told or (now - toldAt).inSeconds >= 10: tell(level)

proc onMemoryPressure*(p: proc (level: MemoryPressure) {.closure.}) =
  ## `p` is called when the device runs short of memory or the program
  ## holds more than `programBudget` (when the level rises, then every ten
  ## seconds while it stays up) and when the program goes to the background
  ## -- let go of what can be made again.
  watchers.add p

# (every program of the kit watches its memory: the frames' hook)
beginFrameHooks.add watchTick

proc releaseMemory*(level = mpLow) =
  ## Tells the caches now (a menu command: "Free memory"; the tests).
  tell(level)

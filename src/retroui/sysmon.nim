## What the computer is doing: the processor (all of it and each core), the
## memory, the disks, the network, the battery, and every process with its
## share of them -- read on a thread of its own, so the window never waits
## for the system: a read that fails or takes too long leaves the last good
## numbers, marked `stale`.
##
## ============  ==================================================================
## Platform      Where it comes from
## ============  ==================================================================
## Linux         /proc (stat, meminfo, diskstats, net/dev, each process's stat,
##               status and io), /sys (the cores' speeds, the battery); a BSD
##               the same where its Linux /proc (linprocfs) is mounted
## Termux        the same; Android shows a shell its own processes only and no
##               processor times (Android 8 and later): the cores' speeds instead
## Android app   /proc for the memory and the app's own process, the network's
##               counts, the battery, the storage (Android shows no other app)
## Windows       one NtQuerySystemInformation for every process and the cores;
##               the memory, the network's interfaces, each physical drive's
##               counters, the drives, the battery
## macOS         host_statistics64, host_processor_info, proc_pidinfo for each
##               process, the network's interfaces, the disks (IOKit), the
##               volumes, the connections (libproc)
## Web page      the cores the browser tells; nothing else is the page's to see
## ============  ==================================================================
##
## .. code-block:: nim
##   import retroui, retroui/sysmon
##   startMonitor()                        # read every second, on its thread
##   app "Monitor", 500, 400:
##     let s = latestSample()              # never waits; nil before the first
##     if s != nil:
##       label "CPU " & $int(s.cpu) & " %, memory " & bytesText(s.memUsed)
##       for p in s.processes:
##         label p.name & "  " & $p.pid & "  " & formatFloat(p.cpu, ffDecimal, 1) & " %"
##
## What Argus taught (a task manager for Windows): read the system on a
## thread with a time limit, keep the last good numbers, know a process by
## its id *and* its start (an id is used again), compute rates from two real
## times, read the costly things (a program's path, its command line) once
## per process, sample less often when nobody looks.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, tables, times, locks, algorithm]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
when not defined(wasm):
  import std/os
when defined(macosx) and not defined(ios):
  import std/dynlib        # (IOKit and CoreFoundation for the disks' counts)
const threaded = compileOption("threads") and not defined(wasm)
  ## (a web page reads where it is asked, in its frame: no thread of its own)
when threaded:
  import std/typedthreads
when defined(posix) and not defined(ios):
  import std/posix         # (an iPhone shows an app nothing of this)

type
  ProcInfo* = object
    ## One process, as the last sample saw it.
    pid*, ppid*: int
    name*: string            ## the program's name ("firefox")
    exe*: string             ## its file, when the system shows it ("" else)
    command*: string         ## its command line ("" when not shown)
    user*: string            ## who runs it
    state*: char             ## R running, S sleeping, D waiting, T stopped, Z ended
    cpu*: float              ## percent of the whole computer (every core: 100)
    memory*: int64           ## bytes it has in memory (its resident set)
    threads*: int
    readRate*, writeRate*: float   ## its disk's bytes a second (where told)
    cpuSeconds*: float       ## the processor's time it took since it started
    started*: float          ## when it started (seconds since 1970): with the
                             ## pid, which process it is (an id is used again)
    nice*: int               ## its priority: -20 (first) .. 19 (last); Windows'
                             ## classes as -10 (high), -5, 0, 5, 10 (idle)
  CoreInfo* = object
    use*: float              ## percent; -1 unknown
    mhz*: int                ## its speed now (0 unknown)
  DiskInfo* = object
    ## A disk (a device): what it reads and writes.
    name*: string
    readRate*, writeRate*: float
    busy*: float             ## percent of the time it was working
  VolumeInfo* = object
    ## A place files live (a mounted file system, a drive).
    path*, device*: string
    total*, free*: int64
  NetInfo* = object
    name*: string
    rxRate*, txRate*: float  ## bytes a second in, out
    rxTotal*, txTotal*: int64
  Sample* = ref object
    ## Everything read at one moment.
    at*: float               ## when (epochTime)
    cpu*: float              ## the whole processor, percent; -1 unknown
    cores*: seq[CoreInfo]
    memTotal*, memUsed*, memAvailable*, memCached*: int64
    swapTotal*, swapUsed*: int64
    disks*: seq[DiskInfo]
    volumes*: seq[VolumeInfo]
    nets*: seq[NetInfo]
    battery*: int            ## percent; -1 no battery
    charging*: bool
    uptime*: float           ## seconds since the computer started
    processes*: seq[ProcInfo]
    threadCount*: int
    seesAll*: bool           ## every process is there (false: the system
                             ## shows this program its own only)
    stale*: bool             ## the last read failed: these are the last good numbers
    readMs*: float           ## how long the read took

  HistoryPoint* = object
    ## (a sample, small: for the charts of the last minutes, and the history)
    at*, cpu*: float
    memUsed*: int64
    memPercent*: float       ## the memory used, percent of all
    diskRate*, netRate*: float
    cores*: seq[float]

proc bytesText*(n: int64): string =
  ## 512 B, 1.5 KB, 23.4 MB, 1.21 GB (1024 a step).
  const units = ["B", "KB", "MB", "GB", "TB"]
  var v = n.float
  var u = 0
  while abs(v) >= 1024 and u < units.high:
    v /= 1024
    inc u
  if u == 0: $n & " B"
  elif v >= 100: $int(v + 0.5) & " " & units[u]
  else: formatFloat(v, ffDecimal, 1) & " " & units[u]

proc rateText*(bytesPerSecond: float): string =
  ## "0 KB/s", "1.4 MB/s".
  if bytesPerSecond < 1024: (if bytesPerSecond < 1: "0" else: "1") & " KB/s"
  else: bytesText(int64(bytesPerSecond)) & "/s"

# ---- the raw counters kept between two reads ----------------------------------------------------

type
  Raw = object
    at: float
    cpuTotal, cpuIdle: float
    cores: seq[tuple[total, idle: float]]
    procs: Table[int, tuple[started, cpu: float; read, write: int64]]
    disks: Table[string, tuple[read, write, ticks: int64]]
    nets: Table[string, tuple[rx, tx: int64]]

var raw: Raw                  # (the sampler's thread only)

when (defined(linux) or defined(android) or defined(bsd)) and not defined(wasm):
  # ---- Linux, Termux, an Android app: /proc and /sys -----------------------------------------------

  when androidApp:
    # (an app sees no other process, nor the network's or the battery's
    # files: Java's counts for those)
    import native

  let clockTicks = (when defined(posix): max(1, int(sysconf(SC_CLK_TCK))) else: 100)
  let pageBytes = (when defined(posix): max(1, int(sysconf(SC_PAGESIZE))) else: 4096)
  var bootTime = 0.0
  var userNames: Table[int, string]
  var exeOf: Table[(int, float), tuple[exe, command: string]]   # (pid, started): read once

  proc readSmall(path: string): string =
    ## (a /proc or /sys file: read whole; "" when it cannot be)
    try: readFile(path) except CatchableError: ""

  proc userName(uid: int): string =
    if uid in userNames: return userNames[uid]
    result = $uid
    when defined(posix):
      let pw = getpwuid(Uid(uid))
      if pw != nil and pw.pw_name != nil: result = $pw.pw_name
    userNames[uid] = result

  proc readBoot() =
    if bootTime > 0: return
    for line in readSmall("/proc/stat").splitLines:
      if line.startsWith("btime "):
        bootTime = (try: parseFloat(line[6 .. ^1].strip) except ValueError: 0.0)
    if bootTime == 0:
      let up = readSmall("/proc/uptime").splitWhitespace
      if up.len > 0: bootTime = epochTime() - (try: parseFloat(up[0]) except ValueError: 0.0)

  proc readCpu(s: Sample; dt: float) =
    let text = readSmall("/proc/stat")
    var cores: seq[tuple[total, idle: float]]
    for line in text.splitLines:
      if not line.startsWith("cpu"): continue
      let f = line.splitWhitespace
      if f.len < 5: continue
      var total = 0.0
      for i in 1 ..< min(f.len, 9): total += (try: parseFloat(f[i]) except ValueError: 0.0)
      let idle = (try: parseFloat(f[4]) except ValueError: 0.0) +
                 (if f.len > 5: (try: parseFloat(f[5]) except ValueError: 0.0) else: 0.0)
      if f[0] == "cpu":
        if raw.cpuTotal > 0 and total > raw.cpuTotal:
          s.cpu = clamp(100 * (1 - (idle - raw.cpuIdle) / (total - raw.cpuTotal)), 0, 100)
        raw.cpuTotal = total
        raw.cpuIdle = idle
      else: cores.add (total, idle)
    # (the cores Android shows no times for: their number all the same)
    var n = cores.len
    if n == 0:
      let possible = readSmall("/sys/devices/system/cpu/possible").strip   # "0-7"
      let dash = possible.find('-')
      if dash > 0: n = (try: parseInt(possible[dash + 1 .. ^1]) + 1 except ValueError: 0)
    s.cores.setLen(n)
    for i in 0 ..< n:
      s.cores[i].use = -1
      if i < cores.len and i < raw.cores.len and cores[i].total > raw.cores[i].total:
        s.cores[i].use = clamp(100 * (1 - (cores[i].idle - raw.cores[i].idle) /
                                       (cores[i].total - raw.cores[i].total)), 0, 100)
      let khz = readSmall("/sys/devices/system/cpu/cpu" & $i & "/cpufreq/scaling_cur_freq").strip
      if khz.len > 0: s.cores[i].mhz = (try: parseInt(khz) div 1000 except ValueError: 0)
    raw.cores = cores

  proc readMemory(s: Sample) =
    var m: Table[string, int64]
    for line in readSmall("/proc/meminfo").splitLines:
      let c = line.find(':')
      if c <= 0: continue
      let v = line[c + 1 .. ^1].strip.split(' ')[0]
      m[line[0 ..< c]] = (try: parseBiggestInt(v) * 1024 except ValueError: 0'i64)
    s.memTotal = m.getOrDefault("MemTotal")
    s.memAvailable = m.getOrDefault("MemAvailable", m.getOrDefault("MemFree"))
    s.memUsed = max(0'i64, s.memTotal - s.memAvailable)
    s.memCached = m.getOrDefault("Cached") + m.getOrDefault("Buffers") + m.getOrDefault("SReclaimable")
    s.swapTotal = m.getOrDefault("SwapTotal")
    s.swapUsed = max(0'i64, s.swapTotal - m.getOrDefault("SwapFree"))

  proc readProcesses(s: Sample; dt: float) =
    readBoot()
    let ncores = max(1, s.cores.len)
    var seen: Table[int, tuple[started, cpu: float; read, write: int64]]
    var others = false
    for kind, dir in walkDir("/proc"):
      let name = dir.extractFilename
      if name.len == 0 or name[0] notin {'0'..'9'}: continue
      let pid = (try: parseInt(name) except ValueError: continue)
      let st = readSmall(dir / "stat")
      if st.len == 0: continue
      let close = st.rfind(')')
      let open = st.find('(')
      if close < 0 or open < 0: continue
      var p = ProcInfo(pid: pid, name: st[open + 1 ..< close])
      let f = st[close + 2 .. ^1].splitWhitespace   # (field 3 on: state first)
      if f.len < 22: continue
      p.state = f[0][0]
      p.ppid = (try: parseInt(f[1]) except ValueError: 0)
      let ticks = (try: parseFloat(f[11]) + parseFloat(f[12]) except ValueError: 0.0)
      p.cpuSeconds = ticks / clockTicks.float
      p.nice = (try: parseInt(f[16]) except ValueError: 0)
      p.threads = (try: parseInt(f[17]) except ValueError: 1)
      p.started = bootTime + (try: parseFloat(f[19]) except ValueError: 0.0) / clockTicks.float
      p.memory = (try: parseBiggestInt(f[21]) * pageBytes except ValueError: 0'i64)
      # (its share since the last read: the same process -- the same start)
      let before = raw.procs.getOrDefault(pid, (-1.0, 0.0, 0'i64, 0'i64))
      if before.started == p.started and dt > 0:
        p.cpu = clamp(100 * (p.cpuSeconds - before.cpu) / (dt * ncores.float), 0, 100)
      for line in readSmall(dir / "status").splitLines:
        if line.startsWith("Uid:"):
          let u = line[4 .. ^1].splitWhitespace
          if u.len > 0: p.user = userName(try: parseInt(u[0]) except ValueError: -1)
          break
      var rd, wr = -1'i64
      for line in readSmall(dir / "io").splitLines:
        if line.startsWith("read_bytes:"): rd = (try: parseBiggestInt(line[11 .. ^1].strip) except ValueError: -1'i64)
        elif line.startsWith("write_bytes:"): wr = (try: parseBiggestInt(line[12 .. ^1].strip) except ValueError: -1'i64)
      if rd >= 0 and before.started == p.started and before.read >= 0 and dt > 0:
        p.readRate = max(0.0, float(rd - before.read) / dt)
        p.writeRate = max(0.0, float(wr - before.write) / dt)
      # (the program's file and command line: read once for each process)
      let key = (pid, p.started)
      if key notin exeOf:
        var exe = ""
        try: exe = expandSymlink(dir / "exe") except CatchableError: discard
        var cmd = readSmall(dir / "cmdline").replace('\0', ' ').strip
        exeOf[key] = (exe, cmd)
      (p.exe, p.command) = exeOf[key]
      if p.name.len == 15 and p.command.len > 0:
        # (the kernel keeps 15 letters of a name: the file's whole name)
        let first = p.command.split(' ')[0].extractFilename
        if first.startsWith(p.name): p.name = first
      seen[pid] = (p.started, p.cpuSeconds, rd, wr)
      s.threadCount += p.threads
      if pid != getCurrentProcessId() and p.ppid != getCurrentProcessId(): others = true
      s.processes.add p
    # (what is gone: forgotten -- the paths too)
    raw.procs = seen
    var gone: seq[(int, float)]
    for k in exeOf.keys:
      if k[0] notin seen or seen[k[0]].started != k[1]: gone.add k
    for k in gone: exeOf.del k
    s.seesAll = others and readSmall("/proc/1/stat").len > 0

  proc readDisks(s: Sample; dt: float) =
    var seen: Table[string, tuple[read, write, ticks: int64]]
    for line in readSmall("/proc/diskstats").splitLines:
      let f = line.splitWhitespace
      if f.len < 14: continue
      let name = f[2]
      # (whole disks: sda, nvme0n1, mmcblk0, vda -- not their parts, not loops)
      let whole = (name.startsWith("sd") and name[^1] notin {'0'..'9'}) or
                  (name.startsWith("vd") and name[^1] notin {'0'..'9'}) or
                  (name.startsWith("nvme") and 'p' notin name) or
                  (name.startsWith("mmcblk") and 'p' notin name)
      if not whole: continue
      let rd = (try: parseBiggestInt(f[5]) * 512 except ValueError: 0'i64)
      let wr = (try: parseBiggestInt(f[9]) * 512 except ValueError: 0'i64)
      let ticks = (try: parseBiggestInt(f[12]) except ValueError: 0'i64)
      var d = DiskInfo(name: name)
      if name in raw.disks and dt > 0:
        let b = raw.disks[name]
        d.readRate = max(0.0, float(rd - b.read) / dt)
        d.writeRate = max(0.0, float(wr - b.write) / dt)
        d.busy = clamp(float(ticks - b.ticks) / (dt * 10), 0, 100)
      seen[name] = (rd, wr, ticks)
      s.disks.add d
    raw.disks = seen
    # (the places files live: the root, the home, the cards)
    var places = @["/", getHomeDir()]
    when defined(android): places.add ["/storage/emulated/0", "/data"]
    for line in readSmall("/proc/mounts").splitLines:
      let f = line.splitWhitespace
      if f.len > 2 and f[0].startsWith("/dev/") and f[1] notin places and
         (f[1].startsWith("/media") or f[1].startsWith("/mnt") or f[1].startsWith("/run/media")):
        places.add f[1]
    when defined(posix):
      var devs: seq[uint]
      for path in places:
        var v: Statvfs
        if path.len > 0 and statvfs(path.cstring, v) == 0 and v.f_blocks > 0:
          let id = uint(v.f_fsid)
          if id != 0 and id in devs: continue
          devs.add id
          s.volumes.add VolumeInfo(path: path, total: int64(v.f_blocks) * int64(v.f_frsize),
                                   free: int64(v.f_bavail) * int64(v.f_frsize))

  proc readNetwork(s: Sample; dt: float) =
    var seen: Table[string, tuple[rx, tx: int64]]
    when androidApp:
      # (TrafficStats: all the device's networks together)
      if javaAvailable():
        let rx = (try: parseBiggestInt(javaStatic("android.net.TrafficStats", "getTotalRxBytes")) except ValueError: -1'i64)
        let tx = (try: parseBiggestInt(javaStatic("android.net.TrafficStats", "getTotalTxBytes")) except ValueError: -1'i64)
        if rx >= 0 and tx >= 0:
          var n = NetInfo(name: "All networks", rxTotal: rx, txTotal: tx)
          if "all" in raw.nets and dt > 0:
            n.rxRate = max(0.0, float(rx - raw.nets["all"].rx) / dt)
            n.txRate = max(0.0, float(tx - raw.nets["all"].tx) / dt)
          seen["all"] = (rx, tx)
          s.nets.add n
      raw.nets = seen
      return
    else:
      for line in readSmall("/proc/net/dev").splitLines:
        let c = line.find(':')
        if c <= 0: continue
        let name = line[0 ..< c].strip
        if name == "lo": continue
        let f = line[c + 1 .. ^1].splitWhitespace
        if f.len < 9: continue
        let rx = (try: parseBiggestInt(f[0]) except ValueError: 0'i64)
        let tx = (try: parseBiggestInt(f[8]) except ValueError: 0'i64)
        var n = NetInfo(name: name, rxTotal: rx, txTotal: tx)
        if name in raw.nets and dt > 0:
          n.rxRate = max(0.0, float(rx - raw.nets[name].rx) / dt)
          n.txRate = max(0.0, float(tx - raw.nets[name].tx) / dt)
        seen[name] = (rx, tx)
        if rx > 0 or tx > 0: s.nets.add n
      raw.nets = seen

  proc readBattery(s: Sample) =
    s.battery = -1
    when androidApp:
      s.battery = batteryLevel()
      return
    else:
      for kind, dir in walkDir("/sys/class/power_supply"):
        if readSmall(dir / "type").strip == "Battery":
          let c = readSmall(dir / "capacity").strip
          if c.len > 0:
            s.battery = (try: clamp(parseInt(c), 0, 100) except ValueError: -1)
            s.charging = readSmall(dir / "status").strip in ["Charging", "Full"]
            return

  proc readAll(s: Sample; dt: float) =
    readCpu(s, dt)
    readMemory(s)
    readProcesses(s, dt)
    readDisks(s, dt)
    readNetwork(s, dt)
    readBattery(s)
    let up = readSmall("/proc/uptime").splitWhitespace
    if up.len > 0: s.uptime = (try: parseFloat(up[0]) except ValueError: 0.0)

  proc endProcessNow(pid: int; force: bool): string =
    when defined(posix):
      if posix.kill(Pid(pid), if force: SIGKILL else: SIGTERM) != 0:
        return (if errno == EPERM: "not allowed (another user's program)" else: "it is gone")
    ""

  proc setNiceNow(pid, nice: int): string =
    when defined(posix):
      proc setpriority(which: cint; who: cint; prio: cint): cint {.importc, header: "<sys/resource.h>".}
      if setpriority(0, cint(pid), cint(nice)) != 0:
        return (if errno == EACCES or errno == EPERM: "not allowed (a higher priority needs the administrator)"
                else: "it is gone")
    ""

elif defined(windows):
  # ---- Windows: one NtQuerySystemInformation for every process ---------------------------------------

  type
    SpInfo = object               # SYSTEM_PROCESS_INFORMATION (its head)
      nextEntryOffset, numberOfThreads: uint32
      workingSetPrivateSize: int64
      hardFaultCount, threadsHighWatermark: uint32
      cycleTime: uint64
      createTime, userTime, kernelTime: int64
      nameLength, nameMax: uint16
      nameBuffer: ptr UncheckedArray[uint16]
      basePriority: int32
      uniqueProcessId, inheritedFromUniqueProcessId: uint
      handleCount, sessionId: uint32
      uniqueProcessKey, peakVirtualSize, virtualSize: uint
      pageFaultCount: uint32
      peakWorkingSetSize, workingSetSize: uint
      quotaPeakPaged, quotaPaged, quotaPeakNonPaged, quotaNonPaged: uint
      pagefileUsage, peakPagefileUsage, privatePageCount: uint
      readOps, writeOps, otherOps: int64
      readBytes, writeBytes, otherBytes: int64
    SppInfo = object              # SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION
      idleTime, kernelTime, userTime, dpcTime, interruptTime: int64
      interruptCount: uint32
    MemoryStatusEx = object
      length, memoryLoad: uint32
      totalPhys, availPhys, totalPageFile, availPageFile: uint64
      totalVirtual, availVirtual, availExtendedVirtual: uint64
    PowerStatus = object
      acLine, flag, percent, saver: uint8
      lifeTime, fullLifeTime: uint32

  proc NtQuerySystemInformation(cls: int32; buf: pointer; len: uint32; got: ptr uint32): int32
    {.stdcall, dynlib: "ntdll.dll", importc.}
  proc GetSystemTimes(idle, kernel, user: ptr int64): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc GlobalMemoryStatusEx(m: ptr MemoryStatusEx): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetTickCount64(): uint64 {.stdcall, dynlib: "kernel32", importc.}
  proc GetSystemPowerStatus(s: ptr PowerStatus): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc OpenProcess(access: uint32; inherit: int32; pid: uint32): pointer {.stdcall, dynlib: "kernel32", importc.}
  proc CloseHandle(h: pointer): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc TerminateProcess(h: pointer; code: uint32): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc SetPriorityClass(h: pointer; cls: uint32): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc QueryFullProcessImageNameW(h: pointer; flags: uint32; buf: ptr uint16; size: ptr uint32): int32
    {.stdcall, dynlib: "kernel32", importc.}
  proc GetLogicalDrives(): uint32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetDriveTypeW(root: WideCString): uint32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetDiskFreeSpaceExW(root: WideCString; avail, total, free: ptr uint64): int32
    {.stdcall, dynlib: "kernel32", importc.}
  proc GetIfTable(t: pointer; size: ptr uint32; order: int32): uint32 {.stdcall, dynlib: "iphlpapi", importc.}
  proc CreateFileW(name: WideCString; access, share: uint32; sec: pointer; disp, flags: uint32;
                   tmpl: pointer): pointer {.stdcall, dynlib: "kernel32", importc.}
  proc DeviceIoControl(h: pointer; code: uint32; inBuf: pointer; inSize: uint32; outBuf: pointer;
                       outSize: uint32; got: ptr uint32; ov: pointer): int32 {.stdcall, dynlib: "kernel32", importc.}

  type DiskPerformance = object   # DISK_PERFORMANCE
    bytesRead, bytesWritten, readTime, writeTime, idleTime: int64
    readCount, writeCount, queueDepth, splitCount: uint32
    queryTime: int64
    deviceNumber: uint32
    managerName: array[8, uint16]

  var diskNumbers: seq[int]               # (the physical drives found at the first read)
  var diskQuery: Table[string, int64]     # (each one's query time at the last read)

  proc readDisks(s: Sample; dt: float) =
    ## (each physical drive's bytes and idle time: Task Manager's "active time")
    if diskNumbers.len == 0:
      for i in 0 .. 15:
        let h = CreateFileW(newWideCString("\\\\.\\PhysicalDrive" & $i), 0, 3, nil, 3, 0, nil)
        if h != cast[pointer](-1):
          diskNumbers.add i
          discard CloseHandle(h)
      if diskNumbers.len == 0: diskNumbers.add -1             # (none: not asked again)
    var seenDisks: Table[string, tuple[read, write, ticks: int64]]
    for i in diskNumbers:
      if i < 0: continue
      let h = CreateFileW(newWideCString("\\\\.\\PhysicalDrive" & $i), 0, 3, nil, 3, 0, nil)
      if h == cast[pointer](-1): continue
      var d: DiskPerformance
      var got = 0'u32
      let ok = DeviceIoControl(h, 0x70020, nil, 0, addr d, uint32(sizeof(d)), addr got, nil) != 0
      discard CloseHandle(h)
      if not ok: continue
      let name = "Disk " & $i
      var di = DiskInfo(name: $i)
      if name in raw.disks and dt > 0:
        let b = raw.disks[name]
        di.readRate = max(0.0, float(d.bytesRead - b.read) / dt)
        di.writeRate = max(0.0, float(d.bytesWritten - b.write) / dt)
        let q = d.queryTime - diskQuery.getOrDefault(name)
        if q > 0: di.busy = clamp(100 * (1 - float(d.idleTime - b.ticks) / float(q)), 0, 100)
      seenDisks[name] = (d.bytesRead, d.bytesWritten, d.idleTime)
      diskQuery[name] = d.queryTime
      s.disks.add di
    raw.disks = seenDisks

  var buf: seq[byte]                      # (the processes' table, kept between reads)
  var exeOf: Table[(int, float), string]

  proc wide(p: ptr UncheckedArray[uint16]; n: int): string =
    var w = newWideCString("", n + 1)
    for i in 0 ..< n: w[i] = Utf16Char(p[i])
    w[n] = Utf16Char(0)
    $w

  proc exePath(pid: int): string =
    let h = OpenProcess(0x1000, 0, uint32(pid))      # PROCESS_QUERY_LIMITED_INFORMATION
    if h == nil: return ""
    var b: array[1024, uint16]
    var n = uint32(b.len)
    if QueryFullProcessImageNameW(h, 0, addr b[0], addr n) != 0:
      result = wide(cast[ptr UncheckedArray[uint16]](addr b[0]), int(n))
    discard CloseHandle(h)

  proc readAll(s: Sample; dt: float) =
    # the processor: all of it, then each core
    var idle, kernel, user: int64
    if GetSystemTimes(addr idle, addr kernel, addr user) != 0:
      let total = float(kernel + user)
      if raw.cpuTotal > 0 and total > raw.cpuTotal:
        s.cpu = clamp(100 * (1 - (idle.float - raw.cpuIdle) / (total - raw.cpuTotal)), 0, 100)
      raw.cpuTotal = total
      raw.cpuIdle = idle.float
    var cores = newSeq[SppInfo](256)
    var got: uint32
    if NtQuerySystemInformation(8, addr cores[0], uint32(cores.len * sizeof(SppInfo)), addr got) == 0:
      let n = int(got) div sizeof(SppInfo)
      var now: seq[tuple[total, idle: float]]
      s.cores.setLen(n)
      for i in 0 ..< n:
        let t = float(cores[i].kernelTime + cores[i].userTime)
        now.add (t, cores[i].idleTime.float)
        s.cores[i].use = -1
        if i < raw.cores.len and t > raw.cores[i].total:
          s.cores[i].use = clamp(100 * (1 - (now[i].idle - raw.cores[i].idle) / (t - raw.cores[i].total)), 0, 100)
      raw.cores = now
    # the memory
    var m = MemoryStatusEx(length: uint32(sizeof(MemoryStatusEx)))
    if GlobalMemoryStatusEx(addr m) != 0:
      s.memTotal = int64(m.totalPhys)
      s.memAvailable = int64(m.availPhys)
      s.memUsed = s.memTotal - s.memAvailable
      s.swapTotal = max(0'i64, int64(m.totalPageFile) - s.memTotal)
      s.swapUsed = max(0'i64, int64(m.totalPageFile - m.availPageFile) - s.memUsed)
    # every process at once (the table grows until it fits)
    if buf.len == 0: buf.setLen(1 shl 20)
    var status = NtQuerySystemInformation(5, addr buf[0], uint32(buf.len), addr got)
    while status == cast[int32](0xC0000004'u32):          # STATUS_INFO_LENGTH_MISMATCH
      buf.setLen(max(buf.len * 2, int(got) + (64 shl 10)))
      status = NtQuerySystemInformation(5, addr buf[0], uint32(buf.len), addr got)
    let ncores = max(1, s.cores.len)
    var seen: Table[int, tuple[started, cpu: float; read, write: int64]]
    if status == 0:
      var off = 0
      while true:
        let e = cast[ptr SpInfo](addr buf[off])
        let pid = int(e.uniqueProcessId)
        if pid != 0:
          var p = ProcInfo(pid: pid, ppid: int(e.inheritedFromUniqueProcessId),
                           name: wide(e.nameBuffer, int(e.nameLength) div 2), state: 'R',
                           threads: int(e.numberOfThreads), memory: int64(e.workingSetSize))
          if p.name.len == 0: p.name = "System"
          p.cpuSeconds = float(e.userTime + e.kernelTime) / 1e7
          p.started = float(e.createTime) / 1e7 - 11644473600.0
          p.nice = case e.basePriority
                   of 0 .. 4: 10
                   of 5 .. 6: 5
                   of 7 .. 8: 0
                   of 9 .. 10: -5
                   else: -10                     # (high, and the system's own above it)
          let before = raw.procs.getOrDefault(pid, (-1.0, 0.0, 0'i64, 0'i64))
          if before.started == p.started and dt > 0:
            p.cpu = clamp(100 * (p.cpuSeconds - before.cpu) / (dt * ncores.float), 0, 100)
            p.readRate = max(0.0, float(e.readBytes - before.read) / dt)
            p.writeRate = max(0.0, float(e.writeBytes - before.write) / dt)
          let key = (pid, p.started)
          if key notin exeOf: exeOf[key] = exePath(pid)
          p.exe = exeOf[key]
          seen[pid] = (p.started, p.cpuSeconds, e.readBytes, e.writeBytes)
          s.threadCount += p.threads
          s.processes.add p
        if e.nextEntryOffset == 0: break
        off += int(e.nextEntryOffset)
      s.seesAll = true
    raw.procs = seen
    var gone: seq[(int, float)]
    for k in exeOf.keys:
      if k[0] notin seen or seen[k[0]].started != k[1]: gone.add k
    for k in gone: exeOf.del k
    # the network (each interface's counts; 32 bits: they wrap)
    var size: uint32 = 0
    discard GetIfTable(nil, addr size, 0)
    if size > 0:
      var t = newSeq[byte](size)
      if GetIfTable(addr t[0], addr size, 0) == 0:
        let n = int(cast[ptr uint32](addr t[0])[])
        var seenNets: Table[string, tuple[rx, tx: int64]]
        for i in 0 ..< n:
          let row = 4 + i * 860
          if row + 860 > t.len: break
          template u32(at: int): uint32 = cast[ptr uint32](addr t[row + at])[]
          if u32(516) == 24 or u32(544) != 5: continue        # loopback, or not up
          let dl = min(int(u32(600)), 255)
          var name = newString(dl)
          if dl > 0: copyMem(addr name[0], addr t[row + 604], dl)
          name = name.strip(chars = {'\0', ' '})
          var rx = int64(u32(552))
          var tx = int64(u32(576))
          var ni = NetInfo(name: name, rxTotal: rx, txTotal: tx)
          if name in raw.nets and dt > 0:
            var drx = rx - raw.nets[name].rx
            var dtx = tx - raw.nets[name].tx
            if drx < 0: drx += 1'i64 shl 32
            if dtx < 0: dtx += 1'i64 shl 32
            ni.rxRate = drx.float / dt
            ni.txRate = dtx.float / dt
          if name notin seenNets:
            seenNets[name] = (rx, tx)
            if rx > 0 or tx > 0: s.nets.add ni
        raw.nets = seenNets
    readDisks(s, dt)
    # the drives
    let drives = GetLogicalDrives()
    for i in 0 .. 25:
      if (drives and (1'u32 shl i)) == 0: continue
      let root = $char(ord('A') + i) & ":\\"
      let kind = GetDriveTypeW(newWideCString(root))
      if kind notin [2'u32, 3]: continue                  # removable, fixed
      var avail, total, free: uint64
      if GetDiskFreeSpaceExW(newWideCString(root), addr avail, addr total, addr free) != 0:
        s.volumes.add VolumeInfo(path: root, total: int64(total), free: int64(avail))
    var ps: PowerStatus
    s.battery = -1
    if GetSystemPowerStatus(addr ps) != 0 and ps.percent != 255 and ps.flag != 128:
      s.battery = int(ps.percent)
      s.charging = ps.acLine == 1
    s.uptime = GetTickCount64().float / 1000

  proc endProcessNow(pid: int; force: bool): string =
    let h = OpenProcess(0x0001, 0, uint32(pid))          # PROCESS_TERMINATE
    if h == nil: return "not allowed (a program of the system, or another user's)"
    result = if TerminateProcess(h, 1) != 0: "" else: "it would not end"
    discard CloseHandle(h)

  proc setNiceNow(pid, nice: int): string =
    let h = OpenProcess(0x0200, 0, uint32(pid))          # PROCESS_SET_INFORMATION
    if h == nil: return "not allowed (a program of the system, or another user's)"
    let cls = if nice <= -10: 0x80'u32                   # high (read back as -10)
              elif nice <= -5: 0x8000'u32                # above normal
              elif nice < 5: 0x20'u32                    # normal
              elif nice < 10: 0x4000'u32                 # below normal
              else: 0x40'u32                             # idle
    result = if SetPriorityClass(h, cls) != 0: "" else: "not allowed"
    discard CloseHandle(h)

elif defined(macosx) and not defined(ios):
  # ---- macOS: the Mach host, libproc for each process ------------------------------------------------

  type
    MachPort = uint32
    TimebaseInfo = object
      numer, denom: uint32
  proc mach_host_self(): MachPort {.importc, header: "<mach/mach.h>".}
  proc mach_task_self(): MachPort {.importc, header: "<mach/mach.h>".}
  proc host_processor_info(host: MachPort; flavor: cint; count: ptr uint32; info: ptr ptr int32;
                           infoCount: ptr uint32): cint {.importc, header: "<mach/mach.h>".}
  proc host_statistics64(host: MachPort; flavor: cint; info: pointer; count: ptr uint32): cint
    {.importc, header: "<mach/mach.h>".}
  proc vm_deallocate(task: MachPort; address: uint; size: uint): cint {.importc, header: "<mach/mach.h>".}
  proc mach_timebase_info(info: ptr TimebaseInfo): cint {.importc, header: "<mach/mach_time.h>".}
  proc proc_listallpids(buf: pointer; size: cint): cint {.importc, header: "<libproc.h>".}
  proc proc_pidinfo(pid: cint; flavor: cint; arg: uint64; buf: pointer; size: cint): cint
    {.importc, header: "<libproc.h>".}
  proc proc_pidpath(pid: cint; buf: pointer; size: uint32): cint {.importc, header: "<libproc.h>".}
  proc proc_pid_rusage(pid: cint; flavor: cint; buf: pointer): cint {.importc, header: "<libproc.h>".}
  type IfAddrs = object          # struct ifaddrs
    next: ptr IfAddrs
    name: cstring
    flags: cuint
    address, netmask, dest: ptr UncheckedArray[uint8]
    data: ptr UncheckedArray[uint8]
  proc getifaddrs(list: ptr ptr IfAddrs): cint {.importc, header: "<ifaddrs.h>".}
  proc freeifaddrs(list: ptr IfAddrs) {.importc, header: "<ifaddrs.h>".}
  proc sysctlbyname(name: cstring; old: pointer; oldlen: ptr csize_t; new: pointer; newlen: csize_t): cint
    {.importc, header: "<sys/sysctl.h>".}
  proc proc_pidfdinfo(pid: cint; fd: cint; flavor: cint; buf: pointer; size: cint): cint
    {.importc, header: "<libproc.h>".}

  var exeOf: Table[(int, float), string]
  var userNames: Table[int, string]
  var tb: TimebaseInfo

  proc userName(uid: int): string =
    if uid in userNames: return userNames[uid]
    let pw = getpwuid(Uid(uid))
    result = if pw != nil and pw.pw_name != nil: $pw.pw_name else: $uid
    userNames[uid] = result

  # (the disks' counts: IOKit's block storage drivers, loaded at run time)
  type
    IOServiceMatchingFn = proc (name: cstring): pointer {.cdecl, gcsafe.}
    IOServiceGetMatchingServicesFn = proc (port: uint32; matching: pointer; it: ptr uint32): cint {.cdecl, gcsafe.}
    IOIteratorNextFn = proc (it: uint32): uint32 {.cdecl, gcsafe.}
    IOObjectReleaseFn = proc (o: uint32): cint {.cdecl, gcsafe.}
    IORegistryEntryCreateCFPropertiesFn = proc (entry: uint32; props: ptr pointer; alloc: pointer;
                                                options: uint32): cint {.cdecl, gcsafe.}
    CFDictionaryGetValueFn = proc (d, key: pointer): pointer {.cdecl, gcsafe.}
    CFStringCreateWithCStringFn = proc (alloc: pointer; s: cstring; enc: uint32): pointer {.cdecl, gcsafe.}
    CFNumberGetValueFn = proc (n: pointer; kind: cint; v: pointer): uint8 {.cdecl, gcsafe.}
    CFReleaseFn = proc (p: pointer) {.cdecl, gcsafe.}
  var
    ioTried = false
    ioMatching: IOServiceMatchingFn
    ioServices: IOServiceGetMatchingServicesFn
    ioNext: IOIteratorNextFn
    ioRelease: IOObjectReleaseFn
    ioProps: IORegistryEntryCreateCFPropertiesFn
    cfGet: CFDictionaryGetValueFn
    cfString: CFStringCreateWithCStringFn
    cfNumber: CFNumberGetValueFn
    cfRelease: CFReleaseFn
    cfKeys: array[5, pointer]      # Statistics, Bytes (Read), Bytes (Write), Total Time (Read), (Write)

  proc loadIoKit(): bool =
    if ioTried: return ioMatching != nil and cfGet != nil
    ioTried = true
    let io = loadLib("/System/Library/Frameworks/IOKit.framework/IOKit")
    let cf = loadLib("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    if io == nil or cf == nil: return false
    ioMatching = cast[IOServiceMatchingFn](io.symAddr("IOServiceMatching"))
    ioServices = cast[IOServiceGetMatchingServicesFn](io.symAddr("IOServiceGetMatchingServices"))
    ioNext = cast[IOIteratorNextFn](io.symAddr("IOIteratorNext"))
    ioRelease = cast[IOObjectReleaseFn](io.symAddr("IOObjectRelease"))
    ioProps = cast[IORegistryEntryCreateCFPropertiesFn](io.symAddr("IORegistryEntryCreateCFProperties"))
    cfGet = cast[CFDictionaryGetValueFn](cf.symAddr("CFDictionaryGetValue"))
    cfString = cast[CFStringCreateWithCStringFn](cf.symAddr("CFStringCreateWithCString"))
    cfNumber = cast[CFNumberGetValueFn](cf.symAddr("CFNumberGetValue"))
    cfRelease = cast[CFReleaseFn](cf.symAddr("CFRelease"))
    if ioMatching == nil or ioServices == nil or ioNext == nil or ioRelease == nil or ioProps == nil or
       cfGet == nil or cfString == nil or cfNumber == nil or cfRelease == nil:
      ioMatching = nil
      return false
    for i, k in ["Statistics", "Bytes (Read)", "Bytes (Write)", "Total Time (Read)", "Total Time (Write)"]:
      cfKeys[i] = cfString(nil, k.cstring, 0x08000100'u32)        # kCFStringEncodingUTF8
    true

  proc readMacDisks(s: Sample; dt: float) =
    ## (each disk's bytes and the time it spent working, from its driver's
    ## statistics: disk0, disk1... in the order IOKit gives them)
    if not loadIoKit(): return
    var it: uint32
    if ioServices(0, ioMatching("IOBlockStorageDriver"), addr it) != 0: return
    var seenDisks: Table[string, tuple[read, write, ticks: int64]]
    var n = 0
    while true:
      let d = ioNext(it)
      if d == 0: break
      var props: pointer
      if ioProps(d, addr props, nil, 0) == 0 and props != nil:
        let stats = cfGet(props, cfKeys[0])
        if stats != nil:
          var v: array[4, int64]
          for k in 0 .. 3:
            let num = cfGet(stats, cfKeys[k + 1])
            if num != nil: discard cfNumber(num, 4, addr v[k])     # kCFNumberSInt64Type
          let name = "disk" & $n
          var di = DiskInfo(name: name)
          let busyNs = v[2] + v[3]
          if name in raw.disks and dt > 0:
            let b = raw.disks[name]
            di.readRate = max(0.0, float(v[0] - b.read) / dt)
            di.writeRate = max(0.0, float(v[1] - b.write) / dt)
            di.busy = clamp(float(busyNs - b.ticks) / (dt * 1e9) * 100, 0, 100)
          seenDisks[name] = (v[0], v[1], busyNs)
          s.disks.add di
          inc n
        cfRelease(props)
      discard ioRelease(d)
    discard ioRelease(it)
    raw.disks = seenDisks

  proc readAll(s: Sample; dt: float) =
    if tb.denom == 0: discard mach_timebase_info(addr tb)
    let host = mach_host_self()
    # each core's ticks: user, system, idle, nice
    var n, count: uint32
    var info: ptr int32
    if host_processor_info(host, 2, addr n, addr info, addr count) == 0 and info != nil:
      let a = cast[ptr UncheckedArray[uint32]](info)
      var now: seq[tuple[total, idle: float]]
      var allT, allI = 0.0
      s.cores.setLen(int(n))
      for i in 0 ..< int(n):
        let total = float(a[i * 4] + a[i * 4 + 1] + a[i * 4 + 2] + a[i * 4 + 3])
        let idle = float(a[i * 4 + 2])
        now.add (total, idle)
        allT += total
        allI += idle
        s.cores[i].use = -1
        if i < raw.cores.len and total > raw.cores[i].total:
          s.cores[i].use = clamp(100 * (1 - (idle - raw.cores[i].idle) / (total - raw.cores[i].total)), 0, 100)
      if raw.cpuTotal > 0 and allT > raw.cpuTotal:
        s.cpu = clamp(100 * (1 - (allI - raw.cpuIdle) / (allT - raw.cpuTotal)), 0, 100)
      raw.cpuTotal = allT
      raw.cpuIdle = allI
      raw.cores = now
      discard vm_deallocate(mach_task_self(), cast[uint](info), uint(count) * 4)
    # the memory
    var memsize: uint64
    var len = csize_t(sizeof(memsize))
    if sysctlbyname("hw.memsize", addr memsize, addr len, nil, 0) == 0: s.memTotal = int64(memsize)
    var vm: array[64, uint32]                      # vm_statistics64 (as 32-bit words)
    var vmCount = uint32(38)                       # HOST_VM_INFO64_COUNT
    if host_statistics64(host, 4, addr vm[0], addr vmCount) == 0:
      let page = int64(sysconf(SC_PAGESIZE))
      # (vm_statistics64 in 32-bit words: wire_count 3, purgeable_count 22,
      # compressor_page_count 32, external_page_count 34, internal_page_count
      # 35) -- used as Activity Monitor counts it: the apps' memory (internal
      # less purgeable), wired, compressed; cached: the files' pages
      let wired = int64(vm[3]) * page
      let purgeable = int64(vm[22]) * page
      let compressed = int64(vm[32]) * page
      let external = int64(vm[34]) * page
      let internal = int64(vm[35]) * page
      s.memUsed = clamp(internal - purgeable + wired + compressed, 0'i64, s.memTotal)
      s.memAvailable = max(0'i64, s.memTotal - s.memUsed)
      s.memCached = external + purgeable
    # every process
    var pids = newSeq[int32](4096)
    let np = proc_listallpids(addr pids[0], cint(pids.len * 4))
    let ncores = max(1, s.cores.len)
    var seen: Table[int, tuple[started, cpu: float; read, write: int64]]
    var all: array[232, byte]                      # proc_taskallinfo
    var ru: array[296, byte]                       # rusage_info_v2
    for i in 0 ..< max(0, np):
      let pid = int(pids[i])
      if pid <= 0: continue
      if proc_pidinfo(cint(pid), 2, 0, addr all[0], cint(all.len)) < 136 + 96: continue
      template u32(at: int): uint32 = cast[ptr uint32](addr all[at])[]
      template u64(at: int): uint64 = cast[ptr uint64](addr all[at])[]
      var p = ProcInfo(pid: pid, ppid: int(u32(16)))
      var name = $cast[cstring](addr all[64])      # pbi_name
      if name.len == 0: name = $cast[cstring](addr all[48])
      p.name = name
      p.user = userName(int(u32(20)))
      p.nice = int(cast[ptr int32](addr all[116])[])
      p.started = float(u64(120)) + float(u64(128)) / 1e6
      p.memory = int64(u64(136 + 8))               # pti_resident_size
      let ticks = float(u64(136 + 16) + u64(136 + 24)) # total user + system (Mach time)
      p.cpuSeconds = ticks * float(tb.numer) / float(max(1'u32, tb.denom)) / 1e9
      p.threads = int(cast[ptr int32](addr all[136 + 84])[])
      p.state = if cast[ptr int32](addr all[136 + 88])[] > 0: 'R' else: 'S'
      var rd, wr = -1'i64
      if proc_pid_rusage(cint(pid), 2, addr ru[0]) == 0:
        p.memory = int64(cast[ptr uint64](addr ru[72])[])   # ri_phys_footprint: Activity Monitor's
        rd = int64(cast[ptr uint64](addr ru[144])[])
        wr = int64(cast[ptr uint64](addr ru[152])[])
      let before = raw.procs.getOrDefault(pid, (-1.0, 0.0, 0'i64, 0'i64))
      if before.started == p.started and dt > 0:
        p.cpu = clamp(100 * (p.cpuSeconds - before.cpu) / (dt * ncores.float), 0, 100)
        if rd >= 0 and before.read >= 0:
          p.readRate = max(0.0, float(rd - before.read) / dt)
          p.writeRate = max(0.0, float(wr - before.write) / dt)
      let key = (pid, p.started)
      if key notin exeOf:
        var b: array[4096, char]
        exeOf[key] = if proc_pidpath(cint(pid), addr b[0], uint32(b.len)) > 0: $cast[cstring](addr b[0]) else: ""
      p.exe = exeOf[key]
      seen[pid] = (p.started, p.cpuSeconds, rd, wr)
      s.threadCount += p.threads
      s.processes.add p
    raw.procs = seen
    s.seesAll = s.processes.len > 1
    var gone: seq[(int, float)]
    for k in exeOf.keys:
      if k[0] notin seen or seen[k[0]].started != k[1]: gone.add k
    for k in gone: exeOf.del k
    # the places files live
    # (the start disk, then what else is mounted: the start disk is in
    # /Volumes too, under its name)
    var root: Statvfs
    if statvfs("/", root) == 0 and root.f_blocks > 0:
      s.volumes.add VolumeInfo(path: "/", total: int64(root.f_blocks) * int64(root.f_frsize),
                               free: int64(root.f_bavail) * int64(root.f_frsize))
    if dirExists("/Volumes"):
      for kind, d in walkDir("/Volumes"):
        var v: Statvfs
        if statvfs(d.cstring, v) == 0 and v.f_blocks > 0 and v.f_fsid != root.f_fsid:
          s.volumes.add VolumeInfo(path: d, total: int64(v.f_blocks) * int64(v.f_frsize),
                                   free: int64(v.f_bavail) * int64(v.f_frsize))
    var boot: array[2, int64]                      # struct timeval
    var bl = csize_t(sizeof(boot))
    if sysctlbyname("kern.boottime", addr boot[0], addr bl, nil, 0) == 0:
      s.uptime = epochTime() - boot[0].float
    s.battery = -1
    readMacDisks(s, dt)
    # the network: each interface's link entry has its counts (if_data:
    # bytes in at 40, out at 44; 32 bits, they wrap)
    var list: ptr IfAddrs
    if getifaddrs(addr list) == 0:
      var seenNets: Table[string, tuple[rx, tx: int64]]
      var a = list
      while a != nil:
        if a.address != nil and a.address[1] == 18 and a.data != nil and   # AF_LINK
           (a.flags and 0x1) != 0 and (a.flags and 0x8) == 0:            # up, not the loopback
          let name = $a.name
          let rx = int64(cast[ptr uint32](addr a.data[40])[])
          let tx = int64(cast[ptr uint32](addr a.data[44])[])
          if name notin seenNets and (rx > 0 or tx > 0):
            seenNets[name] = (rx, tx)
            var ni = NetInfo(name: name, rxTotal: rx, txTotal: tx)
            if name in raw.nets and dt > 0:
              var drx = rx - raw.nets[name].rx
              var dtx = tx - raw.nets[name].tx
              if drx < 0: drx += 1'i64 shl 32
              if dtx < 0: dtx += 1'i64 shl 32
              ni.rxRate = drx.float / dt
              ni.txRate = dtx.float / dt
            s.nets.add ni
        a = a.next
      freeifaddrs(list)
      raw.nets = seenNets

  proc endProcessNow(pid: int; force: bool): string =
    if posix.kill(Pid(pid), if force: SIGKILL else: SIGTERM) != 0:
      return (if errno == EPERM: "not allowed (another user's program)" else: "it is gone")
    ""

  proc setNiceNow(pid, nice: int): string =
    proc setpriority(which: cint; who: cint; prio: cint): cint {.importc, header: "<sys/resource.h>".}
    if setpriority(0, cint(pid), cint(nice)) != 0:
      return (if errno == EACCES or errno == EPERM: "not allowed (a higher priority needs the administrator)"
              else: "it is gone")
    ""

else:
  proc readAll(s: Sample; dt: float) =
    s.cpu = -1
    s.battery = -1
  proc endProcessNow(pid: int; force: bool): string = "not on this system"
  proc setNiceNow(pid, nice: int): string = "not on this system"

# ---- the sampler --------------------------------------------------------------------------------

const HistoryLength* = 300     ## (the points kept for the charts: five minutes at a second)

var
  lock: Lock                    ## (the last sample, the history, the interval)
  readLock: Lock                ## (one read at a time: the counters kept between two)
  locksMade = false
  latest: Sample
  history: seq[HistoryPoint]
  intervalMs = 1000
  running = false
  stopAsked = false

proc makeLocks() =
  if not locksMade:
    initLock(lock)
    initLock(readLock)
    locksMade = true

proc takeSample*(): Sample =
  ## Reads the system now, on this thread (the first one has no rates:
  ## they need two reads). Use `startMonitor` and `latestSample` in a window
  ## (this waits while the reading thread reads).
  makeLocks()
  withLock readLock:
    let t0 = epochTime()
    result = Sample(at: t0, cpu: -1, battery: -1)
    let dt = if raw.at > 0: t0 - raw.at else: 0.0
    try:
      readAll(result, dt)
    except CatchableError, Defect:
      result.stale = true
    raw.at = t0
    result.readMs = (epochTime() - t0) * 1000
  result.processes.sort(proc (a, b: ProcInfo): int = cmp(b.cpu, a.cpu))

proc pointOf(s: Sample): HistoryPoint =
  result = HistoryPoint(at: s.at, cpu: s.cpu, memUsed: s.memUsed,
                        memPercent: (if s.memTotal > 0: s.memUsed.float * 100 / s.memTotal.float else: 0.0))
  for d in s.disks: result.diskRate += d.readRate + d.writeRate
  for n in s.nets: result.netRate += n.rxRate + n.txRate
  for c in s.cores: result.cores.add c.use

when threaded:
  var thread: Thread[void]

  proc loop() {.thread.} =
    {.cast(gcsafe).}:
      while true:
        let s = takeSample()
        var wait = 1000
        withLock lock:
          latest = s
          history.add pointOf(s)
          if history.len > HistoryLength: history.delete(0)
          wait = intervalMs
          if stopAsked: break
        var slept = 0
        while slept < wait:
          sleep(50)
          slept += 50
          withLock lock:
            if stopAsked: break
            wait = intervalMs

proc startMonitor*(everyMs = 1000) =
  ## Reads the system every `everyMs` on a thread of its own (once: again
  ## changes the interval). `latestSample` gives the newest.
  if not running:
    makeLocks()
    running = true
    when threaded:
      createThread(thread, loop)
  withLock lock: intervalMs = max(100, everyMs)

proc setMonitorInterval*(ms: int) =
  ## How often the system is read: a second while a window shows it, five
  ## while it is minimized (`ui.hidden`) or put away (`ui.paused`) -- less
  ## work for nobody.
  if running:
    withLock lock: intervalMs = max(100, ms)

proc stopMonitor*() =
  ## Ends the reading thread (it ends with the program anyway).
  if not running: return
  withLock lock: stopAsked = true
  when threaded: joinThread(thread)
  running = false
  stopAsked = false

proc latestSample*(): Sample =
  ## The newest sample (nil before the first). Never waits. Without threads
  ## (a web page) it reads here, at most once an interval.
  when not threaded:
    if running and (latest == nil or epochTime() - latest.at >= intervalMs / 1000):
      let s = takeSample()
      latest = s
      history.add pointOf(s)
      if history.len > HistoryLength: history.delete(0)
  if not running: return nil
  withLock lock: result = latest

proc monitorHistory*(): seq[HistoryPoint] =
  ## The samples of the last minutes (oldest first): for the charts.
  if not running: return
  withLock lock: result = history

proc endProcess*(p: ProcInfo; force = false): string =
  ## Asks process `p` to end (`force`: ends it at once). "" when done, else
  ## why not. The process must still be the one sampled: an id that is
  ## another program's by now is left alone.
  proc has(s: Sample): int =
    ## (1: there, the same process; -1: its id is another's; 0: not there)
    if s == nil: return 0
    for q in s.processes:
      if q.pid == p.pid: return (if q.started == p.started: 1 else: -1)
  var seen = has(latestSample())
  if seen == 0: seen = has(takeSample())      # (newer than the last sample: read now)
  if seen < 0: return "it is gone (its id is another program's now)"
  if seen == 0: return "it is gone"
  endProcessNow(p.pid, force)

proc endProcessTree*(p: ProcInfo; force = false): string =
  ## Ends `p` and every process it started (theirs too).
  let s = latestSample()
  if s == nil: return endProcess(p, force)
  var kids: seq[ProcInfo]
  var seen = @[p.pid]
  var todo = @[p]
  while todo.len > 0:
    let at = todo.pop()
    for q in s.processes:
      # (started after its parent: on Windows a parent's id may be another
      # program's by now -- that one is not a child)
      if q.ppid == at.pid and q.pid notin seen and (q.started == 0 or at.started == 0 or
         q.started >= at.started - 1):
        seen.add q.pid
        kids.add q
        todo.add q
  for k in kids: discard endProcess(k, force)
  endProcess(p, force)

proc setPriority*(p: ProcInfo; nice: int): string =
  ## Gives `p` another priority: -20 (first) .. 19 (last); "" when done.
  setNiceNow(p.pid, clamp(nice, -20, 19))

# ---- the programs that start with the system -----------------------------------------------------

type
  StartupItem* = object
    ## A program the system starts when the user logs in.
    name*: string            ## as it calls itself
    command*: string         ## what it runs
    where*: string           ## where it is kept (a file, a registry key)
    enabled*: bool
    canChange*: bool         ## the user may turn it on or off here
    forAll*: bool            ## for every user (else this one)

when not defined(wasm):
  proc desktopValue(text, key: string): string =
    ## (a key of a .desktop file's [Desktop Entry])
    var inEntry = false
    for l in text.splitLines:
      let t = l.strip
      if t.startsWith("["): inEntry = t == "[Desktop Entry]"
      elif inEntry and t.startsWith(key & "="): return t[key.len + 1 .. ^1].strip

when defined(windows) and not defined(wasm):
  proc RegOpenKeyExW(key: int; sub: WideCString; opts, sam: uint32; res: ptr int): int32 {.stdcall, dynlib: "advapi32", importc.}
  proc RegEnumValueW(key: int; index: uint32; name: WideCString; nameLen: ptr uint32; reserved: pointer;
                     kind: ptr uint32; data: pointer; dataLen: ptr uint32): int32 {.stdcall, dynlib: "advapi32", importc.}
  proc RegQueryValueExW(key: int; name: WideCString; reserved: pointer; kind: ptr uint32;
                        data: pointer; dataLen: ptr uint32): int32 {.stdcall, dynlib: "advapi32", importc.}
  proc RegSetValueExW(key: int; name: WideCString; reserved, kind: uint32; data: pointer;
                      dataLen: uint32): int32 {.stdcall, dynlib: "advapi32", importc.}
  proc RegCreateKeyExW(key: int; sub: WideCString; reserved: uint32; class: pointer; opts, sam: uint32;
                       sec: pointer; res: ptr int; disp: ptr uint32): int32 {.stdcall, dynlib: "advapi32", importc.}
  proc RegCloseKey(key: int): int32 {.stdcall, dynlib: "advapi32", importc.}
  const
    hkcu = int(0x80000001'u32)
    hklm = int(0x80000002'u32)
    runKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    approvedKey = "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run"

  proc wideToStr(w: openArray[uint16]; n: int): string =
    var z = newSeq[uint16](n + 1)                  # (with its 0)
    for i in 0 ..< min(n, w.len): z[i] = w[i]
    $cast[WideCString](addr z[0])

  proc approved(root: int; name: string): bool =
    ## (Task Manager's own record of what was turned off: 02 on, 03 off)
    var k = 0
    if RegOpenKeyExW(root, newWideCString(approvedKey), 0, 0x20019, addr k) != 0: return true
    var data: array[16, uint8]
    var size = 16'u32
    var kind = 0'u32
    let r = RegQueryValueExW(k, newWideCString(name), nil, addr kind, addr data[0], addr size)
    discard RegCloseKey(k)
    r != 0 or size == 0 or (data[0] and 1) == 0

  proc runEntries(root: int; forAll: bool): seq[StartupItem] =
    var k = 0
    if RegOpenKeyExW(root, newWideCString(runKey), 0, 0x20019, addr k) != 0: return   # KEY_READ
    var i = 0'u32
    while true:
      var name: array[512, uint16]
      var nameLen = 512'u32
      var data: array[4096, uint16]
      var dataLen = uint32(sizeof(data))
      var kind = 0'u32
      if RegEnumValueW(k, i, cast[WideCString](addr name[0]), addr nameLen, nil, addr kind,
                       addr data[0], addr dataLen) != 0: break
      inc i
      if kind notin [1'u32, 2]: continue                   # (REG_SZ, REG_EXPAND_SZ)
      let n = wideToStr(name, int(nameLen))
      let cmd = wideToStr(data, max(0, int(dataLen) div 2 - 1))
      result.add StartupItem(name: n, command: cmd, enabled: approved(root, n),
                             where: (if forAll: "HKLM\\" else: "HKCU\\") & runKey,
                             canChange: not forAll, forAll: forAll)
    discard RegCloseKey(k)

proc startupItems*(): seq[StartupItem] =
  ## What starts when the user logs in: Linux and the BSDs (the autostart
  ## entries, freedesktop's), Windows (the Run keys), macOS (the launch
  ## agents). Phones and web pages: none (the system decides).
  when defined(wasm) or androidApp or defined(ios):
    discard
  elif defined(windows):
    result = runEntries(hkcu, false) & runEntries(hklm, true)
  elif defined(macosx):
    for (dir, all) in [(getHomeDir() / "Library/LaunchAgents", false), ("/Library/LaunchAgents", true)]:
      for f in walkFiles(dir / "*.plist"):
        let t = try: readFile(f) except IOError: ""
        if "<key>RunAtLoad</key>" notin t: continue
        let k = t.find("<key>Program")
        var cmd = ""
        if k >= 0:
          let a = t.find("<string>", k)
          let b = t.find("</string>", a)
          if a > 0 and b > a: cmd = t[a + 8 ..< b]
        result.add StartupItem(name: f.splitFile.name, command: cmd, where: f,
                               enabled: "<key>Disabled</key>\n\t<true/>" notin t and
                                        "<key>Disabled</key><true/>" notin t,
                               canChange: false, forAll: all)
  else:
    var seen: seq[string]
    let mine = getConfigDir() / "autostart"
    for (dir, all) in [(mine, false), ("/etc/xdg/autostart", true)]:
      for f in walkFiles(dir / "*.desktop"):
        let base = f.extractFilename
        if base in seen: continue                          # (the user's own copy wins)
        seen.add base
        let t = try: readFile(f) except IOError: ""
        let hidden = desktopValue(t, "Hidden").toLowerAscii == "true"
        let gnomeOff = desktopValue(t, "X-GNOME-Autostart-enabled").toLowerAscii == "false"
        var name = desktopValue(t, "Name")
        if name.len == 0: name = base.changeFileExt("")
        result.add StartupItem(name: name, command: desktopValue(t, "Exec"), where: f,
                               enabled: not hidden and not gnomeOff, canChange: true, forAll: all)
  result.sort(proc (a, b: StartupItem): int = cmp(a.name.toLowerAscii, b.name.toLowerAscii))

proc setStartupEnabled*(item: StartupItem; on: bool): string =
  ## Turns a startup program on or off ("" done, else why not): Linux a
  ## copy of its entry in the user's own autostart folder with Hidden set
  ## (the system's own stays as it is), Windows as Task Manager does
  ## (StartupApproved).
  if not item.canChange: return "this one is the system's: it is changed where it is kept"
  when defined(wasm) or androidApp or defined(ios) or defined(macosx):
    "not here"
  elif defined(windows):
    var k = 0
    var disp = 0'u32
    if RegCreateKeyExW(hkcu, newWideCString(approvedKey), 0, nil, 0, 0x20006, nil, addr k, addr disp) != 0:
      return "the registry refused"
    var data: array[12, uint8]
    data[0] = (if on: 2 else: 3)
    if not on:
      # (when it was turned off, as a FILETIME)
      let ft = uint64((epochTime() + 11644473600.0) * 10_000_000)
      for i in 0 ..< 8: data[4 + i] = uint8((ft shr (8 * i)) and 0xFF)
    let r = RegSetValueExW(k, newWideCString(item.name), 0, 3, addr data[0], 12)   # REG_BINARY
    discard RegCloseKey(k)
    if r == 0: "" else: "the registry refused"
  else:
    try:
      let mine = getConfigDir() / "autostart"
      createDir(mine)
      let dest = mine / item.where.extractFilename
      var t = readFile(item.where)
      var lines: seq[string]
      var inEntry = false
      var put = false
      for l in t.splitLines:
        let s = l.strip
        if s.startsWith("["):
          if inEntry and not put:
            lines.add "Hidden=" & (if on: "false" else: "true")
            put = true
          inEntry = s == "[Desktop Entry]"
        elif inEntry and (s.startsWith("Hidden=") or s.startsWith("X-GNOME-Autostart-enabled=")):
          if s.startsWith("Hidden="):
            lines.add "Hidden=" & (if on: "false" else: "true")
            put = true
          continue
        lines.add l
      if inEntry and not put: lines.add "Hidden=" & (if on: "false" else: "true")
      writeFile(dest, lines.join("\n").strip & "\n")
      ""
    except CatchableError as e: e.msg

# ---- the network's connections -------------------------------------------------------------------

type
  Connection* = object
    ## A TCP or UDP endpoint of a program.
    proto*: string           ## "TCP", "TCP6", "UDP", "UDP6"
    local*, remote*: string  ## address:port ("" for a UDP endpoint's remote)
    state*: string           ## TCP's: "Established", "Listening", "Time wait"...
    pid*: int                ## the program's (-1 when the system does not say)

const tcpStates = ["", "Established", "SYN sent", "SYN received", "FIN wait 1", "FIN wait 2",
                   "Time wait", "Closed", "Close wait", "Last ACK", "Listening", "Closing"]
  ## (Linux's numbers, /proc/net/tcp)

when (defined(linux) or defined(android)) and not defined(wasm):
  proc hexAddr(s: string; v6: bool): string =
    ## "0100007F:0035" -> "127.0.0.1:53"
    let parts = s.split(':')
    if parts.len != 2: return s
    let port = try: fromHex[int](parts[1]) except ValueError: 0
    let h = parts[0]
    if not v6 and h.len == 8:
      var b: seq[string]
      for i in countdown(3, 0): b.add $fromHex[int](h[i * 2 .. i * 2 + 1])
      result = b.join(".")
    elif h.len == 32:
      # (four 32-bit words, each little-endian)
      var groups: seq[string]
      for w in 0 ..< 4:
        let word = h[w * 8 ..< w * 8 + 8]
        let le = word[6 .. 7] & word[4 .. 5] & word[2 .. 3] & word[0 .. 1]
        groups.add le[0 .. 3].toLowerAscii.strip(trailing = false, chars = {'0'})
        groups.add le[4 .. 7].toLowerAscii.strip(trailing = false, chars = {'0'})
      for g in groups.mitems:
        if g.len == 0: g = "0"
      result = "[" & groups.join(":") & "]"
      if result == "[0:0:0:0:0:0:0:0]": result = "[::]"
      elif result == "[0:0:0:0:0:0:0:1]": result = "[::1]"
    else: result = h
    result.add ":" & $port

proc connections*(): tuple[list: seq[Connection]; why: string] =
  ## The TCP and UDP endpoints of the programs, with the program's id where
  ## the system says it; `why` says when the system shows none (Android 10
  ## and later, an iPhone, a web page). Linux, Termux, Windows, macOS.
  when defined(wasm) or defined(ios):
    result.why = "the system shows no connections here"
  elif defined(linux) or defined(android):
    # which process holds which socket (its inode): /proc/*/fd
    var owner = initTable[string, int]()
    for kind, p in walkDir("/proc"):
      let name = p.extractFilename
      if name.len == 0 or not name[0].isDigit: continue
      let pid = try: parseInt(name) except ValueError: continue
      for k2, fd in walkDir(p / "fd"):
        let target = try: expandSymlink(fd) except OSError: ""
        if target.startsWith("socket:["): owner[target[8 .. ^2]] = pid
    var any = false
    for (file, proto, v6) in [("tcp", "TCP", false), ("tcp6", "TCP6", true),
                              ("udp", "UDP", false), ("udp6", "UDP6", true)]:
      let t = try: readFile("/proc/net/" & file) except IOError: ""
      if t.len == 0: continue
      any = true
      var first = true
      for l in t.splitLines:
        if first:                                    # (the column names)
          first = false
          continue
        let f = l.splitWhitespace
        if f.len < 10: continue
        let st = try: fromHex[int](f[3]) except ValueError: 0
        var c = Connection(proto: proto, local: hexAddr(f[1], v6), pid: owner.getOrDefault(f[9], -1))
        if proto.startsWith("TCP"):
          c.remote = hexAddr(f[2], v6)
          c.state = if st in 0 .. tcpStates.high: tcpStates[st] else: $st
        result.list.add c
    if not any: result.why = "the system shows this app no connections (Android 10 and later)"
  elif defined(windows):
    proc GetExtendedTcpTable(table: pointer; size: ptr uint32; order: int32; af: uint32;
                             cls: int32; reserved: uint32): uint32 {.stdcall, dynlib: "iphlpapi", importc.}
    proc GetExtendedUdpTable(table: pointer; size: ptr uint32; order: int32; af: uint32;
                             cls: int32; reserved: uint32): uint32 {.stdcall, dynlib: "iphlpapi", importc.}
    const winStates = ["", "Closed", "Listening", "SYN sent", "SYN received", "Established",
                       "FIN wait 1", "FIN wait 2", "Close wait", "Closing", "Last ACK", "Time wait",
                       "Delete TCB"]
    proc ip4(a: uint32): string =
      $(a and 0xFF) & "." & $((a shr 8) and 0xFF) & "." & $((a shr 16) and 0xFF) & "." & $(a shr 24)
    proc port(p: uint32): int = int(((p and 0xFF) shl 8) or ((p shr 8) and 0xFF))
    for udp in [false, true]:
      var size = 0'u32
      if udp: discard GetExtendedUdpTable(nil, addr size, 1, 2, 1, 0)       # UDP_TABLE_OWNER_PID
      else: discard GetExtendedTcpTable(nil, addr size, 1, 2, 5, 0)         # TCP_TABLE_OWNER_PID_ALL
      if size == 0: continue
      var buf = newSeq[uint32](int(size) div 4 + 1)
      let r = if udp: GetExtendedUdpTable(addr buf[0], addr size, 1, 2, 1, 0)
              else: GetExtendedTcpTable(addr buf[0], addr size, 1, 2, 5, 0)
      if r != 0: continue
      let n = int(buf[0])
      let w = if udp: 3 else: 6                          # (the rows' words)
      for i in 0 ..< n:
        let b = 1 + i * w
        if b + w > buf.len: break
        if udp:
          result.list.add Connection(proto: "UDP", local: ip4(buf[b]) & ":" & $port(buf[b + 1]),
                                     pid: int(buf[b + 2]))
        else:
          let st = int(buf[b])
          result.list.add Connection(proto: "TCP", local: ip4(buf[b + 1]) & ":" & $port(buf[b + 2]),
                                     remote: ip4(buf[b + 3]) & ":" & $port(buf[b + 4]),
                                     state: (if st in 0 .. winStates.high: winStates[st] else: $st),
                                     pid: int(buf[b + 5]))
  elif defined(macosx):
    # every process's sockets (libproc): another user's are not shown without
    # the administrator's rights
    const macStates = ["Closed", "Listening", "SYN sent", "SYN received", "Established", "Close wait",
                       "FIN wait 1", "Closing", "Last ACK", "FIN wait 2", "Time wait"]
    proc port(v: uint32): int = int(((v and 0xFF) shl 8) or ((v shr 8) and 0xFF))
    proc address(b: ptr UncheckedArray[uint8]; v6: bool): string =
      if v6:
        var groups: seq[string]
        for k in 0 ..< 8: groups.add toHex(int(b[k * 2]) shl 8 or int(b[k * 2 + 1]), 4).toLowerAscii.strip(trailing = false, chars = {'0'})
        for g in groups.mitems:
          if g.len == 0: g = "0"
        result = "[" & groups.join(":") & "]"
        if result == "[0:0:0:0:0:0:0:0]": result = "[::]"
        elif result == "[0:0:0:0:0:0:0:1]": result = "[::1]"
      else:
        result = $b[12] & "." & $b[13] & "." & $b[14] & "." & $b[15]
    var pids = newSeq[int32](4096)
    let np = proc_listallpids(addr pids[0], cint(pids.len * 4))
    var buf: array[1536, uint8]
    for i in 0 ..< max(0, np):
      let pid = pids[i]
      if pid <= 0: continue
      let need = proc_pidinfo(cint(pid), 1, 0, nil, 0)              # PROC_PIDLISTFDS
      if need <= 0: continue
      var fds = newSeq[uint32](need div 4 + 32)
      let got = proc_pidinfo(cint(pid), 1, 0, addr fds[0], cint(fds.len * 4))
      for k in 0 ..< max(0, got) div 8:
        if fds[k * 2 + 1] != 2: continue                            # PROX_FDTYPE_SOCKET
        let n = proc_pidfdinfo(cint(pid), cast[cint](fds[k * 2]), 3, addr buf[0], cint(buf.len))
        if n < 24 + 240 + 84: continue                             # (PROC_PIDFDSOCKETINFO)
        template i32(at: int): int32 = cast[ptr int32](addr buf[at])[]
        let si = 24                                                 # (after proc_fileinfo)
        let kind = i32(si + 232)                                    # soi_kind
        if kind notin [1'i32, 2]: continue                          # IN, TCP
        let proto = i32(si + 156)                                   # soi_protocol
        let ini = si + 240                                          # in_sockinfo
        let v6 = (buf[ini + 24] and 2) != 0                         # insi_vflag
        let fa = cast[ptr UncheckedArray[uint8]](addr buf[ini + 32])
        let la = cast[ptr UncheckedArray[uint8]](addr buf[ini + 48])
        var c = Connection(pid: int(pid),
                           local: address(la, v6) & ":" & $port(cast[uint32](i32(ini + 4))))
        if kind == 2:
          c.proto = if v6: "TCP6" else: "TCP"
          c.remote = address(fa, v6) & ":" & $port(cast[uint32](i32(ini)))
          let st = i32(ini + 80)                                    # tcpsi_state
          c.state = if st in 0'i32 .. int32(macStates.high): macStates[st] else: $st
        elif proto == 17:
          c.proto = if v6: "UDP6" else: "UDP"
        else: continue
        result.list.add c
  else:
    result.why = "connections are not shown on this system yet"

# ---- the history: the last days, kept on disk ------------------------------------------------------

const historyRecord = 24
  ## (a point on disk: when (float64), the processor and the memory used in
  ## percent, the disks' and the network's bytes a second (float32 each))

proc appendHistory*(path: string; s: Sample) =
  ## Adds a sample to the history file (one record, 24 bytes); the file
  ## keeps the last 7 days (rewritten without the older ones now and then).
  when not defined(wasm):
    if path.len == 0 or s == nil: return
    var rec: array[historyRecord, uint8]
    var at = s.at
    var vals = [float32(max(0.0, s.cpu)),
                float32(if s.memTotal > 0: s.memUsed.float * 100 / s.memTotal.float else: 0),
                0'f32, 0'f32]
    for d in s.disks: vals[2] += float32(d.readRate + d.writeRate)
    for n in s.nets: vals[3] += float32(n.rxRate + n.txRate)
    copyMem(addr rec[0], addr at, 8)
    copyMem(addr rec[8], addr vals[0], 16)
    try:
      var f: File
      if open(f, path, fmAppend):
        discard f.writeBuffer(addr rec[0], historyRecord)
        let size = f.getFileSize
        f.close()
        if size > 8 * 86400 div 5 * historyRecord:
          # (more than 8 days: the oldest day goes)
          let all = readFile(path)
          writeFile(path, all[86400 div 5 * historyRecord .. ^1])
    except IOError, OSError: discard

proc loadHistory*(path: string; since: float; points = 300): seq[HistoryPoint] =
  ## The history since `since` (epoch seconds), at most `points` (the
  ## records averaged into that many).
  when not defined(wasm):
    if path.len == 0 or not fileExists(path): return
    let data = try: readFile(path) except IOError: ""
    let n = data.len div historyRecord
    var recs: seq[HistoryPoint]
    for i in 0 ..< n:
      var at: float
      var vals: array[4, float32]
      copyMem(addr at, unsafeAddr data[i * historyRecord], 8)
      if at < since: continue
      copyMem(addr vals[0], unsafeAddr data[i * historyRecord + 8], 16)
      recs.add HistoryPoint(at: at, cpu: vals[0], memPercent: vals[1],
                            diskRate: vals[2], netRate: vals[3])
    if recs.len <= points: return recs
    let per = recs.len / points
    for k in 0 ..< points:
      let a = int(float(k) * per)
      let b = max(a + 1, int(float(k + 1) * per))
      var p = HistoryPoint(at: recs[a].at)
      for j in a ..< min(b, recs.len):
        p.cpu += recs[j].cpu
        p.memPercent += recs[j].memPercent
        p.diskRate += recs[j].diskRate
        p.netRate += recs[j].netRate
      let c = float(min(b, recs.len) - a)
      p.cpu /= c
      p.memPercent /= c
      p.diskRate /= c
      p.netRate /= c
      result.add p

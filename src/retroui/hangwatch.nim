## A window that does not answer, told why. On Windows a thread asks the
## window every second whether it takes its messages, as Windows itself
## does before it writes "Not responding" on a title bar. When it has not
## for five seconds, what the window's thread is doing -- the procs it is
## in, the innermost first -- goes to the app's fault log, and the "Report
## a Problem" box of the next start shows it: a report of where a program
## waited, from the computer it waited on. Once for each time it stops
## answering, six times a run at most; not while the app is starting
## (before it has drawn its first frames: `hangUp`).
##
## The procs are named when the program carries a table of them at its
## end (`nimble exe` puts one there: tools/winsym.py, from the program
## before it is stripped), or one is beside it (`RetroFiles.sym` beside
## `RetroFiles.exe`); else they are places in the program.
##
## A program that is still there thirty seconds after its window closed is
## ended (`hangStopping`): nothing shows of it by then.
##
## Elsewhere than on 64-bit Windows it does nothing.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

type HangNote* = proc (text: string) {.nimcall, gcsafe, raises: [].}
  ## What is done with a report: written to the fault log (`core` gives it).

const HangWatched* = defined(windows) and defined(amd64) and compileOption("threads")
  ## There is a watch on this system.

import std/strutils

type ProcTable* = seq[tuple[at: uint64; name: string]]
  ## A program's procs: where each starts in the program, and its name, in order.

proc procTable*(text: string): ProcTable =
  ## The table tools/winsym.py writes, read: "1a2b3c name" a line, in
  ## order (lines that are not so are left out).
  for line in text.splitLines:
    let sp = line.find(' ')
    if sp <= 0 or sp == line.high: continue
    try: result.add (uint64(parseHexInt(line[0 ..< sp])), line[sp + 1 .. ^1])
    except ValueError: discard

proc procAt*(table: ProcTable; place: uint64): string =
  ## The proc that holds a place in the program: the last one that starts
  ## at it or before it ("" when there is none within a megabyte).
  var lo = 0
  var hi = table.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if table[mid].at <= place: lo = mid + 1 else: hi = mid
  if lo > 0 and place - table[lo - 1].at < 0x100000: table[lo - 1].name else: ""

when HangWatched:
  import std/[typedthreads, os, atomics]
  import uirelays/drivers/winapi_driver
  from codec import zlibDecompress

  type
    Handle = pointer
    WinContext = object
      ## (CONTEXT of x64: 1232 bytes, on a 16-byte boundary; the fields used)
      home: array[6, uint64]
      flags: uint32
      mxcsr: uint32
      segs: array[6, uint16]
      eflags: uint32
      dr: array[6, uint64]
      rax, rcx, rdx, rbx, rsp, rbp, rsi, rdi: uint64
      r8, r9, r10, r11, r12, r13, r14, r15: uint64
      rip: uint64
      rest: array[976, byte]

  proc GetCurrentThreadId(): uint32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetCurrentProcess(): Handle {.stdcall, dynlib: "kernel32", importc.}
  proc OpenThread(access: uint32; inherit: int32; id: uint32): Handle {.stdcall, dynlib: "kernel32", importc.}
  proc SuspendThread(h: Handle): uint32 {.stdcall, dynlib: "kernel32", importc.}
  proc ResumeThread(h: Handle): uint32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetThreadContext(h: Handle; ctx: ptr WinContext): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc RtlLookupFunctionEntry(pc: uint64; base: ptr uint64; history: pointer): pointer
    {.stdcall, dynlib: "kernel32", importc.}
  proc RtlVirtualUnwind(kind: uint32; base, pc: uint64; entry: pointer; ctx: ptr WinContext;
                        data: ptr pointer; frame: ptr uint64; ptrs: pointer): pointer
    {.stdcall, dynlib: "kernel32", importc.}
  proc ReadProcessMemory(p: Handle; at: pointer; buf: pointer; n: uint; got: ptr uint): int32
    {.stdcall, dynlib: "kernel32", importc.}
  proc GetModuleHandleExW(flags: uint32; address: pointer; module: ptr Handle): int32
    {.stdcall, dynlib: "kernel32", importc.}
  proc GetModuleFileNameW(module: Handle; name: ptr uint16; n: uint32): uint32
    {.stdcall, dynlib: "kernel32", importc.}
  proc GetModuleHandleW(name: pointer): Handle {.stdcall, dynlib: "kernel32", importc.}
  proc SendMessageTimeoutW(h: pointer; msg: uint32; wp: uint; lp: int; flags, ms: uint32;
                           res: ptr uint): int {.stdcall, dynlib: "user32", importc.}
  proc IsWindow(h: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc Sleep(ms: uint32) {.stdcall, dynlib: "kernel32", importc.}
  proc TerminateProcess(p: Handle; code: uint32): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetTickCount64(): uint64 {.stdcall, dynlib: "kernel32", importc.}
  proc c_fflush(f: pointer): cint {.importc: "fflush", header: "<stdio.h>".}

  const
    MostFrames = 48
    AfterMs = 5000              # (not answering this long: told)
    GoneMs = 30_000             # (still there this long after its window closed: ended)

  var
    watcher: Thread[void]
    uiThread: Handle
    noteProc: HangNote
    watching = false
    stoppingAt: Atomic[int64]   # (when the window closed: ticks; 0 while it is open)
    upFlag: Atomic[bool]        # (the app has drawn: it is past its start)
    stopCode: Atomic[int]

  proc stackOf(thread: Handle; frames: var array[MostFrames, uint64]): int =
    ## The return addresses of a thread, the innermost first. The thread is
    ## held still meanwhile; nothing is allocated while it is (it may hold
    ## the heap's lock).
    var raw: array[sizeof(WinContext) + 16, byte]
    let ctx = cast[ptr WinContext]((cast[uint](addr raw[0]) + 15) and not 15'u)
    if SuspendThread(thread) == 0xFFFFFFFF'u32: return 0
    ctx.flags = 0x100003'u32                      # CONTEXT_CONTROL, _INTEGER
    if GetThreadContext(thread, ctx) != 0:
      let me = GetCurrentProcess()
      while result < MostFrames and ctx.rip != 0:
        frames[result] = ctx.rip
        inc result
        var base: uint64
        let entry = RtlLookupFunctionEntry(ctx.rip, addr base, nil)
        if entry == nil:
          # (a proc that calls nothing: where it returns to is on top of the stack)
          var back: uint64
          if ReadProcessMemory(me, cast[pointer](ctx.rsp), addr back, 8, nil) == 0: break
          ctx.rip = back
          ctx.rsp += 8
        else:
          var data: pointer
          var frame: uint64
          discard RtlVirtualUnwind(0, base, ctx.rip, entry, ctx, addr data, addr frame, nil)
    discard ResumeThread(thread)

  proc symbols(): ProcTable =
    ## (the table at the program's end, or beside it: "1a2b3c name" a line, in order)
    var text = ""
    try:
      var f = open(getAppFilename(), fmRead)
      defer: f.close()
      let size = f.getFileSize()
      if size > 16:
        var tail = newString(16)
        f.setFilePos(size - 16)
        if f.readBuffer(addr tail[0], 16) == 16 and tail[8 .. 15] == "RETROSYM":
          var n = 0'i64
          for k in countdown(7, 0): n = (n shl 8) or int64(ord(tail[k]))
          if n > 0 and n < size - 16 and n < 64_000_000:
            var packed = newSeq[byte](n.int)
            f.setFilePos(size - 16 - n)
            if f.readBuffer(addr packed[0], n.int) == n.int:
              let raw = zlibDecompress(packed, 64_000_000)
              text = newString(raw.len)
              if raw.len > 0: copyMem(addr text[0], unsafeAddr raw[0], raw.len)
    except CatchableError: text = ""
    if text.len == 0:
      try: text = readFile(getAppFilename().changeFileExt("sym"))
      except CatchableError: discard
    procTable(text)

  proc report(what: string): string =
    ## What the window's thread is in now, as lines.
    var frames: array[MostFrames, uint64]
    let n = stackOf(uiThread, frames)
    result = "--- " & what & "\n"
    if n == 0:
      result.add "(what it is doing could not be read)\n"
      return
    let exe = GetModuleHandleW(nil)
    let syms = symbols()
    for i in 0 ..< n:
      var module: Handle
      var line = "  "
      if GetModuleHandleExW(4 or 2, cast[pointer](frames[i]), addr module) != 0 and module != nil:
        var name: array[300, uint16]
        let len = GetModuleFileNameW(module, addr name[0], 299)
        var s = ""
        for k in 0 ..< len.int: s.add (if name[k] < 128: char(name[k]) else: '?')
        let rva = frames[i] - cast[uint64](module)
        let sym = if module == exe: procAt(syms, rva) else: ""
        line.add (if sym.len > 0: sym & "  (" else: "") & s.extractFilename & "+" & toHex(rva.int, 6).toLowerAscii &
                 (if sym.len > 0: ")" else: "")
      else:
        line.add toHex(frames[i].int, 12).toLowerAscii
      result.add line & "\n"

  proc watch() {.thread.} =
    var silentSince = 0'u64         # (when it last stopped answering; 0: it answers)
    var told = false
    var reports = 0
    while true:
      Sleep(1000)
      {.cast(gcsafe).}:
        let now = GetTickCount64()
        let closed = stoppingAt.load
        if closed != 0:
          # (its window is closed: it should be gone)
          if now - uint64(closed) > GoneMs:
            if noteProc != nil:
              noteProc(report("the program was still there " & $(GoneMs div 1000) &
                              " seconds after its window closed, and was ended: its thread was in"))
            discard c_fflush(nil)
            # (ended as it would have ended; 3 when that was 0: it did not end by itself)
            let code = stopCode.load
            discard TerminateProcess(GetCurrentProcess(), uint32(if code != 0: code else: 3))
          continue
        let w = winWindow()
        if w == nil or IsWindow(w) == 0: continue
        var res: uint
        let answered = SendMessageTimeoutW(w, 0, 0, 0, 2, 1000, addr res) != 0    # WM_NULL, SMTO_ABORTIFHUNG
        if answered:
          silentSince = 0
          told = false
          continue
        if not upFlag.load: continue      # (still starting: a start is as long as it is)
        if silentSince == 0: silentSince = now
        if not told and now - silentSince >= AfterMs and reports < 6:
          told = true
          inc reports
          if noteProc != nil:
            noteProc(report("the window did not answer for " & $(AfterMs div 1000) &
                            " seconds: its thread was in"))

proc startHangWatch*(note: HangNote) =
  ## Call it on the window's thread, once the window is open: from then on
  ## a window that stops answering is told to `note`.
  when HangWatched:
    stoppingAt.store(0)                 # (a window again: the program is not ending)
    if watching: return
    watching = true
    noteProc = note
    uiThread = OpenThread(0x0002 or 0x0008 or 0x0040, 0, GetCurrentThreadId())
    if uiThread == nil: return
    createThread(watcher, watch)
  else:
    discard note == nil

proc hangUp*() {.inline.} =
  ## The app has drawn: from now on a window that does not answer is told
  ## (`core` calls it as the frames go by).
  when HangWatched:
    if watching and not upFlag.load: upFlag.store(true)

proc hangStopping*(exitCode = 0) =
  ## The window is closed and the program is about to end: when it is
  ## still there half a minute later it is ended, with `exitCode`.
  when HangWatched:
    if watching:
      stopCode.store(exitCode)
      stoppingAt.store(int64(GetTickCount64()))
  else:
    discard exitCode

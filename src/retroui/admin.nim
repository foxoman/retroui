## A command run as the computer's administrator, the system asking the
## user first: Windows with its UAC dialog, macOS with its password dialog,
## Linux and the BSDs with polkit's (pkexec). For a short command that
## changes a setting of the whole computer -- Retro DNS's DNS servers -- not
## for a program to keep running. Phones and web pages have none: there the
## answer is `adNone` at once.
##
## It runs on a thread of its own, so the window keeps drawing while the
## system asks and the command runs. The first call with a key starts it;
## each later one says how it goes, until it is no longer `adWaiting` --
## then the key is free again, and the next call starts it anew.
##
## .. code-block:: nim
##   import retroui, retroui/admin
##   var asked = false
##   app "Settings", 400, 200:
##     if button("&Flush the DNS cache"): asked = true
##     if asked:
##       let r = runAsAdmin("flush", "resolvectl", ["flush-caches"])
##       case r.state
##       of adWaiting: wakeIn(200)                 # (asked again soon)
##       of adDone: asked = false; toast(if r.code == 0: "Done" else: r.output)
##       of adRefused: asked = false; toast("Not allowed")
##       of adNone, adFailed: asked = false; toast(r.output)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/strutils
import uirelays/target   # (androidApp: an APK, not a program in Termux)
const posixDesktop = not (androidApp or defined(ios) or defined(wasm) or defined(js) or
                          defined(windows))
when posixDesktop: import std/osproc
when posixDesktop and not defined(macosx): import std/os

type
  AdminState* = enum
    ## How a `runAsAdmin` goes.
    adNone       ## there is no administrator to ask here (a phone, the web)
    adWaiting    ## the system asks, or the command runs: ask again later
    adDone       ## it ran: `code` is its exit code, `output` what it wrote
    adRefused    ## the user said no, or gave no password that works
    adFailed     ## it could not be started: `output` says why

  AdminRun* = object
    ## What became of a command run as the administrator.
    state*: AdminState
    code*: int           ## its exit code (adDone)
    output*: string      ## what it wrote (macOS, Linux; Windows gives
                         ## nothing back), or why it failed

when posixDesktop and not defined(macosx):
  var pkexecHere = -1     ## (pkexec is on the PATH: 1, not: 0, not looked yet: -1)

proc canRunAsAdmin*(): bool =
  ## A command can be run as the administrator here (the system asks).
  when androidApp or defined(ios) or defined(wasm) or defined(js): false
  elif defined(windows) or defined(macosx): true
  else:
    if pkexecHere < 0: pkexecHere = ord(findExe("pkexec").len > 0)
    pkexecHere == 1

proc appleScriptText*(s: string): string =
  ## `s` as an AppleScript string literal, in its quotes.
  result = "\""
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    else: result.add c
  result.add '"'

proc quotedPosix(s: string): string =
  ## (one word for sh, in single quotes)
  if s.len > 0 and s.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '/', ':', '=', ','}):
    s
  else:
    "'" & s.replace("'", "'\\''") & "'"

proc posixCommand*(exe: string; args: openArray[string]): string =
  ## `exe` with `args` as one line for sh, each word quoted as it needs.
  result = quotedPosix(exe)
  for a in args: result.add " " & quotedPosix(a)

proc windowsArgs*(args: openArray[string]): string =
  ## `args` as a Windows command line's (CommandLineToArgvW's rules).
  for i, a in args:
    if i > 0: result.add ' '
    if a.len > 0 and not a.contains({' ', '\t', '"'}):
      result.add a
      continue
    result.add '"'
    var slashes = 0
    for c in a:
      if c == '\\': inc slashes
      elif c == '"':
        result.add repeat('\\', slashes * 2 + 1)
        result.add '"'
        slashes = 0
      else:
        result.add repeat('\\', slashes)
        result.add c
        slashes = 0
    result.add repeat('\\', slashes * 2)
    result.add '"'

when defined(windows) and not defined(js):
  type ShellExecuteInfoW {.pure.} = object
    cbSize, fMask: uint32
    hwnd: pointer
    lpVerb, lpFile, lpParameters, lpDirectory: WideCString
    nShow: int32
    hInstApp, lpIDList: pointer
    lpClass: WideCString
    hkeyClass: pointer
    dwHotKey: uint32
    hIconOrMonitor, hProcess: pointer

  proc ShellExecuteExW(info: ptr ShellExecuteInfoW): int32 {.stdcall, dynlib: "shell32", importc.}
  proc WaitForSingleObject(h: pointer; ms: uint32): uint32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetExitCodeProcess(h: pointer; code: ptr uint32): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc CloseHandle(h: pointer): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetLastError(): uint32 {.stdcall, dynlib: "kernel32", importc.}
  proc CoInitializeEx(r: pointer; flags: uint32): int32 {.stdcall, dynlib: "ole32", importc.}
  proc CoUninitialize() {.stdcall, dynlib: "ole32", importc.}

proc runNow(exe: string; args: seq[string]; why: string): AdminRun =
  ## (the command run as the administrator, waited for: on the job's thread)
  when androidApp or defined(ios) or defined(wasm) or defined(js):
    AdminRun(state: adNone, output: "There is no administrator to ask here.")
  elif defined(windows):
    # (UAC's dialog; "runas" asks for the administrator's rights)
    let com = CoInitializeEx(nil, 0x2 or 0x4)      # (apartment, no OLE1 DDE)
    defer:
      if com >= 0: CoUninitialize()
    let verb = newWideCString("runas")
    let file = newWideCString(exe)
    let params = newWideCString(windowsArgs(args))
    var info = ShellExecuteInfoW(cbSize: uint32(sizeof(ShellExecuteInfoW)),
                                 fMask: 0x40 or 0x100 or 0x400,  # keep the process, wait, no UI
                                 lpVerb: verb, lpFile: file, lpParameters: params,
                                 nShow: 0)                       # (hidden)
    if ShellExecuteExW(addr info) == 0:
      let err = GetLastError()
      if err == 1223: return AdminRun(state: adRefused)          # ERROR_CANCELLED
      return AdminRun(state: adFailed, output: "Windows could not start " & exe &
                      " (error " & $err & ")")
    if info.hProcess == nil: return AdminRun(state: adDone)
    discard WaitForSingleObject(info.hProcess, 0xFFFFFFFF'u32)
    var code: uint32
    discard GetExitCodeProcess(info.hProcess, addr code)
    discard CloseHandle(info.hProcess)
    AdminRun(state: adDone, code: int(code))
  elif defined(macosx):
    # (the password dialog of AppleScript's do shell script)
    var script = "do shell script " & appleScriptText(posixCommand(exe, args))
    if why.len > 0: script.add " with prompt " & appleScriptText(why)
    script.add " with administrator privileges"
    try:
      let (output, code) = execCmdEx(posixCommand("/usr/bin/osascript", ["-e", script]))
      if code != 0 and "-128" in output: AdminRun(state: adRefused)   # (User canceled.)
      elif code != 0 and "execution error" in output and "(-60007)" in output:
        AdminRun(state: adRefused)                                      # (not an administrator)
      else: AdminRun(state: adDone, code: code, output: output.strip)
    except CatchableError as e:
      AdminRun(state: adFailed, output: e.msg)
  else:
    # (polkit's pkexec: 126 when the dialog was dismissed, 127 when it was
    # not allowed)
    let pk = findExe("pkexec")
    if pk.len == 0:
      return AdminRun(state: adFailed, output: "pkexec is not here (polkit): run it as root")
    let full = if exe.isAbsolute: exe else: findExe(exe)
    if full.len == 0: return AdminRun(state: adFailed, output: exe & " is not on the PATH")
    try:
      let (output, code) = execCmdEx(posixCommand(pk, @[full] & args))
      let low = output.toLowerAscii
      if code in [126, 127] and ("no authentication agent" in low or
                                 "error getting authority" in low):
        # (nobody to ask: no polkit, or no agent of it in this session)
        AdminRun(state: adFailed, output: "The administrator cannot be asked here: " & output.strip)
      elif code in [126, 127] and ("dismissed" in low or "not authorized" in low):
        AdminRun(state: adRefused)
      else: AdminRun(state: adDone, code: code, output: output.strip)
    except CatchableError as e:
      AdminRun(state: adFailed, output: e.msg)

when compileOption("threads") and not defined(js) and not defined(wasm):
  import std/[typedthreads, tables]
  type
    Job = ref object
      thread: Thread[(string, string, seq[string], string)]
  var
    jobs: Table[string, Job]
    done: Channel[(string, AdminRun)]
    opened = false
    came: Table[string, AdminRun]

  proc work(a: (string, string, seq[string], string)) {.thread.} =
    var r: AdminRun
    {.cast(gcsafe).}:
      r = runNow(a[1], a[2], a[3])
    done.send((a[0], r))

proc runAsAdmin*(key, exe: string; args: openArray[string] = []; why = ""): AdminRun =
  ## Runs `exe` with `args` as the administrator, the system asking the user
  ## (`why`: the reason macOS's dialog gives). The first call with `key`
  ## starts it and says `adWaiting`; ask again with the same key (each
  ## frame, or in `wakeIn`'s) until it says how it went.
  when androidApp or defined(ios) or defined(wasm) or defined(js):
    AdminRun(state: adNone, output: "There is no administrator to ask here.")
  elif compileOption("threads"):
    if not opened:
      done.open()
      opened = true
    while true:
      let (got, d) = done.tryRecv()
      if not got: break
      came[d[0]] = d[1]
    if key in came:
      result = came[key]
      came.del key
      if key in jobs:
        joinThread(jobs[key].thread)
        jobs.del key
      return
    if key notin jobs:
      let j = Job()
      jobs[key] = j
      createThread(j.thread, work, (key, exe, @args, why))
    AdminRun(state: adWaiting)
  else:
    runNow(exe, @args, why)

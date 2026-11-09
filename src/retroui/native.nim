## The operating system's own APIs, from Nim, with nothing to install:
##
## - **Any OS, any library:** `nativeLib` and `nativeProc` load a shared
##   library (`.so`, `.dll`, `.dylib`, a framework) and give a typed proc of
##   any function in it.
## - **Android:** `javaStatic`, `javaActivity`, `javaCall`, `javaNew` call
##   any Java API by reflection -- no Java to write, no JNI. Objects stay on
##   the Java side as `JObject` handles (`javaRelease` them). Calls that must
##   run on the UI thread go in `onUiThread`.
## - **macOS and iOS:** `objcClass`, `sel`, `objcSend`, `nsString`,
##   `toNim` and `autoreleasePool` talk to Objective-C through its runtime --
##   no Objective-C file.
## - **Windows:** typed Win32 calls (`windowsUserName`,
##   `windowsDocumentsFolder`...) and COM (`taskbarProgress` on the taskbar
##   button) show the way; any other function is `nativeProc` away.
## - **Linux, BSD, Termux:** `termuxApi` runs the Termux:API commands when
##   they are installed.
## - **The same everywhere:** `vibrate`, `deviceName`, `osVersion`,
##   `batteryLevel`, `systemDarkMode`, `beepSystem`, `userName`,
##   `keepScreenOn`, `openSettings` -- neutral answers (-1, "", false) where a
##   system has no such thing; they never raise.
##
## .. code-block:: nim
##   import retroui, retroui/native
##   echo deviceName(), ", ", osVersion(), ", battery ", batteryLevel(), "%"
##   when defined(android):
##     echo javaStatic("android.os.Build", "MODEL")            # a static field
##     echo javaActivity("getPackageName")                      # the app's activity
##   when defined(macosx):
##     let info = objcSend(ObjcId, objcClass("NSProcessInfo"), "processInfo")
##     echo toNim(objcSend(ObjcId, info, "hostName"))
##   when defined(windows):
##     echo windowsDocumentsFolder()

import std/[os, strutils, dynlib, times]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import uirelays/services
when defined(macosx) or defined(ios):
  import std/macros
when not defined(windows):
  import std/posix
when not defined(ios) and not androidApp:
  import std/[osproc, streams]

when androidApp:
  # Android before 9 has no posix_spawn (what std/osproc uses): commands
  # run through popen, which every version has.
  proc c_popen(cmd, mode: cstring): File {.importc: "popen", header: "<stdio.h>".}
  proc c_pclose(f: File): cint {.importc: "pclose", header: "<stdio.h>".}

  proc shellQuote(s: string): string = "'" & s.replace("'", "'\\''") & "'"

  proc runShell(cmd: string): tuple[output: string; code: int] =
    ## Runs `cmd` with /system/bin/sh and gives what it printed and its exit code.
    let f = c_popen(cmd.cstring, "r")
    if f == nil: return ("", -1)
    var buf = newString(4096)
    while true:
      let n = readBuffer(f, addr buf[0], buf.len)
      if n <= 0: break
      result.output.add buf[0 ..< n]
    let st = c_pclose(f)
    result.code = if st == -1: -1 else: (st shr 8) and 0xff

# ---- shared libraries, on every system ---------------------------------------------------------

type NativeLib* = LibHandle
  ## A loaded shared library (nil: none of the names loaded).

proc nativeLib*(names: varargs[string]): NativeLib =
  ## The first of `names` that loads: `nativeLib("libc.so.6", "libc.so")`,
  ## `nativeLib("user32.dll")`,
  ## `nativeLib("/System/Library/Frameworks/AppKit.framework/AppKit")`.
  ## nil when none does. Keep it loaded while its procs are used.
  for n in names:
    let h = loadLib(n)
    if h != nil: return h

proc nativeProc*[T: proc](lib: NativeLib; name: string): T =
  ## The function `name` of `lib` as a proc of type `T` (nil when it is not
  ## there). The type must match the C declaration, with its calling
  ## convention:
  ##
  ## .. code-block:: nim
  ##   let libc = nativeLib("libc.so.6", "libc.so", "libSystem.dylib", "msvcrt.dll")
  ##   let strlen = nativeProc[proc (s: cstring): csize_t {.cdecl.}](libc, "strlen")
  ##   if strlen != nil: echo strlen("hello")       # 5
  if lib == nil: return nil
  cast[T](lib.symAddr(name))

proc nativeFree*(lib: NativeLib) =
  ## Unloads `lib` (its procs must not be called after).
  if lib != nil: unloadLib(lib)

# ---- Android: any Java API by reflection ---------------------------------------------------------

type
  JObject* = distinct int
    ## A Java object kept on the Java side for Nim (0: null). Release it with
    ## `javaRelease` when done.
  JArgKind = enum jaNull, jaString, jaInt, jaLong, jaDouble, jaFloat, jaBool,
                  jaActivity, jaObject
  JArg* = object
    ## An argument of a Java call; strings, ints, floats, bools and
    ## `JObject`s become one by themselves, `jlong`, `jfloat`, `jnull` and
    ## `jactivity` make the others.
    kind: JArgKind
    s: string
    i: int64
    f: float64

const jnull* = JArg(kind: jaNull)
  ## Java's null.

proc `==`*(a, b: JObject): bool {.borrow.}
  ## The same kept object.
proc isNil*(o: JObject): bool = int(o) == 0
  ## The object is null (or the call that should have made it failed).

proc toJArg*(s: string): JArg = JArg(kind: jaString, s: s)
  ## A Java String (or CharSequence).
proc toJArg*(i: int): JArg = JArg(kind: jaInt, i: int64(i))
  ## A Java int (or a long, float, double where the method wants one).
proc toJArg*(i: int32): JArg = JArg(kind: jaInt, i: int64(i))
  ## A Java int.
proc toJArg*(i: int64): JArg = JArg(kind: jaLong, i: i)
  ## A Java long.
proc toJArg*(f: float): JArg = JArg(kind: jaDouble, f: f)
  ## A Java double (or float).
proc toJArg*(f: float32): JArg = JArg(kind: jaFloat, f: float64(f))
  ## A Java float.
proc toJArg*(b: bool): JArg = JArg(kind: jaBool, i: int64(ord(b)))
  ## A Java boolean.
proc toJArg*(o: JObject): JArg =
  ## An object kept on the Java side (null when `o` is).
  if o.isNil: jnull else: JArg(kind: jaObject, i: int64(o))
proc toJArg*(a: JArg): JArg = a
  ## An argument made with `jlong`, `jfloat`, `jnull` or `jactivity`.
proc jlong*(v: int64): JArg = JArg(kind: jaLong, i: v)
  ## `v` as a Java long (`vibrate(jlong(200))`).
proc jfloat*(v: float): JArg = JArg(kind: jaFloat, f: v)
  ## `v` as a Java float.
proc jactivity*(): JArg = JArg(kind: jaActivity)
  ## The app's Activity -- a Context, for the many APIs that want one.

proc escapeField(s: string): string =
  ## Tabs separate the fields of a call: they, newlines, NULs and
  ## backslashes travel as \t \n \0 \\.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '\t': result.add "\\t"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\0': result.add "\\0"
    else: result.add c

proc encodeArg(a: JArg): string =
  case a.kind
  of jaNull: "n"
  of jaString: "s" & a.s
  of jaInt: "i" & $a.i
  of jaLong: "l" & $a.i
  of jaDouble, jaFloat:
    # the shortest text that reads back the same, in Java's words for the
    # values that are not numbers
    let t = if a.f != a.f: "NaN"
            elif a.f == Inf: "Infinity"
            elif a.f == NegInf: "-Infinity"
            elif a.kind == jaFloat: $float32(a.f)
            else: $a.f
    (if a.kind == jaFloat: "f" else: "d") & t
  of jaBool: "b" & $a.i
  of jaActivity: "a"
  of jaObject: "o" & $a.i

var
  lastJavaError {.threadvar.}: string
  uiDepth {.threadvar.}: int
  bridgeState = 0        # 0 not asked yet, 1 there, 2 not there

proc javaRaw(what: string; fields: openArray[string]; args: openArray[JArg]): string =
  ## One call to the Java side; its encoded answer ("e..." when it failed).
  var parts: seq[string]
  for f in fields: parts.add escapeField(f)
  for a in args: parts.add escapeField(encodeArg(a))
  let r = systemCall("native." & what, parts.join("\t"))
  if r == "\0" or r.len == 0: "enot available here (an Android app, not Termux)"
  else: r

proc decodeText(r: string): string =
  case r[0]
  of 's':
    lastJavaError = ""
    r[1 .. ^1]
  of 'n':
    lastJavaError = ""
    ""
  of 'h':
    lastJavaError = ""
    r[1 .. ^1]
  else:
    lastJavaError = r[1 .. ^1]
    ""

proc decodeObj(r: string): JObject =
  if r[0] == 'h':
    lastJavaError = ""
    try: JObject(parseInt(r[1 .. ^1])) except ValueError: JObject(0)
  else:
    discard decodeText(r)
    JObject(0)

proc flags(handle: bool): string =
  (if handle: "h" else: "") & (if uiDepth > 0: "u" else: "")

proc javaError*(): string = lastJavaError
  ## Why the last Java call failed ("" when it worked): the exception's name
  ## and message, e.g. "SecurityException: requires VIBRATE".

proc javaAvailable*(): bool =
  ## The Java side answers: the app runs as an Android app (an APK). False on
  ## other systems and in Termux.
  if bridgeState == 0:
    bridgeState = if javaRaw("ping", [], []) == "s1": 1 else: 2
  bridgeState == 1

template onUiThread*(body: untyped) =
  ## The Java calls in `body` run on Android's UI thread (views, windows,
  ## toasts, dialogs need it), each waiting for its answer:
  ##
  ## .. code-block:: nim
  ##   onUiThread:
  ##     let w = javaActivityObj("getWindow")
  ##     discard javaCall(w, "addFlags", 128)       # keep the screen on
  ##     javaRelease(w)
  inc uiDepth
  try:
    body
  finally:
    dec uiDepth

proc javaStatic*(className, member: string; args: varargs[JArg, toJArg]): string =
  ## Calls the static method `member` of the class `className` with `args`
  ## (the overload whose parameters they fit), or reads the static field of
  ## that name when there is no such method and no argument; its result as
  ## text ("" for null, void or an error: see `javaError`). Nested classes
  ## take a `$`:
  ##
  ## .. code-block:: nim
  ##   echo javaStatic("android.os.Build", "MODEL")                 # "Pixel 9"
  ##   echo javaStatic("android.os.Build$VERSION", "SDK_INT")       # "35"
  ##   echo javaStatic("java.lang.Math", "max", 3, 7)                # "7"
  decodeText(javaRaw("static", [className, member, flags(false)], args))

proc javaStaticObj*(className, member: string; args: varargs[JArg, toJArg]): JObject =
  ## Like `javaStatic`, the result kept as an object to call further:
  ## `let uri = javaStaticObj("android.net.Uri", "parse", "https://nim-lang.org")`.
  decodeObj(javaRaw("static", [className, member, flags(true)], args))

proc javaActivity*(member: string; args: varargs[JArg, toJArg]): string =
  ## Calls the method `member` of the app's Activity (a Context too):
  ## `javaActivity("getPackageName")`; the result as text.
  decodeText(javaRaw("method", ["a", member, flags(false)], args))

proc javaActivityObj*(member: string; args: varargs[JArg, toJArg]): JObject =
  ## Like `javaActivity`, the result kept as an object:
  ## `let vib = javaActivityObj("getSystemService", "vibrator")`.
  decodeObj(javaRaw("method", ["a", member, flags(true)], args))

proc javaCall*(obj: JObject; member: string; args: varargs[JArg, toJArg]): string =
  ## Calls the method `member` of `obj` (or reads, with no argument, or
  ## writes, with one, its public field of that name); the result as text.
  if obj.isNil:
    lastJavaError = "the object is null"
    return ""
  decodeText(javaRaw("method", ["o" & $int(obj), member, flags(false)], args))

proc javaCallObj*(obj: JObject; member: string; args: varargs[JArg, toJArg]): JObject =
  ## Like `javaCall`, the result kept as an object.
  if obj.isNil:
    lastJavaError = "the object is null"
    return JObject(0)
  decodeObj(javaRaw("method", ["o" & $int(obj), member, flags(true)], args))

proc javaNew*(className: string; args: varargs[JArg, toJArg]): JObject =
  ## A new object of `className` (the constructor its arguments fit):
  ## `let intent = javaNew("android.content.Intent", "android.settings.SETTINGS")`.
  decodeObj(javaRaw("new", [className, flags(true)], args))

proc javaRelease*(objs: varargs[JObject]) =
  ## Lets the Java side forget these objects.
  var ids: seq[string]
  for o in objs:
    if not o.isNil: ids.add $int(o)
  if ids.len > 0: discard systemCall("native.release", ids.join("\t"))

proc javaKept*(): int =
  ## How many objects the Java side keeps for Nim now (to find leaks).
  try: parseInt(decodeText(javaRaw("count", [], []))) except ValueError: 0

# ---- Android: ready-made ---------------------------------------------------------------------

proc showAndroidToast*(text: string; long = false): bool {.discardable.} =
  ## Android's own toast (a short message at the bottom of the screen).
  ## The kit's `toast` looks the same everywhere; this is the system's.
  if not javaAvailable(): return false
  onUiThread:
    let t = javaStaticObj("android.widget.Toast", "makeText", jactivity(), text,
                          if long: 1 else: 0)
    if t.isNil: return false
    discard javaCall(t, "show")
    javaRelease(t)
  javaError().len == 0

proc deviceModel*(): string =
  ## The maker and model ("Google Pixel 9" on Android; `deviceName`
  ## elsewhere).
  if javaAvailable():
    let maker = javaStatic("android.os.Build", "MANUFACTURER")
    let model = javaStatic("android.os.Build", "MODEL")
    if model.toLowerAscii.startsWith(maker.toLowerAscii): model
    else: (maker.capitalizeAscii & " " & model).strip
  else: ""

proc androidVersion*(): tuple[release: string; sdk: int] =
  ## Android's version ("15", 35); ("", 0) elsewhere.
  if not javaAvailable(): return ("", 0)
  result.release = javaStatic("android.os.Build$VERSION", "RELEASE")
  result.sdk = try: parseInt(javaStatic("android.os.Build$VERSION", "SDK_INT"))
               except ValueError: 0

# ---- macOS and iOS: Objective-C through its runtime ------------------------------------------------

when defined(macosx) or defined(ios):
  {.passL: "-lobjc".}
  type
    ObjcId* = pointer
      ## An Objective-C object (nil: none).
    ObjcSel* = pointer
      ## A selector (a method's name).

  proc objc_getClass(name: cstring): pointer {.importc, cdecl.}
  proc sel_registerName(name: cstring): pointer {.importc, cdecl.}
  proc objc_msgSend() {.importc, cdecl.}
  when defined(amd64):
    proc objc_msgSend_stret() {.importc, cdecl.}
  proc objc_autoreleasePoolPush(): pointer {.importc, cdecl.}
  proc objc_autoreleasePoolPop(p: pointer) {.importc, cdecl.}

  proc objcClass*(name: string): ObjcId = objc_getClass(name)
    ## The class `name` (nil when there is none): `objcClass("NSString")`.
  proc sel*(name: string): ObjcSel = sel_registerName(name)
    ## The selector `name` ("stringWithUTF8String:", with its colons).

  proc msgSendFor*[T](): pointer =
    ## Which objc_msgSend a method returning `T` needs (x86-64 returns big
    ## structures through objc_msgSend_stret; arm64 never does).
    when T is void: cast[pointer](objc_msgSend)
    elif defined(amd64) and sizeof(T) > 16: cast[pointer](objc_msgSend_stret)
    else: cast[pointer](objc_msgSend)

  macro objcSend*(R: typedesc; obj: typed; selector: static[string];
                  args: varargs[typed]): untyped =
    ## Sends `selector` to `obj` (an object or a class) with `args`; the
    ## result is of type `R` (`void`, `ObjcId`, `int` for NSInteger, `uint`,
    ## `bool` for BOOL, `float` for double and CGFloat, `cstring`, a struct).
    ## The arguments are passed as their Nim types: `ObjcId`, `int`, `float`,
    ## `bool`, `cstring`, `ObjcSel`...
    ##
    ## .. code-block:: nim
    ##   let defaults = objcSend(ObjcId, objcClass("NSUserDefaults"), "standardUserDefaults")
    ##   let style = objcSend(ObjcId, defaults, "stringForKey:", nsString("AppleInterfaceStyle"))
    ##   echo toNim(style)                                   # "Dark" in dark mode
    var fp = nnkFormalParams.newTree(R)
    fp.add newIdentDefs(ident"self", ident"pointer")
    fp.add newIdentDefs(ident"op", ident"pointer")
    for i, a in args:
      fp.add newIdentDefs(ident("a" & $i), getTypeInst(a))
    let pt = nnkProcTy.newTree(fp, nnkPragma.newTree(ident"cdecl", ident"gcsafe"))
    let fn = newCall(nnkBracketExpr.newTree(bindSym"msgSendFor", R))
    result = newCall(nnkPar.newTree(nnkCast.newTree(pt, fn)),
                     newCall(ident"pointer", obj), newCall(bindSym"sel", newLit(selector)))
    for a in args: result.add a

  proc nsString*(s: string): ObjcId =
    ## An NSString of `s` (autoreleased: inside an `autoreleasePool`, or the
    ## app's).
    objcSend(ObjcId, objcClass("NSString"), "stringWithUTF8String:", cstring(s))

  proc toNim*(s: ObjcId): string =
    ## The text of an NSString ("" for nil).
    if s == nil: return ""
    let c = objcSend(cstring, s, "UTF8String")
    if c == nil: "" else: $c

  template autoreleasePool*(body: untyped) =
    ## Objects made autoreleased in `body` are freed at its end (needed on
    ## threads of your own; the app's main loop has one already).
    let pool = objc_autoreleasePoolPush()
    try:
      body
    finally:
      objc_autoreleasePoolPop(pool)

  proc respondsTo*(obj: ObjcId; selector: string): bool =
    ## `obj` has the method `selector` (check before calling one that is
    ## newer than the oldest system the app runs on).
    obj != nil and objcSend(bool, obj, "respondsToSelector:", sel(selector))

  proc processInfo(): ObjcId = objcSend(ObjcId, objcClass("NSProcessInfo"), "processInfo")

# ---- Windows: Win32 and COM ---------------------------------------------------------------------

when defined(windows):
  type
    WinGuid = object
      d1: uint32
      d2, d3: uint16
      d4: array[8, uint8]
    PowerStatus = object
      acLine, batteryFlag, percent, saver: uint8
      lifeTime, fullLifeTime: uint32
    OsVersionInfo = object
      size, major, minor, build, platform: uint32
      csd: array[128, uint16]

  proc MessageBeep(kind: uint32): int32 {.stdcall, dynlib: "user32", importc.}
  proc GetUserNameW(buf: pointer; n: ptr uint32): int32 {.stdcall, dynlib: "advapi32", importc.}
  proc GetComputerNameW(buf: pointer; n: ptr uint32): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetSystemPowerStatus(s: ptr PowerStatus): int32 {.stdcall, dynlib: "kernel32", importc.}
  proc SetThreadExecutionState(flags: uint32): uint32 {.stdcall, dynlib: "kernel32", importc.}
  proc SHGetKnownFolderPath(id: ptr WinGuid; flags: uint32; token: pointer;
                            path: ptr pointer): int32 {.stdcall, dynlib: "shell32", importc.}
  proc CoTaskMemFree(p: pointer) {.stdcall, dynlib: "ole32", importc.}
  proc CoInitializeEx(r: pointer; model: uint32): int32 {.stdcall, dynlib: "ole32", importc.}
  proc CoCreateInstance(clsid: ptr WinGuid; outer: pointer; ctx: uint32; iid: ptr WinGuid;
                        obj: ptr pointer): int32 {.stdcall, dynlib: "ole32", importc.}
  proc RegGetValueW(key: uint; subKey, value: WideCString; flags: uint32; kind: pointer;
                    data: pointer; size: ptr uint32): int32 {.stdcall, dynlib: "advapi32", importc.}
  proc GetActiveWindow(): pointer {.stdcall, dynlib: "user32", importc.}

  proc wideText(buf: openArray[uint16]): string =
    ## A NUL-terminated UTF-16 buffer as UTF-8.
    var n = 0
    while n < buf.len and buf[n] != 0: inc n
    if n == 0: return ""
    var w = newWideCString(n)
    copyMem(addr w[0], unsafeAddr buf[0], n * 2)
    $w

  proc windowsUserName*(): string =
    ## The user's logon name (GetUserNameW).
    var buf: array[257, uint16]
    var n = uint32(buf.len)
    if GetUserNameW(addr buf[0], addr n) != 0: wideText(buf) else: ""

  proc windowsDocumentsFolder*(): string =
    ## The user's Documents folder, wherever it was moved to
    ## (SHGetKnownFolderPath, FOLDERID_Documents).
    var id = WinGuid(d1: 0xFDD39AD0'u32, d2: 0x238F, d3: 0x46AF,
                     d4: [0xAD'u8, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7])
    var p: pointer
    if SHGetKnownFolderPath(addr id, 0, nil, addr p) == 0 and p != nil:
      result = $cast[WideCString](p)
    if p != nil: CoTaskMemFree(p)

  proc windowsAppsUseDarkMode*(): bool =
    ## The user chose the dark app mode in Settings > Personalization >
    ## Colors (the registry's AppsUseLightTheme is 0).
    var data, size: uint32
    size = 4
    let r = RegGetValueW(0x80000001'u,  # HKEY_CURRENT_USER
                         newWideCString("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
                         newWideCString("AppsUseLightTheme"), 0x10, nil, addr data, addr size)
    r == 0 and data == 0

  var taskbar: pointer
  type TaskbarVtbl = object
    queryInterface, addRef, release, hrInit, addTab, deleteTab, activateTab,
      setActiveAlt, markFullscreenWindow: pointer
    setProgressValue: proc (this, hwnd: pointer; done, total: uint64): int32 {.stdcall.}
    setProgressState: proc (this, hwnd: pointer; flags: int32): int32 {.stdcall.}

  proc taskbarProgress*(value: float; hwnd: pointer = nil): bool {.discardable.} =
    ## Shows `value` (0.0 .. 1.0) as progress on the app's taskbar button
    ## (COM, ITaskbarList3); a negative value takes it away. `hwnd`: the
    ## window (nil: the active one).
    let win = if hwnd != nil: hwnd else: GetActiveWindow()
    if win == nil: return false
    if taskbar == nil:
      discard CoInitializeEx(nil, 2)          # COINIT_APARTMENTTHREADED
      var clsid = WinGuid(d1: 0x56FDF344'u32, d2: 0xFD6D, d3: 0x11D0,
                          d4: [0x95'u8, 0x8A, 0x00, 0x60, 0x97, 0xC9, 0xA0, 0x90])
      var iid = WinGuid(d1: 0xEA1AFB91'u32, d2: 0x9E28, d3: 0x4B86,
                        d4: [0x90'u8, 0xE9, 0x9E, 0x9F, 0x8A, 0x5E, 0xEF, 0xAF])
      if CoCreateInstance(addr clsid, nil, 1, addr iid, addr taskbar) != 0 or taskbar == nil:
        taskbar = nil
        return false
      let vt = cast[ptr ptr TaskbarVtbl](taskbar)[]
      discard cast[proc (this: pointer): int32 {.stdcall.}](vt.hrInit)(taskbar)
    let vt = cast[ptr ptr TaskbarVtbl](taskbar)[]
    if value < 0:
      return vt.setProgressState(taskbar, win, 0) == 0       # TBPF_NOPROGRESS
    discard vt.setProgressState(taskbar, win, 2)              # TBPF_NORMAL
    vt.setProgressValue(taskbar, win, uint64(clamp(value, 0.0, 1.0) * 1000), 1000) == 0

# ---- Termux ---------------------------------------------------------------------------------------

proc inTermux*(): bool = existsEnv("TERMUX_VERSION")
  ## The app runs inside Termux (as a Linux program).

proc termuxApi*(command: string; args: openArray[string] = []; input = "";
                timeoutMs = 5000): string =
  ## Runs the Termux:API command `termux-<command>` (installed with
  ## `pkg install termux-api` and the Termux:API app) and returns what it
  ## printed ("" when it is not there or took longer than `timeoutMs`):
  ## `termuxApi("vibrate", ["-d", "200"])`, `termuxApi("battery-status")`,
  ## `termuxApi("toast", ["Saved"])`, `termuxApi("clipboard-get")`.
  when defined(ios): ""
  elif androidApp:
    if command.len == 0 or not command.allCharsInSet(Letters + Digits + {'-'}): return ""
    let exe = findExe("termux-" & command)
    if exe.len == 0: return ""
    var cmd = shellQuote(exe)
    for a in args: cmd.add " " & shellQuote(a)
    let limit = findExe("timeout")
    if limit.len > 0: cmd = shellQuote(limit) & " " & $max(1, (timeoutMs + 999) div 1000) & " " & cmd
    if input.len > 0: cmd = "printf '%s' " & shellQuote(input) & " | " & cmd
    try: runShell(cmd & " 2>&1").output
    except CatchableError, Defect: ""
  else:
    if command.len == 0 or not command.allCharsInSet(Letters + Digits + {'-'}): return ""
    let exe = findExe("termux-" & command)
    if exe.len == 0: return ""
    try:
      var p = startProcess(exe, args = args, options = {poStdErrToStdOut})
      if input.len > 0:
        p.inputStream.write(input)
      p.inputStream.close()
      let t0 = epochTime()
      while p.peekExitCode() == -1:
        if (epochTime() - t0) * 1000 > float(timeoutMs):
          p.terminate()
          p.close()
          return ""
        sleep(10)
      result = p.outputStream.readAll()
      p.close()
    except CatchableError, Defect:
      result = ""

proc jsonNumber(json, key: string): int =
  ## The whole number after `"key":` in a small JSON text (-1: not there).
  let i = json.find("\"" & key & "\"")
  if i < 0: return -1
  var j = json.find(':', i) + 1
  while j < json.len and json[j] in Whitespace: inc j
  var k = j
  while k < json.len and json[k] in {'0'..'9', '-'}: inc k
  try: parseInt(json[j ..< k]) except ValueError: -1

# ---- the same on every system ----------------------------------------------------------------------

proc readSmall(path: string): string =
  try: readFile(path).strip except IOError, OSError: ""

proc getprop(key: string): string =
  ## An Android system property, from Termux (getprop); "" elsewhere.
  when androidApp and not defined(ios):
    try:
      let (o, code) = runShell("getprop " & shellQuote(key))
      if code == 0: o.strip else: ""
    except CatchableError: ""
  else: ""

var toneGen: JObject     # Android: the tone generator of `beepSystem`, kept

proc vibrate*(ms = 50): bool {.discardable.} =
  ## Buzzes the phone for `ms` milliseconds (Android apps need
  ## `retroapk --permission:VIBRATE`; Termux uses Termux:API; iPhones buzz
  ## their standard short buzz; a web page buzzes the phone it runs on).
  ## False where nothing buzzes.
  when defined(wasm): return systemCall("vibrate", $ms) == "1"
  try:
    when defined(ios):
      let tb = nativeLib("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")
      let play = nativeProc[proc (id: uint32) {.cdecl.}](tb, "AudioServicesPlaySystemSound")
      if play != nil:
        play(4095)                              # kSystemSoundID_Vibrate
        result = true
    else:
      when androidApp:
        if javaAvailable():
          let v = javaActivityObj("getSystemService", "vibrator")
          if v.isNil: return false
          discard javaCall(v, "vibrate", jlong(ms))
          result = javaError().len == 0
          javaRelease(v)
          return
      if inTermux() and findExe("termux-vibrate").len > 0:
        discard termuxApi("vibrate", ["-d", $ms, "-f"])
        result = true
  except CatchableError:
    result = false

proc deviceName*(): string =
  ## What the device or computer is called: the model on phones ("Google
  ## Pixel 9", "Foxoman's iPad"), the computer's name on desktops, the
  ## browser in a web page ("Chrome 131 on Windows").
  when defined(wasm): return systemCall("device", "")
  try:
    when defined(ios):
      let dev = objcSend(ObjcId, objcClass("UIDevice"), "currentDevice")
      toNim(objcSend(ObjcId, dev, "name"))
    elif defined(macosx):
      toNim(objcSend(ObjcId, processInfo(), "hostName"))
    elif defined(windows):
      var buf: array[257, uint16]
      var n = uint32(buf.len)
      if GetComputerNameW(addr buf[0], addr n) != 0: wideText(buf) else: ""
    else:
      when androidApp:
        if javaAvailable(): return deviceModel()
        if inTermux():
          let model = getprop("ro.product.model")
          if model.len > 0:
            let maker = getprop("ro.product.manufacturer")
            return if model.toLowerAscii.startsWith(maker.toLowerAscii): model
                   else: (maker.capitalizeAscii & " " & model).strip
      var buf: array[256, char]
      if gethostname(cast[cstring](addr buf[0]), buf.len) == 0: $cast[cstring](addr buf[0])
      else: ""
  except CatchableError:
    ""

proc osVersion*(): string =
  ## The system and its version: "Android 15", "iOS 18.1", "macOS Version
  ## 14.1 (Build 23B74)", "Windows 10.0.22631", "Ubuntu 24.04.1 LTS"; "Web"
  ## and the system under the browser in a page.
  when defined(wasm):
    let d = systemCall("device", "")
    let i = d.find(" on ")
    return "Web" & (if i >= 0: " (" & d[i + 4 .. ^1] & ")" else: "")
  try:
    when defined(ios):
      let dev = objcSend(ObjcId, objcClass("UIDevice"), "currentDevice")
      "iOS " & toNim(objcSend(ObjcId, dev, "systemVersion"))
    elif defined(macosx):
      "macOS " & toNim(objcSend(ObjcId, processInfo(), "operatingSystemVersionString"))
    elif defined(windows):
      let nt = nativeLib("ntdll.dll")
      let rtl = nativeProc[proc (v: ptr OsVersionInfo): int32 {.stdcall.}](nt, "RtlGetVersion")
      if rtl == nil: return "Windows"
      var v = OsVersionInfo(size: uint32(sizeof(OsVersionInfo)))
      if rtl(addr v) != 0: return "Windows"
      "Windows " & $v.major & "." & $v.minor & "." & $v.build
    else:
      when androidApp:
        if javaAvailable(): return "Android " & androidVersion().release
        let rel = getprop("ro.build.version.release")
        if rel.len > 0: return "Android " & rel
      for line in readSmall("/etc/os-release").splitLines:
        if line.startsWith("PRETTY_NAME="): return line[12 .. ^1].strip(chars = {'"'})
      var u: Utsname
      if uname(u) == 0: $cast[cstring](addr u.sysname[0]) & " " & $cast[cstring](addr u.release[0])
      else: hostOS
  except CatchableError:
    hostOS

proc batteryLevel*(): int =
  ## The battery's charge in percent, -1 when unknown (no battery, a desktop
  ## without the information, macOS; a browser that does not tell).
  when defined(wasm):
    return (try: parseInt(systemCall("battery", "").split(' ')[0]) except ValueError: -1)
  try:
    when defined(ios):
      let dev = objcSend(ObjcId, objcClass("UIDevice"), "currentDevice")
      objcSend(void, dev, "setBatteryMonitoringEnabled:", true)
      let f = objcSend(float32, dev, "batteryLevel")
      if f < 0: -1 else: int(f * 100 + 0.5)
    elif defined(macosx):
      -1
    elif defined(windows):
      var s: PowerStatus
      if GetSystemPowerStatus(addr s) == 0 or s.percent == 255 or s.batteryFlag == 128: -1
      else: int(s.percent)
    else:
      when androidApp:
        if javaAvailable():
          let bm = javaActivityObj("getSystemService", "batterymanager")
          if bm.isNil: return -1
          let v = javaCall(bm, "getIntProperty", 4)      # BATTERY_PROPERTY_CAPACITY
          javaRelease(bm)
          return (try: parseInt(v) except ValueError: -1)
      if inTermux():
        let j = termuxApi("battery-status")
        if j.len > 0: return jsonNumber(j, "percentage")
      for kind, dir in walkDir("/sys/class/power_supply"):
        if readSmall(dir / "type") == "Battery":
          let c = readSmall(dir / "capacity")
          if c.len > 0: return (try: clamp(parseInt(c), 0, 100) except ValueError: -1)
      -1
  except CatchableError:
    -1

var darkCache: tuple[at: float; v: bool] = (-100.0, false)

proc systemDarkMode*(): bool =
  ## The user chose a dark look for the system (Android's dark theme, iOS
  ## and macOS Dark appearance, Windows' dark app mode, a dark GTK theme or
  ## GNOME's color scheme on Linux). Asked at most every 5 seconds.
  when defined(wasm): return systemCall("dark", "") == "1"
  let now = epochTime()
  if now - darkCache.at < 5: return darkCache.v
  var dark = false
  try:
    when defined(ios):
      let screen = objcSend(ObjcId, objcClass("UIScreen"), "mainScreen")
      let traits = objcSend(ObjcId, screen, "traitCollection")
      dark = traits != nil and objcSend(int, traits, "userInterfaceStyle") == 2
    elif defined(macosx):
      let d = objcSend(ObjcId, objcClass("NSUserDefaults"), "standardUserDefaults")
      dark = toNim(objcSend(ObjcId, d, "stringForKey:", nsString("AppleInterfaceStyle"))) == "Dark"
    elif defined(windows):
      dark = windowsAppsUseDarkMode()
    else:
      when androidApp:
        if javaAvailable():
          let res = javaActivityObj("getResources")
          let conf = javaCallObj(res, "getConfiguration")
          let mode = try: parseInt(javaCall(conf, "uiMode")) except ValueError: 0
          javaRelease(conf, res)
          dark = (mode and 0x30) == 0x20
      if not dark:
        let gtk = getEnv("GTK_THEME").toLowerAscii
        if "dark" in gtk: dark = true
        else:
          let ini = readSmall(getConfigDir() / "gtk-3.0" / "settings.ini").toLowerAscii
          if "gtk-application-prefer-dark-theme=1" in ini or "gtk-application-prefer-dark-theme=true" in ini:
            dark = true
          else:
            when not androidApp:
              let gs = findExe("gsettings")
              if gs.len > 0:
                let (o, code) = execCmdEx(gs & " get org.gnome.desktop.interface color-scheme")
                dark = code == 0 and "dark" in o
  except CatchableError, Defect:
    dark = false
  darkCache = (now, dark)
  dark

proc beepSystem*() =
  ## The system's alert sound (Windows' default beep, NSBeep on macOS, a
  ## tick on iOS, a short tone on Android, the X11 bell on Linux).
  when defined(wasm):
    discard systemCall("beep", "")
    return
  try:
    when defined(ios):
      let tb = nativeLib("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox")
      let play = nativeProc[proc (id: uint32) {.cdecl.}](tb, "AudioServicesPlaySystemSound")
      if play != nil: play(1104)
    elif defined(macosx):
      let kit = nativeLib("/System/Library/Frameworks/AppKit.framework/AppKit")
      let beep = nativeProc[proc () {.cdecl.}](kit, "NSBeep")
      if beep != nil: beep()
    elif defined(windows):
      discard MessageBeep(0)
    else:
      when androidApp:
        if javaAvailable():
          if toneGen.isNil:                          # the notification stream, 80%
            toneGen = javaNew("android.media.ToneGenerator", 5, 80)
          if not toneGen.isNil: discard javaCall(toneGen, "startTone", 24, 150)  # TONE_PROP_BEEP
          return
      let x = nativeLib("libX11.so.6", "libX11.so")
      if x == nil: return
      let open = nativeProc[proc (name: cstring): pointer {.cdecl.}](x, "XOpenDisplay")
      let bell = nativeProc[proc (d: pointer; percent: cint): cint {.cdecl.}](x, "XBell")
      let flush = nativeProc[proc (d: pointer): cint {.cdecl.}](x, "XFlush")
      let close = nativeProc[proc (d: pointer): cint {.cdecl.}](x, "XCloseDisplay")
      if open == nil or bell == nil or flush == nil or close == nil: return
      let d = open(nil)
      if d == nil: return
      discard bell(d, 0)
      discard flush(d)
      discard close(d)
  except CatchableError:
    discard

proc userName*(): string =
  ## The user's name on this system ("" when there is none, as on Android).
  try:
    when defined(macosx) or defined(ios):
      let fw = nativeLib("/System/Library/Frameworks/Foundation.framework/Foundation")
      let f = nativeProc[proc (): ObjcId {.cdecl.}](fw, "NSUserName")
      if f == nil: "" else: toNim(f())
    elif defined(windows):
      windowsUserName()
    elif androidApp:
      ""
    else:
      let pw = getpwuid(getuid())
      if pw != nil and pw.pw_name != nil: $pw.pw_name
      else: getEnv("USER", getEnv("LOGNAME"))
  except CatchableError:
    ""

proc keepScreenOn*(on: bool): bool {.discardable.} =
  ## Keeps the screen from dimming and the device from sleeping while `on`
  ## (a presentation, a long job). Android, iOS, Windows and web pages (the
  ## Wake Lock); false elsewhere.
  when defined(wasm): return systemCall("wakelock", if on: "1" else: "0") == "1"
  try:
    when defined(ios):
      let app = objcSend(ObjcId, objcClass("UIApplication"), "sharedApplication")
      objcSend(void, app, "setIdleTimerDisabled:", on)
      result = true
    elif defined(windows):
      const continuous = 0x80000000'u32
      result = SetThreadExecutionState(if on: continuous or 0x2 or 0x1 else: continuous) != 0
    elif androidApp:
      if javaAvailable():
        onUiThread:
          let w = javaActivityObj("getWindow")
          discard javaCall(w, if on: "addFlags" else: "clearFlags", 128)  # FLAG_KEEP_SCREEN_ON
          javaRelease(w)
        result = javaError().len == 0
  except CatchableError:
    result = false

proc openSettings*(kind = ""): bool {.discardable.} =
  ## Opens the system's settings: `kind` "" (the main page), "wifi",
  ## "bluetooth", "display", "sound", "battery", "location", "app" (this
  ## app's page; Android) -- where the system has such a page. False when it
  ## could not.
  try:
    when androidApp:
      if not javaAvailable(): return false
      let action = case kind
        of "wifi": "android.settings.WIFI_SETTINGS"
        of "bluetooth": "android.settings.BLUETOOTH_SETTINGS"
        of "display": "android.settings.DISPLAY_SETTINGS"
        of "sound": "android.settings.SOUND_SETTINGS"
        of "battery": "android.intent.action.POWER_USAGE_SUMMARY"
        of "location": "android.settings.LOCATION_SOURCE_SETTINGS"
        of "app": "android.settings.APPLICATION_DETAILS_SETTINGS"
        else: "android.settings.SETTINGS"
      let intent = javaNew("android.content.Intent", action)
      if intent.isNil: return false
      result = true
      if kind == "app":
        let uri = javaStaticObj("android.net.Uri", "parse", "package:" & javaActivity("getPackageName"))
        discard javaCall(intent, "setData", uri)
        javaRelease(uri)
      discard javaActivity("startActivity", intent)
      result = javaError().len == 0
      javaRelease(intent)
    elif defined(ios):
      result = systemRelays.openUrl("app-settings:")
    elif defined(macosx):
      let pane = case kind
        of "wifi": "com.apple.preference.network"
        of "bluetooth": "com.apple.preferences.Bluetooth"
        of "display": "com.apple.preference.displays"
        of "sound": "com.apple.preference.sound"
        of "battery": "com.apple.preference.battery"
        of "location": "com.apple.preference.security?Privacy_LocationServices"
        else: ""
      result = systemRelays.openUrl("x-apple.systempreferences:" & pane)
    elif defined(windows):
      let page = case kind
        of "wifi": "network-wifi"
        of "bluetooth": "bluetooth"
        of "display": "display"
        of "sound": "sound"
        of "battery": "batterysaver"
        of "location": "privacy-location"
        else: ""
      result = systemRelays.openUrl("ms-settings:" & page)
  except CatchableError:
    result = false

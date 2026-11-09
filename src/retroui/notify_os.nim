# (the notifications of the systems: `notify.nim` includes this; see its
# documentation)

import std/[os, strutils, tables, locks, typedthreads, times, unicode]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import native, bgcheck
when defined(windows):
  import std/exitprocs

const
  MaxTitle = 120     ## letters of a title kept
  MaxBody = 600      ## ... of a body

type
  JobKind = enum jkShow, jkClose, jkProbe
  Job = object
    kind: JobKind
    title, body, app, icon, tag: string

var
  lock: Lock
  cond: Cond
  jobs: seq[Job]            # guarded by lock
  pending: int              # guarded by lock: asked and not done yet
  state: int                # guarded by lock: 0 not known, 1 it works, 2 it failed
  failedAt: float           # guarded by lock: when it failed
  started = false
  workerMade = false        # (the UI thread's) the thread that shows them is made
  worker: Thread[void]
  probedAt = -100.0         # (the UI thread's) when the system was last asked
  badgeNow = 0

proc initQueue() =
  if started: return
  started = true
  initLock(lock)
  initCond(cond)

proc stateNow(): int =
  ## What the system's notifications did last; a failure is forgotten after
  ## a minute (the service may have started since).
  if not started: return 0
  withLock lock:
    if state == 2 and epochTime() - failedAt > 60: state = 0
    result = state

proc finished(j: Job; ok: bool) =
  ## (the thread that showed it) `j` is done.
  withLock lock:
    dec pending
    if j.kind != jkClose:
      if ok: state = 1
      else:
        state = 2
        failedAt = epochTime()

proc cleanText(s: string; maxRunes: int): string =
  ## `s` as a notification may take it: valid UTF-8, no control characters
  ## but line breaks and tabs, at most `maxRunes` letters.
  var t = if s.len > maxRunes * 4: s[0 ..< maxRunes * 4] else: s
  var bad = validateUtf8(t)
  while bad >= 0:                      # (a mail's broken bytes)
    t = t[0 ..< bad] & "\uFFFD" & t[bad + 1 .. ^1]
    bad = validateUtf8(t)
  var n = 0
  for r in t.runes:
    if n >= maxRunes:
      result.add "\u2026"
      break
    let c = int(r)
    if c == 13: discard
    elif c == 9 or c == 10: result.add r
    elif c < 32 or c == 127: result.add ' '
    else: result.add r
    inc n
  result = result.strip(chars = {' ', '\t', '\n'})

# ---- Linux, BSD, Termux, macOS: commands run by a thread of their own --------------------------------------

when not defined(windows) and not defined(ios):
  proc c_popen(cmd, mode: cstring): File {.importc: "popen", header: "<stdio.h>".}
  proc c_pclose(f: File): cint {.importc: "pclose", header: "<stdio.h>".}

  const
    Dest = "org.freedesktop.Notifications"
    ObjPath = "/org/freedesktop/Notifications"

  proc sq(s: string): string =
    ## `s` quoted for the shell (as one word, whatever is in it).
    "'" & s.replace("\0", "").replace("'", "'\\''") & "'"

  proc gv(s: string): string =
    ## `s` as a GVariant string (`gdbus call` reads its arguments so).
    result = "\""
    for c in s:
      case c
      of '\\': result.add "\\\\"
      of '"': result.add "\\\""
      of '\n': result.add "\\n"
      of '\t': result.add "\\t"
      of '\r': result.add "\\r"
      of '\0': discard
      of '\1' .. '\8', '\11', '\12', '\14' .. '\31', '\127':
        result.add "\\u00" & toHex(ord(c), 2)
      else: result.add c
    result.add "\""

  proc markup(s: string): string =
    ## The body's text as the services read it (they take a little markup).
    s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"))

  proc runCmd(cmd: string): tuple[output: string; code: int] =
    ## Runs `cmd` with the shell and waits for it (on the worker thread);
    ## what it printed and its exit code. popen: Android before 9 has no
    ## posix_spawn, which std/osproc uses.
    let f = c_popen(cstring(cmd & " </dev/null 2>&1"), "r")
    if f == nil: return ("", -1)
    var buf = newString(4096)
    while true:
      let n = readBuffer(f, addr buf[0], buf.len)
      if n <= 0: break
      if result.output.len < 65536: result.output.add buf[0 ..< n]
    let st = c_pclose(f)
    result.code = if st == -1: -1 else: (st shr 8) and 0xff

  proc idOf(output: string): uint32 =
    ## The notification's number in `gdbus`' answer, "(uint32 12,)", or in
    ## `notify-send --print-id`'s.
    var k = output.find("uint32 ")
    k = if k >= 0: k + 7 else: 0
    while k < output.len and output[k] notin Digits: inc k
    var v = 0'u64
    while k < output.len and output[k] in Digits and v < 0xFFFF_FFFF'u64:
      v = v * 10 + uint64(ord(output[k]) - ord('0'))
      inc k
    uint32(min(v, 0xFFFF_FFFF'u64))

  proc noDash(s: string): string =
    ## (a word that would read as an option: a zero-width space before it)
    if s.startsWith("-"): "\u200B" & s else: s

  type Worker = object
    ids: Table[string, uint32]     ## tag -> the service's number for it
    termuxNext: int
    sendIds: Table[string, bool]   ## a notify-send knows --print-id and --replace-id

  proc gdbusCall(gd, meth, args: string): tuple[output: string; code: int] =
    runCmd(sq(gd) & " call --session --timeout 5 --dest " & Dest & " --object-path " & ObjPath &
           " --method " & Dest & "." & meth & args)

  proc perform(w: var Worker; j: Job): bool =
    case j.kind
    of jkProbe:
      when defined(macosx): return true
      else:
        if inTermux() and findExe("termux-notification").len > 0: return true
        let gd = findExe("gdbus")
        if gd.len == 0: return findExe("notify-send").len > 0
        return gdbusCall(gd, "GetServerInformation", "").code == 0
    of jkShow:
      when defined(macosx):
        proc aq(s: string): string =
          "\"" & s.multiReplace(("\\", "\\\\"), ("\"", "\\\""), ("\n", "\\n"), ("\t", " ")) & "\""
        var script = "display notification " & aq(j.body)
        if j.title.len > 0: script.add " with title " & aq(j.title)
        return runCmd("/usr/bin/osascript -e " & sq(script)).code == 0
      else:
        if inTermux():
          let tn = findExe("termux-notification")
          if tn.len > 0:
            let id = if j.tag.len > 0: "retro-" & j.tag
                     else:
                       inc w.termuxNext
                       "retro-" & $getCurrentProcessId() & "-" & $w.termuxNext
            var cmd = sq(tn) & " --id " & sq(id) & " --title " & sq(j.title) &
                      " --content " & sq(j.body)
            return runCmd(cmd).code == 0
        let gd = findExe("gdbus")
        if gd.len > 0:
          let replaces = if j.tag.len > 0: w.ids.getOrDefault(j.tag, 0'u32) else: 0'u32
          let args = " " & sq(gv(j.app)) & " " & sq("uint32 " & $replaces) & " " & sq(gv(j.icon)) &
                     " " & sq(gv(j.title)) & " " & sq(gv(markup(j.body))) & " '@as []' '@a{sv} {}'" &
                     " 'int32 -1'"
          let (o, code) = gdbusCall(gd, "Notify", args)
          if code == 0:
            let id = idOf(o)
            if j.tag.len > 0 and id > 0: w.ids[j.tag] = id
            return true
        let ns = findExe("notify-send")
        if ns.len > 0:
          if ns notin w.sendIds:
            w.sendIds[ns] = "replace-id" in runCmd(sq(ns) & " --help").output
          let withIds = w.sendIds[ns]
          var cmd = sq(ns)
          if j.app.len > 0: cmd.add " -a " & sq(j.app)
          if j.icon.len > 0: cmd.add " -i " & sq(j.icon)
          if withIds and j.tag.len > 0:
            cmd.add " -p"
            let old = w.ids.getOrDefault(j.tag, 0'u32)
            if old > 0: cmd.add " -r " & $old
          cmd.add " " & sq(noDash(if j.title.len > 0: j.title else: j.app)) & " " &
                  sq(noDash(markup(j.body)))
          let (o, code) = runCmd(cmd)
          if code == 0 and withIds and j.tag.len > 0:
            let id = idOf(o)
            if id > 0: w.ids[j.tag] = id
          return code == 0
        return false
    of jkClose:
      when defined(macosx): return true
      else:
        if inTermux():
          let tr = findExe("termux-notification-remove")
          if tr.len > 0 and j.tag.len > 0:
            return runCmd(sq(tr) & " " & sq("retro-" & j.tag)).code == 0
        let gd = findExe("gdbus")
        var which: seq[string]
        if j.tag.len > 0:
          if j.tag in w.ids: which.add j.tag
        else:
          for t in w.ids.keys: which.add t
        for t in which:
          if gd.len > 0:
            discard gdbusCall(gd, "CloseNotification", " " & sq("uint32 " & $w.ids[t]))
          w.ids.del t
        return true

  proc work() {.thread.} =
    var w: Worker
    while true:
      var j: Job
      {.cast(gcsafe).}:
        acquire(lock)
        while jobs.len == 0: wait(cond, lock)
        j = move jobs[0]
        jobs.delete(0)
        release(lock)
      var ok = false
      {.cast(gcsafe).}:
        try: ok = w.perform(j)
        except CatchableError, Defect: ok = false
        finished(j, ok)

  proc submit(j: sink Job) =
    initQueue()
    if not workerMade:
      workerMade = true
      createThread(worker, work)
    withLock lock:
      inc pending
      jobs.add j
    signal(cond)

  var
    routeAt = -100.0
    routeOk = false

  proc posixRoute(): bool =
    ## A way to the system's notifications is installed (asked every 30 s).
    let now = epochTime()
    if now - routeAt < 30: return routeOk
    routeAt = now
    routeOk =
      when defined(macosx): fileExists("/usr/bin/osascript")
      else:
        (inTermux() and findExe("termux-notification").len > 0) or
          (findExe("gdbus").len > 0 or findExe("notify-send").len > 0) and
          (getEnv("DBUS_SESSION_BUS_ADDRESS").len > 0 or
           (getEnv("XDG_RUNTIME_DIR").len > 0 and fileExists(getEnv("XDG_RUNTIME_DIR") / "bus")))
    routeOk

# ---- Windows: a balloon of the app's icon in the notification area ------------------------------------------

when defined(windows):
  type
    WinGuid = object
      d1: uint32
      d2, d3: uint16
      d4: array[8, uint8]
    NotifyIconData = object
      cbSize: uint32
      hWnd: pointer
      uID, uFlags, uCallbackMessage: uint32
      hIcon: pointer
      szTip: array[128, uint16]
      dwState, dwStateMask: uint32
      szInfo: array[256, uint16]
      uVersion: uint32
      szInfoTitle: array[64, uint16]
      dwInfoFlags: uint32
      guidItem: WinGuid
      hBalloonIcon: pointer
    WndProc = proc (h: pointer; msg: uint32; wp: uint; lp: int): int {.stdcall.}
    WndClassEx = object
      cbSize, style: uint32
      lpfnWndProc: WndProc
      cbClsExtra, cbWndExtra: int32
      hInstance, hIcon, hCursor, hbrBackground: pointer
      lpszMenuName, lpszClassName: pointer
      hIconSm: pointer
    WinMsg = object
      hwnd: pointer
      message: uint32
      wParam: uint
      lParam: int
      time: uint32
      x, y: int32
      priv: uint32

  when sizeof(pointer) == 8:
    static: doAssert sizeof(NotifyIconData) == 976

  proc Shell_NotifyIconW(msg: uint32; data: ptr NotifyIconData): int32 {.stdcall, dynlib: "shell32", importc.}
  proc RegisterClassExW(wc: ptr WndClassEx): uint16 {.stdcall, dynlib: "user32", importc.}
  proc CreateWindowExW(ex: uint32; cls, name: pointer; style: uint32; x, y, w, h: int32;
                       parent, menu, inst, param: pointer): pointer {.stdcall, dynlib: "user32", importc.}
  proc DefWindowProcW(h: pointer; msg: uint32; wp: uint; lp: int): int {.stdcall, dynlib: "user32", importc.}
  proc GetMessageW(m: ptr WinMsg; h: pointer; lo, hi: uint32): int32 {.stdcall, dynlib: "user32", importc.}
  proc TranslateMessage(m: ptr WinMsg): int32 {.stdcall, dynlib: "user32", importc.}
  proc DispatchMessageW(m: ptr WinMsg): int {.stdcall, dynlib: "user32", importc.}
  proc PostMessageW(h: pointer; msg: uint32; wp: uint; lp: int): int32 {.stdcall, dynlib: "user32", importc.}
  proc LoadIconW(inst: pointer; name: pointer): pointer {.stdcall, dynlib: "user32", importc.}
  proc LoadImageW(inst: pointer; name: pointer; kind: uint32; cx, cy: int32;
                  flags: uint32): pointer {.stdcall, dynlib: "user32", importc.}
  proc EnumWindows(cb: proc (h: pointer; lp: int): int32 {.stdcall.}; lp: int): int32 {.stdcall, dynlib: "user32", importc.}
  proc GetWindowThreadProcessId(h: pointer; pid: ptr uint32): uint32 {.stdcall, dynlib: "user32", importc.}
  proc IsWindowVisible(h: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc GetWindow(h: pointer; cmd: uint32): pointer {.stdcall, dynlib: "user32", importc.}
  proc IsIconic(h: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc ShowWindow(h: pointer; cmd: int32): int32 {.stdcall, dynlib: "user32", importc.}
  proc SetForegroundWindow(h: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc GetModuleHandleW(name: pointer): pointer {.stdcall, dynlib: "kernel32", importc.}
  proc GetCurrentProcessId(): uint32 {.stdcall, dynlib: "kernel32", importc.}
  proc GetTickCount(): uint32 {.stdcall, dynlib: "kernel32", importc.}

  const
    WmApp = 0x8000'u32
    WmJobs = WmApp + 1          # jobs are waiting
    WmTray = WmApp + 2          # the icon's and the balloon's events
    NimAdd = 0'u32
    NimModify = 1'u32
    NimDelete = 2'u32
    NimSetVersion = 4'u32
    NifMessage = 1'u32
    NifIcon = 2'u32
    NifTip = 4'u32
    NifInfo = 0x10'u32
    NiifUser = 4'u32
    NiifRespectQuietTime = 0x80'u32

  var
    trayWnd: pointer           # guarded by lock: the thread's window (nil: none yet)
    trayIcon: pointer          # the icon shown (the tray thread's)
    iconShown = false          # guarded by lock: the icon is in the notification area
    lastShow: uint32           # (tray thread) when the last balloon went up
    trayDone = false           # guarded by lock: the thread is there, or failed to be

  proc putWide[N: static int](dst: var array[N, uint16]; s: string) =
    ## `s` into a fixed UTF-16 field, cut to fit (never in a letter's middle).
    let w = newWideCString(s)
    var n = 0
    while n < N - 1 and cast[uint16](w[n]) != 0: inc n
    if n > 0 and cast[uint16](w[n - 1]) in 0xD800'u16 .. 0xDBFF'u16: dec n
    for i in 0 ..< n: dst[i] = cast[uint16](w[i])
    dst[n] = 0

  proc iconFor(path: string): pointer =
    ## The balloon's icon: an .ico file, else the program's own, else
    ## Windows' standard one.
    if path.len > 0 and path.toLowerAscii.endsWith(".ico") and fileExists(path):
      let w = newWideCString(path)
      result = LoadImageW(nil, addr w[0], 1, 0, 0, 0x10 or 0x40)    # LR_LOADFROMFILE, LR_DEFAULTSIZE
    if result == nil: result = LoadIconW(GetModuleHandleW(nil), cast[pointer](1))
    if result == nil: result = LoadIconW(nil, cast[pointer](32512))   # IDI_APPLICATION

  proc baseData(): NotifyIconData =
    {.cast(gcsafe).}:
      result = NotifyIconData(cbSize: uint32(sizeof(NotifyIconData)), hWnd: trayWnd, uID: 1,
                              uCallbackMessage: WmTray)

  proc removeIcon() =
    var d = baseData()
    var was = false
    {.cast(gcsafe).}:
      withLock lock:
        was = iconShown
        iconShown = false
    if was: discard Shell_NotifyIconW(NimDelete, addr d)

  proc showBalloon(j: Job): bool =
    var d = baseData()
    var shown = false
    {.cast(gcsafe).}:
      withLock lock: shown = iconShown
    if not shown:
      trayIcon = iconFor(j.icon)
      d.uFlags = NifMessage or NifIcon or NifTip
      d.hIcon = trayIcon
      d.szTip.putWide(if j.app.len > 0: j.app else: j.title)
      if Shell_NotifyIconW(NimAdd, addr d) == 0: return false
      d.uVersion = 4                                  # NOTIFYICON_VERSION_4
      discard Shell_NotifyIconW(NimSetVersion, addr d)
      {.cast(gcsafe).}:
        withLock lock: iconShown = true
    d = baseData()
    d.uFlags = NifInfo
    d.szInfoTitle.putWide(j.title)
    d.szInfo.putWide(if j.body.len > 0: j.body else: " ")   # (empty: no balloon)
    d.dwInfoFlags = NiifUser or NiifRespectQuietTime
    d.hBalloonIcon = trayIcon
    lastShow = GetTickCount()
    Shell_NotifyIconW(NimModify, addr d) != 0

  proc enumOurs(h: pointer; lp: int): int32 {.stdcall.} =
    var pid: uint32
    discard GetWindowThreadProcessId(h, addr pid)
    if pid == GetCurrentProcessId() and IsWindowVisible(h) != 0 and GetWindow(h, 4) == nil:
      cast[ptr pointer](lp)[] = h
      return 0
    1

  proc bringAppForward() =
    ## A click on the balloon: the app's window comes to the front.
    var found: pointer = nil
    discard EnumWindows(enumOurs, cast[int](addr found))
    if found != nil:
      if IsIconic(found) != 0: discard ShowWindow(found, 9)   # SW_RESTORE
      discard SetForegroundWindow(found)

  proc runJobs() =
    while true:
      var j: Job
      var any = false
      {.cast(gcsafe).}:
        withLock lock:
          if jobs.len > 0:
            j = move jobs[0]
            jobs.delete(0)
            any = true
      if not any: break
      var ok = true
      try:
        case j.kind
        of jkShow: ok = showBalloon(j)
        of jkClose: removeIcon()
        of jkProbe: ok = true
      except CatchableError, Defect: ok = false
      {.cast(gcsafe).}: finished(j, ok)

  proc trayProc(h: pointer; msg: uint32; wp: uint; lp: int): int {.stdcall.} =
    case msg
    of WmJobs:
      runJobs()
      return 0
    of WmTray:
      let ev = lp and 0xFFFF
      case ev
      of 0x405, 0x400, 0x202:          # balloon clicked, NIN_SELECT, the icon clicked
        bringAppForward()
        removeIcon()
      of 0x404:                        # the balloon timed out or was closed
        if GetTickCount() - lastShow > 1500'u32: removeIcon()
      else: discard
      return 0
    else: return DefWindowProcW(h, msg, wp, lp)

  proc trayLoop() {.thread.} =
    let inst = GetModuleHandleW(nil)
    let cls = newWideCString("RetroNotifyArea")
    var wc = WndClassEx(cbSize: uint32(sizeof(WndClassEx)), lpfnWndProc: trayProc,
                        hInstance: inst, lpszClassName: addr cls[0])
    discard RegisterClassExW(addr wc)
    let h = CreateWindowExW(0, addr cls[0], addr cls[0], 0, 0, 0, 0, 0,
                            cast[pointer](-3), nil, inst, nil)   # HWND_MESSAGE
    {.cast(gcsafe).}:
      withLock lock:
        trayWnd = h
        trayDone = true
    if h == nil:
      # no window: what was asked fails (and the next ones answer false)
      while true:
        var j: Job
        var any = false
        {.cast(gcsafe).}:
          withLock lock:
            if jobs.len > 0:
              j = move jobs[0]
              jobs.delete(0)
              any = true
        if not any: break
        {.cast(gcsafe).}: finished(j, false)
      return
    runJobs()
    var m: WinMsg
    while GetMessageW(addr m, nil, 0, 0) > 0:
      discard TranslateMessage(addr m)
      discard DispatchMessageW(addr m)

  proc trayCleanup() {.noconv.} =
    ## (when the app ends) the icon leaves the notification area.
    if not started: return
    {.cast(gcsafe).}: removeIcon()

  proc submit(j: sink Job) =
    initQueue()
    var h: pointer
    withLock lock:
      inc pending
      jobs.add j
      h = trayWnd
    if not workerMade:
      # (the thread's window takes what waits once it is made)
      workerMade = true
      addExitProc(trayCleanup)
      createThread(worker, trayLoop)
    elif h != nil:
      discard PostMessageW(h, WmJobs, 0, 0)

  proc windowsRoute(): bool =
    if not started: return true
    withLock lock:
      result = not trayDone or trayWnd != nil

# ---- Android: NotificationManager through the Java bridge --------------------------------------------------

# (compiled everywhere: the bridge's calls are plain Nim; tests answer for Java)

const
  PostPermission = "android.permission.POST_NOTIFICATIONS"
  ChannelId = "mail"

var
  aSdk = -1                  ## Android's API level
  aChannel = false           ## the channel is made
  aAsked = false             ## the permission was asked for
  aNext = 1000               ## the numbers of notifications without a tag

proc androidSdk(): int =
  if aSdk < 0: aSdk = androidVersion().sdk
  aSdk

proc askPostPermission() =
  ## Android 13+: the dialog that lets the app post notifications (once).
  let cls = javaStaticObj("java.lang.Class", "forName", "java.lang.String")
  let arr = javaStaticObj("java.lang.reflect.Array", "newInstance", cls, 1)
  if not arr.isNil:
    discard javaStatic("java.lang.reflect.Array", "set", arr, 0, PostPermission)
    onUiThread:
      discard javaActivity("requestPermissions", arr, 7301)
  javaRelease(arr, cls)

proc androidAllowed(nm: JObject): bool =
  ## The app may post notifications (asking for that the first time, from
  ## the window: a background check has no Activity to ask with).
  if androidSdk() >= 33 and javaActivity("checkSelfPermission", PostPermission) != "0":
    if not aAsked and not inBackgroundCheck():
      aAsked = true
      askPostPermission()
    return false
  javaCall(nm, "areNotificationsEnabled") != "false"

proc androidNotify(title, body, icon, tag: string; badge: int): bool =
  let nm = javaActivityObj("getSystemService", "notification")
  if nm.isNil: return false
  if not androidAllowed(nm):
    javaRelease(nm)
    return false
  let modern = androidSdk() >= 26
  if modern and not aChannel:
    let ch = javaNew("android.app.NotificationChannel", ChannelId, "Mail", 3)  # IMPORTANCE_DEFAULT
    if not ch.isNil:
      discard javaCall(ch, "setShowBadge", true)
      discard javaCall(nm, "createNotificationChannel", ch)
      aChannel = javaError().len == 0
      javaRelease(ch)
  let b = if modern: javaNew("android.app.Notification$Builder", jactivity(), ChannelId)
          else: javaNew("android.app.Notification$Builder", jactivity())
  if b.isNil:
    javaRelease(nm)
    return false
  # the small icon: the app's (its launcher icon's resource)
  let info = javaActivityObj("getApplicationInfo")
  var res = try: parseInt(javaCall(info, "icon")) except ValueError: 0
  if res == 0:
    res = try: parseInt(javaStatic("android.R$drawable", "ic_dialog_email")) except ValueError: 0
  discard javaCall(b, "setSmallIcon", res)
  if title.len > 0: discard javaCall(b, "setContentTitle", title)
  if body.len > 0:
    discard javaCall(b, "setContentText", body)
    let style = javaNew("android.app.Notification$BigTextStyle")   # (a long body: all of it, opened)
    if not style.isNil:
      discard javaCall(style, "bigText", body)
      discard javaCall(b, "setStyle", style)
    javaRelease(style)
  discard javaCall(b, "setAutoCancel", true)
  if badge > 0: discard javaCall(b, "setNumber", badge)
  var large = JObject(0)
  if icon.len > 0 and fileExists(icon):
    large = javaStaticObj("android.graphics.drawable.Icon", "createWithFilePath", icon)
    if not large.isNil: discard javaCall(b, "setLargeIcon", large)
  # a tap: the app (as its launcher icon opens it)
  let pm = javaActivityObj("getPackageManager")
  let launch = javaCallObj(pm, "getLaunchIntentForPackage", javaActivity("getPackageName"))
  var pi = JObject(0)
  if not launch.isNil:
    discard javaCall(launch, "addFlags", 0x20000000)                  # FLAG_ACTIVITY_SINGLE_TOP
    pi = javaStaticObj("android.app.PendingIntent", "getActivity", jactivity(), 0, launch,
                       0x04000000 or 0x08000000)                      # IMMUTABLE, UPDATE_CURRENT
    if not pi.isNil: discard javaCall(b, "setContentIntent", pi)
  let n = javaCallObj(b, "build")
  if n.isNil: result = false
  else:
    if tag.len > 0:
      discard javaCall(nm, "notify", tag, 1, n)
    else:
      inc aNext
      discard javaCall(nm, "notify", jnull, aNext, n)
    result = javaError().len == 0
  javaRelease(n, pi, launch, pm, large, info, b, nm)

proc androidClear(tag: string) =
  let nm = javaActivityObj("getSystemService", "notification")
  if nm.isNil: return
  if tag.len > 0: discard javaCall(nm, "cancel", tag, 1)
  else: discard javaCall(nm, "cancelAll")
  javaRelease(nm)

proc androidBadge(count: int) =
  ## The count on the notifications shown (launchers show it on the icon);
  ## 0: they go (nothing is unread).
  let nm = javaActivityObj("getSystemService", "notification")
  if nm.isNil: return
  if count <= 0:
    discard javaCall(nm, "cancelAll")
    javaRelease(nm)
    return
  let arr = javaCallObj(nm, "getActiveNotifications")
  let n = try: parseInt(javaStatic("java.lang.reflect.Array", "getLength", arr)) except ValueError: 0
  for i in 0 ..< min(n, 24):
    let sbn = javaStaticObj("java.lang.reflect.Array", "get", arr, i)
    let old = javaCallObj(sbn, "getNotification")
    let tag = javaCall(sbn, "getTag")
    let id = try: parseInt(javaCall(sbn, "getId")) except ValueError: 0
    let b = javaStaticObj("android.app.Notification$Builder", "recoverBuilder", jactivity(), old)
    if not b.isNil:
      discard javaCall(b, "setNumber", count)
      discard javaCall(b, "setOnlyAlertOnce", true)              # (no second sound)
      let nn = javaCallObj(b, "build")
      if not nn.isNil:
        discard javaCall(nm, "notify", (if tag.len > 0: toJArg(tag) else: jnull), id, nn)
      javaRelease(nn)
    javaRelease(b, old, sbn)
  javaRelease(arr, nm)

# ---- macOS: the Dock -----------------------------------------------------------------------------

when defined(macosx):
  proc dockBadge(count: int) =
    autoreleasePool:
      let app = objcSend(ObjcId, objcClass("NSApplication"), "sharedApplication")
      if app == nil: return
      let tile = objcSend(ObjcId, app, "dockTile")
      if tile == nil: return
      let label = if count > 0: nsString($count) else: ObjcId(nil)
      objcSend(void, tile, "setBadgeLabel:", label)

# ---- the calls ------------------------------------------------------------------------------------

proc notifyAvailable*(): bool =
  ## The system shows notifications here (as far as the app can tell: the
  ## first `notify` or this asks the system, and a failure is remembered
  ## for a minute). False on iOS, and where `notify` would answer false.
  when defined(ios): return false
  else:
    when androidApp:
      if javaAvailable():
        let nm = javaActivityObj("getSystemService", "notification")
        if nm.isNil: return false
        result = (androidSdk() < 33 or javaActivity("checkSelfPermission", PostPermission) == "0") and
                 javaCall(nm, "areNotificationsEnabled") != "false"
        javaRelease(nm)
        return
    when defined(windows):
      result = windowsRoute() and stateNow() != 2
    else:
      if not posixRoute(): return false
      let s = stateNow()
      if s == 0 and epochTime() - probedAt > 60:
        probedAt = epochTime()
        submit(Job(kind: jkProbe))            # (asked off the UI thread; known soon)
      result = s != 2

proc notify*(title, body: string; app = ""; icon = ""; tag = ""): bool {.discardable.} =
  ## A notification of the system (the bubble or banner outside the window):
  ## `title` ("New mail"), `body` (who and what), `app` (the app's name,
  ## where the system shows one), `icon` (a picture file: PNG on Android
  ## and Linux, .ico on Windows; "" the app's own). A `tag` replaces an
  ## earlier one with the same tag ("inbox": one card for the new mail,
  ## not one each). False when the system has none here (the app then
  ## shows a `toast`); it never waits for the system.
  let t = cleanText(title, MaxTitle)
  let b = cleanText(body, MaxBody)
  if t.len == 0 and b.len == 0: return false
  when defined(ios): return false
  else:
    when androidApp:
      if javaAvailable():
        try: return androidNotify(t, b, icon, tag, badgeNow)
        except CatchableError: return false
    when defined(windows):
      if not windowsRoute() or stateNow() == 2: return false
    else:
      if not posixRoute() or stateNow() == 2: return false
    submit(Job(kind: jkShow, title: t, body: b, app: cleanText(app, 60), icon: icon, tag: tag))
    true

proc clearNotification*(tag = "") =
  ## Takes the app's notification with `tag` away (the mail was read);
  ## "": all of them. (macOS leaves them; Windows has one at a time.)
  when defined(ios): discard
  else:
    when androidApp:
      if javaAvailable():
        androidClear(tag)
        return
    if started: submit(Job(kind: jkClose, tag: tag))

proc setBadge*(count: int) =
  ## The unread count on the app's icon where the system has one: the
  ## Dock's badge on macOS, the app's notifications on Android (launchers
  ## show their count; 0 takes them away). Nothing elsewhere. Cheap to call
  ## every frame: only a change does something.
  let c = max(0, count)
  if c == badgeNow: return
  badgeNow = c
  when defined(macosx):
    try: dockBadge(c)
    except CatchableError: discard
  elif androidApp:
    if javaAvailable():
      try: androidBadge(c)
      except CatchableError: discard

proc badgeCount*(): int = badgeNow
  ## The count `setBadge` set last.

proc notifyWait*(timeoutMs = 3000): bool =
  ## Waits (at most `timeoutMs`) until the notifications asked for are
  ## handed to the system -- before the app quits, in tests. True when
  ## nothing is left.
  if not started: return true
  let t0 = epochTime()
  while true:
    var left: int
    withLock lock: left = pending
    if left == 0: return true
    if (epochTime() - t0) * 1000 > float(timeoutMs): return false
    sleep(5)

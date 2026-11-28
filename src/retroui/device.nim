## The device's features an app reaches past its window: the links it is opened with, one copy of
## it running at a time, the screen lock asked before something private (fingerprint, face or
## PIN), how the device is held and shaken, picture in picture, drag and drop with the app beside
## it, and purchases in the app.
##
## ```nim
## let link = takeLink()                 # "myapp://song/12": opened by a link (each once)
## if button("Show the Secrets"): discard askUnlock("To show your saved passwords")
## if unlockAnswer() == laOk: showSecrets = true
## if shaken() and undo.canUndo: discard undo.undo()
## ```
##
## Where a system has no such thing the calls say so (false, `laUnavailable`, an empty
## `Motion`): the app offers another way. Building for a phone: `retroapk --links:myapp --pip`,
## `retroios --links:myapp`; a Mac's app: `RETRO_LINKS=myapp sh tools/macapp.sh ...`; Linux and
## Windows: `registerLinks(["myapp"])` once.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, times, math, atomics]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import uirelays/services
from uirelays/input import interruptWaitEvent
import gfx, core, widgets
when androidApp or defined(ios) or defined(macosx):
  import native

when defined(windows):
  import std/winlean
when defined(ios):
  {.passL: "-framework LocalAuthentication -framework CoreMotion -framework StoreKit".}
elif defined(macosx):
  {.passL: "-framework LocalAuthentication".}

# ---- links ----------------------------------------------------------------------------------------

when defined(ios):
  proc uirelays_take_link(): cstring {.importc, cdecl.}

when defined(macosx) and not defined(ios):
  var macLinks: seq[string]
  var macHooked = false
  proc onGetUrl(self: ObjcId; cmd: ObjcSel; event, reply: ObjcId) {.cdecl.} =
    ## (the system's "open this link" for the app: its address kept)
    let d = objcSend(ObjcId, event, "paramDescriptorForKeyword:", 0x2d2d2d2d'u32)   # keyDirectObject '----'
    if d != nil:
      let s = objcSend(ObjcId, d, "stringValue")
      if s != nil: macLinks.add $objcSend(cstring, s, "UTF8String")
  proc hookMacLinks() =
    if macHooked: return
    macHooked = true
    proc objc_allocateClassPair(super: pointer; name: cstring; extra: int): pointer {.importc, cdecl.}
    proc objc_registerClassPair(cls: pointer) {.importc, cdecl.}
    proc class_addMethod(cls, name, imp: pointer; types: cstring): bool {.importc, cdecl.}
    try:
      autoreleasePool:
        var cls = cast[pointer](objcClass("RetroLinkTarget"))
        if cls == nil:
          cls = objc_allocateClassPair(cast[pointer](objcClass("NSObject")), "RetroLinkTarget", 0)
          discard class_addMethod(cls, cast[pointer](sel("getUrl:withReply:")), cast[pointer](onGetUrl), "v@:@@")
          objc_registerClassPair(cls)
        let target = objcSend(ObjcId, objcSend(ObjcId, cast[ObjcId](cls), "alloc"), "init")
        let mgr = objcSend(ObjcId, objcClass("NSAppleEventManager"), "sharedAppleEventManager")
        objcSend(void, mgr, "setEventHandler:andSelector:forEventClass:andEventID:", target,
                 sel("getUrl:withReply:"), 0x4755524c'u32, 0x4755524c'u32)          # 'GURL', 'GURL'
    except CatchableError: discard

var
  argsTaken = false
  linkSchemesKnown: seq[string]      # (registerLinks: the schemes whose links the arguments carry)
  inboxPath: string                  # (singleInstance: the folder other copies write to)
  inboxLinks: seq[string]            # (links another copy handed over, not taken yet)
  inboxSeen: Atomic[bool]            # (the watcher found something in the inbox: a frame to read it)
  inboxChecked: float                # (without threads: when the inbox was looked at)

# ---- the window brought forward -------------------------------------------------------------------

when defined(windows):
  proc EnumWindows(cb: proc (h: pointer; lp: int): int32 {.stdcall.}; lp: int): int32 {.stdcall, dynlib: "user32", importc.}
  proc GetWindowThreadProcessId(h: pointer; pid: ptr uint32): uint32 {.stdcall, dynlib: "user32", importc.}
  proc IsWindowVisible(h: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc IsIconic(h: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc ShowWindow(h: pointer; cmd: int32): int32 {.stdcall, dynlib: "user32", importc.}
  proc SetForegroundWindow(h: pointer): int32 {.stdcall, dynlib: "user32", importc.}
  proc AllowSetForegroundWindow(pid: uint32): int32 {.stdcall, dynlib: "user32", importc.}
  var ownWindows: seq[pointer]
  proc collect(h: pointer; lp: int): int32 {.stdcall.} =
    var pid: uint32
    discard GetWindowThreadProcessId(h, addr pid)
    if int(pid) == lp and IsWindowVisible(h) != 0: ownWindows.add h
    1

elif defined(linux) and not androidApp:
  import std/dynlib
  type XClientMessage = object
    kind: cint
    serial: culong
    sendEvent: cint
    display: pointer
    window: culong
    messageType: culong
    format: cint
    data: array[5, clong]

  proc raiseOnX11(): bool =
    ## (the window whose _NET_WM_PID is this process's: mapped, raised and made active by the
    ## window manager -- _NET_ACTIVE_WINDOW, as a task bar asks it)
    if getEnv("DISPLAY").len == 0: return false
    let lib = loadLib("libX11.so.6")
    if lib == nil: return false
    defer: unloadLib(lib)
    type
      OpenF = proc (name: cstring): pointer {.cdecl.}
      RootF = proc (d: pointer): culong {.cdecl.}
      AtomF = proc (d: pointer; name: cstring; onlyIfExists: cint): culong {.cdecl.}
      PropF = proc (d: pointer; w, prop: culong; offset, length: clong; delete: cint; reqType: culong;
                    actualType: ptr culong; actualFormat: ptr cint; n, after: ptr culong;
                    data: ptr pointer): cint {.cdecl.}
      FreeF = proc (p: pointer): cint {.cdecl.}
      SendF = proc (d: pointer; w: culong; propagate: cint; mask: clong; e: pointer): cint {.cdecl.}
      WinF = proc (d: pointer; w: culong): cint {.cdecl.}
      DispF = proc (d: pointer): cint {.cdecl.}
    let
      xOpen = cast[OpenF](lib.symAddr("XOpenDisplay"))
      xRoot = cast[RootF](lib.symAddr("XDefaultRootWindow"))
      xAtom = cast[AtomF](lib.symAddr("XInternAtom"))
      xProp = cast[PropF](lib.symAddr("XGetWindowProperty"))
      xFree = cast[FreeF](lib.symAddr("XFree"))
      xSend = cast[SendF](lib.symAddr("XSendEvent"))
      xMapRaised = cast[WinF](lib.symAddr("XMapRaised"))
      xFlush = cast[DispF](lib.symAddr("XFlush"))
      xClose = cast[DispF](lib.symAddr("XCloseDisplay"))
    if xOpen == nil or xRoot == nil or xAtom == nil or xProp == nil or xFree == nil or
       xSend == nil or xMapRaised == nil or xFlush == nil or xClose == nil: return false
    let d = xOpen(nil)
    if d == nil: return false
    defer: discard xClose(d)
    let root = xRoot(d)
    proc longs(w, prop, kind: culong): seq[culong] =
      var actual: culong
      var format: cint
      var n, after: culong
      var data: pointer
      if xProp(d, w, prop, 0, 4096, 0, kind, addr actual, addr format, addr n, addr after,
               addr data) == 0 and data != nil:
        if format == 32:
          let a = cast[ptr UncheckedArray[culong]](data)
          for i in 0 ..< int(n): result.add a[i]
        discard xFree(data)
    let me = culong(getCurrentProcessId())
    let pidAtom = xAtom(d, "_NET_WM_PID", 0)
    for w in longs(root, xAtom(d, "_NET_CLIENT_LIST", 0), 33):     # XA_WINDOW
      let pid = longs(w, pidAtom, 6)                                  # XA_CARDINAL
      if pid.len == 0 or pid[0] != me: continue
      discard xMapRaised(d, w)
      var e: array[24, clong]                                        # (an XEvent's room)
      let m = cast[ptr XClientMessage](addr e[0])
      m.kind = 33                                                    # ClientMessage
      m.sendEvent = 1
      m.display = d
      m.window = w
      m.messageType = xAtom(d, "_NET_ACTIVE_WINDOW", 0)
      m.format = 32
      m.data[0] = 2                                                  # (asked as a task bar asks)
      discard xSend(d, root, 0, clong((1 shl 20) or (1 shl 19)), addr e[0])
      result = true
    discard xFlush(d)

proc bringForward*() =
  ## The app's window in front of the others, made whole if it was minimized, and given the
  ## keyboard: what a second copy started does to the first (`singleInstance`), what a link
  ## or a notification that opens the app does. Windows, macOS and X11; on Wayland the window
  ## asks for attention only as its compositor lets it, and phones bring an app forward
  ## themselves.
  when defined(windows):
    ownWindows.setLen(0)
    discard EnumWindows(collect, getCurrentProcessId())
    for h in ownWindows:
      if IsIconic(h) != 0: discard ShowWindow(h, 9)               # SW_RESTORE
      discard SetForegroundWindow(h)
  elif defined(macosx) and not defined(ios):
    try:
      autoreleasePool:
        let app = objcSend(ObjcId, objcClass("NSApplication"), "sharedApplication")
        objcSend(void, app, "unhide:", nil)
        let wins = objcSend(ObjcId, app, "windows")
        for i in 0 ..< objcSend(int, wins, "count"):
          let w = objcSend(ObjcId, wins, "objectAtIndex:", i)
          if objcSend(bool, w, "isMiniaturized"): objcSend(void, w, "deminiaturize:", nil)
        objcSend(void, app, "activateIgnoringOtherApps:", true)
    except CatchableError: discard
  elif defined(linux) and not androidApp:
    discard raiseOnX11()
  ui.redraw = true

iterator inboxFiles(dir: string): string =
  ## (the links other copies handed over: listed, not globbed -- Android before 9 has no glob)
  for kind, f in walkDir(dir):
    if kind == pcFile and f.endsWith(".link"): yield f

proc readInbox() {.nimcall.} =
  ## (each frame: what another copy handed over -- links for `takeLink`; an empty one, "come
  ## forward" -- read once the watcher saw it)
  if inboxPath.len == 0: return
  when compileOption("threads"):
    if not inboxSeen.load: return
    inboxSeen.store(false)
  else:
    if epochTime() - inboxChecked < 0.3: return       # (no watcher: a look now and then)
    inboxChecked = epochTime()
  var any = false
  try:
    for f in inboxFiles(inboxPath):
      let t = readFile(f)
      removeFile(f)
      any = true
      if t.len > 0: inboxLinks.add t
  except CatchableError: discard
  if any: bringForward()

when compileOption("threads"):
  proc watchInbox(dir: string) {.thread.} =
    ## (a look at the inbox every 0.3 s: the screen's loop woken when something came)
    while true:
      sleep(300)
      var found = false
      try:
        for f in inboxFiles(dir):
          found = true
          break
      except CatchableError: discard
      if found and not inboxSeen.exchange(true):
        {.cast(gcsafe).}: interruptWaitEvent()

  var inboxWatcher: Thread[string]

proc looksLikeLink(s: string): bool =
  let k = s.find("://")
  if k <= 0: return s.len > 3 and s.find(':') > 1 and s.split(':')[0] in linkSchemesKnown
  for c in s[0 ..< k]:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.'}: return false
  true

proc instanceDir(id: string): string =
  dataDir(if id.len > 0: id else: "") / "instance"

proc takeLink*(): string =
  ## A link the app was opened with -- or that came to it while it ran: a link of its scheme
  ## tapped in a message, a web page, another app (`myapp://song/12`) --, each once, the oldest
  ## first; "" when there is none. Ask each frame (it is cheap).
  when androidApp:
    if javaAvailable(): return javaStatic("org.retro.RetroDevice", "takeLink")
  elif defined(ios):
    return $uirelays_take_link()
  else:
    when defined(macosx):
      hookMacLinks()
      if macLinks.len > 0:
        let l = macLinks[0]
        macLinks.delete(0)
        return l
    if not argsTaken:
      # (on Linux and Windows a link comes as the program's argument)
      argsTaken = true
      for a in appArguments():
        if looksLikeLink(a): return a
    # (a second copy started with a link sent it here: `singleInstance`)
    readInbox()
    if inboxLinks.len > 0:
      let l = inboxLinks[0]
      inboxLinks.delete(0)
      return l
  ""

proc singleInstance*(id = ""): bool =
  ## Call it first thing on Linux, Windows or macOS: true when this is the only copy of the app
  ## running (keep going); false when another one runs -- what this one was opened with (a link,
  ## files) has been handed to it, and it is brought forward: quit then. Opening the app again
  ## brings its window back instead of a second one, as the guide asks. True on phones (one copy
  ## always). `id`: the app's own name for it (its data folder's).
  when androidApp or defined(ios) or defined(wasm): return true
  else:
    let dir = instanceDir(id)
    try: createDir(dir)
    except CatchableError: return true
    let pidFile = dir / "pid"
    var other = 0
    try:
      if fileExists(pidFile): other = parseInt(readFile(pidFile).strip)
    except CatchableError: other = 0
    proc alive(pid: int): bool =
      if pid <= 0 or pid == getCurrentProcessId(): return false
      when defined(windows):
        let h = openProcess(0x1000, 0, int32(pid))       # PROCESS_QUERY_LIMITED_INFORMATION
        if h == 0: return false
        var code: int32
        result = getExitCodeProcess(h, code) != 0 and code == 259   # STILL_ACTIVE
        discard closeHandle(h)
      elif defined(linux):
        # (a process of this program, not one ended and not yet reaped -- a zombie -- nor
        # another program given the same number since)
        try:
          let stat = readFile("/proc/" & $pid & "/stat")
          let k = stat.rfind(')')
          if k < 0 or k + 2 >= stat.len or stat[k + 2] in {'Z', 'X'}: return false
          let exe = expandSymlink("/proc/" & $pid & "/exe")
          exe.endsWith(" (deleted)") or exe == getAppFilename() or
            exe.extractFilename == getAppFilename().extractFilename
        except CatchableError: false
      else:
        proc kill(pid, sig: cint): cint {.importc, header: "<signal.h>".}
        kill(cint(pid), 0) == 0
    if alive(other):
      # (another runs: what this one was opened with, to it -- it looks three times a second --,
      # and leave to come forward given to it: the system lets the app in front give it)
      when defined(windows): discard AllowSetForegroundWindow(uint32(other))
      proc handOver(n: int; text: string): bool =
        # (written beside, then renamed: the first copy never reads one half written)
        let name = dir / ($getCurrentProcessId() & "-" & $n)
        try:
          writeFile(name & ".part", text)
          moveFile(name & ".part", name & ".link")
          true
        except CatchableError: false
      var sent = false
      for i, a in appArguments():
        if handOver(i, if looksLikeLink(a) or not fileExists(a): a else: absolutePath(a)): sent = true
      if not sent: discard handOver(-1, "")       # (nothing to hand over: just come forward)
      return false
    try: writeFile(pidFile, $getCurrentProcessId())
    except CatchableError: discard
    inboxPath = dir
    try:
      for f in inboxFiles(dir): removeFile(f)    # (a copy's that ended before it was read)
    except CatchableError: discard
    beginFrameHooks.add readInbox
    when compileOption("threads"): createThread(inboxWatcher, watchInbox, dir)
    true

proc registerLinks*(schemes: openArray[string]; app = ""): bool {.discardable.} =
  ## Makes this program the one the system opens links of these schemes with (`myapp`:
  ## myapp://anything) -- on Linux a desktop entry and xdg-mime, on Windows the user's classes
  ## in the registry. Once, at the first start, is enough. (Phones and Macs say it in the app's
  ## bundle: `retroapk --links`, `retroios --links`, RETRO_LINKS for tools/macapp.sh.)
  for s in schemes: (if s notin linkSchemesKnown: linkSchemesKnown.add s)
  let exe = getAppFilename()
  when defined(windows):
    try:
      for s in schemes:
        let base = "HKCU\\Software\\Classes\\" & s
        discard execShellCmd("reg add \"" & base & "\" /ve /d \"URL:" & s & "\" /f >nul 2>&1")
        discard execShellCmd("reg add \"" & base & "\" /v \"URL Protocol\" /d \"\" /f >nul 2>&1")
        discard execShellCmd("reg add \"" & base & "\\shell\\open\\command\" /ve /d \"\\\"" & exe &
                             "\\\" \\\"%1\\\"\" /f >nul 2>&1")
      true
    except CatchableError: false
  elif defined(linux) and not androidApp:
    try:
      let name = if app.len > 0: app else: extractFilename(exe)
      let apps = getHomeDir() / ".local" / "share" / "applications"
      createDir(apps)
      var mimes = ""
      for s in schemes: mimes.add "x-scheme-handler/" & s & ";"
      let file = apps / ("retro-" & name.toLowerAscii.replace(' ', '-') & ".desktop")
      writeFile(file, "[Desktop Entry]\nType=Application\nName=" & name & "\nExec=\"" & exe &
                "\" %u\nMimeType=" & mimes & "\nNoDisplay=true\n")
      for s in schemes:
        discard execShellCmd("xdg-mime default " & quoteShell(extractFilename(file)) & " x-scheme-handler/" &
                             s & " >/dev/null 2>&1")
      true
    except CatchableError: false
  else: false

# ---- the screen lock: fingerprint, face or PIN -----------------------------------------------------

type LockAnswer* = enum
  ## What the screen lock said (`unlockAnswer`).
  laNone,         ## not asked
  laAsking,       ## its sheet is up
  laOk,           ## it was the device's owner
  laFailed,       ## it wasn't, or the user let it be (Cancel)
  laUnavailable   ## this device has no lock set, or the system no way to ask

var lockState = laNone

when defined(ios) or (defined(macosx) and not defined(ios)):
  type
    LockBlockDesc = object
      reserved, size: culong
    LockBlock = object
      isa: pointer
      flags, reserved: int32
      invoke: pointer
      descriptor: ptr LockBlockDesc
  var concreteGlobalBlockL {.importc: "_NSConcreteGlobalBlock".}: array[32, pointer]
  var lockDesc = LockBlockDesc(size: culong(sizeof(LockBlock)))
  var lockReply {.volatile.}: int     # (0 waiting, 1 ok, 2 failed: from the system's thread)
  proc onLockReply(b: ptr LockBlock; ok: bool; err: ObjcId) {.cdecl.} =
    lockReply = if ok: 1 else: 2
  var lockBlock = LockBlock(flags: 1'i32 shl 28, descriptor: addr lockDesc)

proc canUnlock*(): bool =
  ## The device can ask its owner -- a screen lock is set (a fingerprint, a face, a PIN).
  when androidApp:
    javaAvailable() and javaStatic("org.retro.RetroDevice", "lockAvailable", jactivity()) == "1"
  elif defined(ios) or defined(macosx):
    try:
      autoreleasePool:
        let ctx = objcSend(ObjcId, objcSend(ObjcId, objcClass("LAContext"), "alloc"), "init")
        if ctx == nil: return false
        result = objcSend(bool, ctx, "canEvaluatePolicy:error:", 2, nil)   # deviceOwnerAuthentication
        objcSend(void, ctx, "release")
    except CatchableError: result = false
  else: false

proc askUnlock*(reason: string; title = "Confirm it is you"): bool {.discardable.} =
  ## Asks the device's owner to prove it is them, with the system's own sheet -- a fingerprint, a
  ## face, or the PIN or pattern of the screen lock -- before something private is shown or done
  ## (`reason` says what: "To show your saved passwords"). `unlockAnswer` tells how it went.
  ## False when it can't be asked here (Linux, Windows, no lock set): offer the app's own password.
  lockState = laAsking
  when androidApp:
    if javaAvailable() and javaStatic("org.retro.RetroDevice", "askLock", jactivity(), title, reason) == "1":
      return true
  elif defined(ios) or defined(macosx):
    try:
      lockReply = 0
      lockBlock.isa = addr concreteGlobalBlockL
      lockBlock.invoke = cast[pointer](onLockReply)
      autoreleasePool:
        let ctx = objcSend(ObjcId, objcSend(ObjcId, objcClass("LAContext"), "alloc"), "init")
        if ctx != nil:
          objcSend(void, ctx, "evaluatePolicy:localizedReason:reply:", 2, nsString(reason),
                   cast[pointer](addr lockBlock))
          return true
    except CatchableError: discard
  lockState = laUnavailable
  false

proc unlockAnswer*(): LockAnswer =
  ## What the screen lock asked by `askUnlock` said: `laAsking` while its sheet is up, then
  ## `laOk` or `laFailed` (each frame until it is asked again).
  if lockState == laAsking:
    when androidApp:
      case javaStatic("org.retro.RetroDevice", "lockResult")
      of "2": lockState = laOk
      of "3": lockState = laFailed
      of "4": lockState = laUnavailable
      else: discard
    elif defined(ios) or defined(macosx):
      if lockReply == 1: lockState = laOk
      elif lockReply == 2: lockState = laFailed
    if lockState == laAsking: wakeIn(100)
  lockState

# ---- motion ----------------------------------------------------------------------------------------

type Motion* = object
  ## How the device is held and moved (`motion`).
  ok*: bool                   ## the device has the sensors and they are on
  tiltX*, tiltY*: float       ## leaning left (-1) or right (1); back (-1) or forward (1), flat 0
  gravity*: array[3, float]   ## the pull of gravity on it (m/s²), x right, y up, z out of the screen
  jolt*: array[3, float]      ## how it is pushed now, gravity taken away (m/s²)

var
  motionOn = false
  shakeSeen = 0.0
  lastShakeAt = 0.0

when defined(ios):
  var motionManager: ObjcId

proc startMotion*(): bool {.discardable.} =
  ## Turns the motion sensors on (they use a little power: turn them off with `stopMotion` when
  ## the app no longer needs them); false when the device has none.
  if motionOn: return true
  when androidApp:
    motionOn = javaAvailable() and javaStatic("org.retro.RetroDevice", "startMotion", jactivity()) == "1"
  elif defined(ios):
    try:
      if motionManager == nil:
        motionManager = objcSend(ObjcId, objcSend(ObjcId, objcClass("CMMotionManager"), "alloc"), "init")
      if motionManager != nil and objcSend(bool, motionManager, "isDeviceMotionAvailable"):
        objcSend(void, motionManager, "setDeviceMotionUpdateInterval:", 1.0 / 30.0)
        objcSend(void, motionManager, "startDeviceMotionUpdates")
        motionOn = true
    except CatchableError: discard
  motionOn

proc stopMotion*() =
  ## Turns the motion sensors off.
  if not motionOn: return
  motionOn = false
  when androidApp:
    discard javaStatic("org.retro.RetroDevice", "stopMotion")
  elif defined(ios):
    if motionManager != nil: objcSend(void, motionManager, "stopDeviceMotionUpdates")

proc motion*(): Motion =
  ## How the device is held and pushed now (`startMotion` first). `ok` false where there is no
  ## way to tell (a desktop).
  if not motionOn: return
  when androidApp:
    let v = javaStatic("org.retro.RetroDevice", "motion").splitWhitespace
    if v.len >= 7:
      try:
        # (Android's axes: x right, y up, z out of the screen -- gravity's pull as the sensor feels it)
        for k in 0 .. 2:
          result.gravity[k] = parseFloat(v[k])
          result.jolt[k] = parseFloat(v[3 + k])
        let at = parseFloat(v[6]) / 1000
        if at > lastShakeAt:
          lastShakeAt = at
          shakeSeen = at
        result.ok = true
      except ValueError: discard
  elif defined(ios):
    try:
      let m = objcSend(ObjcId, motionManager, "deviceMotion")
      if m != nil:
        type V3 {.bycopy.} = object
          x, y, z: float
        let g = objcSend(V3, m, "gravity")
        let a = objcSend(V3, m, "userAcceleration")
        # (iOS's in g, the other way round: as Android's)
        result.gravity = [-g.x * 9.81, -g.y * 9.81, -g.z * 9.81]
        result.jolt = [a.x * 9.81, a.y * 9.81, a.z * 9.81]
        result.ok = true
        let f = sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
        if f > 1.4 and epochTime() - lastShakeAt > 1.0:
          lastShakeAt = epochTime()
          shakeSeen = lastShakeAt
    except CatchableError: discard
  if result.ok:
    result.tiltX = clamp(-result.gravity[0] / 9.81, -1.0, 1.0)
    result.tiltY = clamp(result.gravity[1] / 9.81, -1.0, 1.0)

proc shaken*(): bool =
  ## The device was shaken since this was asked last -- shake to undo, as phones do (offer it
  ## with a question: "Undo Typing?"). Turns the sensors on the first time.
  if not motionOn: discard startMotion()
  discard motion()
  if shakeSeen > 0:
    shakeSeen = 0
    return true
  false

# ---- picture in picture ----------------------------------------------------------------------------

proc pictureInPicture*(): bool {.discardable.} =
  ## The app goes on in a small window over the others -- a video, a call, a timer keep showing
  ## while the user is elsewhere (Android 7 and later, an APK made with `retroapk --pip`). False
  ## where it can't: then `minimizeApp` is the nearest.
  when androidApp:
    javaAvailable() and javaStatic("org.retro.RetroDevice", "enterPip", jactivity()) == "1"
  else: false

proc inPictureInPicture*(): bool =
  ## The app is in its small window over the others now: show its video alone, no controls.
  when androidApp:
    javaAvailable() and javaStatic("org.retro.RetroDevice", "inPip", jactivity()) == "1"
  else: false

# ---- drag and drop with other apps (Android) ---------------------------------------------------------

proc dragToApps*(paths: openArray[string]; text = ""): bool {.discardable.} =
  ## Starts dragging `paths` (files of the app's) or `text` out to another app -- the one beside it
  ## in split screen, a small window --, from where the finger is (Android 7 and later; call it
  ## when a drag starts: `lifted`). On desktops a drag of the kit's (`startDrag` with `files`)
  ## already goes out of the window by itself.
  when androidApp:
    javaAvailable() and javaStatic("org.retro.RetroDevice", "dragOut", jactivity(), paths.join("\n"), text) == "1"
  else: false

when androidApp:
  # (a drag of the kit's files -- `fileDragSource`, `dragFilesOut` -- goes out to the app beside it)
  fileDragRelays.dragOut = proc (paths: seq[string]; move, backInside: bool): DragOutResult {.nimcall.} =
    if dragToApps(paths): drCopied else: drNone
  fingerDragOut = true

type AppDrop* = object
  ## What another app dropped on this one (`droppedFromApps`).
  files*: seq[string]     ## copies of its files, in the app's cache
  texts*: seq[string]
  at*: Point              ## where (logical pixels)

proc droppedFromApps*(): AppDrop =
  ## What another app (beside it in split screen) dropped on this one this frame: files copied
  ## in, or text. (Desktops' file managers: `droppedFiles`.)
  when androidApp:
    if not javaAvailable(): return
    let t = javaStatic("org.retro.RetroDevice", "takeDrop")
    if t.len == 0: return
    let lines = t.split('\n')
    let xy = lines[0].splitWhitespace
    if xy.len == 2:
      try: result.at = Point(x: parseInt(xy[0]) * 100 div max(1, uiScale()), y: parseInt(xy[1]) * 100 div max(1, uiScale()))
      except ValueError: discard
    for l in lines[1 .. ^1]:
      if l.len < 2: continue
      if l[0] == 'f': result.files.add l[1 .. ^1]
      elif l[0] == 't': result.texts.add l[1 .. ^1].replace('\x01', '\n')
    ui.redraw = true

# ---- purchases in the app ---------------------------------------------------------------------------

type
  StoreState* = enum
    ## How the store is (`storeStart`).
    ssNone,         ## not started
    ssConnecting,
    ssReady,
    ssUnavailable   ## no store here: no billing library in the APK, a desktop

  StoreEventKind* = enum
    ## What came from the store (`storeEvent`).
    seNone,
    seProduct,      ## a product asked for (`storeProducts`): `product`
    sePurchase,     ## a purchase -- made now, or owned from before (`storeOwned`): `purchase`
    seError         ## the store said no (`code`)

  Product* = object
    ## A product of the store (as the developer set it up there).
    id*, title*, price*, description*: string

  Purchase* = object
    ## A purchase: give what was bought once `state` is 1 (paid), then `storeFinish` it.
    token*: string
    products*: seq[string]
    state*: int             ## 1 paid, 2 pending (paid later: cash, a card being checked)
    orderId*: string

  StoreEvent* = object
    case kind*: StoreEventKind
    of seProduct: product*: Product
    of sePurchase: purchase*: Purchase
    of seError: code*: int
    of seNone: discard

when defined(ios):
  # (StoreKit: an object of the kit's own the store calls back -- products found, purchases
  # changed --, what it says kept as events; the products and the purchases by their ids)
  var
    storeEvents: seq[StoreEvent]
    storeObserver: ObjcId
    skProducts: seq[(string, ObjcId)]
    skTransactions: seq[(string, ObjcId)]
    skRequests: seq[ObjcId]
  proc objc_allocateClassPair(super: pointer; name: cstring; extra: int): pointer {.importc, cdecl.}
  proc objc_registerClassPair(cls: pointer) {.importc, cdecl.}
  proc class_addMethod(cls, name, imp: pointer; types: cstring): bool {.importc, cdecl.}
  proc objc_retain(o: ObjcId): ObjcId {.importc, cdecl.}

  proc strOf(o: ObjcId): string =
    if o == nil: "" else: $objcSend(cstring, o, "UTF8String")

  proc onProducts(self: ObjcId; cmd: ObjcSel; req, resp: ObjcId) {.cdecl.} =
    let list = objcSend(ObjcId, resp, "products")
    let n = objcSend(int, list, "count")
    for i in 0 ..< n:
      let p = objcSend(ObjcId, list, "objectAtIndex:", i)
      discard objc_retain(p)
      let id = strOf(objcSend(ObjcId, p, "productIdentifier"))
      let f = objcSend(ObjcId, objcSend(ObjcId, objcClass("NSNumberFormatter"), "alloc"), "init")
      objcSend(void, f, "setNumberStyle:", 2)                     # (currency)
      objcSend(void, f, "setLocale:", objcSend(ObjcId, p, "priceLocale"))
      let price = strOf(objcSend(ObjcId, f, "stringFromNumber:", objcSend(ObjcId, p, "price")))
      skProducts.add (id, p)
      storeEvents.add StoreEvent(kind: seProduct, product: Product(id: id,
        title: strOf(objcSend(ObjcId, p, "localizedTitle")), price: price,
        description: strOf(objcSend(ObjcId, p, "localizedDescription"))))
    ui.redraw = true

  proc onTransactions(self: ObjcId; cmd: ObjcSel; queue, list: ObjcId) {.cdecl.} =
    let n = objcSend(int, list, "count")
    for i in 0 ..< n:
      let t = objcSend(ObjcId, list, "objectAtIndex:", i)
      let state = objcSend(int, t, "transactionState")   # 0 buying, 1 bought, 2 failed, 3 restored, 4 deferred
      let pid = strOf(objcSend(ObjcId, objcSend(ObjcId, t, "payment"), "productIdentifier"))
      let tid = strOf(objcSend(ObjcId, t, "transactionIdentifier"))
      case state
      of 1, 3, 4:
        discard objc_retain(t)
        skTransactions.add (tid, t)
        storeEvents.add StoreEvent(kind: sePurchase, purchase: Purchase(token: tid, products: @[pid],
                                   state: (if state == 4: 2 else: 1), orderId: tid))
      of 2:
        storeEvents.add StoreEvent(kind: seError, code: 1)
        objcSend(void, queue, "finishTransaction:", t)
      else: discard
    ui.redraw = true

  proc onFail(self: ObjcId; cmd: ObjcSel; req, err: ObjcId) {.cdecl.} =
    storeEvents.add StoreEvent(kind: seError, code: 2)

proc storeStart*(): StoreState {.discardable.} =
  ## Connects to the system's store (Google Play: the app brings the Play Billing library with
  ## `retroapk --java`, the kit reaches it by name; the App Store: StoreKit). Ask again until
  ## `ssReady`.
  when defined(ios):
    try:
      if storeObserver == nil:
        var cls = cast[pointer](objcClass("RetroStoreObserver"))
        if cls == nil:
          cls = objc_allocateClassPair(cast[pointer](objcClass("NSObject")), "RetroStoreObserver", 0)
          discard class_addMethod(cls, cast[pointer](sel("productsRequest:didReceiveResponse:")),
                                  cast[pointer](onProducts), "v@:@@")
          discard class_addMethod(cls, cast[pointer](sel("paymentQueue:updatedTransactions:")),
                                  cast[pointer](onTransactions), "v@:@@")
          discard class_addMethod(cls, cast[pointer](sel("request:didFailWithError:")),
                                  cast[pointer](onFail), "v@:@@")
          objc_registerClassPair(cls)
        storeObserver = objcSend(ObjcId, objcSend(ObjcId, cast[ObjcId](cls), "alloc"), "init")
        objcSend(void, objcSend(ObjcId, objcClass("SKPaymentQueue"), "defaultQueue"),
                 "addTransactionObserver:", storeObserver)
      return if objcSend(bool, objcClass("SKPaymentQueue"), "canMakePayments"): ssReady else: ssUnavailable
    except CatchableError: return ssUnavailable
  when androidApp:
    if javaAvailable():
      return case javaStatic("org.retro.RetroDevice", "billingStart", jactivity())
             of "1": ssConnecting
             of "2": ssReady
             of "3": ssUnavailable
             else: ssNone
  ssUnavailable

proc storeProducts*(ids: openArray[string]; subscriptions = false): bool {.discardable.} =
  ## Asks the store for the products `ids` (set up in its console): each comes as a `seProduct`
  ## event, its price in the user's money.
  when androidApp:
    javaStatic("org.retro.RetroDevice", "billingProducts", ids.join(","),
               if subscriptions: "subs" else: "inapp") == "1"
  elif defined(ios):
    if storeObserver == nil: return false
    autoreleasePool:
      let arr = objcSend(ObjcId, objcClass("NSMutableArray"), "array")
      for id in ids: objcSend(void, arr, "addObject:", nsString(id))
      let set = objcSend(ObjcId, objcClass("NSSet"), "setWithArray:", arr)
      let req = objcSend(ObjcId, objcSend(ObjcId, objcClass("SKProductsRequest"), "alloc"),
                         "initWithProductIdentifiers:", set)
      objcSend(void, req, "setDelegate:", storeObserver)
      objcSend(void, req, "start")
      skRequests.add req
    true
  else: false

proc storeBuy*(id: string): bool {.discardable.} =
  ## Opens the store's own sheet to buy the product `id` (asked with `storeProducts`); the
  ## purchase comes as a `sePurchase` event.
  when androidApp:
    javaStatic("org.retro.RetroDevice", "billingBuy", jactivity(), id) == "1"
  elif defined(ios):
    for (pid, p) in skProducts:
      if pid == id:
        let pay = objcSend(ObjcId, objcClass("SKPayment"), "paymentWithProduct:", p)
        objcSend(void, objcSend(ObjcId, objcClass("SKPaymentQueue"), "defaultQueue"), "addPayment:", pay)
        return true
    false
  else: false

proc storeFinish*(p: Purchase; consumable: bool): bool {.discardable.} =
  ## Tells the store what was bought was given: `consumable` (coins, credits: bought again
  ## later) or kept for good (a pro version). Unfinished purchases are refunded after a few days.
  when androidApp:
    javaStatic("org.retro.RetroDevice", "billingFinish", p.token, consumable) == "1"
  elif defined(ios):
    for i, (tid, t) in skTransactions:
      if tid == p.token:
        objcSend(void, objcSend(ObjcId, objcClass("SKPaymentQueue"), "defaultQueue"), "finishTransaction:", t)
        skTransactions.delete(i)
        return true
    false
  else: false

proc storeOwned*(subscriptions = false): bool {.discardable.} =
  ## Asks for what the user owns -- bought before, on another device --: each a `sePurchase`.
  when androidApp:
    javaStatic("org.retro.RetroDevice", "billingOwned", if subscriptions: "subs" else: "inapp") == "1"
  elif defined(ios):
    if storeObserver == nil: return false
    objcSend(void, objcSend(ObjcId, objcClass("SKPaymentQueue"), "defaultQueue"), "restoreCompletedTransactions")
    true
  else: false

proc storeEvent*(): StoreEvent =
  ## The next thing that came from the store (`seNone`: nothing): call it each frame while the
  ## store is in use.
  when defined(ios):
    if storeEvents.len > 0:
      let ev = storeEvents[0]
      storeEvents.delete(0)
      return ev
  when androidApp:
    let e = javaStatic("org.retro.RetroDevice", "billingEvent")
    if e.len < 1: return
    let f = e[1 .. ^1].split('\t')
    case e[0]
    of 'i':
      if f.len >= 4: return StoreEvent(kind: seProduct, product: Product(id: f[0], title: f[1], price: f[2], description: f[3]))
    of 'p':
      if f.len >= 4:
        return StoreEvent(kind: sePurchase, purchase: Purchase(token: f[0], state: (try: parseInt(f[1]) except ValueError: 0),
                                                               products: f[2].split(','), orderId: f[3]))
    of 'e': return StoreEvent(kind: seError, code: (try: parseInt(e[1 .. ^1]) except ValueError: -1))
    else: discard
  StoreEvent()

# ---- the glass effect's light, by how the phone is held ---------------------------------------------

var glassTilt* = false
  ## With the glass effect, the light on its glass follows how the device is held -- tilted left
  ## the glint runs left -- as the glass effect's does on phones (the motion sensors on while the
  ## app shows; off on desktops, which have none).

var tiltHooked = false

proc followTilt() {.nimcall.} =
  if not glassTilt or ui.paused or not glassFx(): return
  if not motionOn and not startMotion(): return
  let m = motion()
  if not m.ok: return
  let l = round(clamp(0.5 + m.tiltX * 0.45, 0.05, 0.95) * 20) / 20
  if l != glassLight:
    glassLight = l
    ui.redraw = true
  wakeIn(100)

proc stopOnPause() {.nimcall.} =
  if glassTilt: stopMotion()

if not tiltHooked:
  tiltHooked = true
  beginFrameHooks.add followTilt
  pauseHooks.add stopOnPause

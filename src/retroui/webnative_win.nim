## (included by webnative) Windows: WebView2, the Edge engine Windows 10 and
## 11 come with. Its loader (WebView2Loader.dll) is used when it is beside the
## program; else the engine is found where Windows keeps it (the registry of
## Edge's updater, then its folders) and started through its own entry. Each
## page is a WebView2 controller in the app's window (the WinAPI driver's),
## placed where the widget is; everything happens in the app's thread, whose
## message loop WebView2 runs on.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, widestrs, algorithm, options]
import imaging
import uirelays/drivers/winapi_driver

type
  HRESULT = int32
  WBOOL = int32
  WRect {.pure, bycopy.} = object
    left, top, right, bottom: int32
  Com = ptr object
    vtbl: ptr UncheckedArray[pointer]

  HandlerKind = enum hkNone, hkEnv, hkController, hkNavStart, hkNavDone, hkMessage, hkNewWindow,
                     hkCapture, hkPermission
  Handler = object
    vtbl: ptr array[4, pointer]
    refs: int32
    kind: HandlerKind
    view: int            ## (which page: an index into `wvViews`)

  WinView = object
    key: string
    controller, webview: Com
    pending: bool        ## being made
    wanted: WRect        ## where the app wants it
    visible: bool
    url, loaded: string
    zoom: float
    hosts: seq[string]
    st: WebNativeState
    closed: bool
    permit: set[WebPermission]
    capture: Com         ## the stream a picture of the page is coming into

var
  wvEnv: Com
  wvEnvState = 0         ## 0 not asked, 1 being made, 2 ready, -1 none
  wvViews: seq[WinView]
  wvHandlerVtbl: array[4, pointer]

proc CoInitializeEx(reserved: pointer; coInit: uint32): HRESULT
  {.stdcall, dynlib: "ole32", importc.}
proc CoTaskMemFree(p: pointer) {.stdcall, dynlib: "ole32", importc.}
proc LoadLibraryW(name: WideCString): pointer {.stdcall, dynlib: "kernel32", importc.}
proc GetProcAddress(m: pointer; name: cstring): pointer {.stdcall, dynlib: "kernel32", importc.}
proc RegGetValueW(key: uint; subKey, value: WideCString; flags: uint32; kind: ptr uint32;
                  data: pointer; size: ptr uint32): int32
  {.stdcall, dynlib: "advapi32", importc.}
proc GetDpiForWindow(w: pointer): uint32 {.stdcall, dynlib: "user32", importc.}
proc CreateStreamOnHGlobal(h: pointer; deleteOnRelease: WBOOL; s: ptr Com): HRESULT
  {.stdcall, dynlib: "ole32", importc.}
proc GetHGlobalFromStream(s: Com; h: ptr pointer): HRESULT {.stdcall, dynlib: "ole32", importc.}
proc GlobalLock(h: pointer): pointer {.stdcall, dynlib: "kernel32", importc.}
proc GlobalUnlock(h: pointer): WBOOL {.stdcall, dynlib: "kernel32", importc.}
proc GlobalSize(h: pointer): uint {.stdcall, dynlib: "kernel32", importc.}

const
  HkeyCurrentUser = 0x80000001'u
  HkeyLocalMachine = 0x80000002'u
  RrfRtRegSz = 0x00000002'u32
  RrfSubkeyWow6432 = 0x00020000'u32
  WebView2Client = "{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"

type WvGuid {.bycopy.} = object
  d1: uint32
  d2, d3: uint16
  d4: array[8, uint8]

const Guid3 = WvGuid(d1: 0xA0D6DF20'u32, d2: 0x3B92, d3: 0x416D,
                     d4: [0xAA'u8, 0x0C, 0x43, 0x7A, 0x9C, 0x72, 0x78, 0x57])   # ICoreWebView2_3

template call(o: Com; slot: int; T: typedesc): untyped =
  ## The method in `slot` of COM object `o`, as a proc of type `T`.
  cast[T](o.vtbl[slot])

proc release(o: Com) =
  if o != nil: discard o.call(2, proc (this: Com): uint32 {.stdcall.})(o)

proc wstr(p: WideCString): string =
  ## A string WebView2 gave (freed here).
  if p == nil: return ""
  result = $p
  CoTaskMemFree(cast[pointer](p))

proc viewIndex(key: string): int =
  for i, v in wvViews:
    if v.key == key and not v.closed: return i
  -1

# ---- the handlers WebView2 calls back (COM objects of the kit's) --------------------------------

proc newHandler(kind: HandlerKind; view = -1): ptr Handler

proc onEnv(err: HRESULT; env: Com)
proc onController(view: int; err: HRESULT; c: Com)
proc onNavStart(view: int; args: Com)
proc onNavDone(view: int)
proc onMessage(view: int; args: Com)
proc onNewWindow(view: int; args: Com)
proc onCapture(view: int; err: HRESULT)
proc onPermission(view: int; args: Com)

proc hQuery(this: ptr Handler; iid, obj: pointer): HRESULT {.stdcall.} =
  cast[ptr pointer](obj)[] = this
  inc this.refs
  0

proc hAddRef(this: ptr Handler): uint32 {.stdcall.} =
  inc this.refs
  uint32(this.refs)

proc hRelease(this: ptr Handler): uint32 {.stdcall.} =
  dec this.refs
  result = uint32(max(0, this.refs))
  if this.refs <= 0: dealloc(this)

proc hInvoke(this: ptr Handler; a, b: pointer): HRESULT {.stdcall.} =
  ## (every handler takes two things: an error code and an object, or the
  ##  sender and the event's arguments)
  case this.kind
  of hkNone: discard
  of hkEnv: onEnv(cast[HRESULT](uint32(cast[uint](a) and 0xFFFF_FFFF'u)), cast[Com](b))
  of hkController:
    onController(this.view, cast[HRESULT](uint32(cast[uint](a) and 0xFFFF_FFFF'u)), cast[Com](b))
  of hkNavStart: onNavStart(this.view, cast[Com](b))
  of hkNavDone: onNavDone(this.view)
  of hkMessage: onMessage(this.view, cast[Com](b))
  of hkNewWindow: onNewWindow(this.view, cast[Com](b))
  of hkCapture: onCapture(this.view, cast[HRESULT](uint32(cast[uint](a) and 0xFFFF_FFFF'u)))
  of hkPermission: onPermission(this.view, cast[Com](b))
  0

proc newHandler(kind: HandlerKind; view = -1): ptr Handler =
  if wvHandlerVtbl[0] == nil:
    wvHandlerVtbl = [cast[pointer](hQuery), cast[pointer](hAddRef), cast[pointer](hRelease),
                     cast[pointer](hInvoke)]
  result = create(Handler)
  result.vtbl = addr wvHandlerVtbl
  result.refs = 1
  result.kind = kind
  result.view = view

# ---- finding WebView2 ---------------------------------------------------------------------------

proc regString(root: uint; sub, value: string; flags: uint32): string =
  var size = 0'u32
  let s = newWideCString(sub)
  let v = newWideCString(value)
  if RegGetValueW(root, s, v, RrfRtRegSz or flags, nil, nil, addr size) != 0 or size == 0:
    return ""
  var buf = newSeq[uint16](int(size) div 2 + 1)
  if RegGetValueW(root, s, v, RrfRtRegSz or flags, nil, addr buf[0], addr size) != 0: return ""
  $cast[WideCString](addr buf[0])

proc engineDll(): string =
  ## Where WebView2's EmbeddedBrowserWebView.dll is ("" when Windows has
  ## none): where Edge's updater says it put it, else its folders.
  let arch = when defined(arm64): "arm64" elif defined(amd64): "x64" else: "x86"
  let sub = "Software\\Microsoft\\EdgeUpdate\\ClientState\\" & WebView2Client
  for (root, flags) in [(HkeyLocalMachine, RrfSubkeyWow6432), (HkeyCurrentUser, 0'u32),
                        (HkeyLocalMachine, 0'u32)]:
    let dir = regString(root, sub, "EBWebView", flags)
    if dir.len > 0:
      let dll = dir / "EBWebView" / arch / "EmbeddedBrowserWebView.dll"
      if fileExists(dll): return dll
  # (its folders: the newest version)
  for base in [getEnv("ProgramFiles(x86)"), getEnv("ProgramFiles"), getEnv("LOCALAPPDATA")]:
    if base.len == 0: continue
    let app = base / "Microsoft" / "EdgeWebView" / "Application"
    var versions: seq[string]
    for kind, d in walkDir(app):
      if kind == pcDir and d.extractFilename.len > 0 and d.extractFilename[0] in {'0'..'9'}:
        versions.add d
    versions.sort(proc (a, b: string): int =
      let x = a.extractFilename.split('.')
      let y = b.extractFilename.split('.')
      for i in 0 ..< min(x.len, y.len):
        let c = cmp((try: parseInt(x[i]) except ValueError: 0), (try: parseInt(y[i]) except ValueError: 0))
        if c != 0: return c
      cmp(x.len, y.len))
    for i in countdown(versions.high, 0):
      let dll = versions[i] / "EBWebView" / arch / "EmbeddedBrowserWebView.dll"
      if fileExists(dll): return dll
  ""

proc startEnvironment(): bool =
  ## Asks WebView2 for its environment (it comes in `onEnv`); false when
  ## Windows has no WebView2.
  discard CoInitializeEx(nil, 2)                   # (apartment threaded; once is enough)
  let data = newWideCString(getEnv("LOCALAPPDATA", getTempDir()) /
                            getAppFilename().splitFile.name / "WebView2")
  let h = newHandler(hkEnv)
  # its loader, when it is beside the program
  let loader = LoadLibraryW(newWideCString("WebView2Loader.dll"))
  if loader != nil:
    let create = cast[proc (exeFolder, userData: WideCString; options, handler: pointer): HRESULT
                         {.stdcall.}](GetProcAddress(loader, "CreateCoreWebView2EnvironmentWithOptions"))
    if create != nil and create(nil, data, nil, h) >= 0: return true
  # else the engine itself, through the entry its loader uses
  let dll = engineDll()
  if dll.len == 0: return false
  let m = LoadLibraryW(newWideCString(dll))
  if m == nil: return false
  let internal = cast[proc (checkRunning, runtimeType: int32; userData: WideCString;
                            options, handler: pointer): HRESULT {.stdcall.}](
    GetProcAddress(m, "CreateWebViewEnvironmentWithOptionsInternal"))
  if internal == nil: return false
  internal(1, 0, data, nil, h) >= 0

# ---- what WebView2 tells ------------------------------------------------------------------------

proc makeView(i: int)

proc onEnv(err: HRESULT; env: Com) =
  if err < 0 or env == nil:
    wvEnvState = -1
    return
  discard env.call(1, proc (this: Com): uint32 {.stdcall.})(env)     # (kept)
  wvEnv = env
  wvEnvState = 2
  for i in 0 ..< wvViews.len:
    if not wvViews[i].closed and wvViews[i].controller == nil: makeView(i)

proc placeView(v: var WinView) =
  if v.controller == nil: return
  discard v.controller.call(6, proc (this: Com; r: WRect): HRESULT {.stdcall.})(v.controller, v.wanted)
  discard v.controller.call(4, proc (this: Com; on: WBOOL): HRESULT {.stdcall.})(
    v.controller, WBOOL(ord(v.visible)))
  if v.zoom > 0:
    discard v.controller.call(8, proc (this: Com; z: float): HRESULT {.stdcall.})(v.controller, v.zoom)

proc loadView(v: var WinView) =
  if v.webview == nil or v.url == v.loaded: return
  v.loaded = v.url
  let u = v.url
  if u.startsWith("html:"):
    discard v.webview.call(6, proc (this: Com; html: WideCString): HRESULT {.stdcall.})(
      v.webview, newWideCString(u[5 .. ^1]))
  else:
    let target = if u.len > 2 and (u[1] == ':' or u[0] == '/' or u[0] == '\\'): fileUrl(u) else: u
    discard v.webview.call(5, proc (this: Com; uri: WideCString): HRESULT {.stdcall.})(
      v.webview, newWideCString(target))
  v.st.progress = 0

proc onController(view: int; err: HRESULT; c: Com) =
  if view < 0 or view >= wvViews.len: return
  template v: untyped = wvViews[view]
  v.pending = false
  if err < 0 or c == nil or v.closed: return
  discard c.call(1, proc (this: Com): uint32 {.stdcall.})(c)
  v.controller = c
  var wv: Com
  discard c.call(25, proc (this: Com; o: ptr Com): HRESULT {.stdcall.})(c, addr wv)
  v.webview = wv
  var token: int64
  type AddHandler = proc (this: Com; h: pointer; token: ptr int64): HRESULT {.stdcall.}
  discard wv.call(7, AddHandler)(wv, newHandler(hkNavStart, view), addr token)
  discard wv.call(15, AddHandler)(wv, newHandler(hkNavDone, view), addr token)
  discard wv.call(34, AddHandler)(wv, newHandler(hkMessage, view), addr token)
  discard wv.call(44, AddHandler)(wv, newHandler(hkNewWindow, view), addr token)
  discard wv.call(23, AddHandler)(wv, newHandler(hkPermission, view), addr token)
  # the app's own folder at https://app.local/ (ICoreWebView2_3)
  let folder = appFolderNow()
  if folder.len > 0:
    var iid3 = Guid3
    var wv3: Com
    if wv.call(0, proc (this: Com; iid: ptr WvGuid; r: ptr Com): HRESULT {.stdcall.})(
         wv, addr iid3, addr wv3) >= 0 and wv3 != nil:
      discard wv3.call(71, proc (this: Com; host, path: WideCString; kind: int32): HRESULT {.stdcall.})(
        wv3, newWideCString("app.local"), newWideCString(folder), 1)   # SetVirtualHostNameToFolderMapping
      release(wv3)
  # the developer tools (F12, Inspect) only when asked for
  var settings: Com
  discard wv.call(3, proc (this: Com; o: ptr Com): HRESULT {.stdcall.})(wv, addr settings)
  if settings != nil:
    discard settings.call(12, proc (this: Com; on: WBOOL): HRESULT {.stdcall.})(
      settings, WBOOL(webToolsWanted()))
    settings.release()
  # `retro.post(text)` in every page, before its own scripts
  discard wv.call(27, proc (this: Com; js: WideCString; h: pointer): HRESULT {.stdcall.})(
    wv, newWideCString(shimFor("window.chrome.webview.postMessage")), newHandler(hkNone))
  placeView(v)
  loadView(v)

proc onNavStart(view: int; args: Com) =
  if view < 0 or view >= wvViews.len or args == nil: return
  var p: WideCString
  discard args.call(3, proc (this: Com; u: ptr WideCString): HRESULT {.stdcall.})(args, addr p)
  let url = wstr(p)
  if not allowedBy(wvViews[view].hosts, url):
    discard args.call(8, proc (this: Com; c: WBOOL): HRESULT {.stdcall.})(args, 1)
    wvViews[view].st.blocked.add url
    return
  wvViews[view].st.progress = 10

proc onNavDone(view: int) =
  if view >= 0 and view < wvViews.len: wvViews[view].st.progress = 100

proc onMessage(view: int; args: Com) =
  if view < 0 or view >= wvViews.len or args == nil: return
  var p: WideCString
  if args.call(5, proc (this: Com; s: ptr WideCString): HRESULT {.stdcall.})(args, addr p) >= 0:
    wvViews[view].st.notes.add wstr(p)

proc onNewWindow(view: int; args: Com) =
  ## A link that wants a new window: opened in the same view.
  if view < 0 or view >= wvViews.len or args == nil: return
  var p: WideCString
  discard args.call(3, proc (this: Com; u: ptr WideCString): HRESULT {.stdcall.})(args, addr p)
  let url = wstr(p)
  discard args.call(6, proc (this: Com; h: WBOOL): HRESULT {.stdcall.})(args, 1)
  if url.len > 0 and wvViews[view].webview != nil:
    if allowedBy(wvViews[view].hosts, url):
      discard wvViews[view].webview.call(5, proc (this: Com; uri: WideCString): HRESULT {.stdcall.})(
        wvViews[view].webview, newWideCString(url))
    else: wvViews[view].st.blocked.add url

proc makeView(i: int) =
  if wvEnv == nil or wvViews[i].pending or wvViews[i].controller != nil: return
  let hwnd = winWindow()
  if hwnd == nil: return
  wvViews[i].pending = true
  discard wvEnv.call(3, proc (this: Com; parent: pointer; h: pointer): HRESULT {.stdcall.})(
    wvEnv, hwnd, newHandler(hkController, i))

proc onCapture(view: int; err: HRESULT) =
  ## A picture of the page came (PNG, into a stream in memory).
  if view < 0 or view >= wvViews.len: return
  template v: untyped = wvViews[view]
  let stream = v.capture
  v.capture = nil
  if stream == nil: return
  var h: pointer
  if err >= 0 and GetHGlobalFromStream(stream, addr h) >= 0 and h != nil:
    let n = int(GlobalSize(h))
    let p = GlobalLock(h)
    if p != nil and n > 0:
      var data = newString(n)
      copyMem(addr data[0], p, n)
      discard GlobalUnlock(h)
      let pic = try: decodePng(data) except CatchableError: nil
      if pic != nil: v.st.snapshot = pic
  release(stream)

proc onPermission(view: int; args: Com) =
  ## A page asks to use the camera, the microphone, the location or
  ## notifications: allowed only what the app allowed.
  if view < 0 or view >= wvViews.len or args == nil: return
  var kind: int32
  discard args.call(4, proc (this: Com; k: ptr int32): HRESULT {.stdcall.})(args, addr kind)
  let what = case kind
             of 1: some(wpMicrophone)
             of 2: some(wpCamera)
             of 3: some(wpLocation)
             of 4: some(wpNotifications)
             else: none(WebPermission)
  if what.isNone: return                         # (others: as WebView2 does)
  let ok = what.get in wvViews[view].permit
  discard args.call(7, proc (this: Com; s: int32): HRESULT {.stdcall.})(args, if ok: 1 else: 2)
  if not ok and what.get notin wvViews[view].st.asked: wvViews[view].st.asked.add what.get

# ---- in the app's thread ------------------------------------------------------------------------

proc webNativeAvailable*(): bool =
  ## Whether the system has a browser engine the kit can show pages in
  ## (WebView2 here, with the WinAPI driver's window).
  if winWindow() == nil: return false
  if wvEnvState == 0:
    wvEnvState = if startEnvironment(): 1 else: -1
  wvEnvState >= 1

proc viewFor(key: string): int =
  result = viewIndex(key)
  if result < 0:
    wvViews.add WinView(key: key, zoom: 0)
    result = wvViews.high

proc webNativeShow*(key: string; r: Rect; url: string; zoom: float) =
  ## The page `key` placed at `r` (window pixels), showing `url`; `zoom`
  ## (> 0) the size of its text and pictures.
  if not webNativeAvailable(): return
  let i = viewFor(key)
  template v: untyped = wvViews[i]
  v.wanted = WRect(left: int32(r.x), top: int32(r.y), right: int32(r.x + r.w),
                   bottom: int32(r.y + r.h))
  v.visible = true
  v.url = url
  # (WebView2 sizes pages for the screen's scale itself)
  let dpi = float(max(96'u32, GetDpiForWindow(winWindow()))) / 96.0
  v.zoom = if zoom > 0: zoom / dpi else: 1.0
  if v.controller == nil: makeView(i)
  else:
    placeView(v)
    loadView(v)

proc webNativeHide*(key: string) =
  ## Hides the page (kept with its place in history).
  let i = viewIndex(key)
  if i < 0: return
  wvViews[i].visible = false
  placeView(wvViews[i])

proc webNativeClose*(key: string) =
  ## Lets the page go.
  let i = viewIndex(key)
  if i < 0: return
  template v: untyped = wvViews[i]
  v.closed = true
  if v.controller != nil:
    discard v.controller.call(24, proc (this: Com): HRESULT {.stdcall.})(v.controller)
    release(v.webview)
    release(v.controller)
    v.webview = nil
    v.controller = nil

proc webNativeShutdown*() =
  ## Every page let go, before the app ends.
  for i in 0 ..< wvViews.len:
    if not wvViews[i].closed: webNativeClose(wvViews[i].key)

proc webNativeNav*(key: string; what: WebNav) =
  ## Back, Forward, Reload or Stop in the page.
  let i = viewIndex(key)
  if i < 0 or wvViews[i].webview == nil: return
  let wv = wvViews[i].webview
  if what == wnPrint:
    # (WebView2 prints as Edge does: its print preview)
    discard wv.call(29, proc (this: Com; js: WideCString; h: pointer): HRESULT {.stdcall.})(
      wv, newWideCString("window.print()"), newHandler(hkNone))
    return
  let slot = case what
             of wnBack: 40
             of wnForward: 41
             of wnReload: 31
             of wnStop: 43
             of wnPrint: 31
  discard wv.call(slot, proc (this: Com): HRESULT {.stdcall.})(wv)

proc webNativeRun*(key: string; js: string) =
  ## Runs `js` in the page (what it posts comes as notes).
  let i = viewIndex(key)
  if i < 0 or wvViews[i].webview == nil: return
  let wv = wvViews[i].webview
  discard wv.call(29, proc (this: Com; js: WideCString; h: pointer): HRESULT {.stdcall.})(
    wv, newWideCString(js), newHandler(hkNone))

proc webNativeSnap*(key: string) =
  ## A picture of the page (WebView2's CapturePreview, as PNG): in a later
  ## `webNativeTake`'s `snapshot`.
  let i = viewIndex(key)
  if i < 0 or wvViews[i].webview == nil or wvViews[i].capture != nil: return
  var stream: Com
  if CreateStreamOnHGlobal(nil, 1, addr stream) < 0 or stream == nil: return
  wvViews[i].capture = stream
  discard wvViews[i].webview.call(30, proc (this: Com; fmt: int32; s: Com; h: pointer): HRESULT {.stdcall.})(
    wvViews[i].webview, 0, stream, newHandler(hkCapture, i))      # CapturePreview: PNG

proc webNativePermit*(key: string; allowed: set[WebPermission]) =
  ## What the page may use when it asks (the rest is refused).
  wvViews[viewFor(key)].permit = allowed

proc webNativeAppUrl*(path: string): string =
  ## The address of the file `path` of the app's folder (`webNativeAppFolder`):
  ## WebView2 serves the folder as a host of its own.
  "https://app.local/" & path.strip(chars = {'/'})

proc webNativeAllow*(key: string; hosts: seq[string]) =
  ## The hosts the page may open (none: any).
  wvViews[viewFor(key)].hosts = hosts

proc webNativeTake*(key: string): WebNativeState =
  ## The page now, and what it posted since the last look.
  let i = viewIndex(key)
  if i < 0: return
  template v: untyped = wvViews[i]
  if v.webview != nil:
    var p: WideCString
    if v.webview.call(4, proc (this: Com; s: ptr WideCString): HRESULT {.stdcall.})(v.webview, addr p) >= 0:
      v.st.url = wstr(p)
    if v.webview.call(48, proc (this: Com; s: ptr WideCString): HRESULT {.stdcall.})(v.webview, addr p) >= 0:
      v.st.title = wstr(p)
    var b: WBOOL
    if v.webview.call(38, proc (this: Com; s: ptr WBOOL): HRESULT {.stdcall.})(v.webview, addr b) >= 0:
      v.st.canBack = b != 0
    if v.webview.call(39, proc (this: Com; s: ptr WBOOL): HRESULT {.stdcall.})(v.webview, addr b) >= 0:
      v.st.canForward = b != 0
  result = v.st
  v.st.notes.setLen(0)
  v.st.blocked.setLen(0)
  v.st.asked.setLen(0)
  v.st.snapshot = nil

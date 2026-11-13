## (included by webnative) macOS and iOS: WKWebView, WebKit as the system has
## it, loaded when the first page is shown and reached through the
## Objective-C runtime (nothing to link). Each page is a WKWebView put in the
## app's window over the widget; a class of the kit's made at run time hears
## what the page posts (`retro.post`) and decides where it may go.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[dynlib, os]
import native

type
  CGRect {.bycopy.} = object
    x, y, w, h: float64
  WkView = object
    key: string
    view: ObjcId
    url: string
    zoom: float
    hosts: seq[string]
    st: WebNativeState
    shown: bool
    permit: set[WebPermission]
  BlockDesc = object
    reserved, size: culong
  BlockLit = object
    ## (an Objective-C block of the kit's, with nothing captured: global)
    isa: pointer
    flags, reserved: int32
    invoke: pointer
    desc: ptr BlockDesc

var
  wkState = 0            ## 0 not tried, 1 ready, -1 none
  wkHandler: ObjcId      ## the kit's script message handler and navigation delegate
  wkScheme: ObjcId       ## the kit's app:// handler
  wkViews: seq[WkView]
  wkSnapKey: string      ## the page a picture is coming for
  wkSession: ObjcId      ## downloads (answers on the main queue)
  wkDownloads: seq[tuple[key, url: string]]
  nsGlobalBlock {.importc: "_NSConcreteGlobalBlock".}: pointer
  blockDesc = BlockDesc(reserved: 0, size: culong(sizeof(BlockLit)))

proc globalBlock(invoke: pointer): BlockLit =
  BlockLit(isa: addr nsGlobalBlock, flags: 1'i32 shl 28, invoke: invoke, desc: addr blockDesc)

# CoreGraphics: a picture (CGImage) into the kit's pixels
type CGRectC {.bycopy.} = object
  x, y, w, h: float64
var
  cgWidth, cgHeight: proc (img: pointer): csize_t {.cdecl.}
  cgSpace: proc (): pointer {.cdecl.}
  cgSpaceRelease, cgContextRelease: proc (p: pointer) {.cdecl.}
  cgContext: proc (data: pointer; w, h, bits, row: csize_t; space: pointer; info: uint32): pointer {.cdecl.}
  cgDraw: proc (ctx: pointer; r: CGRectC; img: pointer) {.cdecl.}

proc pictureOf(img: pointer): Bitmap =
  if img == nil: return nil
  if cgWidth == nil:
    let cg = loadLib("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    if cg == nil: return nil
    cgWidth = cast[typeof(cgWidth)](cg.symAddr("CGImageGetWidth"))
    cgHeight = cast[typeof(cgHeight)](cg.symAddr("CGImageGetHeight"))
    cgSpace = cast[typeof(cgSpace)](cg.symAddr("CGColorSpaceCreateDeviceRGB"))
    cgSpaceRelease = cast[typeof(cgSpaceRelease)](cg.symAddr("CGColorSpaceRelease"))
    cgContextRelease = cast[typeof(cgContextRelease)](cg.symAddr("CGContextRelease"))
    cgContext = cast[typeof(cgContext)](cg.symAddr("CGBitmapContextCreate"))
    cgDraw = cast[typeof(cgDraw)](cg.symAddr("CGContextDrawImage"))
  if cgWidth == nil or cgContext == nil or cgDraw == nil: return nil
  let w = int(cgWidth(img))
  let h = int(cgHeight(img))
  if w <= 0 or h <= 0 or w > 8192 or h > 8192: return nil
  result = newBitmap(w, h)
  let cs = cgSpace()
  # (premultiplied first, 32-bit little-endian: the kit's 0xAARRGGBB)
  let ctx = cgContext(addr result.px[0], csize_t(w), csize_t(h), 8, csize_t(w * 4), cs, 2 or (2 shl 12))
  if ctx != nil:
    cgDraw(ctx, CGRectC(x: 0, y: 0, w: float64(w), h: float64(h)), img)
    cgContextRelease(ctx)
  cgSpaceRelease(cs)
  for i in 0 ..< w * h: result.px[i] = result.px[i] or 0xFF000000'u32
  result.opaque = true

proc objc_allocateClassPair(super: pointer; name: cstring; extra: int): pointer {.importc, cdecl.}
proc objc_registerClassPair(cls: pointer) {.importc, cdecl.}
proc class_addMethod(cls, name, imp: pointer; types: cstring): bool {.importc, cdecl.}
proc class_addProtocol(cls, protocol: pointer): bool {.importc, cdecl.}
proc objc_getProtocol(name: cstring): pointer {.importc, cdecl.}

proc indexOf(view: ObjcId): int =
  for i, v in wkViews:
    if v.view == view: return i
  -1

proc indexOf(key: string): int =
  for i, v in wkViews:
    if v.key == key and v.view != nil: return i
  -1

proc urlOf(u: ObjcId): string =
  if u == nil: "" else: toNim(objcSend(ObjcId, u, "absoluteString"))

proc onScriptMessage(self, cmd, controller, message: ObjcId) {.cdecl.} =
  ## `retro.post(text)` in a page.
  let i = indexOf(objcSend(ObjcId, message, "webView"))
  if i < 0: return
  let body = objcSend(ObjcId, message, "body")
  if body != nil: wkViews[i].st.notes.add toNim(objcSend(ObjcId, body, "description"))

proc callDecision(handler: pointer; policy: int) =
  ## (WebKit's decision handler is a block: its function is 16 bytes in)
  let invoke = cast[ptr pointer](cast[uint](handler) + 16)[]
  cast[proc (blk: pointer; policy: int) {.cdecl.}](invoke)(handler, policy)

proc onDecide(self, cmd, webView, action: ObjcId; decision: pointer) {.cdecl.} =
  ## Where a page goes: an address it is not allowed is kept from it (the app
  ## is told); a new window opens in the same view.
  let i = indexOf(webView)
  let req = objcSend(ObjcId, action, "request")
  let url = urlOf(objcSend(ObjcId, req, "URL"))
  if i >= 0 and not allowedBy(wkViews[i].hosts, url):
    wkViews[i].st.blocked.add url
    callDecision(decision, 0)                                # cancel
    return
  if objcSend(ObjcId, action, "targetFrame") == nil:
    callDecision(decision, 0)
    discard objcSend(ObjcId, webView, "loadRequest:", req)
    return
  callDecision(decision, 1)                                  # allow

proc onSnapshot(blk, image, error: pointer) {.cdecl.} =
  ## takeSnapshotWithConfiguration:completionHandler:'s answer.
  let i = indexOf(wkSnapKey)
  wkSnapKey = ""
  if i < 0 or image == nil: return
  let cg = when defined(ios): objcSend(pointer, image, "CGImage")
           else: objcSend(pointer, image, "CGImageForProposedRect:context:hints:", pointer(nil),
                          pointer(nil), pointer(nil))
  let pic = pictureOf(cg)
  if pic != nil: wkViews[i].st.snapshot = pic

var snapBlock = globalBlock(cast[pointer](onSnapshot))

proc onMedia(self, cmd, webView, origin, frame: ObjcId; kind: int; decision: pointer) {.cdecl.} =
  ## A page asks for the camera or the microphone (macOS 12, iOS 15).
  let i = indexOf(webView)
  var wanted: set[WebPermission]
  case kind
  of 0: wanted = {wpCamera}
  of 1: wanted = {wpMicrophone}
  else: wanted = {wpCamera, wpMicrophone}
  let ok = i >= 0 and wanted <= wkViews[i].permit
  if not ok and i >= 0:
    for p in wanted - wkViews[i].permit:
      if p notin wkViews[i].st.asked: wkViews[i].st.asked.add p
  callDecision(decision, if ok: 1 else: 2)                   # grant, deny

proc onOpenPanel(self, cmd, webView, params, frame: ObjcId; done: pointer) {.cdecl.} =
  ## <input type=file> (macOS: WebKit leaves it to the app): the system's
  ## Open panel.
  let invoke = cast[ptr pointer](cast[uint](done) + 16)[]
  let answer = cast[proc (blk: pointer; urls: ObjcId) {.cdecl.}](invoke)
  when defined(ios):
    answer(done, nil)
  else:
    let panel = objcSend(ObjcId, objcClass("NSOpenPanel"), "openPanel")
    objcSend(void, panel, "setAllowsMultipleSelection:", objcSend(bool, params, "allowsMultipleSelection"))
    if respondsTo(params, "allowsDirectories"):
      objcSend(void, panel, "setCanChooseDirectories:", objcSend(bool, params, "allowsDirectories"))
    if objcSend(int, panel, "runModal") == 1: answer(done, objcSend(ObjcId, panel, "URLs"))
    else: answer(done, nil)

proc onDownloaded(blk, data, response, error: pointer) {.cdecl.} =
  ## A download's answer (on the main queue): written into Downloads.
  if response == nil: return
  let url = urlOf(objcSend(ObjcId, response, "URL"))
  var at = -1
  for k, d in wkDownloads:
    if d.url == url: at = k
  if at < 0: return
  let key = wkDownloads[at].key
  wkDownloads.delete(at)
  let i = indexOf(key)
  if i < 0: return
  var d = WebDownload(url: url, progress: 100)
  if data == nil or error != nil: d.failed = true
  else:
    let base = downloadsFolder()
    try: createDir(base) except OSError: discard
    var name = toNim(objcSend(ObjcId, response, "suggestedFilename"))
    if name.len == 0: name = "download"
    var file = base / name.extractFilename
    var n = 1
    let (dir, stem, ext) = file.splitFile
    while fileExists(file):
      file = dir / stem & " (" & $n & ")" & ext
      inc n
    d.file = file
    d.done = objcSend(bool, data, "writeToFile:atomically:", nsString(file), true)
    d.failed = not d.done
  wkViews[i].st.downloads.add d

var downloadBlock = globalBlock(cast[pointer](onDownloaded))

proc onResponse(self, cmd, webView, response: ObjcId; decision: pointer) {.cdecl.} =
  ## What a page cannot show (an archive, a program) is downloaded.
  if objcSend(bool, response, "canShowMIMEType"):
    callDecision(decision, 1)
    return
  callDecision(decision, 0)
  let i = indexOf(webView)
  let r = objcSend(ObjcId, response, "response")
  let u = objcSend(ObjcId, r, "URL")
  if i < 0 or u == nil: return
  if wkSession == nil:
    wkSession = objcSend(ObjcId, objcClass("NSURLSession"), "sessionWithConfiguration:delegate:delegateQueue:",
                         objcSend(ObjcId, objcClass("NSURLSessionConfiguration"), "defaultSessionConfiguration"),
                         ObjcId(nil), objcSend(ObjcId, objcClass("NSOperationQueue"), "mainQueue"))
    objcSend(void, wkSession, "retain")
  wkDownloads.add (wkViews[i].key, urlOf(u))
  wkViews[i].st.downloads.add WebDownload(url: urlOf(u))
  let task = objcSend(ObjcId, wkSession, "dataTaskWithURL:completionHandler:", u, addr downloadBlock)
  objcSend(void, task, "resume")

proc onSchemeStart(self, cmd, webView, task: ObjcId) {.cdecl.} =
  ## app://local/PATH: a file of the app's folder.
  let url = objcSend(ObjcId, objcSend(ObjcId, task, "request"), "URL")
  let file = appFile(toNim(objcSend(ObjcId, url, "path")))
  let data = if file.len > 0: objcSend(ObjcId, objcClass("NSData"), "dataWithContentsOfFile:", nsString(file))
             else: nil
  if data == nil:
    objcSend(void, task, "didFailWithError:",
             objcSend(ObjcId, objcClass("NSError"), "errorWithDomain:code:userInfo:", nsString("retro"),
                      404, ObjcId(nil)))
    return
  let resp = objcSend(ObjcId, objcSend(ObjcId, objcClass("NSURLResponse"), "alloc"),
                      "initWithURL:MIMEType:expectedContentLength:textEncodingName:", url,
                      nsString(mimeOf(file)), objcSend(int, data, "length"), ObjcId(nil))
  objcSend(void, task, "didReceiveResponse:", resp)
  objcSend(void, task, "didReceiveData:", data)
  objcSend(void, task, "didFinish")
  objcSend(void, resp, "release")

proc onSchemeStop(self, cmd, webView, task: ObjcId) {.cdecl.} = discard

proc loadWebKit(): bool =
  ## WebKit, and the kit's class that hears its pages.
  if loadLib("/System/Library/Frameworks/WebKit.framework/WebKit") == nil: return false
  if objcClass("WKWebView") == nil: return false
  var cls = objcClass("RetroWebHandler")
  if cls == nil:
    cls = objc_allocateClassPair(objcClass("NSObject"), "RetroWebHandler", 0)
    if cls == nil: return false
    discard class_addMethod(cls, sel("userContentController:didReceiveScriptMessage:"),
                            cast[pointer](onScriptMessage), "v@:@@")
    discard class_addMethod(cls, sel("webView:decidePolicyForNavigationAction:decisionHandler:"),
                            cast[pointer](onDecide), "v@:@@@?")
    discard class_addMethod(cls, sel("webView:decidePolicyForNavigationResponse:decisionHandler:"),
                            cast[pointer](onResponse), "v@:@@@?")
    discard class_addMethod(cls,
      sel("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"),
      cast[pointer](onMedia), "v@:@@@q@?")
    discard class_addMethod(cls, sel("webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:"),
                            cast[pointer](onOpenPanel), "v@:@@@@?")
    for p in ["WKScriptMessageHandler", "WKNavigationDelegate", "WKUIDelegate"]:
      let proto = objc_getProtocol(cstring(p))
      if proto != nil: discard class_addProtocol(cls, proto)
    objc_registerClassPair(cls)
  var sc = objcClass("RetroSchemeHandler")
  if sc == nil:
    sc = objc_allocateClassPair(objcClass("NSObject"), "RetroSchemeHandler", 0)
    if sc == nil: return false
    discard class_addMethod(sc, sel("webView:startURLSchemeTask:"), cast[pointer](onSchemeStart), "v@:@@")
    discard class_addMethod(sc, sel("webView:stopURLSchemeTask:"), cast[pointer](onSchemeStop), "v@:@@")
    let proto = objc_getProtocol("WKURLSchemeHandler")
    if proto != nil: discard class_addProtocol(sc, proto)
    objc_registerClassPair(sc)
  wkHandler = objcSend(ObjcId, objcSend(ObjcId, cls, "alloc"), "init")
  wkScheme = objcSend(ObjcId, objcSend(ObjcId, sc, "alloc"), "init")
  wkHandler != nil

proc hostView(): ObjcId =
  ## The view the pages go into: the window's content (macOS), its root
  ## view (iOS).
  when defined(ios):
    let app = objcSend(ObjcId, objcClass("UIApplication"), "sharedApplication")
    var win = objcSend(ObjcId, app, "keyWindow")
    if win == nil:
      let wins = objcSend(ObjcId, app, "windows")
      if wins != nil and objcSend(int, wins, "count") > 0: win = objcSend(ObjcId, wins, "firstObject")
    if win == nil: return nil
    let root = objcSend(ObjcId, win, "rootViewController")
    if root != nil: objcSend(ObjcId, root, "view") else: win
  else:
    let app = objcSend(ObjcId, objcClass("NSApplication"), "sharedApplication")
    var win = objcSend(ObjcId, app, "mainWindow")
    if win == nil:
      let wins = objcSend(ObjcId, app, "windows")
      if wins != nil and objcSend(int, wins, "count") > 0: win = objcSend(ObjcId, wins, "firstObject")
    if win == nil: nil else: objcSend(ObjcId, win, "contentView")

proc frameFor(host: ObjcId; r: Rect): CGRect =
  ## Window pixels as the host view's points (macOS counts from the bottom
  ## unless the view is flipped).
  when defined(ios):
    let scale = objcSend(float64, objcSend(ObjcId, objcClass("UIScreen"), "mainScreen"), "scale")
    let k = if scale > 0: scale else: 1.0
    CGRect(x: float(r.x) / k, y: float(r.y) / k, w: float(r.w) / k, h: float(r.h) / k)
  else:
    let win = objcSend(ObjcId, host, "window")
    let scale = if win != nil: objcSend(float64, win, "backingScaleFactor") else: 1.0
    let k = if scale > 0: scale else: 1.0
    let b = objcSend(CGRect, host, "bounds")
    var f = CGRect(x: float(r.x) / k, y: float(r.y) / k, w: float(r.w) / k, h: float(r.h) / k)
    if not objcSend(bool, host, "isFlipped"): f.y = b.h - f.y - f.h
    f

proc loadInto(v: var WkView; url: string) =
  v.url = url
  v.st.progress = 0
  if url.startsWith("html:"):
    discard objcSend(ObjcId, v.view, "loadHTMLString:baseURL:", nsString(url[5 .. ^1]), ObjcId(nil))
  elif url.len > 0 and url[0] == '/':
    let file = objcSend(ObjcId, objcClass("NSURL"), "fileURLWithPath:", nsString(url))
    let dir = objcSend(ObjcId, objcClass("NSURL"), "fileURLWithPath:", nsString(url.parentDir))
    discard objcSend(ObjcId, v.view, "loadFileURL:allowingReadAccessToURL:", file, dir)
  else:
    let u = objcSend(ObjcId, objcClass("NSURL"), "URLWithString:", nsString(url))
    if u == nil: return
    let req = objcSend(ObjcId, objcClass("NSURLRequest"), "requestWithURL:", u)
    discard objcSend(ObjcId, v.view, "loadRequest:", req)

var
  wkRules: ObjcId        ## the block list, compiled (a WKContentRuleList), or nil
  wkRulesAsked = 0       ## the block list asked to be compiled

proc rulesInto(view: ObjcId) =
  ## (the compiled block list for `view`, in place of the one it had)
  if view == nil: return
  let ucc = objcSend(ObjcId, objcSend(ObjcId, view, "configuration"), "userContentController")
  if ucc == nil or not respondsTo(ucc, "addContentRuleList:"): return
  objcSend(void, ucc, "removeAllContentRuleLists")
  if wkRules != nil: objcSend(void, ucc, "addContentRuleList:", wkRules)

proc onRules(blk, list, error: pointer) {.cdecl.} =
  ## compileContentRuleListForIdentifier:...'s answer: every view gets it.
  if list == nil: return
  if wkRules != nil: objcSend(void, wkRules, "release")
  wkRules = cast[ObjcId](list)
  objcSend(void, wkRules, "retain")
  for v in wkViews: rulesInto(v.view)

var rulesBlock = globalBlock(cast[pointer](onRules))

proc askRules() =
  ## (the block list compiled into WebKit's content rules, when it changed:
  ## macOS 10.13, iOS 11)
  let b = blockListNow()
  if b.gen == wkRulesAsked: return
  wkRulesAsked = b.gen
  if b.hosts.len + b.patterns.len == 0:
    if wkRules != nil: objcSend(void, wkRules, "release")
    wkRules = nil
    for v in wkViews: rulesInto(v.view)
    return
  let store = objcSend(ObjcId, objcClass("WKContentRuleListStore"), "defaultStore")
  if store == nil: return
  objcSend(void, store, "compileContentRuleListForIdentifier:encodedContentRuleList:completionHandler:",
           nsString("retro-blocked"), nsString(contentRules(b.hosts, b.patterns, b.spared)), addr rulesBlock)

proc makeView(host: ObjcId; frame: CGRect; key: string): ObjcId =
  let config = objcSend(ObjcId, objcSend(ObjcId, objcClass("WKWebViewConfiguration"), "alloc"), "init")
  let ucc = objcSend(ObjcId, config, "userContentController")
  objcSend(void, ucc, "addScriptMessageHandler:name:", wkHandler, nsString("retro"))
  let script = objcSend(ObjcId, objcSend(ObjcId, objcClass("WKUserScript"), "alloc"),
                        "initWithSource:injectionTime:forMainFrameOnly:",
                        nsString(shimFor("window.webkit.messageHandlers.retro.postMessage") &
                                 startScriptOf(key)), 0, true)
  objcSend(void, ucc, "addUserScript:", script)
  objcSend(void, script, "release")
  if wkRules != nil and respondsTo(ucc, "addContentRuleList:"):
    objcSend(void, ucc, "addContentRuleList:", wkRules)
  # a page's element in full screen (a video's button): WebKit's own (macOS
  # 12.3, iOS 16.4)
  let prefs = objcSend(ObjcId, config, "preferences")
  if prefs != nil and respondsTo(prefs, "setElementFullscreenEnabled:"):
    objcSend(void, prefs, "setElementFullscreenEnabled:", true)
  # the app's own folder at app://local/ (macOS 10.13, iOS 11)
  if wkScheme != nil and respondsTo(config, "setURLSchemeHandler:forURLScheme:"):
    objcSend(void, config, "setURLSchemeHandler:forURLScheme:", wkScheme, nsString("app"))
  result = objcSend(ObjcId, objcSend(ObjcId, objcClass("WKWebView"), "alloc"),
                    "initWithFrame:configuration:", frame, config)
  objcSend(void, config, "release")
  objcSend(void, result, "setNavigationDelegate:", wkHandler)
  objcSend(void, result, "setUIDelegate:", wkHandler)
  # (Safari's Web Inspector reaches it only when asked for: macOS 13.3, iOS 16.4)
  if webToolsWanted() and respondsTo(result, "setInspectable:"):
    objcSend(void, result, "setInspectable:", true)
  objcSend(void, host, "addSubview:", result)

# ---- in the app's thread ------------------------------------------------------------------------

proc webNativeAvailable*(): bool =
  ## Whether the system has a browser engine the kit can show pages in
  ## (WKWebView here).
  if wkState == 0: wkState = if loadWebKit(): 1 else: -1
  wkState == 1 and hostView() != nil

proc webNativeShow*(key: string; r: Rect; url: string; zoom: float) =
  ## The page `key` placed at `r` (window pixels), showing `url`; `zoom`
  ## (> 0) the size of its text and pictures.
  if not webNativeAvailable(): return
  autoreleasePool:
    askRules()
    let host = hostView()
    let frame = frameFor(host, r)
    var i = indexOf(key)
    if i < 0:
      # (one made by `webNativePermit` before the page: its view now)
      for k, v in wkViews:
        if v.key == key and v.view == nil: i = k
      if i < 0:
        wkViews.add WkView(key: key)
        i = wkViews.high
      wkViews[i].view = makeView(host, frame, key)
    else:
      objcSend(void, wkViews[i].view, "setFrame:", frame)
    objcSend(void, wkViews[i].view, "setHidden:", false)
    wkViews[i].shown = true
    # (WebKit sizes pages for the screen's scale itself; this is the app's zoom)
    let scale = when defined(ios): objcSend(float64, objcSend(ObjcId, objcClass("UIScreen"), "mainScreen"), "scale")
                else: objcSend(float64, objcSend(ObjcId, host, "window"), "backingScaleFactor")
    let z = if zoom > 0: zoom / max(1.0, scale) else: 1.0
    if z != wkViews[i].zoom and respondsTo(wkViews[i].view, "setPageZoom:"):
      wkViews[i].zoom = z
      objcSend(void, wkViews[i].view, "setPageZoom:", z)
    if url != wkViews[i].url: wkViews[i].loadInto(url)

proc webNativeHide*(key: string) =
  ## Hides the page (kept with its place in history).
  let i = indexOf(key)
  if i < 0: return
  objcSend(void, wkViews[i].view, "setHidden:", true)
  wkViews[i].shown = false

proc webNativeClose*(key: string) =
  ## Lets the page go.
  let i = indexOf(key)
  if i < 0: return
  objcSend(void, wkViews[i].view, "removeFromSuperview")
  objcSend(void, wkViews[i].view, "release")
  wkViews[i].view = nil

proc webNativeSuspend*(key: string) = discard
  ## (WebKit slows a hidden page's timers by itself)

proc onDataRemoved(b: pointer) {.cdecl.} = discard
var dataBlock = globalBlock(cast[pointer](onDataRemoved))

proc webNativeClearData*() =
  ## Clears what WebKit keeps of the pages (the default WKWebsiteDataStore):
  ## cookies, caches, the sites' storage.
  if not webNativeAvailable(): return
  autoreleasePool:
    let store = objcSend(ObjcId, objcClass("WKWebsiteDataStore"), "defaultDataStore")
    let kinds = objcSend(ObjcId, objcClass("WKWebsiteDataStore"), "allWebsiteDataTypes")
    let since = objcSend(ObjcId, objcClass("NSDate"), "distantPast")
    if store != nil and kinds != nil and since != nil:
      objcSend(void, store, "removeDataOfTypes:modifiedSince:completionHandler:", kinds, since,
               addr dataBlock)

proc webNativeShutdown*() =
  ## Every page let go, before the app ends.
  for i in 0 ..< wkViews.len:
    if wkViews[i].view != nil: webNativeClose(wkViews[i].key)

proc webNativeNav*(key: string; what: WebNav) =
  ## Back, Forward, Reload or Stop in the page.
  let i = indexOf(key)
  if i < 0: return
  let v = wkViews[i].view
  case what
  of wnBack: discard objcSend(ObjcId, v, "goBack")
  of wnForward: discard objcSend(ObjcId, v, "goForward")
  of wnReload: discard objcSend(ObjcId, v, "reload")
  of wnStop: objcSend(void, v, "stopLoading")
  of wnPrint:
    autoreleasePool:
      when defined(ios):
        let pc = objcSend(ObjcId, objcClass("UIPrintInteractionController"), "sharedPrintController")
        objcSend(void, pc, "setPrintFormatter:", objcSend(ObjcId, v, "viewPrintFormatter"))
        discard objcSend(bool, pc, "presentAnimated:completionHandler:", true, pointer(nil))
      else:
        if respondsTo(v, "printOperationWithPrintInfo:"):
          let op = objcSend(ObjcId, v, "printOperationWithPrintInfo:",
                            objcSend(ObjcId, objcClass("NSPrintInfo"), "sharedPrintInfo"))
          objcSend(void, objcSend(ObjcId, op, "view"), "setFrame:", objcSend(CGRect, v, "bounds"))
          objcSend(void, op, "runOperationModalForWindow:delegate:didRunSelector:contextInfo:",
                   objcSend(ObjcId, v, "window"), ObjcId(nil), pointer(nil), pointer(nil))

proc webNativeRun*(key: string; js: string) =
  ## Runs `js` in the page (what it posts comes as notes).
  let i = indexOf(key)
  if i < 0: return
  autoreleasePool:
    objcSend(void, wkViews[i].view, "evaluateJavaScript:completionHandler:", nsString(js),
             pointer(nil))

proc webNativeAllow*(key: string; hosts: seq[string]) =
  ## The hosts the page may open (none: any).
  let i = indexOf(key)
  if i >= 0: wkViews[i].hosts = hosts

proc webNativeSnap*(key: string) =
  ## A picture of the page (WebKit's snapshot): in a later `webNativeTake`'s
  ## `snapshot`.
  let i = indexOf(key)
  if i < 0 or wkSnapKey.len > 0 or not respondsTo(wkViews[i].view, "takeSnapshotWithConfiguration:completionHandler:"):
    return
  wkSnapKey = key
  objcSend(void, wkViews[i].view, "takeSnapshotWithConfiguration:completionHandler:", ObjcId(nil),
           addr snapBlock)

proc webNativePermit*(key: string; allowed: set[WebPermission]) =
  ## What the page may use when it asks (the rest is refused).
  let i = indexOf(key)
  if i >= 0: wkViews[i].permit = allowed
  else: wkViews.add WkView(key: key, permit: allowed)

proc webNativeAppUrl*(path: string): string =
  ## The address of the file `path` of the app's folder (`webNativeAppFolder`).
  "app://local/" & path.strip(chars = {'/'})

proc webNativeTake*(key: string): WebNativeState =
  ## The page now, and what it posted since the last look.
  let i = indexOf(key)
  if i < 0: return
  autoreleasePool:
    let v = wkViews[i].view
    wkViews[i].st.url = urlOf(objcSend(ObjcId, v, "URL"))
    wkViews[i].st.title = toNim(objcSend(ObjcId, v, "title"))
    wkViews[i].st.progress = clamp(int(objcSend(float64, v, "estimatedProgress") * 100), 0, 100)
    if not objcSend(bool, v, "isLoading"): wkViews[i].st.progress = 100
    wkViews[i].st.canBack = objcSend(bool, v, "canGoBack")
    wkViews[i].st.canForward = objcSend(bool, v, "canGoForward")
    # (macOS 13 and later: entering or in full screen)
    if respondsTo(v, "fullscreenState"):
      wkViews[i].st.fullscreen = objcSend(int, v, "fullscreenState") in [1, 2]
  result = wkViews[i].st
  wkViews[i].st.notes.setLen(0)
  wkViews[i].st.blocked.setLen(0)
  wkViews[i].st.asked.setLen(0)
  wkViews[i].st.snapshot = nil
  var keep: seq[WebDownload]
  for d in wkViews[i].st.downloads:
    if not (d.done or d.failed): keep.add d
  wkViews[i].st.downloads = keep

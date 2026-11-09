## The system's own browser engine for `webView` (in `htmlview`): what the
## app sees of it is the same everywhere -- a page placed over the widget,
## its address, title and loading, Back and Forward, JavaScript run in it,
## messages from the page (`retro.post(text)` in its scripts) and to it (a
## `retro` event on its `window`), the addresses it may open, its zoom.
##
## - Android, in an APK: the phone's WebView (`tools/android/RetroWeb.java`,
##   reached through `systemCall`).
## - Linux and BSD (the X11 driver, Termux:X11 too): WebKitGTK
##   (`libwebkit2gtk-4.1`), loaded when the first page is shown -- nothing to
##   link; without it there is no system engine. It runs in a thread of its
##   own (GTK's), its window put inside the app's.
## - Windows (the WinAPI driver): WebView2, the Edge engine Windows 10 and 11
##   have, found where Windows keeps it (WebView2Loader.dll is used when it is
##   beside the program, and needed by nothing).
## - macOS and iOS (the Cocoa and UIKit drivers): WKWebView (WebKit, part of
##   the system), reached through the Objective-C runtime.
##
## Other drivers (SDL, GTK 4, Siwin) have none: `webView` shows pages the
## kit's way there.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, uri, os, locks]
import uirelays/target
import uirelays/[coords, services]
import gfx

type
  WebNav* = enum
    ## What `webNativeNav` asks of a page.
    wnBack, wnForward, wnReload, wnStop, wnPrint
  WebPermission* = enum
    ## What a page may ask to use (`webPermit`).
    wpCamera, wpMicrophone, wpLocation, wpNotifications
  WebDownload* = object
    ## A file a page downloads (into the user's Downloads folder).
    url*: string
    file*: string               ## where it goes ("" until it is known)
    progress*: int              ## 0..100
    done*, failed*: bool
  WebNativeState* = object
    ## A page as the system's engine has it now.
    url*, title*: string
    progress*: int              ## 0..100
    canBack*, canForward*: bool
    backOut*: bool              ## (Android) Back with no page before
    notes*: seq[string]         ## what the page posted since the last look
                                ## (`retro.post`; "\1id\1json": a script's answer)
    blocked*: seq[string]       ## addresses it was kept from (not allowed)
    focused*: bool              ## it has the keyboard
    asked*: seq[WebPermission]  ## what it asked to use and was not allowed
    downloads*: seq[WebDownload]  ## files it downloads (the state of each, as it changes)
    snapshot*: Bitmap           ## a new picture of the page (`webNativeSnap`), else nil

const
  NoSystemDriver = defined(sdl2) or defined(sdl3) or defined(gtk4) or
    defined(features.uirelays.siwin) or defined(features.uirelays.figDrawSiwin) or
    defined(figDrawSiwin) or defined(features.uirelays.figDrawWindy) or
    defined(figDrawWindy) or defined(features.uirelays.figDrawSiwinGpu) or
    defined(wayland) or           # (WebKitGTK's windows go inside an X11 window)
    defined(wasm)                 # (a browser page: its iframes, `webnative_web`)
  WebGtk = not androidApp and not NoSystemDriver and
    (defined(linux) or defined(freebsd) or defined(openbsd) or defined(netbsd) or
     defined(dragonfly) or defined(android))
  WebWin = defined(windows) and not NoSystemDriver
  WebWk = (defined(macosx) or defined(ios)) and not NoSystemDriver

proc allowedBy*(hosts: openArray[string]; url: string): bool =
  ## Whether `url` may be opened in a page that is allowed `hosts` (none:
  ## anything): its host is one of them or under one ("nim-lang.org" lets
  ## "forum.nim-lang.org" in). Local pages, the app's own (`webNativeAppUrl`),
  ## `about:`, `data:` and `blob:` always may.
  if hosts.len == 0: return true
  let l = url.toLowerAscii
  if l.startsWith("file:") or l.startsWith("about:") or l.startsWith("data:") or
     l.startsWith("blob:") or l.startsWith("javascript:") or l.startsWith("app:") or
     l.startsWith("https://app.local/") or
     l.startsWith("https://appassets.androidplatform.net/app/"): return true
  let host = try: parseUri(url).hostname.toLowerAscii except CatchableError: ""
  if host.len == 0: return true
  for h in hosts:
    let x = h.toLowerAscii.strip
    if x.len > 0 and (host == x or host.endsWith("." & x)): return true
  false

proc fileUrl*(path: string): string =
  ## A local path as a `file://` address.
  var p = path.replace('\\', '/')
  if p.len >= 2 and p[1] == ':': p = "/" & p          # C:/... -> /C:/...
  result = "file://"
  for c in p:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '/', '-', '_', '.', '~', ':'}: result.add c
    else: result.add '%' & toHex(ord(c), 2)

var
  appFolderLock: Lock
  appFolder {.guard: appFolderLock.}: string
initLock appFolderLock

proc webNativeAppFolder*(folder: string) =
  ## The folder whose files pages get at the app's own address
  ## (`webNativeAppUrl`): an app's web part, shipped with it.
  withLock appFolderLock: appFolder = folder

proc appFolderNow(): string {.used, gcsafe.} =
  {.cast(gcsafe).}:
    withLock appFolderLock: result = appFolder

proc appFile(path: string): string {.used, gcsafe.} =
  ## The file of the app's folder an address's path names ("": none, or
  ## one outside it).
  let base = appFolderNow()
  if base.len == 0: return ""
  var p = decodeUrl(path)
  let q = p.find({'?', '#'})
  if q >= 0: p = p[0 ..< q]
  p = p.strip(leading = true, trailing = false, chars = {'/'})
  if p.len == 0: p = "index.html"
  for part in p.split('/'):
    if part == "..": return ""
  result = base / p
  if dirExists(result): result = result / "index.html"
  if not fileExists(result): result = ""

proc mimeOf*(path: string): string =
  ## The MIME type of a file the app's address serves, by its extension.
  case path.splitFile.ext.toLowerAscii
  of ".html", ".htm": "text/html"
  of ".js", ".mjs": "text/javascript"
  of ".css": "text/css"
  of ".json", ".map": "application/json"
  of ".svg": "image/svg+xml"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".webp": "image/webp"
  of ".ico": "image/x-icon"
  of ".woff": "font/woff"
  of ".woff2": "font/woff2"
  of ".ttf": "font/ttf"
  of ".otf": "font/otf"
  of ".wasm": "application/wasm"
  of ".mp4": "video/mp4"
  of ".webm": "video/webm"
  of ".mp3": "audio/mpeg"
  of ".ogg": "audio/ogg"
  of ".wav": "audio/wav"
  of ".pdf": "application/pdf"
  of ".txt", ".md": "text/plain; charset=utf-8"
  of ".xml": "application/xml"
  else: "application/octet-stream"

proc downloadsFolder(): string {.used.} =
  result = standardFolder("downloads")
  if result.len == 0: result = getHomeDir() / "Downloads"

proc webToolsWanted(): bool {.used.} =
  ## The engine's developer tools (Inspect Element...) are offered: only with
  ## $RETRO_WEB_TOOLS=1, while making an app.
  getEnv("RETRO_WEB_TOOLS") == "1"

proc shimFor(post: string): string {.used.} =
  ## The script put in every page before its own: `retro.post(text)`.
  "(function(){if(window.retro&&window.retro.post)return;" &
    "window.retro={post:function(m){" & post & "(String(m));}};})();"

# ---- per system -------------------------------------------------------------------------------
#
# (an Android app's WebView is reached through `systemCall` by `htmlview`
#  itself: "web.show", "web.info"... -- the protocol tests fake)

when androidApp:
  proc webNativeAvailable*(): bool = false
    ## Whether the system has a browser engine the kit can show pages in.
  proc webNativeShow*(key: string; r: Rect; url: string; zoom: float) = discard
  proc webNativeHide*(key: string) = discard
  proc webNativeClose*(key: string) = discard
  proc webNativeNav*(key: string; what: WebNav) = discard
  proc webNativeRun*(key: string; js: string) = discard
  proc webNativeAllow*(key: string; hosts: seq[string]) = discard
  proc webNativeTake*(key: string): WebNativeState = discard
  proc webNativeShutdown*() = discard
  proc webNativeSnap*(key: string) = discard
  proc webNativePermit*(key: string; allowed: set[WebPermission]) = discard
  proc webNativeAppUrl*(path: string): string =
    ## (the WebView's own address for an app's files)
    "https://appassets.androidplatform.net/app/" & path.strip(chars = {'/'})

# ---- a browser page: iframes over the canvas -------------------------------------------------------

elif defined(wasm):
  import std/tables
  include webnative_web

# ---- Linux and BSD: WebKitGTK in a thread of its own --------------------------------------------

elif WebGtk:
  include webnative_gtk

# ---- Windows: WebView2 ----------------------------------------------------------------------------

elif WebWin:
  include webnative_win

# ---- macOS and iOS: WKWebView ---------------------------------------------------------------------

elif WebWk:
  include webnative_wk

else:
  proc webNativeAvailable*(): bool = false
  proc webNativeShow*(key: string; r: Rect; url: string; zoom: float) = discard
  proc webNativeHide*(key: string) = discard
  proc webNativeClose*(key: string) = discard
  proc webNativeNav*(key: string; what: WebNav) = discard
  proc webNativeRun*(key: string; js: string) = discard
  proc webNativeAllow*(key: string; hosts: seq[string]) = discard
  proc webNativeTake*(key: string): WebNativeState = discard
  proc webNativeShutdown*() = discard
  proc webNativeSnap*(key: string) = discard
  proc webNativePermit*(key: string; allowed: set[WebPermission]) = discard
  proc webNativeAppUrl*(path: string): string = "app://local/" & path.strip(chars = {'/'})

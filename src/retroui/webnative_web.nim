## (included by webnative) In a browser page (`-d:wasm`): a page is an
## <iframe> the page (`retro.js`) puts over the canvas where the view is.
## What it can say back depends on where it comes from: the app's own pages
## (`webNativeAppUrl`, the same origin) get `retro.post` and are run scripts
## in, have their title and history read; another site's pages are shown
## and navigated, and may post with `parent.postMessage({retro: text},
## "*")`. A picture of a page under a menu cannot be taken from a browser
## (`snapshot` stays nil: the view's place is drawn plain while covered).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

proc rwWebShow(key, url: cstring; x, y, w, h: cint; zoom: cdouble; allow: cint) {.importc: "rw_web_show", cdecl.}
proc rwWebHide(key: cstring) {.importc: "rw_web_hide", cdecl.}
proc rwWebClose(key: cstring) {.importc: "rw_web_close", cdecl.}
proc rwWebNav(key: cstring; what: cint) {.importc: "rw_web_nav", cdecl.}
proc rwWebRun(key, js: cstring) {.importc: "rw_web_run", cdecl.}
proc rwWebAllow(key, hosts: cstring) {.importc: "rw_web_allow", cdecl.}
proc rwWebState(key: cstring; buf: pointer; cap: cint): cint {.importc: "rw_web_state", cdecl.}

var webPermits: Table[string, set[WebPermission]]

proc webNativeAvailable*(): bool = true
  ## Whether the system has a browser engine the kit can show pages in (a
  ## browser: always).

proc webNativeShow*(key: string; r: Rect; url: string; zoom: float) =
  ## The page `key` placed at `r` (window pixels), showing `url`.
  var allow = 0
  for p in webPermits.getOrDefault(key): allow = allow or (1 shl ord(p))
  rwWebShow(cstring(key), cstring(url), cint(r.x), cint(r.y), cint(r.w), cint(r.h),
            cdouble(zoom), cint(allow))

proc webNativeHide*(key: string) = rwWebHide(cstring(key))
  ## The page out of sight (kept).
proc webNativeClose*(key: string) = rwWebClose(cstring(key))
  ## The page let go of.
proc webNativeNav*(key: string; what: WebNav) = rwWebNav(cstring(key), cint(ord(what)))
  ## Back, forward, reload, stop, print.
proc webNativeRun*(key: string; js: string) = rwWebRun(cstring(key), cstring(js))
  ## A script run in the page (the app's own pages).
proc webNativeAllow*(key: string; hosts: seq[string]) =
  ## The sites the page's links may open in it (the others in a new tab).
  rwWebAllow(cstring(key), cstring(hosts.join("\n")))
proc webNativeSnap*(key: string) = discard
  ## (no picture of a page can be taken in a browser)
proc webNativePermit*(key: string; allowed: set[WebPermission]) = webPermits[key] = allowed
  ## What the page may use (its iframe's `allow`).
proc webNativeAppUrl*(path: string): string =
  ## The address of the file `path` of the app's own web part (`app/` beside
  ## the program).
  "app/" & path.strip(chars = {'/'})
proc webNativeShutdown*() = discard
proc webNativeClearData*() = discard
  ## (a browser page's frames: the browser keeps their data)

proc webNativeTake*(key: string): WebNativeState =
  ## The page now, and what it posted since the last look: the page's side
  ## writes it as lines (url, title, progress, back, forward, then a note a
  ## line, each "\1"-free).
  var buf = newString(4096)
  var n = rwWebState(cstring(key), addr buf[0], cint(buf.len))
  if n > buf.len:
    buf.setLen(n)
    n = rwWebState(cstring(key), addr buf[0], cint(buf.len))
  if n <= 0: return
  buf.setLen(n)
  let lines = buf.split('\1')
  if lines.len < 5: return
  result.url = lines[0]
  result.title = lines[1]
  result.progress = try: parseInt(lines[2]) except ValueError: 0
  result.canBack = lines[3] == "1"
  result.canForward = lines[4] == "1"
  for i in 5 ..< lines.len:
    if lines[i].startsWith("\2"): result.blocked.add lines[i][1 .. ^1]
    elif lines[i].len > 0: result.notes.add lines[i]

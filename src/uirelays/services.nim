# Platform services as relays: where an app keeps its files, opening a
# link in the browser or a file in its app, the standard folders, storage
# permission, decoding photos, which platform this is. The defaults below
# serve the desktops; the Android and iOS drivers replace the ones their
# platform does differently.

import std/[os, strutils]
import target
when not defined(windows) and not androidApp and not defined(ios):
  import std/osproc

type
  SystemRelays* = object
    dataDir*: proc (app: string): string {.nimcall.}
      ## A folder only this app writes to, created on demand; `app` its name
      ## (`folderName` makes it one the system takes). A phone's app has the
      ## one folder of its own whatever the name: nothing else is in it.
    openUrl*: proc (url: string): bool {.nimcall.}
      ## Open `url` (https:, mailto:, a file) with the system's handler.
    platform*: proc (): string {.nimcall.}
    openFile*: proc (path: string; share: bool): bool {.nimcall.}
      ## Open a file in the app the system has for it, or (`share`) offer
      ## it to other apps. False when nothing could take it.
    places*: proc (): seq[tuple[name, path: string]] {.nimcall.}
      ## The standard folders: home, documents, downloads, pictures... and
      ## the drives, SD cards or volumes.
    storageAccess*: proc (): bool {.nimcall.}
      ## The app may read and write the shared storage (Android asks).
    requestStorageAccess*: proc () {.nimcall.}
      ## Ask the user for that (Android opens its settings page).
    decodeImage*: proc (path: string; maxW, maxH: int):
                       tuple[w, h: int; px: seq[uint32]] {.nimcall.}
      ## A picture (JPEG, WebP, HEIC...) the platform decodes, about
      ## `maxW` x `maxH` or larger, upright, 0xAARRGGBB; w = 0 if it cannot.
    minimize*: proc (): bool {.nimcall.}
      ## Send the app to the background; false where apps cannot.
    call*: proc (name, arg: string): string {.gcsafe, nimcall.}
      ## Something only the platform's own side can do, by name (Android:
      ## the activity's `uirelaysCall(name, arg)`, an app's own Java code);
      ## "\0" when it failed or is not there.

  WindowPart* = enum
    ## A part of a window whose frame the app draws itself: what the mouse
    ## took hold of, as Windows' WM_NCHITTEST names it.
    wpClient,        ## the inside, the app's own
    wpCaption,       ## the title bar: it moves the window
    wpLeft, wpRight, wpTop, wpBottom,
    wpTopLeft, wpTopRight, wpBottomLeft, wpBottomRight

  FrameRelays* = object
    ## The window's frame, for an app that draws its own title bar and
    ## borders in a window without the system's. Every relay is optional:
    ## nil where the platform has no such thing, and the wrappers below then
    ## answer false (or true for `active`).
    ##
    ## Who has what: Windows (winapi) all of it; macOS (cocoa) all of it,
    ## the item in the menu bar; X11 -- Linux and the BSDs, and Wayland
    ## desktops through XWayland -- all but `menuItem`, the window manager
    ## doing the moving, sizing and maximizing (EWMH), or the driver itself
    ## where there is none; GTK 4 (Wayland's own windows too; the arrow keys
    ## on X11 only) and Siwin (not on macOS; no arrow keys) all but
    ## `menuItem`; SDL 3 and SDL 2 all but `menuItem` and `dragWindow`,
    ## moving and sizing by `windowPartAt` instead. Android and iOS have no
    ## windows to frame.
    setSystemFrame*: proc (on: bool): bool {.nimcall.}
      ## The system's frame and title bar on (true) or off: off, the app's
      ## drawing fills the whole window and the app draws a frame of its own.
      ## Called before `createWindow`, it is how the window is made. False
      ## when the window cannot have it so (some only as they are made: the
      ## frame is then the next window's).
    dragWindow*: proc (part: WindowPart; keyboard: bool): bool {.nimcall.}
      ## The system moves (`wpCaption`) or sizes (an edge or a corner) the
      ## window from here on, as its own frame would (snapping to the sides
      ## of the screen where it does that): with the mouse, whose left button
      ## is down on that part now -- its release is reported when the system
      ## is done -- or with the arrow keys (`keyboard`: a control menu's Move
      ## and Size; Enter keeps the place, Esc puts the window back). False
      ## when it cannot (the button is up already; no keys on Wayland).
    setMaximized*: proc (on: bool) {.nimcall.}
      ## Maximize the window -- to the desktop without its taskbar, Dock or
      ## panels -- or restore it.
    maximized*: proc (): bool {.nimcall.}
      ## The window is maximized now (by the app, the system's keys, a snap).
    active*: proc (): bool {.nimcall.}
      ## The window is the one in front, taking the keyboard: its title bar
      ## is drawn in the active colors.
    menuItem*: proc (label: string; checked: bool) {.nimcall.}
      ## One item of the app's own in a menu of the system's that is there
      ## whatever the frame -- Windows: the system menu (the title bar's
      ## icon, Alt+Space; the taskbar button's with the app's frame); macOS:
      ## the menu bar's Window menu -- with `label` ("&" before the access
      ## key, which macOS leaves out) and a check mark when `checked`; ""
      ## takes it away. Set before `createWindow`, it is added with the
      ## window. `menuItemChosen` tells when the user picks it. X11 and
      ## Wayland have no such menu: the window manager's (Alt+Space, a right
      ## click on the title bar) is its own, and an app offers the item in
      ## the window instead -- in a menu of the frame it draws, in its
      ## settings.
    menuItemChosen*: proc (): bool {.nimcall.}
      ## The item of `menuItem` was picked since the last call (once).

  DragOutResult* = enum
    ## How a drag of files out of the window ended (`startFileDragOut`).
    drNone,          ## there was none: the platform cannot drag files out,
                     ## there were no files, or the button was up already
    drCancelled,     ## let go where nothing took them, or Esc
    drCopied,        ## another program took a copy (a file manager, a
                     ## browser's upload box, a mail being written)
    drMoved,         ## a file manager moved them (allowed with `move`): they
                     ## may be gone from where they were
    drBack           ## (`backInside`) the pointer came back over the window,
                     ## the button still down: the app's own drag goes on

  FileDragRelays* = object
    ## Files dragged out of the window, to the system's file manager or
    ## another program. Optional: nil where the platform cannot, and
    ## `startFileDragOut` then answers `drNone`.
    dragOut*: proc (paths: seq[string]; move, backInside: bool): DragOutResult {.nimcall.}
      ## The system's drag of `paths` (files on disk), begun while the left
      ## button is down and over when it is let go (or Esc): the call returns
      ## then -- the window shows what it showed meanwhile. The program let
      ## go over takes a copy, or (`move`) may move them instead. The window
      ## itself takes no drop of its own files. `backInside`: the drag ends
      ## with `drBack` when the pointer comes back over the window, the button
      ## still down (a drag the app began in its window, that left it). The
      ## button's release, which the system takes, is reported as a
      ## MouseUpEvent; keys and clicks meanwhile were the drag's and are not.

proc folderName*(name: string): string =
  ## `name` (an app's, a title) as the name of a folder this system takes:
  ## on Windows `<>:"|?*` and control characters as `_`, no dot or space at
  ## the end, nor a device's name (CON, NUL, COM1...); elsewhere as it is.
  result = name
  when defined(windows):
    for c in result.mitems:
      if c in {'<', '>', ':', '"', '|', '?', '*'} or c < ' ': c = '_'
    while result.len > 0 and result[^1] in {'.', ' '}: result.setLen(result.len - 1)
    let stem = result.split('.')[0].strip.toUpperAscii
    if stem in ["CON", "PRN", "AUX", "NUL"] or
       (stem.len == 4 and stem[0 .. 2] in ["COM", "LPT"] and stem[3] in {'0' .. '9'}):
      result.add '_'

proc defaultDataDir(app: string): string =
  let base =
    when defined(windows): getEnv("APPDATA", getHomeDir())
    elif defined(macosx): getHomeDir() / "Library" / "Application Support"
    else:
      # (empty is the same as unset, as the XDG spec says)
      let x = getEnv("XDG_DATA_HOME")
      if x.len > 0 and x.isAbsolute: x else: getHomeDir() / ".local" / "share"
  result = base / folderName(app)
  try: createDir(result) except OSError: discard

when defined(windows):
  proc shellExecuteW(hwnd: pointer; op, file, params, dir: WideCString;
                     show: int32): int {.stdcall, dynlib: "shell32",
                     importc: "ShellExecuteW".}

proc defaultOpenUrl(url: string): bool =
  if url.len == 0: return false
  when defined(windows):
    shellExecuteW(nil, newWideCString("open"), newWideCString(url), nil, nil,
                  1) > 32
  elif androidApp or defined(ios):
    false
  else:
    let tool = when defined(macosx): "open" else: "xdg-open"
    try:
      let p = startProcess(tool, args = [url], options = {poUsePath, poDaemon})
      p.close()
      true
    except OSError:
      false

proc defaultPlatform(): string =
  when androidApp: "android"
  elif defined(ios): "ios"
  elif defined(windows): "windows"
  elif defined(macosx): "macos"
  elif defined(linux): "linux"
  elif defined(freebsd): "freebsd"
  elif defined(openbsd): "openbsd"
  elif defined(netbsd): "netbsd"
  elif defined(dragonfly): "dragonfly"
  else: hostOS

proc defaultOpenFile(path: string; share: bool): bool =
  if share: false else: defaultOpenUrl(path)

proc systemCall*(name, arg: string): string {.gcsafe.}
  ## `SystemRelays.call`: "\0" when it failed or is not there.

when defined(windows):
  type KnownFolderId = object
    d1: uint32
    d2, d3: uint16
    d4: array[8, uint8]
  proc shGetKnownFolderPath(id: ptr KnownFolderId; flags: uint32; token: pointer;
                            path: ptr ptr UncheckedArray[uint16]): int32
    {.stdcall, dynlib: "shell32", importc: "SHGetKnownFolderPath".}
  proc coTaskMemFree(p: pointer) {.stdcall, dynlib: "ole32", importc: "CoTaskMemFree".}

  proc knownFolder(id: KnownFolderId): string =
    ## Where Windows has one of the user's folders (moved to another drive,
    ## to OneDrive, by a policy...); "" when it cannot say.
    var id = id
    var p: ptr UncheckedArray[uint16]
    if shGetKnownFolderPath(addr id, 0, nil, addr p) == 0 and p != nil:
      var n = 0
      while p[n] != 0: inc n
      var w = newWideCString("", n)
      copyMem(addr w[0], p, n * 2)
      result = $w
    if p != nil: coTaskMemFree(p)

proc standardFolder*(which: string): string =
  ## The user's own folder `which` -- "desktop", "documents", "downloads",
  ## "music", "pictures", "videos", "templates", "public" -- where the system
  ## keeps it: named in the user's language (Linux and the BSDs: XDG's
  ## user-dirs.dirs), moved to another drive or to OneDrive (Windows' Known
  ## Folders); the usual name in the home folder on a Mac. "" when there is
  ## none.
  let key = which.toLowerAscii
  when defined(windows):
    const ids = [
      ("desktop", KnownFolderId(d1: 0xB4BFCC3A'u32, d2: 0xDB2C, d3: 0x424C,
                                d4: [0xB0'u8, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41])),
      ("documents", KnownFolderId(d1: 0xFDD39AD0'u32, d2: 0x238F, d3: 0x46AF,
                                  d4: [0xAD'u8, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7])),
      ("downloads", KnownFolderId(d1: 0x374DE290'u32, d2: 0x123F, d3: 0x4565,
                                  d4: [0x91'u8, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B])),
      ("music", KnownFolderId(d1: 0x4BD8D571'u32, d2: 0x6D19, d3: 0x48D3,
                              d4: [0xBE'u8, 0x97, 0x42, 0x22, 0x20, 0x08, 0x0E, 0x43])),
      ("pictures", KnownFolderId(d1: 0x33E28130'u32, d2: 0x4E1E, d3: 0x4676,
                                 d4: [0x83'u8, 0x5A, 0x98, 0x39, 0x5C, 0x3B, 0xC3, 0xBB])),
      ("videos", KnownFolderId(d1: 0x18989B1D'u32, d2: 0x99B5, d3: 0x455B,
                               d4: [0x84'u8, 0x1C, 0xAB, 0x7C, 0x74, 0xE4, 0xDD, 0xFC])),
      ("templates", KnownFolderId(d1: 0xA63293E8'u32, d2: 0x664E, d3: 0x48DB,
                                  d4: [0xA0'u8, 0x79, 0xDF, 0x75, 0x9E, 0x05, 0x09, 0xF7])),
      ("public", KnownFolderId(d1: 0xDFDF76A2'u32, d2: 0xC82A, d3: 0x4D63,
                               d4: [0x90'u8, 0x6A, 0x56, 0x44, 0xAC, 0x45, 0x73, 0x85]))]
    for (name, id) in ids:
      if name == key:
        result = knownFolder(id)
    if result.len == 0:
      let sub = case key
                of "desktop": "Desktop"
                of "documents": "Documents"
                of "downloads": "Downloads"
                of "music": "Music"
                of "pictures": "Pictures"
                of "videos": "Videos"
                else: ""
      if sub.len > 0: result = getHomeDir() / sub
  elif defined(macosx) or androidApp or defined(ios):
    let sub = case key
              of "desktop": "Desktop"
              of "documents": "Documents"
              of "downloads": "Downloads"
              of "music": "Music"
              of "pictures": "Pictures"
              of "videos": "Movies"
              of "public": "Public"
              else: ""
    if sub.len > 0: result = getHomeDir() / sub
  else:
    # XDG's user-dirs.dirs: XDG_DOCUMENTS_DIR="$HOME/Dokumente" and the
    # like, as xdg-user-dirs wrote them in the user's language (a folder
    # that is the home folder itself is none)
    let name = case key
               of "downloads": "DOWNLOAD"
               of "public": "PUBLICSHARE"
               else: key.toUpperAscii
    let home = getHomeDir()
    try:
      for line in lines((let x = getEnv("XDG_CONFIG_HOME"); if x.len > 0: x else: home / ".config") / "user-dirs.dirs"):
        let l = line.strip
        let start = "XDG_" & name & "_DIR="
        if l.startsWith(start):
          var v = l[start.len .. ^1].strip.strip(chars = {'"'})
          if v.startsWith("$HOME"): v = home / v[5 .. ^1]
          elif not v.startsWith("/"): v = ""
          if v.len > 0 and v.normalizedPath != home.normalizedPath: result = v
    except IOError, OSError: discard
    if result.len == 0:
      let sub = case key
                of "desktop": "Desktop"
                of "documents": "Documents"
                of "downloads": "Downloads"
                of "music": "Music"
                of "pictures": "Pictures"
                of "videos": "Videos"
                of "templates": "Templates"
                of "public": "Public"
                else: ""
      if sub.len > 0: result = home / sub
  if result.len > 0: result = result.normalizedPath

proc defaultPlaces(): seq[tuple[name, path: string]] =
  let home = getHomeDir()
  result.add ("Home", home.normalizedPath)
  # inside Termux (its X11 or a terminal app): its home, its system and the
  # phone's shared storage it links in
  let prefix = getEnv("PREFIX")
  if getEnv("TERMUX_VERSION").len > 0 or "com.termux" in prefix:
    result[0].name = "Termux home"
    if prefix.len > 0 and dirExists(prefix): result.add ("Termux system", prefix)
    if dirExists(home / "storage" / "shared"):
      result.add ("Shared storage", (home / "storage" / "shared").normalizedPath)
  when defined(android):
    result.setLen(0)
    for root in ["/storage/emulated/0", "/sdcard"]:
      if dirExists(root):
        result.add ("Internal storage", root)
        break
  let base = if result.len > 0: result[0].path else: home
  var seen: seq[string]
  for (name, key, sub) in [("Desktop", "desktop", "Desktop"), ("Documents", "documents", "Documents"),
                           ("Downloads", "downloads", "Download"), ("Downloads", "downloads", "Downloads"),
                           ("Pictures", "pictures", "Pictures"), ("Camera", "", "DCIM"),
                           ("Music", "music", "Music"), ("Videos", "videos", "Videos"),
                           ("Movies", "", "Movies")]:
    # (where the system keeps it -- in the user's language, on another
    # drive -- else by its usual name)
    var p = if key.len > 0 and base == home.normalizedPath: standardFolder(key) else: ""
    if (p.len == 0 or not dirExists(p)) and dirExists(base / sub): p = (base / sub).normalizedPath
    if p.len > 0 and dirExists(p) and p notin seen:
      seen.add p
      result.add (name, p)
  when defined(windows):
    for c in 'A' .. 'Z':
      if dirExists($c & ":\\"): result.add ($c & ":", $c & ":\\")
  elif defined(android):
    try:                                     # SD cards and USB drives
      for kind, p in walkDir("/storage"):
        let n = p.extractFilename
        if n notin ["emulated", "self"] and dirExists(p):
          result.add ("SD card " & n, p)
    except OSError: discard
  elif defined(macosx):
    result.add ("Computer", "/")
    try:
      for kind, p in walkDir("/Volumes"): result.add (p.extractFilename, p)
    except OSError: discard
  else:
    result.add ("Computer", "/")
    for mounts in ["/media" / getEnv("USER"), "/run/media" / getEnv("USER"), "/mnt"]:
      try:
        for kind, p in walkDir(mounts):
          if kind in {pcDir, pcLinkToDir}: result.add (p.extractFilename, p)
      except OSError: discard

var systemRelays* = SystemRelays(
  dataDir: defaultDataDir,
  openUrl: defaultOpenUrl,
  platform: defaultPlatform,
  openFile: defaultOpenFile,
  places: defaultPlaces,
  storageAccess: proc (): bool = true,
  requestStorageAccess: proc () = discard,
  decodeImage: proc (path: string; maxW, maxH: int):
                    tuple[w, h: int; px: seq[uint32]] = (0, 0, @[]),
  minimize: proc (): bool = false,
  call: proc (name, arg: string): string {.gcsafe.} = "\0")

proc dataDir*(app: string): string = systemRelays.dataDir(app)
  ## A folder only this app writes to, created on demand.
proc openUrl*(url: string): bool {.discardable.} = systemRelays.openUrl(url)
  ## Opens `url` (https:, mailto:, a file) with the system's handler.
proc platformName*(): string = systemRelays.platform()
  ## Which platform this is: "linux", "windows", "macos", "android", "ios",
  ## "freebsd", "openbsd", "netbsd", "dragonfly"...
proc openFile*(path: string): bool {.discardable.} =
  ## Open `path` in the app the system has for its kind of file.
  systemRelays.openFile(path, false)
proc shareFile*(path: string): bool {.discardable.} =
  ## Offer `path` to other apps (Android's share sheet); false elsewhere.
  systemRelays.openFile(path, true)
proc places*(): seq[tuple[name, path: string]] = systemRelays.places()
  ## The standard folders (home, documents, downloads...) and the drives.
proc systemCall*(name, arg: string): string {.gcsafe.} =
  ## `SystemRelays.call`: "\0" when it failed or is not there.
  {.cast(gcsafe).}: systemRelays.call(name, arg)
proc storageAccess*(): bool = systemRelays.storageAccess()
  ## The app may read and write the shared storage (Android asks).
proc requestStorageAccess*() = systemRelays.requestStorageAccess()
  ## Asks the user for that (Android opens its settings page).
proc minimizeApp*(): bool {.discardable.} = systemRelays.minimize()
  ## Sends the app to the background; false where apps cannot.

proc filesOfUriList*(text: string): seq[string] =
  ## The local files of a `text/uri-list` (what a file manager hands over
  ## in a drag, XDND's and Wayland's alike): one URI a line, "#" lines
  ## left out, `file://` URIs as paths with their `%XX` decoded; the other
  ## URIs are not files and are left out.
  for line in text.splitLines:
    let u = line.strip
    if u.len == 0 or u[0] == '#' or not u.startsWith("file:"): continue
    var p = u[5 .. ^1]
    if p.startsWith("//"):
      # file://host/path: the path starts where the host ends ("" or
      # localhost, this computer)
      let slash = p.find('/', 2)
      if slash < 0: continue
      p = p[slash .. ^1]
    var path = newStringOfCap(p.len)
    var i = 0
    while i < p.len:
      if p[i] == '%' and i + 2 <= p.high and
         p[i + 1] in HexDigits and p[i + 2] in HexDigits:
        path.add char(parseHexInt(p[i + 1 .. i + 2]))
        i += 3
      else:
        path.add p[i]
        inc i
    when defined(windows):
      # (file:///C:/dir/file -> C:\dir\file)
      if path.len >= 3 and path[0] == '/' and path[2] == ':': path = path[1 .. ^1]
      path = path.replace('/', '\\')
    if path.len > 0: result.add path

proc uriListOfFiles*(paths: openArray[string]): string =
  ## `paths` as a `text/uri-list` (what XDND and Wayland hand over in a drag
  ## of files): `file://` URIs, one a line (CR LF), every byte but letters,
  ## digits, `-._~` and `/` written `%XX` -- `filesOfUriList` the other way.
  ## Windows' `C:\dir\file` is `file:///C:/dir/file`.
  for path in paths:
    if path.len == 0: continue
    var p = if path.isAbsolute: path else: absolutePath(path)
    when defined(windows):
      p = p.replace('\\', '/')
      if p.len >= 2 and p[1] == ':': p = "/" & p
    result.add "file://"
    for i, c in p:
      if c in {'A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/'} or
         (c == ':' and i == 2 and defined(windows)):
        result.add c
      else:
        result.add '%'
        result.add toHex(ord(c), 2)
    result.add "\r\n"

proc hdropOfFiles*(paths: openArray[string]): string =
  ## `paths` as Windows' CF_HDROP (what a drag of files, or a copy of them,
  ## hands over): a DROPFILES header -- where the names start (20), a point
  ## and a flag (0), the names are UTF-16 (1) -- then each path in UTF-16
  ## ended by a 0, and one more 0 after the last. Bytes, little-endian.
  proc put(s: var string; v: uint32; n: int) =
    for i in 0 ..< n: s.add char((v shr (8 * i)) and 0xFF)
  result.put(20, 4)                      # pFiles
  result.put(0, 4)                       # pt.x
  result.put(0, 4)                       # pt.y
  result.put(0, 4)                       # fNC
  result.put(1, 4)                       # fWide
  for p in paths:
    if p.len == 0: continue
    var i = 0
    while i < p.len:
      # (UTF-8 in; a byte that starts no character stands for itself)
      let b = uint32(p[i])
      var n = if b >= 0xF0 and b < 0xF8: 3 elif b >= 0xE0: 2 elif b >= 0xC0: 1 else: 0
      if b >= 0xF8 or i + n >= p.len: n = 0
      var c = if n == 0: b else: b and (0x3F'u32 shr n)
      for k in 1 .. n:
        if (uint32(p[i + k]) and 0xC0) != 0x80:
          c = b
          n = 0
          break
        c = (c shl 6) or (uint32(p[i + k]) and 0x3F)
      i += n + 1
      if c >= 0x10000:                   # (a surrogate pair)
        c -= 0x10000
        result.put(0xD800 + (c shr 10), 2)
        result.put(0xDC00 + (c and 0x3FF), 2)
      else:
        result.put(c, 2)
    result.put(0, 2)
  result.put(0, 2)

var frameRelays*: FrameRelays
  ## Filled by the desktop drivers whose windows can go without the system's
  ## frame (none by default).

var windowPartAt*: proc (x, y: int): WindowPart {.nimcall.}
  ## Set by an app that draws its own frame (nil: none): the part of the
  ## window at `x`, `y`, as the mouse's events give them -- `wpClient` for
  ## the app's own, its title bar's buttons too. Where the system asks
  ## where the frame is before a press reaches the app (SDL's hit test),
  ## the driver answers with it, and the system moves or sizes the window
  ## from such a press, which never comes to the app (nor a double click
  ## there: Windows maximizes the window for it, the others do nothing):
  ## `dragWindow` is not needed there.

var textCaretRelay*: proc (x, y, w, h: int) {.nimcall.}
  ## Set by the drivers whose input method (an IME: Chinese, Japanese,
  ## Korean...) can be told where the text goes (nil: none): see
  ## `setTextCaret`.

proc setTextCaret*(x, y, w, h: int) =
  ## Where the caret of the text box being typed in is -- in the window's
  ## coordinates, as the mouse's events give them; `h` the line's height --
  ## so that an input method shows what it composes, and its candidates,
  ## there instead of in a corner of the screen. Called while a box has the
  ## keyboard, again when its caret moves; nothing where the driver has no
  ## use for it (Windows and macOS have).
  if textCaretRelay != nil: textCaretRelay(x, y, w, h)

proc canDrawFrame*(): bool = frameRelays.setSystemFrame != nil
  ## The window can go without the system's frame, for the app to draw one.
proc setSystemFrame*(on: bool): bool {.discardable.} =
  ## The system's frame on or off (see `FrameRelays.setSystemFrame`).
  frameRelays.setSystemFrame != nil and frameRelays.setSystemFrame(on)
proc startWindowMove*(keyboard = false): bool {.discardable.} =
  ## The system moves the window from here on: with the mouse, whose left
  ## button is down on the app's title bar, or with the arrow keys.
  frameRelays.dragWindow != nil and frameRelays.dragWindow(wpCaption, keyboard)
proc startWindowResize*(edge: WindowPart; keyboard = false): bool {.discardable.} =
  ## The system sizes the window from `edge` (an edge or a corner) from
  ## here on: with the mouse, whose left button is down there, or with the
  ## arrow keys.
  edge notin {wpClient, wpCaption} and frameRelays.dragWindow != nil and
    frameRelays.dragWindow(edge, keyboard)
proc maximizeWindow*(on = true) =
  ## Maximizes the window (true) or restores it.
  if frameRelays.setMaximized != nil: frameRelays.setMaximized(on)
proc windowMaximized*(): bool =
  ## The window is maximized now.
  frameRelays.maximized != nil and frameRelays.maximized()
proc windowActive*(): bool =
  ## The window is the one in front (true where the driver cannot tell).
  frameRelays.active == nil or frameRelays.active()
proc canFrameMenuItem*(): bool = frameRelays.menuItem != nil
  ## The menu of the system's frame can take an item of the app's here.
proc setFrameMenuItem*(label: string; checked = false): bool {.discardable.} =
  ## The app's item in the menu of the system's frame (see
  ## `FrameRelays.menuItem`); false where there is no such menu.
  if frameRelays.menuItem == nil: return false
  frameRelays.menuItem(label, checked)
  true
proc frameMenuItemChosen*(): bool =
  ## The item of `setFrameMenuItem` was picked since the last call.
  frameRelays.menuItemChosen != nil and frameRelays.menuItemChosen()

var fileDragRelays*: FileDragRelays
  ## Filled by the desktop drivers that can drag files out of the window
  ## (none by default).

proc canDragFilesOut*(): bool = fileDragRelays.dragOut != nil
  ## Files can be dragged out of the window to other programs here.

proc startFileDragOut*(paths: openArray[string]; move = false;
                       backInside = false): DragOutResult =
  ## Drags `paths` (files on disk) out of the window: the system's drag,
  ## while the left button is down, until it is let go (see
  ## `FileDragRelays.dragOut`). `drNone` where the platform cannot, or with
  ## no paths.
  if fileDragRelays.dragOut == nil or paths.len == 0: return drNone
  fileDragRelays.dragOut(@paths, move, backInside)

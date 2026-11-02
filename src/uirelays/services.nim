# Platform services as relays: where an app keeps its files, opening a
# link in the browser or a file in its app, the standard folders, storage
# permission, decoding photos, which platform this is. The defaults below
# serve the desktops; the Android and iOS drivers replace the ones their
# platform does differently.

import std/[os, strutils]
when not defined(windows) and not defined(android) and not defined(ios):
  import std/osproc

type
  SystemRelays* = object
    dataDir*: proc (app: string): string {.nimcall.}
      ## A folder only this app writes to, created on demand.
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

proc defaultDataDir(app: string): string =
  let base =
    when defined(windows): getEnv("APPDATA", getHomeDir())
    elif defined(macosx): getHomeDir() / "Library" / "Application Support"
    else: getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share")
  result = base / app
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
  elif defined(android) or defined(ios):
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
  when defined(android): "android"
  elif defined(ios): "ios"
  elif defined(windows): "windows"
  elif defined(macosx): "macos"
  elif defined(linux): "linux"
  else: hostOS

proc defaultOpenFile(path: string; share: bool): bool =
  if share: false else: defaultOpenUrl(path)

proc systemCall*(name, arg: string): string {.gcsafe.}
  ## `SystemRelays.call`: "\0" when it failed or is not there.

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
  for (name, sub) in [("Desktop", "Desktop"), ("Documents", "Documents"),
                      ("Downloads", "Download"), ("Downloads", "Downloads"),
                      ("Pictures", "Pictures"), ("Camera", "DCIM"),
                      ("Music", "Music"), ("Videos", "Videos"), ("Movies", "Movies")]:
    if dirExists(base / sub): result.add (name, (base / sub).normalizedPath)
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
  ## Which platform this is: "linux", "windows", "macos", "android", "ios"...
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

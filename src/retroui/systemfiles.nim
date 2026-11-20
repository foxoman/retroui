## Open and Save As through the system's own file picker, where a system
## has one that apps are meant to use: Android (its documents picker:
## the phone's storage, an SD card, Drive, any app that offers its files)
## and iOS (Files). Turned on with `systemFiles(true)`, the kit's own
## `fileDialog` and `filePicker` (opening a file, naming one to save; not
## picking a folder) show the system's picker instead of themselves -- an
## app's code stays as it is:
##
## ```nim
## systemFiles(true)                      # once, at the start (nothing happens where there is none)
## ...
## if fileDialog(openDlg, path): load(path)             # the system's picker on a phone
## if fileDialog(saveDlg, path, fmSave): save(path)     # ... and its "save to"
## ```
##
## An app works with files, the systems with documents that have no path.
## So a document picked to open is copied into the app's cache and the
## app is given that copy; a file to save is written there too. What the
## app writes is handed back by itself: when a file given so has changed
## and is then left alone for a moment, it is written into its document
## (Android: the one opened, or the one "save to" made -- a later Save
## goes there without asking again; iOS: Files asks where it goes).
## `fileDialog` and `filePicker` look after that as they are called each
## frame; an app that does not call them each frame calls
## `pumpSystemFiles`.
##
## On a desktop and in a web page there is none (`hasSystemFiles` is
## false): the kit's dialogs are what they were (a web page has the
## browser's file chooser through them already).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, times, monotimes, strutils, algorithm, tables]
import uirelays/target   # (androidApp: an APK, not a program in Termux)

type
  SystemFilesBackend* = object
    ## What a system's picker is reached through (Android's and iOS's are
    ## set by the kit; a test sets its own).
    askOpen*: proc (): bool
      ## Shows the picker to open a document; false when it cannot.
    opened*: proc (): string
      ## What it gave, taken: "" not yet; "\1" the user left it; else the
      ## copy's path, a tab and where it came from ("" when it cannot be
      ## written back to).
    askSave*: proc (name, mime: string): bool
      ## Shows the picker to choose where a new document goes.
    saveTo*: proc (): string
      ## Its answer, taken: "" not yet; "\1" left; else where it goes.
    write*: proc (origin, path: string): bool
      ## The file at `path` written into the document `origin`.
    hand*: proc (path: string): bool
      ## The file at `path` handed to the system, which asks where it goes
      ## (a system that asks after the file is written: iOS).
    cache*: proc (): string
      ## A folder of the app's own for the copies.
    askFolder*: proc (): bool
      ## Shows the picker to choose a folder (Android's: a folder of any app that offers its
      ## files); nil: the system has none.
    folderPicked*: proc (): string
      ## Its answer, taken: "" not yet; "\1" left; else the folder: its tree, a tab, its document.
    putInto*: proc (tree, folder, name, mime, path: string): string
      ## The file at `path` written into the folder `folder` of `tree` as `name` (over the one so
      ## named there); `path` "": a folder made there (or the one so named). Its document ("":
      ## it could not be).
  WatchedFolder = object
    path, tree, root: string
    sent: seq[(string, (int64, Time))]   # (each file as it was last handed over)
    seen: string                         # (what is in it, as last looked at)
    since: MonoTime
  Watched = object
    path, origin: string
    given: (int64, Time)               # (its size and date when it was last handed over, or opened)
    seen: (int64, Time)
    since: MonoTime

var
  backend: SystemFilesBackend
  wanted = false
  watched: seq[Watched]
  folders: seq[WatchedFolder]
  picking = ""                         # (the dialog waiting for the picker)
  lastLook: MonoTime
  saves = 0
  note = ""

proc setSystemFilesBackend*(b: SystemFilesBackend) =
  ## Another way to the system's picker (for a test; a system the kit does
  ## not know).
  backend = b
  watched.setLen(0)
  folders.setLen(0)
  picking = ""

proc hasSystemFiles*(): bool = backend.askOpen != nil
  ## This system has a file picker of its own (Android, iOS).

proc hasSystemFolders*(): bool = backend.askFolder != nil
  ## This system has a folder picker of its own that apps write into (Android's).

proc systemFiles*(on: bool) = wanted = on
  ## The kit's Open and Save As dialogs are the system's own picker from
  ## now on, where there is one.

proc systemFilesOn*(): bool = wanted and hasSystemFiles()
  ## The system's picker is what `fileDialog` and `filePicker` show.

proc systemFoldersOn*(): bool = wanted and hasSystemFolders()
  ## ... and, picking a folder, the system's folder picker.

proc systemFilesNote*(): string =
  ## What went wrong handing a file to the system since this was last
  ## asked ("" nothing): to show the user.
  result = note
  note = ""

proc stampOf(path: string): (int64, Time) =
  try: (getFileSize(path), getLastModificationTime(path))
  except CatchableError: (-1'i64, Time())

proc mimeOf(name: string): string =
  case name.splitFile.ext.toLowerAscii
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".webp": "image/webp"
  of ".svg": "image/svg+xml"
  of ".pdf": "application/pdf"
  of ".txt": "text/plain"
  of ".html", ".htm": "text/html"
  of ".csv": "text/csv"
  of ".json": "application/json"
  of ".zip": "application/zip"
  else: "application/octet-stream"

proc watch(path, origin: string; fresh: bool) =
  for i in countdown(watched.high, 0):
    if watched[i].path == path: watched.delete(i)
  if watched.len >= 32: watched.delete(0)
  let s = if fresh: (-1'i64, Time()) else: stampOf(path)
  watched.add Watched(path: path, origin: origin, given: s, seen: s, since: getMonoTime())

proc adoptSystemFile*(path, origin: string) =
  ## A copy of a document another app gave (`system.sharedIn`'s files and origins: "Open
  ## with" a file manager) written back to that document when it changes, as one the system's
  ## picker opened is.
  if path.len > 0 and origin.len > 0: watch(path, origin, fresh = false)

proc folderLook(dir: string): string =
  ## (what is in a folder: each file's place in it, size and date)
  var items: seq[string]
  try:
    for p in walkDirRec(dir, relative = true):
      let s = stampOf(dir / p)
      items.add p & "\t" & $s[0] & "\t" & $s[1].toUnix & "." & $s[1].nanosecond
  except OSError: discard
  items.sort()
  items.join("\n")

proc relParent(rel: string): string =
  ## (the folder a file is in, within the folder: "" its top)
  let i = max(rel.rfind('/'), rel.rfind(DirSep))
  if i < 0: "" else: rel[0 ..< i]

proc relName(rel: string): string =
  let i = max(rel.rfind('/'), rel.rfind(DirSep))
  rel[i + 1 .. ^1]

proc sendFolder(f: var WatchedFolder): bool =
  ## (the files of the folder the app wrote into, new or changed since, written into the folder
  ## the system's picker gave -- its folders as folders there)
  result = true
  var ids = initTable[string, string]()     # (a folder in it: its document there)
  ids[""] = f.root
  let tree = f.tree
  proc folderId(rel: string): string =
    if rel in ids: return ids[rel]
    let up = folderId(rel.relParent)
    if up.len == 0: return ""
    result = backend.putInto(tree, up, rel.relName, "vnd.android.document/directory", "")
    ids[rel] = result
  var files: seq[string]
  try:
    for p in walkDirRec(f.path, relative = true): files.add p
  except OSError: return false
  files.sort()
  for rel in files:
    let st = stampOf(f.path / rel)
    var sent = false
    for (p, s) in f.sent:
      if p == rel and s == st: sent = true
    if sent: continue
    let parent = folderId(rel.relParent)
    if parent.len == 0 or backend.putInto(f.tree, parent, rel.relName, mimeOf(rel), f.path / rel).len == 0:
      result = false
      continue
    for k in countdown(f.sent.high, 0):
      if f.sent[k][0] == rel: f.sent.delete(k)
    f.sent.add (rel, st)

proc pumpSystemFiles*() =
  ## The files the app was given through the system's picker looked at:
  ## one that changed and has been left alone since (a second and more)
  ## is handed back to the system; so are the files the app wrote into a
  ## folder the system's folder picker gave. `fileDialog` and `filePicker`
  ## call it; it looks a few times a second at most.
  if (watched.len == 0 and folders.len == 0) or (backend.askOpen == nil and backend.askFolder == nil): return
  let now = getMonoTime()
  if (now - lastLook).inMilliseconds < 300: return
  lastLook = now
  for f in folders.mitems:
    let look = folderLook(f.path)
    if look == f.seen:
      if look.len > 0 and (now - f.since).inMilliseconds >= 1200 and f.since != MonoTime():
        if not sendFolder(f): note = "Could not write everything into \"" & f.path.extractFilename & "\"."
        f.since = MonoTime()
      continue
    f.seen = look
    f.since = now
  for w in watched.mitems:
    let s = stampOf(w.path)
    if s[0] < 0 or s == w.given: continue
    if s != w.seen:
      w.seen = s
      w.since = now
      continue
    if (now - w.since).inMilliseconds < 1200: continue
    w.given = s
    var ok = true
    if w.origin.len > 0:
      ok = backend.write != nil and backend.write(w.origin, w.path)
    elif backend.hand != nil:
      ok = backend.hand(w.path)
    if not ok: note = "Could not save \"" & w.path.extractFilename & "\" where it came from."

proc systemFileDialog*(open: var bool; path: var string; save: bool; key: string): bool =
  ## An Open or Save As through the system's picker while `open`: true
  ## once, with `path` set to a file of the app's own to read or to write
  ## (`fileDialog` and `filePicker` call it when `systemFilesOn`). `key`
  ## tells one dialog of an app from another.
  pumpSystemFiles()
  if not open:
    if picking == key: picking = ""
    return false
  if backend.askOpen == nil:
    open = false
    return false
  if not save:
    if picking != key:
      picking = key
      if not backend.askOpen():
        picking = ""
        open = false
      return false
    let r = backend.opened()
    if r.len == 0: return false
    picking = ""
    open = false
    if r == "\1": return false
    let first = r.split('\n')[0].split('\t')
    if first[0].len == 0: return false
    path = first[0]
    watch(path, (if first.len > 1: first[1] else: ""), fresh = false)
    return true
  # saving
  let name = if path.len > 0 and not path.endsWith("/") and not dirExists(path): path.extractFilename
             else: "Untitled"
  proc place(): string =
    inc saves
    result = backend.cache() / "saved" / $saves
    createDir(result)
    result = result / name
  if backend.askSave == nil:
    # (the system asks where when the file is there: the app writes it first)
    try: path = place()
    except CatchableError:
      open = false
      return false
    watch(path, "", fresh = true)
    open = false
    return true
  if picking != key:
    picking = key
    if not backend.askSave(name, mimeOf(name)):
      picking = ""
      open = false
    return false
  let r = backend.saveTo()
  if r.len == 0: return false
  picking = ""
  open = false
  if r == "\1": return false
  try: path = place()
  except CatchableError: return false
  watch(path, r, fresh = true)
  true

proc systemFolderDialog*(open: var bool; path: var string; key: string): bool =
  ## Picking a folder through the system's folder picker while `open`: true once, with `path` a
  ## folder of the app's own to write into -- what the app writes there is written into the
  ## folder picked by itself when it is left alone for a moment (`pumpSystemFiles`). `fileDialog`
  ## and `filePicker` call it when `systemFoldersOn`.
  pumpSystemFiles()
  if not open:
    if picking == key: picking = ""
    return false
  if backend.askFolder == nil:
    open = false
    return false
  if picking != key:
    picking = key
    if not backend.askFolder():
      picking = ""
      open = false
    return false
  let r = backend.folderPicked()
  if r.len == 0: return false
  picking = ""
  open = false
  if r == "\1": return false
  let p = r.split('\t')
  if p.len < 2: return false
  inc saves
  try:
    path = backend.cache() / "folders" / $saves
    removeDir(path)
    createDir(path)
  except CatchableError: return false
  if folders.len >= 8: folders.delete(0)
  folders.add WatchedFolder(path: path, tree: p[0], root: p[1])
  true

proc flushSystemFolders*() =
  ## What the app wrote into folders the system's folder picker gave, written there now (not
  ## waiting for it to be left alone: as the app is closing, or a job is done).
  for f in folders.mitems:
    f.seen = folderLook(f.path)
    if not sendFolder(f): note = "Could not write everything into the folder picked."

# ---- Android ---------------------------------------------------------------------------

when androidApp:
  import uirelays/services

  proc gave(r: string): string = (if r == "\0": "\1" else: r)

  proc droidAskOpen(): bool = systemCall("pickOpen", "0") == "1"
  proc droidOpened(): string = gave(systemCall("picked", ""))
  proc droidAskSave(name, mime: string): bool =
    systemCall("pickSave", name.multiReplace(("\t", " "), ("\n", " ")) & "\t" & mime) == "1"
  proc droidSaveTo(): string = gave(systemCall("pickSaved", ""))
  proc droidWrite(origin, path: string): bool = systemCall("uriWrite", origin & "\t" & path) == "1"
  proc droidCache(): string =
    let d = systemCall("cacheDir", "")
    (if d.len > 0 and d != "\0": d else: getTempDir())

  proc droidAskFolder(): bool =
    discard systemCall("treeAsk", "")
    true
  proc droidFolderPicked(): string = gave(systemCall("treePicked", ""))
  proc droidPutInto(tree, folder, name, mime, path: string): string =
    # (the one so named there: written over; else made)
    var id = ""
    let kids = systemCall("list", tree & "\t" & folder)
    if kids != "\0":
      for line in kids.splitLines:
        let q = line.split('\t')
        if q.len >= 3 and q[1] == name and ((path.len == 0) == (q[2] == "vnd.android.document/directory")):
          id = q[0]
    if id.len == 0:
      let made = systemCall("create", tree & "\t" & folder & "\t" & mime & "\t" & name)
      if made == "\0" or made.len == 0: return ""
      id = made
    if path.len == 0: return id
    let fdS = systemCall("open", tree & "\t" & id & "\twt")
    var fd = -1
    try: fd = parseInt(fdS) except ValueError: discard
    var f: File
    if fd < 0 or not open(f, FileHandle(fd), fmWrite): return ""
    try:
      let data = readFile(path)
      if data.len > 0 and f.writeBuffer(unsafeAddr data[0], data.len) != data.len: id = ""
    except IOError, OSError: id = ""
    finally: f.close()
    id

  setSystemFilesBackend SystemFilesBackend(askOpen: droidAskOpen, opened: droidOpened, askSave: droidAskSave,
                                           saveTo: droidSaveTo, write: droidWrite, cache: droidCache,
                                           askFolder: droidAskFolder, folderPicked: droidFolderPicked,
                                           putInto: droidPutInto)

# ---- iOS -------------------------------------------------------------------------------

when defined(ios):
  import native

  proc objc_allocateClassPair(super: pointer; name: cstring; extra: int): pointer {.importc, cdecl.}
  proc objc_registerClassPair(cls: pointer) {.importc, cdecl.}
  proc class_addMethod(cls, name, imp: pointer; types: cstring): bool {.importc, cdecl.}

  var
    iosOpened = ""                     # (as `opened` gives it)
    iosDelegate: ObjcId
    iosExporting = false

  proc onPicked(self: ObjcId; cmd: pointer; picker, urls: ObjcId) {.cdecl.} =
    if iosExporting:
      iosExporting = false
      return
    var got = ""
    let n = objcSend(int, urls, "count")
    for k in 0 ..< n:
      let u = objcSend(ObjcId, urls, "objectAtIndex:", k)
      let p = toNim(objcSend(ObjcId, u, "path"))
      if p.len > 0:
        if got.len > 0: got.add '\n'
        got.add p & "\t"
    iosOpened = if got.len > 0: got else: "\1"

  proc onLeft(self: ObjcId; cmd: pointer; picker: ObjcId) {.cdecl.} =
    if iosExporting: iosExporting = false
    else: iosOpened = "\1"

  proc present(vc: ObjcId): bool =
    if vc == nil: return false
    if iosDelegate == nil:
      var cls = objcClass("RetroFilesDelegate")
      if cls == nil:
        cls = objc_allocateClassPair(objcClass("NSObject"), "RetroFilesDelegate", 0)
        discard class_addMethod(cls, sel("documentPicker:didPickDocumentsAtURLs:"), cast[pointer](onPicked), "v@:@@")
        discard class_addMethod(cls, sel("documentPickerWasCancelled:"), cast[pointer](onLeft), "v@:@")
        objc_registerClassPair(cls)
      iosDelegate = objcSend(ObjcId, objcSend(ObjcId, cls, "alloc"), "init")
    objcSend(void, vc, "setDelegate:", iosDelegate)
    let app = objcSend(ObjcId, objcClass("UIApplication"), "sharedApplication")
    var window = objcSend(ObjcId, app, "keyWindow")
    if window == nil:
      let all = objcSend(ObjcId, app, "windows")
      if all != nil and objcSend(int, all, "count") > 0: window = objcSend(ObjcId, all, "objectAtIndex:", 0)
    if window == nil: return false
    let root = objcSend(ObjcId, window, "rootViewController")
    if root == nil: return false
    objcSend(void, root, "presentViewController:animated:completion:", vc, true, nil)
    true

  proc iosAskOpen(): bool =
    # (any kind of document, given as a copy the app may read)
    let kinds = objcSend(ObjcId, objcClass("NSArray"), "arrayWithObject:", nsString("public.item"))
    let cls = objcClass("UIDocumentPickerViewController")
    if cls == nil: return false
    iosOpened = ""
    iosExporting = false
    present(objcSend(ObjcId, objcSend(ObjcId, cls, "alloc"), "initWithDocumentTypes:inMode:", kinds, 0))

  proc iosTaken(): string =
    result = iosOpened
    if result.len > 0: iosOpened = ""

  proc iosHand(path: string): bool =
    # (Files asks where the file goes: a copy of it is put there)
    let cls = objcClass("UIDocumentPickerViewController")
    if cls == nil: return false
    let url = objcSend(ObjcId, objcClass("NSURL"), "fileURLWithPath:", nsString(path))
    iosExporting = true
    present(objcSend(ObjcId, objcSend(ObjcId, cls, "alloc"), "initWithURL:inMode:", url, 2))

  proc iosCache(): string = getTempDir()

  setSystemFilesBackend SystemFilesBackend(askOpen: iosAskOpen, opened: iosTaken, hand: iosHand, cache: iosCache)

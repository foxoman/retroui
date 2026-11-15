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

import std/[os, times, monotimes, strutils]
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
  Watched = object
    path, origin: string
    given: (int64, Time)               # (its size and date when it was last handed over, or opened)
    seen: (int64, Time)
    since: MonoTime

var
  backend: SystemFilesBackend
  wanted = false
  watched: seq[Watched]
  picking = ""                         # (the dialog waiting for the picker)
  lastLook: MonoTime
  saves = 0
  note = ""

proc setSystemFilesBackend*(b: SystemFilesBackend) =
  ## Another way to the system's picker (for a test; a system the kit does
  ## not know).
  backend = b
  watched.setLen(0)
  picking = ""

proc hasSystemFiles*(): bool = backend.askOpen != nil
  ## This system has a file picker of its own (Android, iOS).

proc systemFiles*(on: bool) = wanted = on
  ## The kit's Open and Save As dialogs are the system's own picker from
  ## now on, where there is one.

proc systemFilesOn*(): bool = wanted and hasSystemFiles()
  ## The system's picker is what `fileDialog` and `filePicker` show.

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

proc pumpSystemFiles*() =
  ## The files the app was given through the system's picker looked at:
  ## one that changed and has been left alone since (a second and more)
  ## is handed back to the system. `fileDialog` and `filePicker` call it;
  ## it looks a few times a second at most.
  if watched.len == 0 or backend.askOpen == nil: return
  let now = getMonoTime()
  if (now - lastLook).inMilliseconds < 300: return
  lastLook = now
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

  setSystemFilesBackend SystemFilesBackend(askOpen: droidAskOpen, opened: droidOpened, askSave: droidAskSave,
                                           saveTo: droidSaveTo, write: droidWrite, cache: droidCache)

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

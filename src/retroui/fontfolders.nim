## Font folders of the user's own -- a folder of fonts they keep -- whose fonts every font list
## of the app offers, on each system the way it allows:
##
## - **Windows, macOS, Linux:** the folder by its path, looked through again when it changes.
## - **Android:** the folder picked through the system's folder picker, the right to read it
##   kept for good (Android's persisted permission); its fonts listed once (their names kept,
##   so they are not opened again at the next start) and read through the documents provider
##   the first time they draw (`fontReader`).
## - **iOS:** the folder picked in Files, kept as a bookmark that opens it again at the next start.
## - **A web page:** font files chosen (or dropped on the page) are kept in the page's own
##   storage, a folder "Your Fonts".
##
## .. code-block:: nim
##   useFontFolders("My App")        # at the start: their fonts offered
##   fontFoldersPanel("My App")      # in a settings page: the list, Add, Remove, Refresh
##
## Fonts with TrueType or CFF outlines (.ttf, .otf, .ttc, .otc), in the folder and every folder
## inside it (CFF made TrueType when a font is first drawn: retroui/cff).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, json, times, tables, algorithm, sets, monotimes]
import core, widgets, platform, textengine, ttf
import uirelays/target
when not androidApp and not defined(ios):
  import business, filewidgets           # (the kit's own picker: not a phone's)
import uirelays/services

type
  FontFolderKind* = enum
    ffPath,         ## a folder on disk (desktops; the web's storage)
    ffTree,         ## Android: a folder given through the system's picker (`place`: its tree, a tab, its document)
    ffBookmark      ## iOS: a folder picked in Files (`place`: its bookmark, base64)

  FontFolder* = object
    ## A font folder of the user's.
    name*: string             ## what it is called (the folder's name)
    kind*: FontFolderKind
    place*: string            ## where it is (see `FontFolderKind`)


var
  fontsOf: Table[string, seq[string]]           # (each folder's families, by its place)
  stamps: Table[string, Time]                   # (desktop: when each folder last changed)
  lastLook = 0                                  # (when the folders were last looked at)
  picking = false
  pickPath = ""
  pickSel = -1
  storeOpen = false
  storePath = ""

proc folderList(app: string): string = dataDir(app) / "fontfolders.json"

proc fontFolders*(app: string): seq[FontFolder] =
  ## The font folders `app` keeps.
  try:
    for j in parseFile(folderList(app)){"folders"}:
      var f = FontFolder(name: j{"name"}.getStr, place: j{"place"}.getStr)
      for k in FontFolderKind:
        if $k == j{"kind"}.getStr: f.kind = k
      if f.place.len > 0: result.add f
  except CatchableError: discard

proc keep(app: string; list: seq[FontFolder]; index: JsonNode = nil) =
  var arr = newJArray()
  for f in list: arr.add %*{"name": f.name, "kind": $f.kind, "place": f.place}
  var j = %*{"folders": arr}
  # (Android: the fonts found, so they are not opened again)
  var old = newJObject()
  try: old = parseFile(folderList(app)){"index"} except CatchableError: discard
  j["index"] = if index != nil: index elif old != nil: old else: newJObject()
  try:
    createDir(dataDir(app))
    writeFile(folderList(app), $j)
  except CatchableError: discard

proc familiesIn*(f: FontFolder): seq[string] = fontsOf.getOrDefault(f.place)
  ## The families a folder's fonts gave (once `useFontFolders` has looked).

proc isFontFile(name: string): bool =
  let e = name.splitFile.ext.toLowerAscii
  e in fontFileExts

# ---- Android: through the documents provider ------------------------------------------------------

proc docPrefix(tree: string): string = "<doc:" & tree & "\t"

proc openDoc(tree, doc: string; f: var File): bool =
  let r = systemCall("open", tree & "\t" & doc & "\tr")
  if r.len == 0 or r == "\0": return false
  var fd = -1
  try: fd = parseInt(r) except ValueError: return false
  fd >= 0 and open(f, FileHandle(fd), fmRead)

proc readDoc(path: string): string {.nimcall, gcsafe.} =
  ## (`fontReader`: "<doc:TREE\tDOCUMENT>")
  {.cast(gcsafe).}:
    if not path.startsWith("<doc:") or not path.endsWith(">"): return ""
    let p = path[5 ..< path.high].split('\t')
    if p.len < 2: return ""
    var f: File
    if not openDoc(p[0], p[1], f): return ""
    defer: close(f)
    try: result = readAll(f) except IOError: result = ""

# ---- iOS: a bookmark of the folder picked in Files -------------------------------------------------

when defined(ios):
  import native

  proc objc_allocateClassPair(super: pointer; name: cstring; extra: int): pointer {.importc, cdecl.}
  proc objc_registerClassPair(cls: pointer) {.importc, cdecl.}
  proc class_addMethod(cls, name, imp: pointer; types: cstring): bool {.importc, cdecl.}

  var
    iosPicked = ""                     # (the bookmark of the folder picked; "\1" none)
    iosDelegate: ObjcId

  proc onFolderPicked(self: ObjcId; cmd: pointer; picker, urls: ObjcId) {.cdecl.} =
    iosPicked = "\1"
    if urls == nil or objcSend(int, urls, "count") == 0: return
    let u = objcSend(ObjcId, urls, "objectAtIndex:", 0)
    discard objcSend(bool, u, "startAccessingSecurityScopedResource")
    let data = objcSend(ObjcId, u, "bookmarkDataWithOptions:includingResourceValuesForKeys:relativeToURL:error:",
                        0, ObjcId(nil), ObjcId(nil), ObjcId(nil))
    if data == nil: return
    iosPicked = toNim(objcSend(ObjcId, data, "base64EncodedStringWithOptions:", 0)) & "\t" &
                toNim(objcSend(ObjcId, u, "lastPathComponent"))

  proc onFolderLeft(self: ObjcId; cmd: pointer; picker: ObjcId) {.cdecl.} = iosPicked = "\1"

  proc iosAskFolder(): bool =
    let utt = objcSend(ObjcId, objcClass("UTType"), "typeWithIdentifier:", nsString("public.folder"))
    if utt == nil: return false
    let types = objcSend(ObjcId, objcClass("NSArray"), "arrayWithObject:", utt)
    let vc = objcSend(ObjcId, objcSend(ObjcId, objcClass("UIDocumentPickerViewController"), "alloc"),
                      "initForOpeningContentTypes:", types)
    if vc == nil: return false
    if iosDelegate == nil:
      var cls = objcClass("RetroFontFolderDelegate")
      if cls == nil:
        cls = objc_allocateClassPair(objcClass("NSObject"), "RetroFontFolderDelegate", 0)
        discard class_addMethod(cls, sel("documentPicker:didPickDocumentsAtURLs:"),
                                cast[pointer](onFolderPicked), "v@:@@")
        discard class_addMethod(cls, sel("documentPickerWasCancelled:"), cast[pointer](onFolderLeft), "v@:@")
        objc_registerClassPair(cls)
      iosDelegate = objcSend(ObjcId, objcSend(ObjcId, cls, "alloc"), "init")
    objcSend(void, vc, "setDelegate:", iosDelegate)
    let app = objcSend(ObjcId, objcClass("UIApplication"), "sharedApplication")
    var window = objcSend(ObjcId, app, "keyWindow")
    if window == nil: return false
    let root = objcSend(ObjcId, window, "rootViewController")
    if root == nil: return false
    iosPicked = ""
    objcSend(void, root, "presentViewController:animated:completion:", vc, true, ObjcId(nil))
    true

  proc iosOpenBookmark(b64: string): string =
    ## (the folder a bookmark keeps, opened to read: its path; "" when it cannot be)
    let data = objcSend(ObjcId, objcSend(ObjcId, objcClass("NSData"), "alloc"),
                        "initWithBase64EncodedString:options:", nsString(b64), 0)
    if data == nil: return ""
    let u = objcSend(ObjcId, objcClass("NSURL"),
                     "URLByResolvingBookmarkData:options:relativeToURL:bookmarkDataIsStale:error:",
                     data, 0, ObjcId(nil), ObjcId(nil), ObjcId(nil))
    if u == nil: return ""
    discard objcSend(bool, u, "startAccessingSecurityScopedResource")
    toNim(objcSend(ObjcId, u, "path"))

# ---- using them ---------------------------------------------------------------------------------------

proc pathOf(f: FontFolder): string =
  ## (a folder on disk where there is one: a desktop's, the web's storage, iOS's bookmark opened)
  case f.kind
  of ffPath: f.place
  of ffBookmark:
    when defined(ios): iosOpenBookmark(f.place.split('\t')[0])
    else: ""
  of ffTree: ""

# ---- looking through them: a little each frame, its progress shown --------------------------------------
#
# A folder of fonts can hold thousands of files in folders inside folders, on a phone each one
# reached through the documents provider: looked through all at once the app would stop
# answering. So it is looked through a few milliseconds each frame -- the folders inside
# folders too, to the last --, what was found before taken from the index kept beside the
# list (a file's faces by its size and time: not opened again), and `fontScan` says how far
# it has got for a progress bar; `stopFontScan` lets it go.

type
  FontScan* = object
    ## How far looking through the font folders has got (`fontScan`).
    running*: bool             ## it is looking
    looked*: int               ## files and folders looked at so far
    found*: int                ## fonts (faces) found so far
    left*: int                 ## files and folders seen and not looked at yet
    folder*: string            ## the font folder it is in
  ScanDir = tuple[folder: int; dir: string]         # (a folder still to look in: a path or a document)
  ScanFile = tuple[folder: int; file: string; size, modified: int64]

var
  scan: FontScan
  scanApp = ""
  scanList: seq[FontFolder]
  scanDirs: seq[ScanDir]
  scanFiles: seq[ScanFile]
  scanFams: seq[seq[string]]           # (each folder's families, as they are found)
  scanIndex = newJObject()             # (each font file's faces, by its path or document)
  scanUsed: HashSet[string]            # (the files of the index still there)
  scanStop = false
  hooked = false

proc fontScan*(): FontScan =
  ## How far looking through the font folders has got (running: false when it is not).
  result = scan
  result.left = scanDirs.len + scanFiles.len

proc fontScanDone*(s: FontScan): float =
  ## About how much of it is done, 0 .. 1 (the folders inside folders are only known as it
  ## comes to them: it can go back a little).
  if not s.running: 1.0 else: s.looked / max(1, s.looked + s.left)

proc stopFontScan*() =
  ## Stops looking through the font folders: the fonts found so far stay offered.
  if scan.running: scanStop = true

proc offer(folder: int; file: string; faces: JsonNode) =
  let f = scanList[folder]
  for fj in faces:
    let fam = fj{"family"}.getStr
    if fam.len == 0: continue
    let path = if f.kind == ffTree: docPrefix(f.place.split('\t')[0]) & file & ">" else: file
    addFontFile(fam, fj{"style"}.getStr, path, fj{"weight"}.getInt(400), fj{"italic"}.getBool,
                fj{"index"}.getInt)
    if fam notin scanFams[folder]: scanFams[folder].add fam
    inc scan.found

proc facesJson(fs: seq[tuple[family, style: string; weight: int; italic: bool; index: int;
                             variable: bool]]): JsonNode =
  result = newJArray()
  for fi in fs:
    result.add %*{"family": fi.family, "style": fi.style, "weight": fi.weight, "index": fi.index,
                  "italic": fi.italic}

proc scanOne(): bool =
  ## (one step of looking: a file's faces, or a folder's list; false when there is nothing left)
  if scanFiles.len > 0:
    let it = scanFiles.pop()
    inc scan.looked
    let key = it.file
    let known = scanIndex{key}
    scanUsed.incl key
    if known != nil and known{"size"}.getBiggestInt == it.size and known{"modified"}.getBiggestInt == it.modified:
      offer(it.folder, it.file, known{"faces"})
      return true
    var faces = newJArray()
    let f = scanList[it.folder]
    if f.kind == ffTree:
      when androidApp:
        var fh: File
        if openDoc(f.place.split('\t')[0], it.file, fh):
          try: faces = facesJson(faceInfo(fh))
          finally: close(fh)
    else:
      faces = facesJson(faceInfo(it.file))
    scanIndex[key] = %*{"size": it.size, "modified": it.modified, "faces": faces}
    offer(it.folder, it.file, faces)
    return true
  if scanDirs.len > 0:
    let d = scanDirs.pop()
    inc scan.looked
    let f = scanList[d.folder]
    scan.folder = f.name
    if f.kind == ffTree:
      when androidApp:
        let r = systemCall("list", f.place.split('\t')[0] & "\t" & d.dir)
        if r.len > 0 and r != "\0":
          for line in r.splitLines:
            let q = line.split('\t')
            if q.len < 5: continue
            if q[2] == "vnd.android.document/directory": scanDirs.add (d.folder, q[0])
            elif isFontFile(q[1]):
              scanFiles.add (d.folder, q[0], (try: parseBiggestInt(q[3]) except ValueError: 0'i64),
                             (try: parseBiggestInt(q[4]) except ValueError: 0'i64))
    else:
      try:
        for kind, p in walkDir(d.dir):
          case kind
          of pcDir, pcLinkToDir: scanDirs.add (d.folder, p)
          of pcFile, pcLinkToFile:
            if isFontFile(p):
              let size = try: getFileSize(p) except OSError: 0'i64
              let t = try: getLastModificationTime(p).toUnix except OSError: 0'i64
              scanFiles.add (d.folder, p, size, t)
        try: stamps[d.dir] = getLastModificationTime(d.dir) except OSError: discard
      except OSError: discard
    return true
  false

proc finishScan() =
  scan.running = false
  scan.folder = ""
  for i, f in scanList:
    scanFams[i].sort(cmpIgnoreCase)
    fontsOf[f.place] = scanFams[i]
  # (the index: the files still there, so it does not grow with fonts taken away)
  if not scanStop:
    var kept = newJObject()
    for k, v in scanIndex:
      if k in scanUsed: kept[k] = v
    scanIndex = kept
  keep(scanApp, scanList, scanIndex)
  scanStop = false
  scanFonts(force = true)

proc scanFrame() {.nimcall.} =
  ## (each frame while it looks: what a few milliseconds allow)
  if not scan.running: return
  if scanStop:
    scanDirs.setLen(0)
    scanFiles.setLen(0)
  let until = getMonoTime() + initDuration(milliseconds = 12)
  while true:
    if not scanOne():
      finishScan()
      return
    if getMonoTime() > until: break
  # (and the next frame soon: the progress drawn, the looking going on)
  wakeIn(1)

proc waitFontScan*() =
  ## Looks through the font folders to the end now, if it is looking (a tool without frames,
  ## a test).
  while scan.running:
    if scanStop or not scanOne():
      finishScan()
      return

proc startScan(app: string) =
  ## (the folders looked through from the start: what each offers dropped first)
  scanApp = app
  scanList = fontFolders(app)
  scanDirs.setLen(0)
  scanFiles.setLen(0)
  scanUsed.clear()
  scanFams = newSeq[seq[string]](scanList.len)
  try:
    let old = parseFile(folderList(app)){"index"}
    scanIndex = if old != nil and old.kind == JObject: old else: newJObject()
  except CatchableError: scanIndex = newJObject()
  for i, f in scanList:
    case f.kind
    of ffTree:
      let p = f.place.split('\t')
      dropFontFiles(docPrefix(p[0]))
      if p.len >= 2: scanDirs.add (i, p[1])
    of ffPath, ffBookmark:
      let dir = pathOf(f)
      if dir.len > 0:
        dropFontFiles(dir)
        if dirExists(dir): scanDirs.add (i, dir)
  scanDirs.reverse()                   # (the first folder first)
  scan = FontScan(running: true)
  scanStop = false
  if not hooked:
    hooked = true
    beginFrameHooks.add scanFrame
  wakeIn(1)

proc useFontFolders*(app: string) =
  ## The fonts of `app`'s font folders -- in them and in every folder inside them -- offered to
  ## every font list (at the start; again after a folder is added: `refreshFontFolders`). They
  ## are looked through a little each frame from now (`fontScan`: how far it has got), the
  ## fonts it found before offered as it comes to them without being opened again.
  fontReader = readDoc
  startScan(app)

proc refreshFontFolders*(app: string) =
  ## Looks through `app`'s font folders again (fonts added or taken away).
  startScan(app)

proc addFontFolder*(app: string; f: FontFolder) =
  ## Keeps a font folder for `app` and offers its fonts.
  var list = fontFolders(app)
  for g in list:
    if g.place == f.place: return
  list.add f
  keep(app, list)
  refreshFontFolders(app)

proc removeFontFolder*(app: string; i: int) =
  ## Forgets font folder `i` of `app`; its fonts are no longer offered.
  var list = fontFolders(app)
  if i notin 0 ..< list.len: return
  let f = list[i]
  list.delete(i)
  keep(app, list)
  case f.kind
  of ffTree: dropFontFiles(docPrefix(f.place.split('\t')[0]))
  else: dropFontFiles(pathOf(f))
  fontsOf.del f.place
  scanFonts(force = true)

proc watchFontFolders*(app: string) =
  ## (desktops: every few seconds, a folder that changed looked through again -- fonts put in
  ## or taken away while the app runs)
  if ui.now - lastLook < 5000 or scan.running: return
  lastLook = ui.now
  for dir, t in stamps:
    try:
      if getLastModificationTime(dir) != t:
        refreshFontFolders(app)
        return
    except OSError: discard

proc storeFolder*(app: string): string = dataDir(app) / "Your Fonts"
  ## (a web page: where the fonts chosen are kept, in the page's storage)

proc storeFonts*(app: string; paths: openArray[string]): int =
  ## A web page (or anywhere): font files chosen or dropped kept in `app`'s own "Your Fonts"
  ## folder, which becomes a font folder; how many were fonts.
  let dir = storeFolder(app)
  try: createDir(dir) except OSError: return 0
  for p in paths:
    if not isFontFile(p) or faceInfo(p).len == 0: continue
    try:
      copyFile(p, dir / p.extractFilename)
      inc result
    except OSError: discard
  if result > 0:
    var list = fontFolders(app)
    var has = false
    for f in list:
      if f.place == dir: has = true
    if not has:
      list.add FontFolder(name: "Your Fonts", kind: ffPath, place: dir)
      keep(app, list)
    refreshFontFolders(app)

# ---- the panel ------------------------------------------------------------------------------------------

proc fontFoldersPanel*(app: string) =
  ## The font folders of `app` -- each with its families --, and Add, Remove, Refresh: a settings
  ## page's part. Adding uses this system's way: a folder picked (the system's picker on a
  ## phone), or in a web page font files chosen and kept.
  let list = fontFolders(app)
  var names: seq[string]
  for f in list:
    let fams = f.familiesIn
    names.add f.name & "  -- " & (if fams.len == 0: tr("no fonts found")
                                  elif fams.len <= 3: fams.join(", ")
                                  else: fams[0 .. 2].join(", ") & tr(" and ") & $(fams.len - 3) & tr(" more"))
  if names.len == 0:
    label("No folder yet: fonts you keep in a folder of your own come into every font list.",
          color = ui.theme.gray)
  let sc = fontScan()
  if sc.running:
    label(tr("Looking through ") & sc.folder & ": " & $sc.looked & tr(" files and folders, ") & $sc.found &
          tr(" fonts"))
    row:
      progress(sc.fontScanDone, w = dp(240))
      if button("Stop", w = dp(70)): stopFontScan()
  else:
    pickSel = clamp(pickSel, -1, names.high)
    listbox(names, pickSel, rows = min(6, max(3, names.len)))
  row:
    let web = platformName() == "web"
    if button(if web: "Add Fonts..." else: "Add Folder...", w = dp(110)):
      when androidApp:
        discard systemCall("treeAsk", "")
        picking = true
      elif defined(ios):
        picking = iosAskFolder()
      else:
        if web: storeOpen = true else: picking = true
    if button("Remove", w = dp(80), enabled = pickSel in 0 ..< list.len):
      removeFontFolder(app, pickSel)
      pickSel = -1
    if button("Refresh", w = dp(80), enabled = list.len > 0 and not sc.running): refreshFontFolders(app)
  # what a picker gave
  when androidApp:
    if picking:
      let r = systemCall("treePicked", "")
      if r.len > 0 and r != "\0":
        picking = false
        let p = r.split('\t')
        if r != "\1" and p.len >= 2:
          let doc = p[1]
          let tail = doc.split({':', '/'})
          addFontFolder(app, FontFolder(name: (if tail.len > 0 and tail[^1].len > 0: tail[^1] else: doc),
                                        kind: ffTree, place: p[0] & "\t" & doc))
      else: wakeIn(200)
  elif defined(ios):
    if picking:
      if iosPicked.len > 0:
        picking = false
        if iosPicked != "\1":
          let p = iosPicked.split('\t')
          addFontFolder(app, FontFolder(name: (if p.len > 1: p[1] else: "Fonts"), kind: ffBookmark,
                                        place: p[0]))
      else: wakeIn(200)
  else:
    if filePicker(picking, pickPath, fmFolder, [], "Add a Font Folder"):
      addFontFolder(app, FontFolder(name: pickPath.lastPathPart, kind: ffPath, place: pickPath))
    if filePicker(storeOpen, storePath, fmOpen, ["*.ttf", "*.otf", "*.ttc", "*.otc"], "Add Fonts"):
      discard storeFonts(app, [storePath])
  watchFontFolders(app)

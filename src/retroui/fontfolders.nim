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
## Only TrueType fonts (.ttf, .ttc): the text engine draws TrueType outlines.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, json, times, tables, algorithm]
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

  FolderFont = object
    file, family, style: string
    weight, index: int
    italic: bool
    size, modified: int64

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
  e in [".ttf", ".ttc"]

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

proc indexTree(app: string; folder: FontFolder; index: JsonNode): seq[FolderFont] =
  ## (the fonts in a folder given through the picker, and below: those seen before by their
  ## size and time, the others opened for their names)
  let p = folder.place.split('\t')
  if p.len < 2: return
  let tree = p[0]
  var dirs = @[p[1]]
  var seen = 0
  while dirs.len > 0 and seen < 4000:
    let dir = dirs.pop()
    let r = systemCall("list", tree & "\t" & dir)
    if r.len == 0 or r == "\0": continue
    for line in r.splitLines:
      let q = line.split('\t')
      if q.len < 5: continue
      inc seen
      if q[2] == "vnd.android.document/directory":
        dirs.add q[0]
        continue
      if not isFontFile(q[1]): continue
      let size = (try: parseBiggestInt(q[3]) except ValueError: 0'i64)
      let modified = (try: parseBiggestInt(q[4]) except ValueError: 0'i64)
      let known = index{q[0]}
      if known != nil and known{"size"}.getBiggestInt == size and known{"modified"}.getBiggestInt == modified:
        for fj in known{"faces"}:
          result.add FolderFont(file: q[0], family: fj{"family"}.getStr, style: fj{"style"}.getStr,
                                weight: fj{"weight"}.getInt(400), index: fj{"index"}.getInt,
                                italic: fj{"italic"}.getBool, size: size, modified: modified)
        continue
      var f: File
      if not openDoc(tree, q[0], f): continue
      var faces = newJArray()
      try:
        for fi in faceInfo(f):
          faces.add %*{"family": fi.family, "style": fi.style, "weight": fi.weight, "index": fi.index,
                       "italic": fi.italic}
          result.add FolderFont(file: q[0], family: fi.family, style: fi.style, weight: fi.weight,
                                index: fi.index, italic: fi.italic, size: size, modified: modified)
      finally: close(f)
      index[q[0]] = %*{"size": size, "modified": modified, "faces": faces}

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

proc familiesOfDir(dir: string): seq[string] =
  for path in walkDirRec(dir):
    if not isFontFile(path): continue
    for fi in faceInfo(path):
      if fi.family notin result: result.add fi.family
  result.sort(cmpIgnoreCase)

proc useFontFolders*(app: string) =
  ## The fonts of `app`'s font folders offered to every font list (at the start; again after a
  ## folder is added: `refreshFontFolders`).
  fontReader = readDoc
  let list = fontFolders(app)
  var index = newJObject()
  try:
    let old = parseFile(folderList(app)){"index"}
    if old != nil and old.kind == JObject: index = old
  except CatchableError: discard
  var touched = false
  for f in list:
    case f.kind
    of ffPath, ffBookmark:
      let dir = pathOf(f)
      if dir.len > 0 and dirExists(dir):
        addFontDir(dir)
        fontsOf[f.place] = familiesOfDir(dir)
        try: stamps[dir] = getLastModificationTime(dir) except OSError: discard
    of ffTree:
      when androidApp:
        let before = index.len
        var fams: seq[string]
        for ff in indexTree(app, f, index):
          addFontFile(ff.family, ff.style, docPrefix(f.place.split('\t')[0]) & ff.file & ">", ff.weight,
                      ff.italic, ff.index)
          if ff.family notin fams: fams.add ff.family
        fams.sort(cmpIgnoreCase)
        fontsOf[f.place] = fams
        if index.len != before: touched = true
  if touched: keep(app, list, index)
  scanFonts(force = true)

proc refreshFontFolders*(app: string) =
  ## Looks through `app`'s font folders again (fonts added or taken away).
  for f in fontFolders(app):
    if f.kind == ffTree: dropFontFiles(docPrefix(f.place.split('\t')[0]))
  useFontFolders(app)

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
  else: removeFontDir(pathOf(f))
  fontsOf.del f.place
  scanFonts(force = true)

proc watchFontFolders*(app: string) =
  ## (desktops: every few seconds, a folder that changed looked through again -- fonts put in
  ## or taken away while the app runs)
  if ui.now - lastLook < 5000: return
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
    names.add f.name & "  -- " & (if fams.len == 0: "no fonts found"
                                  elif fams.len <= 3: fams.join(", ")
                                  else: fams[0 .. 2].join(", ") & " and " & $(fams.len - 3) & " more")
  if names.len == 0:
    label("No folder yet: fonts you keep in a folder of your own come into every font list.",
          color = ui.theme.gray)
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
    if button("Refresh", w = dp(80), enabled = list.len > 0): refreshFontFolders(app)
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
    if filePicker(storeOpen, storePath, fmOpen, ["*.ttf", "*.ttc"], "Add Fonts"):
      discard storeFonts(app, [storePath])
  watchFontFolders(app)

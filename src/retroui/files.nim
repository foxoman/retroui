## Files for apps that work with them (a file manager, an Open dialog, a
## backup tool): folder listings with sizes and dates, file types with their
## names and icons, readable sizes and times, free disk space, and file
## jobs -- copy, move, delete, zip, unzip, measure a folder -- that run a
## few milliseconds per frame, so the window stays alive and can show
## their progress and ask what to do when a name is taken. The trash
## (`moveToTrash`, `trashItems`) and undo of file operations (`remember`,
## `undo`) are here too; `retroui/filewidgets` shows files on screen.
##
## ```nim
## var items = listFolder(getHomeDir())
## sortFiles(items, bySize, descending = true)
## for f in items: echo f.name, "  ", sizeText(f.size), "  ", kindName(f)
## let job = newJob(jkCopy, [getHomeDir() / "notes.txt"], getTempDir())
## runAll(job)                     # (in an app: `run(job)` each frame)
## ```

import std/[os, times, strutils, algorithm, monotimes]
import gfx, icons, business, zip, docfs, core

when defined(windows):
  import std/widestrs
else:
  from std/posix import Statvfs, statvfs, Stat, stat, getuid, Dev

type
  FileItem* = object
    ## A file or folder as a listing shows it.
    name*, path*: string    ## its name, and its whole path
    isDir*, isLink*, hidden*, readOnly*: bool
      ## a folder; a symbolic link; hidden (`hiddenFile`: its name starts
      ## with a dot, or the system hides it); not writable by this user
    size*: int64            ## bytes (folders: 0)
    modified*: Time         ## when it last changed
    stub*: bool             ## from a quick listing: size and date not read yet

  FileKind* = enum
    ## The kind of a file, by its extension (`kindOf`): for its icon
    ## (`kindIcon`) and the Type column.
    fkFolder, fkText, fkCode, fkDocument, fkImage, fkAudio, fkVideo,
    fkArchive, fkApp, fkOther

  SortKey* = enum
    ## What `sortFiles` sorts by.
    byName, bySize, byKind, byDate

# ---- listing ---------------------------------------------------------------------

when defined(windows):
  proc getFileAttributesW(path: WideCString): uint32
    {.stdcall, dynlib: "kernel32", importc: "GetFileAttributesW".}
elif defined(macosx) and not defined(ios):
  type MacStat {.importc: "struct stat", header: "<sys/stat.h>", pure, final.} = object
    st_flags: uint32
  proc macLstat(path: cstring; st: var MacStat): cint
    {.importc: "lstat", header: "<sys/stat.h>".}

proc hiddenFile*(path: string; name = path.extractFilename): bool =
  ## `path` is one a file manager leaves out until it is asked for hidden
  ## files: its name starts with a dot (everywhere), Windows marks it hidden
  ## or the system's (desktop.ini, $RECYCLE.BIN, System Volume Information),
  ## the Finder hides it (~/Library, the system's folders in /).
  if name.startsWith("."): return true
  when defined(windows):
    if path.len <= 3: return false      # (a drive: C:\ is marked so itself)
    let a = getFileAttributesW(newWideCString(path))
    a != 0xFFFFFFFF'u32 and (a and 0x6'u32) != 0   # FILE_ATTRIBUTE_HIDDEN, _SYSTEM
  elif defined(macosx) and not defined(ios):
    var st: MacStat
    if macLstat(path.cstring, st) == 0 and (st.st_flags and 0x8000'u32) != 0:
      return true                       # UF_HIDDEN
    path.normalizedPath == (getHomeDir() / "Library").normalizedPath
  else:
    false

proc infoOf*(path: string): FileItem =
  ## What is known about `path` (it follows symbolic links).
  result.path = path
  result.name = path.extractFilename
  if result.name.len == 0: result.name = path
  result.hidden = hiddenFile(path, result.name)
  try:
    let i = getFileInfo(path, followSymlink = true)
    result.isDir = i.kind in {pcDir, pcLinkToDir}
    result.size = if result.isDir: 0 else: i.size
    result.modified = i.lastWriteTime
    result.readOnly = fpUserWrite notin i.permissions
    result.isLink = symlinkExists(path)
    when defined(windows):
      if result.isDir and path.len <= 3: result.name = path   # "C:\"
  except OSError:
    result.isLink = symlinkExists(path)

proc listFolder*(dir: string; showHidden = false; quick = false): seq[FileItem] =
  ## The files and folders in `dir`. Raises `OSError` if it cannot be read.
  ## One `stat` per entry: the entry's kind comes with the listing. A
  ## folder of another app given through its provider (`docfs`) is listed
  ## by the provider. `quick`: names and kinds only, no `stat` (items are
  ## `stub`) -- many times faster on slow storage (a phone's shared
  ## storage, network drives), for showing a folder at once.
  if isDocPath(dir):
    for e in docList(dir):
      if not showHidden and e.name.startsWith("."): continue
      result.add FileItem(path: e.path, name: e.name, hidden: e.name.startsWith("."),
                          isDir: e.isDir, size: (if e.isDir: 0 else: e.size),
                          modified: e.modified)
    return
  for kind, p in walkDir(dir, checkDir = true):
    let n = p.extractFilename
    let hidden = hiddenFile(p, n)
    if not showHidden and hidden: continue
    var f = FileItem(path: p, name: n, hidden: hidden,
                     isLink: kind in {pcLinkToFile, pcLinkToDir},
                     isDir: kind in {pcDir, pcLinkToDir}, stub: quick)
    if quick:
      result.add f
      continue
    try:
      let i = getFileInfo(p, followSymlink = true)
      f.isDir = i.kind in {pcDir, pcLinkToDir}
      f.size = if f.isDir: 0 else: i.size
      f.modified = i.lastWriteTime
      f.readOnly = fpUserWrite notin i.permissions
    except OSError: discard
    result.add f

proc subFolders*(dir: string; showHidden = false): seq[string] =
  ## The folders in `dir`, sorted by name (empty if it cannot be read).
  try:
    for (kind, p) in vWalk(dir):
      if kind in {pcDir, pcLinkToDir} and (showHidden or not hiddenFile(p)):
        result.add p
  except OSError: discard
  result.sort(proc (a, b: string): int =
    cmpIgnoreCase(a.extractFilename, b.extractFilename))

proc hasSubFolders*(dir: string; showHidden = false): bool =
  ## `dir` has folders in it (hidden ones count only with `showHidden`).
  try:
    for (kind, p) in vWalk(dir):
      if kind in {pcDir, pcLinkToDir} and (showHidden or not hiddenFile(p)): return true
  except OSError: discard

# ---- kinds ------------------------------------------------------------------------

const kindsByExt = [
  (fkText, @["txt", "md", "log", "csv", "tsv", "ini", "cfg", "conf", "rst",
             "srt", "nfo", "readme"]),
  (fkCode, @["nim", "nims", "nimble", "c", "h", "cpp", "hpp", "cc", "m", "js",
             "ts", "py", "rb", "go", "rs", "java", "kt", "swift", "sh", "bat",
             "ps1", "json", "xml", "html", "htm", "css", "yaml", "yml", "toml",
             "sql", "lua", "php", "cs", "pl", "zig", "v", "d", "asm"]),
  (fkDocument, @["pdf", "doc", "docx", "odt", "rtf", "xls", "xlsx", "ods",
                 "ppt", "pptx", "odp", "epub"]),
  (fkImage, @["png", "jpg", "jpeg", "gif", "bmp", "webp", "svg", "ico", "tif",
              "tiff", "heic", "heif", "psd"]),
  (fkAudio, @["mp3", "wav", "ogg", "opus", "flac", "m4a", "aac", "wma", "mid",
              "midi", "amr"]),
  (fkVideo, @["mp4", "mkv", "avi", "mov", "webm", "wmv", "3gp", "m4v", "flv",
              "mpg", "mpeg"]),
  (fkArchive, @["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst",
                "jar", "iso"]),
  (fkApp, @["apk", "exe", "msi", "app", "deb", "rpm", "appimage", "so", "dll",
            "dylib", "bin"])]

proc extOf*(name: string): string =
  ## "Photo.JPG" -> "jpg".
  let e = name.splitFile.ext
  if e.len > 1: e[1 .. ^1].toLowerAscii else: ""

proc kindOf*(f: FileItem): FileKind =
  ## The kind of a file, by its extension (`fkFolder` for a folder).
  if f.isDir: return fkFolder
  let e = extOf(f.name)
  for (k, exts) in kindsByExt:
    if e in exts: return k
  fkOther

proc kindIcon*(k: FileKind): Icon =
  ## The 16x16 icon of a kind of file.
  case k
  of fkFolder: icFolder
  of fkText: icText
  of fkCode: icCode
  of fkDocument: icText
  of fkImage: icImage
  of fkAudio: icAudio
  of fkVideo: icVideo
  of fkArchive: icArchive
  of fkApp: icApp
  of fkOther: icFile

proc kindNameEn(f: FileItem; e, up: string): string =
  case kindOf(f)
  of fkText:
    case e
    of "txt": "Text Document"
    of "md", "markdown": "Markdown Document"
    of "log": "Log File"
    else: up & " File"
  of fkCode: up & " Source"
  of fkDocument: up & " Document"
  of fkImage: up & " Image"
  of fkAudio: up & " Audio"
  of fkVideo: up & " Video"
  of fkArchive: up & " Archive"
  of fkApp: (if e == "apk": "Android App" elif e == "exe": "Application" else: up & " File")
  of fkFolder: "File folder"
  of fkOther: (if e.len > 0: up & " File" else: "File")

proc kindName*(f: FileItem): string =
  ## "File folder", "Text Document", "PNG Image", "MP3 Audio"... (in
  ## another language: "$1 Image" and the others looked up, $1 the kind).
  if f.isDir: return tr("File folder")
  let e = extOf(f.name)
  let up = e.toUpperAscii
  result = kindNameEn(f, e, up)
  if uiLanguageCode() notin ["", "en"]:
    let t = tr(result)
    if t != result: result = t; return
    if up.len > 0 and result.startsWith(up & " "):
      result = tr("$1" & result[up.len .. ^1]).replace("$1", up)

proc mimeType*(name: string): string =
  ## The MIME type of a file name, for handing it to other apps.
  case extOf(name)
  of "txt", "log", "ini", "cfg", "conf", "nim", "c", "h", "py", "sh", "md",
     "markdown":
    "text/plain"           # (more apps take text/plain than text/markdown)
  of "csv": "text/csv"
  of "html", "htm": "text/html"
  of "json": "application/json"
  of "xml": "text/xml"
  of "pdf": "application/pdf"
  of "zip": "application/zip"
  of "apk": "application/vnd.android.package-archive"
  of "png": "image/png"
  of "jpg", "jpeg": "image/jpeg"
  of "gif": "image/gif"
  of "webp": "image/webp"
  of "bmp": "image/bmp"
  of "svg": "image/svg+xml"
  of "mp3": "audio/mpeg"
  of "wav": "audio/wav"
  of "ogg", "opus": "audio/ogg"
  of "m4a", "aac": "audio/mp4"
  of "flac": "audio/flac"
  of "mp4", "m4v": "video/mp4"
  of "mkv": "video/x-matroska"
  of "webm": "video/webm"
  of "3gp": "video/3gpp"
  of "doc": "application/msword"
  of "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  of "xls": "application/vnd.ms-excel"
  of "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
  of "ppt": "application/vnd.ms-powerpoint"
  of "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
  of "odt": "application/vnd.oasis.opendocument.text"
  of "epub": "application/epub+zip"
  else: "*/*"

proc cmpNatural*(a, b: string): int =
  ## Compares names as people read them: case does not matter, and numbers
  ## by their value ("file2" before "file10"). Names that read the same
  ## ("a" and "A", "7" and "007") still get a fixed order.
  var i, j = 0
  while i < a.len and j < b.len:
    let ca = a[i]
    let cb = b[j]
    if ca in Digits and cb in Digits:
      var ea = i
      while ea < a.len and a[ea] in Digits: inc ea
      var eb = j
      while eb < b.len and b[eb] in Digits: inc eb
      var za = i
      while za < ea - 1 and a[za] == '0': inc za     # leading zeros
      var zb = j
      while zb < eb - 1 and b[zb] == '0': inc zb
      if ea - za != eb - zb: return cmp(ea - za, eb - zb)
      for k in 0 ..< ea - za:
        if a[za + k] != b[zb + k]: return cmp(a[za + k], b[zb + k])
      i = ea
      j = eb
    else:
      let la = toLowerAscii(ca)
      let lb = toLowerAscii(cb)
      if la != lb: return cmp(la, lb)
      inc i
      inc j
  result = cmp(a.len - i, b.len - j)
  if result == 0: result = cmp(a, b)

proc sortFiles*(items: var seq[FileItem]; by = byName; descending = false;
                foldersFirst = true) =
  ## Sorts a listing; folders stay before files. Names sort naturally
  ## ("photo 2" before "photo 10").
  var kinds: seq[string]
  if by == byKind:
    kinds = newSeq[string](items.len)
    for i, it in items: kinds[i] = kindName(it).toLowerAscii
  var order = newSeq[int](items.len)
  for i in 0 ..< order.len: order[i] = i
  let all = cast[ptr UncheckedArray[FileItem]](if items.len > 0: addr items[0] else: nil)
  order.sort(proc (x, y: int): int =
    let a = addr all[x]
    let b = addr all[y]
    if foldersFirst and a.isDir != b.isDir: return (if a.isDir: -1 else: 1)
    result = case by
      of byName: cmpNatural(a.name, b.name)
      of bySize: cmp(a.size, b.size)
      of byKind: cmp(kinds[x], kinds[y])
      of byDate: cmp(a.modified, b.modified)
    if result == 0 and by != byName: result = cmpNatural(a.name, b.name)
    if descending: result = -result)
  var sorted = newSeq[FileItem](items.len)
  for i, k in order: sorted[i] = move items[k]
  items = move sorted

proc isPicture*(f: FileItem): bool =
  ## A picture `loadPicture` may read (by its extension).
  not f.isDir and (extOf(f.name) in ["png", "bmp", "jpg", "jpeg", "gif", "webp", "heic", "heif", "ico"] or
                   pictureReaderFor(f.name) != nil)

proc isTextFile*(f: FileItem): bool =
  ## A file that is text (by its kind or extension): shown as lines.
  not f.isDir and (kindOf(f) in {fkText, fkCode} or extOf(f.name) in
    ["txt", "log", "ini", "cfg", "conf", "csv", "tsv", "json", "xml", "yml",
     "yaml", "toml", "nim", "nims", "nimble", "sh", "md", "markdown", "html",
     "htm", "css", "js", "ts", "c", "h", "cpp", "py", "java", "kt", "go", "rs"])

proc isMarkdown*(f: FileItem): bool =
  ## A Markdown file (.md, .markdown).
  not f.isDir and extOf(f.name) in ["md", "markdown"]

proc cleanPath*(p: string): string =
  ## `p` normalized, without a trailing separator ("/" and "C:\" stay).
  result = p.normalizedPath
  while result.len > 1 and result[^1] in {'/', '\\'} and not result.endsWith(":\\"):
    result.setLen(result.len - 1)

# ---- formats ---------------------------------------------------------------------

proc countText*(n: int; what: string; many = ""): string =
  ## 1 -> "1 file", 3 -> "3 files", 1204 -> "1,204 files" (`many`: the
  ## plural when it is not `what` & "s").
  ## In another language (`setUiLanguage`) the word is looked up with its
  ## space (" files").
  insertSep($n, ',') & tr(" " & (if n == 1: what elif many.len > 0: many else: what & "s"))

proc sizeText*(bytes: int64): string =
  ## 532 -> "532 bytes", 1536 -> "1.5 KB", 734003200 -> "700 MB".
  if bytes < 1024: return $bytes & tr(if bytes == 1: " byte" else: " bytes")
  const units = ["KB", "MB", "GB", "TB", "PB"]
  var v = bytes.float / 1024
  var u = 0
  while v >= 1024 and u < units.high:
    v /= 1024
    inc u
  (if v < 10: formatFloat(v, ffDecimal, 1) else: $int(v + 0.5)) & " " & units[u]

proc timeText*(t: Time): string =
  ## The date in `dateStyle` and the time: "27/10/2026 10:04".
  if t.toUnix == 0: return ""
  let d = t.local
  $date(d.year, ord(d.month), d.monthday) & " " & intToStr(d.hour, 2) & ":" &
    intToStr(d.minute, 2)

proc uniqueName*(dir, name: string): string =
  ## `name`, or "name (2).ext", "name (3).ext"... -- the first not in `dir`.
  if not vExists(dir / name): return name
  let (_, base, ext) = splitFile(name)
  var n = 2
  while true:
    let t = base & " (" & $n & ")" & ext
    if not vExists(dir / t): return t
    inc n

proc validName*(name: string): string =
  ## Why `name` cannot be a file name ("" when it can). On Windows also a
  ## device's name (CON, PRN, AUX, NUL, COM1..9, LPT1..9, with an extension
  ## or not), and a dot or a space at the end, which Windows drops.
  if name.strip.len == 0: return "A name cannot be empty."
  if name in [".", ".."]: return "That name is reserved."
  for c in name:
    if c in {'/', '\0'} or (defined(windows) and c in {'\\', ':', '*', '?', '"', '<', '>', '|'}):
      return "A name cannot contain " & (if c == '\0': "NUL" else: $c) & "."
  when defined(windows):
    if name[^1] in {'.', ' '}: return "A name cannot end in a dot or a space."
    let stem = name.split('.')[0].strip.toUpperAscii
    if stem in ["CON", "PRN", "AUX", "NUL"] or
       (stem.len == 4 and stem[0 .. 2] in ["COM", "LPT"] and stem[3] in {'1' .. '9'}):
      return "That name is reserved."

proc diskSpace*(path: string): tuple[free, total: int64] =
  ## Free and total bytes of the disk that holds `path` (0, 0 if unknown).
  when defined(windows):
    proc getDiskFreeSpaceExW(dir: WideCString; avail, total, free: ptr int64): int32
      {.stdcall, dynlib: "kernel32", importc: "GetDiskFreeSpaceExW".}
    var a, t, f: int64
    if getDiskFreeSpaceExW(newWideCString(path), addr a, addr t, addr f) != 0:
      result = (a, t)
  else:
    var s: Statvfs
    if statvfs(path.cstring, s) == 0:
      result = (int64(s.f_bavail) * int64(s.f_frsize),
                int64(s.f_blocks) * int64(s.f_frsize))

# ---- the trash -------------------------------------------------------------------
#
# The freedesktop.org trash (Linux, BSD, Android here): files go to
# Trash/files, a Trash/info/NAME.trashinfo says where they came from and
# when. Files on the home disk use ~/.local/share/Trash; files on another
# disk (a USB stick, the phone's shared storage) use DISK/.Trash-UID, so
# nothing is copied across disks. Windows uses the Recycle Bin, macOS
# ~/.Trash.

type
  TrashItem* = object
    ## Something in the trash.
    name*: string            ## its name in the trash
    original*: string        ## where it was
    deleted*: Time           ## when it went to the trash
    isDir*: bool             ## a folder
    size*: int64             ## bytes (folders: 0)
    path*: string            ## where it is now (in the trash)
    info: string             ## its .trashinfo file

proc homeTrash(): string =
  let data = (let x = getEnv("XDG_DATA_HOME"); if x.len > 0: x else: getHomeDir() / ".local" / "share")
  data / "Trash"

when not defined(windows):
  proc deviceOf(path: string): Dev =
    var st: Stat
    var p = path
    while p.len > 0:
      if stat(p.cstring, st) == 0: return st.st_dev
      let up = p.parentDir
      if up == p: break
      p = up
    Dev(0)

  proc mountRoot(path: string): string =
    ## The folder where the disk holding `path` begins.
    let dev = deviceOf(path)
    result = path
    while true:
      let up = result.parentDir
      if up.len == 0 or up == result or deviceOf(up) != dev: return
      result = up

proc usable(trash: string): bool =
  try:
    createDir(trash / "files")
    createDir(trash / "info")
    true
  except CatchableError: false

proc trashFor*(path: string): string =
  ## The trash folder `path` goes to ("" where there is none: Windows): the
  ## home one for the home disk, else one at the top of the disk -- or as
  ## high above `path` as the app may write (phones' shared storage).
  when defined(windows): ""
  elif defined(macosx) or defined(ios): getHomeDir() / ".Trash"
  else:
    let home = homeTrash()
    if deviceOf(path.parentDir) == deviceOf(getHomeDir()) and usable(home): return home
    let mine = ".Trash-" & $getuid()
    var tops: seq[string]
    var a = path.parentDir
    let root = mountRoot(path)
    while a.len > 0:
      tops.insert(a, 0)
      if a == root: break
      let up = a.parentDir
      if up == a: break
      a = up
    for t in tops:
      if usable(t / mine): return t / mine
    ""

proc encodePath(p: string): string =
  for c in p:
    if c in {'a'..'z', 'A'..'Z', '0'..'9', '/', '-', '_', '.', '~'}: result.add c
    else: result.add '%' & toHex(ord(c), 2)

proc decodePath(p: string): string =
  var i = 0
  while i < p.len:
    if p[i] == '%' and i + 2 < p.len:
      try: result.add char(parseHexInt(p[i + 1 .. i + 2]))
      except ValueError: result.add p[i]
      i += 3
    else:
      result.add p[i]
      inc i

proc moveToTrash*(path: string): string =
  ## Moves `path` (a file or a folder) to the trash; returns the error, or
  ## "" (`trashItems` lists it, `restore` brings it back).
  when defined(windows):
    type SHFILEOPSTRUCTW = object
      hwnd: pointer
      wFunc: uint32
      pFrom, pTo: WideCString
      fFlags: uint16
      fAnyOperationsAborted: int32
      hNameMappings: pointer
      lpszProgressTitle: pointer
    proc shFileOperationW(op: ptr SHFILEOPSTRUCTW): int32
      {.stdcall, dynlib: "shell32", importc: "SHFileOperationW".}
    let w = newWideCString(absolutePath(path) & "\0")   # (a list: two NULs)
    var op = SHFILEOPSTRUCTW(wFunc: 3,                    # FO_DELETE
                             fFlags: 0x40 or 0x10 or 0x4 or 0x400)
    op.pFrom = w
    if shFileOperationW(addr op) != 0 or op.fAnyOperationsAborted != 0:
      return "Cannot move " & path.extractFilename & " to the Recycle Bin."
    ""
  else:
    if not fileExists(path) and not dirExists(path) and not symlinkExists(path):
      return path.extractFilename & " is not there."
    let trash = trashFor(path)
    if trash.len == 0: return "There is no trash for " & path.extractFilename & "."
    try:
      createDir(trash / "files")
      createDir(trash / "info")
      let name = uniqueName(trash / "files", path.extractFilename)
      when not (defined(macosx) or defined(ios)):
        writeFile(trash / "info" / name & ".trashinfo",
                  "[Trash Info]\nPath=" & encodePath(absolutePath(path)) &
                  "\nDeletionDate=" & now().format("yyyy-MM-dd'T'HH:mm:ss") & "\n")
      if dirExists(path) and not symlinkExists(path): moveDir(path, trash / "files" / name)
      else: moveFile(path, trash / "files" / name)
      ""
    except CatchableError as e:
      "Cannot move " & path.extractFilename & " to the trash: " & e.msg

proc trashFolders*(): seq[string] =
  ## The trash folders there are: the home one, and those of other disks
  ## (shared storage, SD cards, USB sticks).
  when defined(windows): discard
  elif defined(macosx) or defined(ios): result.add getHomeDir() / ".Trash"
  else:
    result.add homeTrash()
    let mine = ".Trash-" & $getuid()
    for root in ["/storage/emulated/0", "/sdcard"]:
      if dirExists(root / mine) and (root / mine) notin result: result.add root / mine
    for base in ["/storage", "/media" / getEnv("USER"), "/run/media" / getEnv("USER"), "/mnt"]:
      try:
        for kind, p in walkDir(base):
          if kind in {pcDir, pcLinkToDir} and dirExists(p / mine) and (p / mine) notin result:
            result.add p / mine
      except OSError: discard

proc trashItems*(): seq[TrashItem] =
  ## What is in the trash, the most recently deleted first.
  for t in trashFolders():
    try:
      for kind, p in walkDir(t / "files"):
        let name = p.extractFilename
        var it = TrashItem(name: name, path: p, info: t / "info" / name & ".trashinfo",
                           isDir: kind in {pcDir, pcLinkToDir})
        try:
          let fi = getFileInfo(p, followSymlink = false)
          it.size = if it.isDir: 0 else: fi.size
          it.deleted = fi.lastWriteTime
        except OSError: discard
        try:
          for line in lines(it.info):
            if line.startsWith("Path="): it.original = decodePath(line[5 .. ^1])
            elif line.startsWith("DeletionDate="):
              try: it.deleted = parse(line[13 .. ^1], "yyyy-MM-dd'T'HH:mm:ss").toTime
              except CatchableError: discard
        except IOError, OSError: discard
        if it.original.len == 0: it.original = name
        result.add it
    except OSError: discard
  result.sort(proc (a, b: TrashItem): int = cmp(b.deleted, a.deleted))

proc restore*(it: TrashItem): string =
  ## Puts `it` back where it was (beside it, under a new name, when that
  ## name is taken now); returns the error, or "".
  try:
    let dir = it.original.parentDir
    if not dirExists(dir): createDir(dir)
    let target = dir / uniqueName(dir, it.original.extractFilename)
    if it.isDir: moveDir(it.path, target) else: moveFile(it.path, target)
    if fileExists(it.info): removeFile(it.info)
    ""
  except CatchableError as e:
    "Cannot restore " & it.original.extractFilename & ": " & e.msg

proc deleteForever*(it: TrashItem): string =
  ## Removes `it` from the trash for good.
  try:
    # (a link to a folder is the link alone: removeDir would go through it
    # and delete what is in the folder it leads to)
    if it.isDir and not symlinkExists(it.path): removeDir(it.path) else: removeFile(it.path)
    if fileExists(it.info): removeFile(it.info)
    ""
  except CatchableError as e: e.msg

proc emptyTrash*(): int =
  ## Removes everything in the trash; how many items could not be.
  for it in trashItems():
    if deleteForever(it).len > 0: inc result

# ---- jobs -------------------------------------------------------------------------

type
  JobKind* = enum
    ## What a `FileJob` does (see `newJob`): `jkMeasure` counts the files,
    ## folders and bytes of its sources; `jkTrash` moves them to the trash.
    jkCopy, jkMove, jkDelete, jkZip, jkUnzip, jkMeasure, jkTrash
  JobState* = enum
    ## Where a job is: working, waiting for an answer about a name taken
    ## (`conflict`; answer with `resolve`), finished, or cancelled.
    jsRunning, jsAsking, jsDone, jsCancelled
  Conflict* = enum
    ## What to do when a name is already taken: ask, replace the one there,
    ## skip the item, or keep both (the new one renamed, `uniqueName`).
    cfAsk, cfReplace, cfSkip, cfKeepBoth
  StepKind = enum skMkdir, skCopy, skMove, skRemoveFile, skRemoveDir,
                  skZipDir, skZipFile, skUnzip, skTrash
  Step = object
    kind: StepKind
    src, dst: string
    size: int64
    top: bool               ## one of the job's own items (not inside one)
    decision: Conflict
    entry: ZipEntry
  FileJob* = ref object
    ## A long file operation, done a little at a time by `run`.
    kind*: JobKind               ## what it does
    state*: JobState             ## where it is
    sources*: seq[string]        ## the files and folders it works on
    dest*: string                ## target folder (copy, move, unzip) or zip file
    totalBytes*, doneBytes*: int64  ## the bytes to do and done (`progressOf`)
    totalItems*, doneItems*: int    ## the files and folders to do and done
    files*, folders*: int        ## measure: what was found
    current*: string             ## the item being worked on
    errors*: seq[string]         ## what failed, a line each (empty: all went well)
    conflict*: string            ## while asking: the name already there
    onConflict*: Conflict        ## what to do with taken names
    created*: seq[string]        ## the job's results (to select them after)
    moved*: seq[tuple[src, dst: string]]   ## move: where each item went (for undo)
    trashed*: seq[string]        ## trash: what went to the trash
    began*: MonoTime             ## when it started (for its speed)
    scan: seq[tuple[src, dst: string]]
    steps: seq[Step]
    at: int
    planned, started: bool
    copying: tuple[open: bool; f, g: File]
    zipw: ZipWriter
    zipBase: string

proc newJob*(kind: JobKind; sources: openArray[string]; dest = "";
             onConflict = cfAsk): FileJob =
  ## A job; call `run` every frame until its `state` is not `jsRunning`
  ## (`jsAsking`: answer with `resolve`). Copy and move put the `sources`
  ## into the folder `dest`; zip writes the archive `dest`; unzip extracts
  ## the archive `sources[0]` into the folder `dest`.
  FileJob(kind: kind, sources: @sources, dest: dest, onConflict: onConflict)

proc progressOf*(j: FileJob): float =
  ## How much of the job is done, 0.0 .. 1.0: by its bytes, else by its
  ## items (0 while nothing is known).
  if j.totalBytes > 0: min(1.0, j.doneBytes.float / j.totalBytes.float)
  elif j.totalItems > 0: j.doneItems / j.totalItems
  else: 0.0

proc closeCopy(j: FileJob; removePartial: bool) =
  if j.copying.open:
    j.copying.f.close()
    j.copying.g.close()
    j.copying.open = false
    if removePartial and j.at < j.steps.len:
      try: removeFile(j.steps[j.at].dst) except OSError: discard

proc cancel*(j: FileJob) =
  ## Stops the job; a half-copied file is removed.
  j.closeCopy(true)
  j.state = jsCancelled

proc resolve*(j: FileJob; choice: Conflict; forAll = false) =
  ## Answers the question about `j.conflict`: replace it, skip this item,
  ## or keep both (the new one gets "name (2)"); `forAll` for the rest too.
  if j.state != jsAsking: return
  if forAll: j.onConflict = choice
  if j.at < j.steps.len: j.steps[j.at].decision = choice
  j.conflict = ""
  j.state = jsRunning

proc isRealDir(p: string): bool = vIsDir(p)

proc fileSize(p: string): int64 = vSize(p)

proc plan(j: FileJob; deadline: MonoTime): bool =
  ## Lists the steps; reads folders a few at a time. True when complete.
  if not j.started:
    j.started = true
    case j.kind
    of jkUnzip:
      try:
        for e in zipEntries(j.sources[0]):
          let t = safeTarget(j.dest, e.name)
          let top = '/' notin e.name.strip(chars = {'/'})
          j.steps.add Step(kind: skUnzip, src: e.name, dst: t, size: e.size,
                           entry: e, top: top)
          j.totalBytes += e.size
      except CatchableError as e:
        j.errors.add e.msg
      j.totalItems = j.steps.len
      return true
    of jkZip:
      j.zipBase = if j.sources.len > 0: j.sources[0].parentDir else: ""
    of jkTrash:
      for s in j.sources:
        j.steps.add Step(kind: skTrash, src: s, size: 1, top: true)
        j.totalBytes += 1
      j.totalItems = j.steps.len
      return true
    else: discard
    for s in j.sources:
      let dir = isRealDir(s)
      case j.kind
      of jkCopy:
        if dir and (j.dest == s or j.dest.startsWith(s & DirSep)):
          j.errors.add "Cannot copy " & s.extractFilename & " into itself."
          continue
        var t = j.dest / s.extractFilename
        if t == s:                     # into its own folder: a copy beside it
          t = j.dest / uniqueName(j.dest, s.extractFilename)
        if dir:
          j.steps.add Step(kind: skMkdir, src: s, dst: t, top: true)
          j.scan.add (s, t)
          inc j.folders
        else:
          let n = fileSize(s)
          j.steps.add Step(kind: skCopy, src: s, dst: t, size: n, top: true)
          j.totalBytes += n
          inc j.files
      of jkMove:
        let t = j.dest / s.extractFilename
        if t == s: continue
        if dir and j.dest.startsWith(s & DirSep):
          j.errors.add "Cannot move " & s.extractFilename & " into itself."
          continue
        j.steps.add Step(kind: skMove, src: s, dst: t, size: 1, top: true)
        j.totalBytes += 1
      of jkDelete, jkMeasure, jkZip:
        if dir:
          if j.kind == jkZip:
            j.steps.add Step(kind: skZipDir, src: s, top: true)
          j.scan.add (s, "")
          inc j.folders
        else:
          let n = fileSize(s)
          if j.kind == jkDelete:
            j.steps.add Step(kind: skRemoveFile, src: s, size: n, top: true)
          elif j.kind == jkZip:
            j.steps.add Step(kind: skZipFile, src: s, size: n, top: true)
          j.totalBytes += n
          inc j.files
      of jkUnzip, jkTrash: discard
  var dirsToRemove: seq[string]
  while j.scan.len > 0:
    let (dir, dst) = j.scan.pop()
    j.current = dir.extractFilename
    try:
      for (kind, p) in vWalk(dir):
        let t = if dst.len > 0: dst / p.extractFilename else: ""
        if kind == pcDir:                # links to folders are not followed
          inc j.folders
          j.scan.add (p, t)
          case j.kind
          of jkCopy: j.steps.add Step(kind: skMkdir, src: p, dst: t)
          of jkZip: j.steps.add Step(kind: skZipDir, src: p)
          else: discard
        else:
          let n = if kind == pcFile: fileSize(p) else: 0
          inc j.files
          j.totalBytes += n
          case j.kind
          of jkCopy: j.steps.add Step(kind: skCopy, src: p, dst: t, size: n)
          of jkDelete: j.steps.add Step(kind: skRemoveFile, src: p, size: n)
          of jkZip: j.steps.add Step(kind: skZipFile, src: p, size: n)
          else: discard
    except OSError as e:
      j.errors.add dir & ": " & e.msg
    if getMonoTime() > deadline: return false
  if j.kind == jkDelete:
    # the folders last, the deepest first
    var dirs: seq[string]
    for s in j.sources:
      if isRealDir(s): dirs.add s
    var i = 0
    while i < dirs.len:
      try:
        for (kind, p) in vWalk(dirs[i]):
          if kind == pcDir: dirs.add p
      except OSError: discard
      inc i
    dirs.sort(proc (a, b: string): int = cmp(b.len, a.len))
    for d in dirs:
      j.steps.add Step(kind: skRemoveDir, src: d, top: d in j.sources)
  j.totalItems = j.steps.len
  true

proc copyChunks(j: FileJob; s: Step; deadline: MonoTime): bool =
  ## Copies a file 1 MB at a time; true when it is complete.
  if not j.copying.open:
    j.copying.f = vOpen(s.src, fmRead)
    try:
      j.copying.g = vOpen(s.dst, fmWrite)
    except IOError:
      j.copying.f.close()
      raise newException(IOError, "cannot write " & s.dst)
    j.copying.open = true
  var buf = newString(1 shl 20)
  while true:
    let n = j.copying.f.readBuffer(addr buf[0], buf.len)
    if n > 0 and j.copying.g.writeBuffer(addr buf[0], n) != n:
      raise newException(IOError, "the disk is full")
    j.doneBytes += n
    if n < buf.len:
      j.closeCopy(false)
      try:
        setLastModificationTime(s.dst, getLastModificationTime(s.src))
        setFilePermissions(s.dst, getFilePermissions(s.src))
      except OSError: discard
      return true
    if getMonoTime() > deadline: return false

proc taken(p: string): bool = vExists(p)

proc run*(j: FileJob; budgetMs = 12) =
  ## Works on `j` for about `budgetMs` milliseconds.
  if j.state != jsRunning: return
  let deadline = getMonoTime() + initDuration(milliseconds = budgetMs)
  if j.began == MonoTime(): j.began = getMonoTime()
  if not j.planned:
    j.planned = plan(j, deadline)
    if not j.planned: return
    if j.kind == jkMeasure:
      j.state = jsDone
      return
  while j.at < j.steps.len:
    var s = j.steps[j.at]
    j.current = s.src.extractFilename
    # a name that is taken: ask, or do what was decided
    if s.kind in {skCopy, skMove, skUnzip} and s.dst.len > 0 and taken(s.dst) and
       not (s.kind == skUnzip and s.entry.isDir) and
       not j.copying.open:              # (going on with a file begun before)
      var d = if s.decision != cfAsk: s.decision else: j.onConflict
      if d == cfAsk:
        j.state = jsAsking
        j.conflict = s.dst.extractFilename
        return
      case d
      of cfSkip:
        j.doneBytes += s.size
        inc j.doneItems
        inc j.at
        continue
      of cfKeepBoth:
        let t = s.dst.parentDir / uniqueName(s.dst.parentDir, s.dst.extractFilename)
        # what goes inside a copied folder follows it to its new name
        for k in j.at + 1 ..< j.steps.len:
          if j.steps[k].dst.startsWith(s.dst & DirSep):
            j.steps[k].dst = t & j.steps[k].dst[s.dst.len .. ^1]
        s.dst = t
        j.steps[j.at].dst = t
      of cfReplace, cfAsk: discard
    try:
      case s.kind
      of skMkdir:
        vMkdir(s.dst)
        if s.top: j.created.add s.dst
      of skCopy:
        if vIsDir(s.dst): raise newException(IOError, "a folder has that name")
        if not copyChunks(j, s, deadline): return
        if s.top: j.created.add s.dst
      of skMove:
        if taken(s.dst):
          let srcDir = isRealDir(s.src)
          if srcDir != isRealDir(s.dst):
            raise newException(IOError, "a " & (if srcDir: "file" else: "folder") &
                               " has that name")
          if not srcDir: vRemoveFile(s.dst)
        if isRealDir(s.src) and vIsDir(s.dst):
          # into an existing folder: copy over it, then remove the source
          let sub = newJob(jkCopy, [s.src], s.dst.parentDir, cfReplace)
          while sub.state == jsRunning: sub.run(1000)
          if sub.errors.len > 0: j.errors.add sub.errors
          else: vRemoveDir(s.src)
        else: vMove(s.src, s.dst)         # (copies across disks and apps)
        j.doneBytes += 1
        j.created.add s.dst
        j.moved.add (s.src, s.dst)
      of skTrash:
        let err = moveToTrash(s.src)
        if err.len > 0: raise newException(IOError, err)
        j.doneBytes += 1
        j.trashed.add s.src
      of skRemoveFile:
        vRemoveFile(s.src)
        j.doneBytes += s.size
      of skRemoveDir:
        vRemoveDir(s.src)
      of skZipDir:
        j.zipw.addDir(s.src.relativePath(j.zipBase).replace('\\', '/'),
                      vModTime(s.src))
      of skZipFile:
        j.zipw.addFile(s.src.relativePath(j.zipBase).replace('\\', '/'),
                       vReadFile(s.src), vModTime(s.src))
        j.doneBytes += s.size
      of skUnzip:
        if s.entry.isDir: vMkdir(s.dst)
        else:                            # straight to the name decided on
          vMkdir(s.dst.parentDir)
          vWriteFile(s.dst, readEntry(j.sources[0], s.entry))
          try: setLastModificationTime(s.dst, s.entry.time) except OSError: discard
        j.doneBytes += s.size
        if s.top: j.created.add s.dst
    except CatchableError as e:
      j.closeCopy(true)
      j.errors.add s.src.extractFilename & ": " & e.msg
    inc j.at
    inc j.doneItems
    if getMonoTime() > deadline: return
  if j.kind == jkZip:
    try:
      vWriteFile(j.dest, j.zipw.finish())
      j.created.add j.dest
    except CatchableError as e: j.errors.add e.msg
  j.current = ""
  j.state = jsDone

proc bytesPerSecond*(j: FileJob): float =
  ## How fast it goes (0 until it has run a moment).
  let s = (getMonoTime() - j.began).inMilliseconds.float / 1000
  if j.began == MonoTime() or s < 0.3: 0.0 else: j.doneBytes.float / s

proc secondsLeft*(j: FileJob): int =
  ## About how long it still takes (-1: not known yet).
  let bps = j.bytesPerSecond
  if bps <= 0 or j.totalBytes <= j.doneBytes: -1
  else: int((j.totalBytes - j.doneBytes).float / bps + 0.5)

proc runAll*(j: FileJob) =
  ## Finishes `j` at once (taken names follow `onConflict`; cfAsk skips).
  if j.onConflict == cfAsk: j.onConflict = cfSkip
  while j.state == jsRunning: j.run(1000)

# ---- undo ------------------------------------------------------------------------

type
  UndoKind* = enum
    ## What an `UndoStep` takes back.
    ukRename        ## `pairs`: old -> new name
    ukMove          ## `pairs`: where from -> where to
    ukCopy          ## `paths`: the copies made
    ukCreate        ## `paths`: the folders or files made
    ukTrash         ## `paths`: what went to the trash (where it was)
  UndoStep* = object
    ## One thing done to files that can be taken back.
    kind*: UndoKind                     ## what was done
    what*: string                       ## "Rename notes.txt", for the menu
    pairs*: seq[tuple[src, dst: string]]  ## renames and moves: each path before and after
    paths*: seq[string]                 ## copies, new items, what went to the trash

var undoSteps: seq[UndoStep]

proc remember*(step: UndoStep) =
  ## Keeps `step` so `undo` can take it back (the last 50 are kept).
  if step.pairs.len == 0 and step.paths.len == 0: return
  undoSteps.add step
  if undoSteps.len > 50: undoSteps.delete(0)

proc remember*(j: FileJob) =
  ## Keeps what a finished job did (copy, move, trash) for `undo`.
  case j.kind
  of jkMove:
    remember UndoStep(kind: ukMove, pairs: j.moved,
                      what: "Move " & (if j.moved.len == 1: j.moved[0].src.extractFilename
                                       else: $j.moved.len & " items"))
  of jkCopy:
    remember UndoStep(kind: ukCopy, paths: j.created,
                      what: "Copy " & (if j.created.len == 1: j.created[0].extractFilename
                                       else: $j.created.len & " items"))
  of jkTrash:
    remember UndoStep(kind: ukTrash, paths: j.trashed,
                      what: "Delete " & (if j.trashed.len == 1: j.trashed[0].extractFilename
                                         else: $j.trashed.len & " items"))
  of jkZip, jkUnzip:
    remember UndoStep(kind: ukCopy, paths: j.created, what: "Make " &
                      (if j.created.len == 1: j.created[0].extractFilename
                       else: $j.created.len & " items"))
  else: discard

proc canUndo*(): bool = undoSteps.len > 0
  ## There is a file operation to undo (see `undoLabel`).
proc undoLabel*(): string =
  ## "Undo Rename notes.txt" ("Undo" when there is nothing).
  if undoSteps.len == 0: tr("Undo") else: tr("Undo ") & undoSteps[^1].what

proc undo*(): tuple[error: string; touched: seq[string]] =
  ## Takes back the last step: names back, moves back, copies and new items
  ## to the trash, deleted items out of it. `touched`: the folders that
  ## changed (to list again).
  if undoSteps.len == 0: return
  let step = undoSteps.pop()
  var errors: seq[string]
  case step.kind
  of ukRename, ukMove:
    for i in countdown(step.pairs.high, 0):
      let (src, dst) = step.pairs[i]
      try:
        if vExists(src):
          errors.add src.extractFilename & " is there again"
        else: vMove(dst, src)
        result.touched.add src.parentDir
        result.touched.add dst.parentDir
      except CatchableError as e: errors.add e.msg
  of ukCopy, ukCreate:
    for p in step.paths:
      if isDocPath(p):                     # (another app's folder: no trash)
        try:
          if vIsDir(p): vRemoveDir(p) else: vRemoveFile(p)
        except CatchableError as e: errors.add e.msg
      else:
        let err = moveToTrash(p)
        if err.len > 0: errors.add err
      result.touched.add p.parentDir
  of ukTrash:
    let items = trashItems()
    for p in step.paths:
      var found = false
      for it in items:                     # (the most recent first)
        if it.original == p:
          let err = restore(it)
          if err.len > 0: errors.add err
          found = true
          break
      if not found: errors.add p.extractFilename & " is not in the trash"
      result.touched.add p.parentDir
  result.error = errors.join("\n")

# ---- shortcuts: Explorer's Paste Shortcut --------------------------------------------------

proc fileUrl(path: string): string =
  ## (a Windows path as a file:// address, the letters other than a plain
  ## few written %XX)
  result = "file:///"
  for c in path.replace('\\', '/'):
    if c in {'A'..'Z', 'a'..'z', '0'..'9', '/', ':', '.', '-', '_', '~'}: result.add c
    else: result.add '%' & toHex(ord(c), 2)

proc shortcutTarget*(path: string): string =
  ## Where a shortcut leads -- a symbolic link's target, a Windows Internet
  ## shortcut's (".url") file:// address as a path -- "" when `path` is
  ## not one.
  if symlinkExists(path):
    try:
      let t = expandSymlink(path)
      return if t.isAbsolute: t else: path.parentDir / t
    except OSError: return ""
  if path.toLowerAscii.endsWith(".url") and fileExists(path):
    try:
      for line in readFile(path).splitLines:
        let l = line.strip
        if l.toLowerAscii.startsWith("url=file:///"):
          var p = ""
          var i = 12
          let u = l
          while i < u.len:
            if u[i] == '%' and i + 2 < u.len:
              try: p.add char(parseHexInt(u[i + 1 .. i + 2]))
              except ValueError: p.add u[i]
              i += 3
            else:
              p.add u[i]
              inc i
          return (when defined(windows): p.replace('/', '\\') else: "/" & p)
    except IOError, OSError: discard
  ""

proc makeShortcuts*(paths: openArray[string]; dir: string): tuple[made: seq[string]; error: string] =
  ## A shortcut in `dir` to each of `paths` -- Explorer's Paste Shortcut --
  ## named "Shortcut to" its name (a second one "(2)"...): a symbolic link
  ## on Linux, macOS, the BSDs and Termux; on Windows an Internet shortcut
  ## (".url", a file:// address), which Explorer opens as well. `made`: the
  ## shortcuts made (Edit > Undo takes them back: `remember`); `error`:
  ## the ones that could not be (a phone's shared storage, another app's
  ## folder, have no links).
  var errors: seq[string]
  for p in paths:
    let name = p.extractFilename
    if name.len == 0: continue
    if isDocPath(dir) or isDocPath(p):
      errors.add name & ": " & tr("another app's folder holds no shortcuts")
      continue
    try:
      when defined(windows):
        let at = dir / uniqueName(dir, tr("Shortcut to ") & name & ".url")
        writeFile(at, "[InternetShortcut]\r\nURL=" & fileUrl(absolutePath(p)) & "\r\n")
      else:
        let at = dir / uniqueName(dir, tr("Shortcut to ") & name)
        createSymlink(absolutePath(p), at)
      result.made.add at
    except CatchableError as e:
      errors.add name & ": " & e.msg
  result.error = errors.join("\n")
  if result.made.len > 0:
    remember UndoStep(kind: ukCreate, paths: result.made,
                      what: tr("Paste Shortcut"))

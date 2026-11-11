## Files on screen: what an app that shows files needs, ready made and
## fast with big folders and big files.
##
## - `fileGlyph`, `fileIcon`: an icon (and its color) for each kind of file
## - `PictureCache`, `cachedPicture`, `drawPicture`, `pictureBox`: pictures
##   decoded on worker threads, kept up to a memory budget, drawn when they
##   are there
## - `FolderModel`: a folder listed on a worker thread, filtered, sorted
##   naturally, searched (also through its subfolders), watched for
##   changes, with back / forward / up and a selection
## - `fileList`: a folder model as details or as icons, with thumbnails
## - `filePreview`: the details pane of an explorer -- the picture or the
##   start of a text, sizes, what a folder holds, Open / Share / Properties
## - `folderTree`: places, favorites and the folders under them
## - `textFileView`, `hexFileView`: files of any size, read as shown
## - `runJobDialog`, `propertiesDialog`, `filePicker`: the dialogs around
##   file jobs, file details, and opening or saving a file
##
## .. code-block:: nim
##   var folder = newFolderModel(getHomeDir())
##   app "Files", 900, 600:
##     let ev = fileList(folder, fvIcons)
##     if ev.activated and ev.item.isDir: folder.open(ev.item.path)

import std/[os, strutils, times, tables, sets, algorithm, monotimes, sequtils]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import gfx, core, widgets, business, extras, nerdicons, pixelicons, platform, files,
       imaging, background, textfile, docfs, memwatch
import uirelays/services

template th: untyped = ui.theme

# ---- icons -----------------------------------------------------------------------------

const folderColor* = color(222, 170, 40)
  ## The color of folder icons.

proc pixelGlyph(f: FileItem): string =
  if f.isDir: return pxFolder
  case extOf(f.name)
  of "md", "markdown": pxMarkdown
  of "html", "htm", "css", "url", "webloc": pxWeb
  of "json", "xml", "svg", "yml", "yaml", "toml", "ini", "cfg", "conf", "plist": pxData
  of "sh", "bash", "zsh", "fish", "bat", "cmd", "ps1": pxScript
  of "pdf": pxPdf
  of "doc", "docx", "odt", "rtf", "wpd": pxDocument
  of "xls", "xlsx", "ods", "csv", "tsv": pxSheet
  of "ppt", "pptx", "odp", "key": pxSlides
  of "apk", "aab", "exe", "msi", "app", "dmg", "deb", "rpm", "appimage", "com": pxApp
  of "ttf", "otf", "woff", "woff2", "fon": pxFont
  else:
    case kindOf(f)
    of fkImage: pxImage
    of fkAudio: pxAudio
    of fkVideo: pxVideo
    of fkArchive: pxArchive
    of fkText, fkDocument: pxText
    of fkCode: pxCode
    of fkApp: pxApp
    else: pxFile

proc fontGlyph(f: FileItem): tuple[glyph: string; color: Color] =
  case extOf(f.name)
  of "nim", "nims", "nimble": (nfNim, color(220, 180, 0))
  of "md", "markdown": (nfMarkdown, color(70, 110, 190))
  of "json": (nfJson, color(200, 150, 30))
  of "html", "htm": (nfHtml, color(220, 90, 40))
  of "css": (nfCss, color(40, 110, 200))
  of "py": (nfPython, color(50, 110, 170))
  of "js", "ts": (nfJavascript, color(200, 170, 0))
  of "c", "h": (nfC, color(70, 100, 170))
  of "cpp", "cc", "hpp", "cxx": (nfCpp, color(70, 100, 170))
  of "java", "kt": (nfJava, color(190, 80, 40))
  of "go": (nfGo, color(0, 150, 190))
  of "rs": (nfRust, color(160, 80, 50))
  of "sh", "bash", "zsh", "bat", "cmd", "ps1": (nfShell, color(60, 140, 60))
  of "xml", "svg": (nfXml, color(220, 120, 40))
  of "yml", "yaml", "toml", "ini", "cfg", "conf": (nfYaml, color(150, 80, 150))
  of "pdf": (nfFilePdf, color(200, 40, 40))
  of "doc", "docx", "odt", "rtf": (nfFileWord, color(40, 90, 180))
  of "xls", "xlsx", "ods": (nfFileExcel, color(30, 130, 70))
  of "csv", "tsv": (nfFileCsv, color(30, 130, 70))
  of "ppt", "pptx", "odp": (nfFilePowerpoint, color(210, 90, 40))
  of "apk", "aab": (nfAndroid, color(100, 170, 50))
  of "exe", "msi", "app", "dmg", "deb", "rpm": (nfApplication, color(90, 90, 160))
  of "ttf", "otf", "woff", "woff2": (nfFontFile, color(120, 120, 120))
  else:
    case kindOf(f)
    of fkImage: (nfFileImage, color(40, 150, 90))
    of fkAudio: (nfFileAudio, color(150, 70, 170))
    of fkVideo: (nfFileVideo, color(200, 60, 60))
    of fkArchive: (nfFileZip, color(150, 110, 50))
    of fkText, fkDocument: (nfFileText, color(90, 110, 140))
    of fkCode: (nfFileCode, color(90, 110, 140))
    else: (nfFile, color(130, 130, 140))

# A list asks for the icon, the kind and the date of the same rows every
# frame: they are worked out once per name (or time) and kept, a few
# thousand at most.
const memoMax = 4096
var
  glyphMemo: array[bool, Table[string, tuple[glyph: string; color: Color]]]
  kindMemo: Table[string, string]
  timeMemo: Table[(int64, DateStyle), string]

proc fileGlyph*(f: FileItem): tuple[glyph: string; color: Color] =
  ## The icon of a file, by its extension, else by its kind: a pixel icon
  ## (`retroIcons`, the default) or an icon-font glyph and its color.
  if f.isDir: return ((if retroIcons: pxFolder else: nfFolder), folderColor)
  glyphMemo[retroIcons].withValue(f.name, v):
    return v[]
  result = if retroIcons: (pixelGlyph(f), folderColor) else: fontGlyph(f)
  if glyphMemo[retroIcons].len >= memoMax: glyphMemo[retroIcons].clear()
  glyphMemo[retroIcons][f.name] = result

var kindLang = ""

proc kindText(f: FileItem): string =
  ## `kindName`, kept per name (and per language).
  if f.isDir: return kindName(f)
  if kindLang != uiLanguageCode():
    kindLang = uiLanguageCode()
    kindMemo.clear()
  kindMemo.withValue(f.name, v):
    return v[]
  result = kindName(f)
  if kindMemo.len >= memoMax: kindMemo.clear()
  kindMemo[f.name] = result

proc dateText(t: Time): string =
  ## `timeText`, kept per time.
  let key = (t.toUnix, dateStyle)
  timeMemo.withValue(key, v):
    return v[]
  result = timeText(t)
  if timeMemo.len >= memoMax: timeMemo.clear()
  timeMemo[key] = result

proc fileIcon*(f: FileItem; size = 16): Icon =
  ## `fileGlyph` as an icon `size` logical pixels square.
  let (g, c) = fileGlyph(f)
  glyphIcon(g, c, size)

proc placeGlyph*(name: string): string =
  ## The icon of a place `places()` names ("Home", "Downloads", "SD card"...).
  if retroIcons:
    return case name
      of "Home": pxHome
      of "Desktop": pxDesktop
      of "Documents": pxDocuments
      of "Downloads": pxDownloads
      of "Pictures", "Camera": pxPictures
      of "Music": pxMusic
      of "Videos", "Movies": pxVideos
      of "Computer": pxComputer
      of "Internal storage", "Shared storage": pxPhone
      of "Trash": pxTrash
      of "Termux", "Termux home": pxScript
      of "Termux system": pxDrive
      else:
        if name.startsWith("SD card"): pxSdCard else: pxDrive
  case name
  of "Home": nfHome
  of "Desktop": nfDesktop
  of "Documents": nfFileDocument
  of "Downloads": nfDownload
  of "Pictures", "Camera": nfImage
  of "Music": nfMusic
  of "Videos", "Movies": nfFilm
  of "Computer": nfDesktop
  of "Internal storage", "Shared storage": nfCellphone
  of "Termux", "Termux home": nfTerminal
  else:
    if name.startsWith("SD card"): nfSdCard else: nfHarddisk

# ---- pictures -------------------------------------------------------------------------------

type
  CachedPicture = object
    bmp: Bitmap
    used: int                    ## the frame it was last asked for in
  PictureCache* = ref object
    ## Pictures decoded in the background and kept, the least recently
    ## used dropped when they take more than `budget` pixels.
    budget*: int                         ## pixels kept at most
    pics: Table[string, CachedPicture]
    sizes: Table[string, seq[int]]       ## picture -> the sizes kept of it
    asked: HashSet[string]
    failed: HashSet[string]
    pixels: int

proc newPictureCache*(budget = 0): PictureCache =
  ## A cache holding at most `budget` pixels (4 bytes each); 0: as many as
  ## a share of the device's memory holds (`retroui/memwatch`'s
  ## `cacheBudget`: 16 to 192 MB).
  PictureCache(budget: if budget > 0: budget else: int(cacheBudget() div 4))

proc release*(c: PictureCache; keep = 0.5)
  ## Lets go of pictures until no more than `keep` of the budget is kept
  ## (0: all but those on screen; all of them while the program is in the
  ## background). They are decoded again -- or read from the disk cache,
  ## `retroui/thumbcache` -- when they are shown.

var sharedPictures: PictureCache

proc pictures*(): PictureCache =
  ## The cache `cachedPicture`, `pictureBox` and the file widgets share. It
  ## lets go of pictures when the device runs short of memory and when the
  ## program goes to the background (`onMemoryPressure`).
  if sharedPictures == nil:
    let c = newPictureCache()
    sharedPictures = c
    onMemoryPressure(proc (level: MemoryPressure) =
      c.release(if level == mpCritical or ui.paused: 0.0 else: 0.5))
  sharedPictures

proc bucket(n: int): int =
  ## Sizes asked for are rounded up to a few steps, so a picture shown a
  ## little larger is not decoded again.
  result = 64
  while result < n and result < 16384: result = result * 3 div 2

proc pictureKey(path: string; stamp: int64): string = path & "\0" & $stamp

proc trimTo(c: PictureCache; target: int; all = false; since = ui.frameNo) =
  ## The least recently used dropped until no more than `target` pixels are
  ## kept -- not those shown since frame `since`, unless `all`.
  var order: seq[(int, string)]
  for k, p in c.pics: order.add (p.used, k)
  order.sort()
  for (used, k) in order:
    if c.pixels <= target or (used >= since and not all): break
    let p = c.pics[k]
    c.pixels -= p.bmp.w * p.bmp.h
    c.pics.del k
    let cut = k.rfind('#')
    let base = k[0 ..< cut]
    let size = parseInt(k[cut + 1 .. ^1])
    var s = c.sizes.getOrDefault(base)
    s.keepItIf(it != size)
    if s.len == 0: c.sizes.del base else: c.sizes[base] = s

proc trim(c: PictureCache) =
  if c.pixels > c.budget: c.trimTo(c.budget * 3 div 4)

proc release*(c: PictureCache; keep = 0.5) =
  ## Lets go of pictures until no more than `keep` of the budget is kept
  ## (0: all but those on screen; all of them while the program is in the
  ## background). They are decoded again -- or read from the disk cache,
  ## `retroui/thumbcache` -- when they are shown.
  # (the hooks run as a frame begins: those shown in the last one stay)
  c.trimTo(int(c.budget.float * clamp(keep, 0.0, 1.0)), all = ui.paused, since = ui.frameNo - 1)
  if c.failed.len > 4096: c.failed.clear()

proc get*(c: PictureCache; path: string; maxW, maxH: int; stamp = 0'i64;
          priority = 1; group = 0): Bitmap =
  ## The picture `path` fitted into `maxW` x `maxH` device pixels: nil until
  ## it is decoded (it is asked for on a worker thread the first time), then
  ## the same bitmap every frame. A smaller copy already decoded stands in
  ## while the larger one comes. `stamp` (the file's time) tells versions
  ## of a file apart.
  let size = bucket(max(maxW, maxH))
  let base = pictureKey(path, stamp)
  let key = base & "#" & $size
  if key in c.pics:
    c.pics[key].used = ui.frameNo
    return c.pics[key].bmp
  if key notin c.asked and base notin c.failed:
    c.asked.incl key
    discard pictureAsync(path, size, size, priority, group,
      onDone = proc (r: var TaskResult) =
        c.asked.excl key
        if r.cancelled: return
        let b = toBitmap(move r)
        if b == nil:
          c.failed.incl base
          return
        c.pics[key] = CachedPicture(bmp: b, used: ui.frameNo)
        c.sizes.mgetOrPut(base, @[]).add size
        c.pixels += b.w * b.h
        c.trim())
  # meanwhile: the largest smaller one there is
  var best = -1
  for s in c.sizes.getOrDefault(base):
    if s < size and s > best: best = s
  if best > 0:
    let k = base & "#" & $best
    c.pics[k].used = ui.frameNo
    return c.pics[k].bmp

proc failed*(c: PictureCache; path: string; stamp = 0'i64): bool =
  ## The picture could not be decoded (show an icon instead).
  pictureKey(path, stamp) in c.failed

proc loading*(c: PictureCache; path: string; stamp = 0'i64): bool =
  ## The picture is being decoded.
  let base = pictureKey(path, stamp) & "#"
  for k in c.asked:
    if k.startsWith(base): return true

proc clear*(c: PictureCache) =
  ## Forgets every picture (they are decoded again when asked for).
  c.pics.clear()
  c.sizes.clear()
  c.failed.clear()
  c.pixels = 0

proc pixelsKept*(c: PictureCache): int = c.pixels
  ## How many pixels the cache holds now.

proc cachedPicture*(path: string; maxW, maxH: int; stamp = 0'i64;
                    priority = 1): Bitmap =
  ## `pictures().get(...)`: the picture once it is decoded, else nil.
  pictures().get(path, maxW, maxH, stamp, priority)

proc drawFit*(r: Rect; b: Bitmap; enlarge = true) =
  ## `b` as large as fits in `r` (keeping its shape), centered; a picture
  ## smaller than `r` is enlarged only if `enlarge`.
  if b == nil or b.w <= 0 or b.h <= 0 or r.w <= 0 or r.h <= 0: return
  var k = min(r.w / b.w, r.h / b.h)
  if not enlarge: k = min(k, 1.0 / float(max(1, pxScale)))
  let w = max(1, int(float(b.w) * k))
  let h = max(1, int(float(b.h) * k))
  drawBitmap(rect(r.x + (r.w - w) div 2, r.y + (r.h - h) div 2, w, h), b)

proc drawPicture*(r: Rect; path: string; stamp = 0'i64; priority = 2;
                  enlarge = true; group = 0): bool {.discardable.} =
  ## The picture `path` fitted into `r` once it is decoded (true when it
  ## was drawn); decoded at the screen's resolution.
  let b = pictures().get(path, r.w * pxScale, r.h * pxScale, stamp, priority, group)
  if b == nil: return false
  drawFit(r, b, enlarge)
  # a video's picture: a play mark over it, so it is not taken for a photo
  if kindOf(FileItem(name: path.extractFilename)) == fkVideo and min(r.w, r.h) >= dp(20):
    var k = min(r.w / b.w, r.h / b.h)
    if not enlarge: k = min(k, 1.0 / float(max(1, pxScale)))
    let d = clamp(int(min(b.w.float, b.h.float) * k * 0.42), dp(10), dp(44))
    let cx = r.x + r.w div 2
    let cy = r.y + r.h div 2
    disc(cx.float, cy.float, d / 2, color(0, 0, 0, 150))
    arrow(cx + d div 10, cy, dRight, color(255, 255, 255), max(3, d div 3))
  true

proc pictureBox*(path: string; w = 0; h = 0; stamp = 0'i64; frame = true) =
  ## A picture as a widget, `w` x `h` (0: the room there is): busy dots
  ## while it is decoded, an icon if it cannot be.
  let r = place(w, if h > 0: h else: remainingH(), fill = w <= 0)
  ui.lastId = 0
  ui.lastRect = r
  if frame:
    fill(r, th.field)
    fieldFrame(r)
  let inner = inset(r, if frame: 2 else: 0)
  if drawPicture(inner, path, stamp): return
  if pictures().failed(path, stamp):
    let (g, c) = fileGlyph(FileItem(name: path.extractFilename))
    let st = style(size = float(min(inner.w, inner.h)) * 0.4 / float(FontH))
    text(inner.x + (inner.w - textWidth(g, st)) div 2,
         inner.y + (inner.h - lineHeight(st)) div 2, g, c, st)
  else:
    drawSpinner(inner.x + inner.w div 2, inner.y + inner.h div 2,
                min(FontH * 2, min(inner.w, inner.h) div 2))

# ---- the folder model -------------------------------------------------------------------------

type
  FolderModel* = ref object
    ## A folder as an app shows it: listed on a worker thread (the old
    ## listing stays until the new one is there), filtered, sorted, with a
    ## selection and a history. Draw it with `fileList`.
    dir*: string                 ## the folder shown ("" before the first listing)
    all*: seq[FileItem]          ## everything in it
    items*: seq[FileItem]        ## what is shown: filtered and sorted, or found
    sel*: int                    ## the current item (where the keyboard is)
    marked*: seq[bool]           ## the selected items
    sortBy*: SortKey             ## the column the items are sorted by
    descending*: bool            ## largest / newest / last first
    showHidden*: bool            ## (`reload` after changing it)
    filter*: string              ## only names with this in them (`setFilter`)
    patterns*: seq[string]       ## only files matching one ("*.png"); folders always
    error*: string               ## why the last listing failed ("" if it did not)
    changed*: bool               ## a new listing came in this frame
    columns*: seq[Column]        ## the details view's columns (widths kept)
    phoneColumns*: seq[Column]   ## ... on narrow screens
    showExtensions*: bool        ## names with their extensions ("notes.txt")
    hot*: int                    ## the item under the mouse now (-1: none)
    attention: string            ## the item the mouse rested on (the preview's)
    attentionAt: int
    hoverPath: string
    hoverSince: int
    backStack, fwdStack: seq[string]
    ticket: int
    loadPath, keepName: string
    selectAfter: seq[string]
    since: int
    stamp: Time
    checkedAt: int
    deep: bool                   ## searching through the subfolders
    searchFor: string
    todo: seq[string]
    group: int                   ## of its requests (its listings, its thumbnails)
    stats: tuple[files, folders: int; bytes: int64]
    needsAccess*: bool           ## `dir` is another app's folder, not given to
                                 ## this app yet (`askAccess`; `fileList` offers it)
    askedAt, polledAt: int

var modelGroups = 1_000_000

proc globMatch*(name, pattern: string): bool =
  ## `name` matches `pattern`: `*` any run of characters, `?` any one
  ## (case is not ignored: lower both for that).
  var i, j = 0
  var star = -1
  var mark = 0
  while i < name.len:
    if j < pattern.len and (pattern[j] == '?' or pattern[j] == name[i]):
      inc i
      inc j
    elif j < pattern.len and pattern[j] == '*':
      star = j
      mark = i
      inc j
    elif star >= 0:
      j = star + 1
      inc mark
      i = mark
    else:
      return false
  while j < pattern.len and pattern[j] == '*': inc j
  j == pattern.len

proc matchesAny*(name: string; patterns: openArray[string]): bool =
  ## `name` matches one of `patterns` (`"*.png"`, `"*.*"`, `"IMG_20??*"`,
  ## `"notes.txt"`; case is ignored); true when there are none.
  if patterns.len == 0: return true
  let n = name.toLowerAscii
  for p in patterns:
    let p = p.toLowerAscii
    if p == "*" or p == "*.*": return true
    if p.startsWith("*.") and '*' notin p[1 .. ^1] and '?' notin p:
      if n.endsWith(p[1 .. ^1]): return true
    elif n == p or globMatch(n, p): return true

var spaces: Table[string, tuple[at: int; v: tuple[free, total: int64]]]

proc diskSpaceCached*(dir: string): tuple[free, total: int64] =
  ## `diskSpace(dir)`, asked at most every 3 seconds for each folder.
  let c = spaces.getOrDefault(dir, (-100_000, (0'i64, 0'i64)))
  if ui.now - c.at > 3000 or ui.now < c.at:
    let v = diskSpace(dir)
    spaces[dir] = (ui.now, v)
    return v
  c.v

proc searching*(m: FolderModel): bool = m.deep and m.searchFor.len > 0
  ## Showing what a search through the subfolders found.

proc applyView*(m: FolderModel; keepName = "") =
  ## Filters and sorts `all` into `items` again (after changing `sortBy`,
  ## `descending` or `filter`), keeping the selection.
  if m.searching: return
  let before = if keepName.len > 0: keepName
               elif m.sel >= 0 and m.sel < m.items.len: m.items[m.sel].name else: ""
  var keep: HashSet[string]
  for i, mk in m.marked:
    if mk and i < m.items.len: keep.incl m.items[i].name
  m.items.setLen(0)
  let f = m.filter.toLowerAscii
  for it in m.all:
    if (f.len == 0 or f in it.name.toLowerAscii) and
       (it.isDir or it.name.matchesAny(m.patterns)): m.items.add it
  sortFiles(m.items, m.sortBy, m.descending)
  m.marked = newSeq[bool](m.items.len)
  m.sel = 0
  for i, it in m.items:
    if it.name == before: m.sel = i
    if it.name in keep or (keepName.len > 0 and it.name == keepName): m.marked[i] = true

proc took(m: FolderModel; r: var TaskResult) =
  if r.ticket != m.ticket: return                # an older request
  m.ticket = 0
  if r.cancelled: return                         # (let go: `forget`)
  if r.error.len > 0:
    m.error = "Cannot open " & r.path & ":\n" & r.error
    if r.path == m.dir: m.all.setLen(0)
    return
  let other = r.path != m.dir
  if other:
    cancelTasks(tkPicture, m.group)              # the old folder's thumbnails
    m.deep = false
    m.searchFor = ""
    m.todo.setLen(0)
  m.dir = r.path
  m.all = move r.items
  m.stamp = vModTime(m.dir)
  m.checkedAt = ui.now
  m.applyView(m.keepName)
  if other and m.keepName.len == 0: m.sel = 0
  m.keepName = ""
  if m.selectAfter.len > 0:
    for i in 0 ..< m.marked.len: m.marked[i] = false
    for i, it in m.items:
      if it.path in m.selectAfter:
        m.marked[i] = true
        m.sel = i
    m.selectAfter.setLen(0)
  m.stats = (0, 0, 0'i64)
  for it in m.all:
    if it.isDir: inc m.stats.folders
    else:
      inc m.stats.files
      m.stats.bytes += it.size
  m.changed = true
  if r.quick:
    # the names are shown: now the sizes and dates (the selection stays)
    m.ticket = folderAsync(m.dir, m.showHidden, group = m.group,
      onDone = proc (r: var TaskResult) = m.took(r))

proc load(m: FolderModel; path: string; keepName = "") =
  let p = cleanPath(if path.len == 0: getHomeDir() else: path)
  if needsDocAccess(p):
    # another app's folder this app may not read yet: shown empty, with
    # the offer to ask for it (`askAccess`)
    cancelTasks(tkPicture, m.group)
    m.ticket = 0
    m.dir = p
    m.loadPath = p
    m.all.setLen(0)
    m.items.setLen(0)
    m.marked.setLen(0)
    m.sel = 0
    m.deep = false
    m.searchFor = ""
    m.todo.setLen(0)
    m.stats = (0, 0, 0'i64)
    m.error = ""
    m.needsAccess = true
    m.changed = true
    return
  m.needsAccess = false
  m.loadPath = p
  m.keepName = keepName
  m.since = ui.now
  m.error = ""
  # a folder not shown yet: names first (no waiting for every file's size
  # and date on slow storage), then everything; sorted by size or date,
  # the order would jump: everything at once
  let quick = p != m.dir and m.sortBy in {byName, byKind} and not isDocPath(p)
  m.ticket = folderAsync(p, m.showHidden, quick = quick, group = m.group,
    onDone = proc (r: var TaskResult) = m.took(r))

proc forget(m: FolderModel) =
  ## (a model let go) its listings and thumbnails not started are dropped,
  ## so nothing waits on them -- or keeps the model alive
  cancelTasks(tkFolder, m.group)
  cancelTasks(tkPicture, m.group)

proc newFolderModel*(path = ""; showHidden = false): FolderModel =
  ## A model, listing `path` if given.
  inc modelGroups
  result = FolderModel(showHidden: showHidden, group: modelGroups, hot: -1,
    showExtensions: true,
    columns: @[column("Name", 280, editable = true), column("Size", 90, alRight),
               column("Type", 140), column("Modified", 150)],
    phoneColumns: @[column("Name", 230, editable = true), column("Size", 80, alRight)])
  if path.len > 0: result.load(path)

proc heading(m: FolderModel): string =
  ## (the folder being listed, when a listing is on its way; else the one
  ## shown: Up pressed twice before the first listing came goes up two)
  if m.ticket != 0 and m.loadPath.len > 0: m.loadPath else: m.dir

proc reload*(m: FolderModel; keepName = "") =
  ## Lists the folder again (after files changed, or `showHidden`).
  m.load(if m.loadPath.len > 0 and m.ticket != 0: m.loadPath else: m.dir, keepName)

proc open*(m: FolderModel; path: string; keepName = "") =
  ## Shows the folder `path` (remembered for `goBack`); `keepName` is
  ## selected when it is there.
  let p = cleanPath(path)
  let here = m.heading
  if p != here and here.len > 0:
    m.backStack.add here
    m.fwdStack.setLen(0)
  m.filter = ""
  m.deep = false
  m.searchFor = ""
  m.todo.setLen(0)
  m.load(p, keepName)

proc askAccess*(m: FolderModel) =
  ## Shows the system's folder picker at the folder of another app that
  ## `m` shows (`needsAccess`); once the user allows it, the folder is
  ## listed.
  if m.needsAccess and askDocAccess(m.dir):
    m.askedAt = max(1, ui.now)
    m.polledAt = ui.now
    wakeIn(500)

proc accessApp*(m: FolderModel): string =
  ## The app whose folder `m` shows ("Termux"), or "".
  providerFor(m.dir).app

proc canGoBack*(m: FolderModel): bool = m.backStack.len > 0
  ## There is a folder to go back to (`goBack`).
proc canGoForward*(m: FolderModel): bool = m.fwdStack.len > 0
  ## There is a folder to go forward to (`goForward`).
proc canGoUp*(m: FolderModel): bool =
  ## The folder has a parent (`goUp`).
  let d = m.heading
  d.len > 0 and d.parentDir.len > 0 and d.parentDir != d

proc goBack*(m: FolderModel) =
  ## Opens the folder shown before this one (like a browser's Back).
  if m.backStack.len > 0:
    m.fwdStack.add m.dir
    m.load(m.backStack.pop())

proc goForward*(m: FolderModel) =
  ## Undoes a `goBack`.
  if m.fwdStack.len > 0:
    m.backStack.add m.dir
    m.load(m.fwdStack.pop())

proc goUp*(m: FolderModel) =
  ## The folder above, with the one we were in selected (above the one on
  ## its way, when its listing has not come yet).
  let d = m.heading
  if m.canGoUp: m.open(d.parentDir, d.extractFilename)

proc loading*(m: FolderModel): bool = m.ticket != 0
  ## A listing is on its way.

proc loadingPath*(m: FolderModel): string = m.loadPath
  ## The folder being listed (or the last one).

proc loadingFor*(m: FolderModel): int =
  ## How long the listing has taken so far, in ms (0: not loading).
  if m.ticket == 0: 0 else: ui.now - m.since

proc selectAfterLoad*(m: FolderModel; paths: openArray[string]) =
  ## Selects these items once the next listing is in (a job's results).
  m.selectAfter = @paths

proc setFilter*(m: FolderModel; text: string) =
  ## Shows only names with `text` in them.
  m.filter = text
  m.deep = false
  m.searchFor = ""
  m.todo.setLen(0)
  m.applyView()

proc search*(m: FolderModel; text: string) =
  ## Looks for `text` in the names of this folder and all its subfolders
  ## (a few milliseconds a frame); `items` are what is found.
  m.filter = text
  m.deep = true
  m.searchFor = text.toLowerAscii
  m.todo = @[m.dir]
  m.items.setLen(0)
  m.marked.setLen(0)
  m.sel = 0

proc searchBusy*(m: FolderModel): bool = m.deep and m.todo.len > 0
  ## The search is still going through folders.

proc stopSearch*(m: FolderModel) =
  ## Ends the search: the folder is listed as it is again.
  m.deep = false
  m.searchFor = ""
  m.todo.setLen(0)
  m.applyView()

proc step(m: FolderModel) =
  if m.todo.len == 0 or m.searchFor.len == 0: return
  let deadline = getMonoTime() + initDuration(milliseconds = 8)
  while m.todo.len > 0 and getMonoTime() < deadline and m.items.len < 5000:
    let d = m.todo.pop()
    try:
      for kind, p in walkDir(d):
        let name = p.extractFilename
        if not m.showHidden and name.startsWith("."): continue
        if kind == pcDir: m.todo.add p
        if m.searchFor in name.toLowerAscii: m.items.add infoOf(p)
    except OSError: discard
  if m.items.len >= 5000: m.todo.setLen(0)
  if m.todo.len > 0: wakeIn(1)
  else: sortFiles(m.items, m.sortBy, m.descending)
  m.marked.setLen(m.items.len)
  ui.redraw = true

proc update*(m: FolderModel) =
  ## Once a frame (`fileList` calls it): the search goes on, and a folder
  ## another program changed is listed again (checked every 1.5 s).
  m.changed = false
  if m.needsAccess:
    # asked for access: looked at again until it is given (the system's
    # folder picker is over the app meanwhile)
    if m.askedAt != 0 and ui.now - m.askedAt < 300_000:
      if ui.now - m.polledAt >= 500 or ui.now < m.polledAt:
        m.polledAt = ui.now
        refreshDocRoots()
        if isDocPath(m.dir):
          m.askedAt = 0
          m.load(m.dir)
          return
      wakeIn(500)
    return
  m.step()
  if m.dir.len == 0 or m.ticket != 0 or m.deep or ui.now - m.checkedAt < 1500: return
  m.checkedAt = ui.now
  let t = vModTime(m.dir)
  if t != m.stamp:
    m.stamp = t
    m.reload()

proc current*(m: FolderModel): FileItem =
  ## The current item (an empty `FileItem` if there is none).
  if m.sel >= 0 and m.sel < m.items.len: m.items[m.sel] else: FileItem()

proc markedCount*(m: FolderModel): int =
  ## How many items are selected (marked; the current item alone is not).
  for i, mk in m.marked:
    if mk and i < m.items.len: inc result

proc selectedItems*(m: FolderModel): seq[FileItem] =
  ## The selected (marked) items; none when nothing is selected, as in
  ## Explorer -- the current item (`current`, the one with the focus
  ## rectangle) is not selected by itself.
  for i, mk in m.marked:
    if mk and i < m.items.len: result.add m.items[i]

proc selectedPaths*(m: FolderModel): seq[string] =
  ## The paths of `selectedItems`.
  for f in m.selectedItems: result.add f.path

proc selectAll*(m: FolderModel) =
  ## Selects every item shown (Ctrl+A).
  m.marked = newSeq[bool](m.items.len)
  for x in m.marked.mitems: x = true

proc selectMatching*(m: FolderModel; patterns: string; add = false): int =
  ## Selects the items whose names match one of `patterns` ("*.jpg *.png",
  ## "IMG_2026*"; case is ignored), with the selection there was when
  ## `add`; how many match.
  var pats: seq[string]
  for p in patterns.split({';', ',', ' '}):
    if p.strip.len > 0: pats.add p.strip.toLowerAscii
  if m.marked.len != m.items.len or not add: m.marked = newSeq[bool](m.items.len)
  if pats.len == 0: return 0
  for i, it in m.items:
    if matchesAny(it.name, pats):
      m.marked[i] = true
      inc result
      if m.sel < 0 or not add and result == 1: m.sel = i

proc clearSelection*(m: FolderModel) =
  ## Selects nothing.
  for x in m.marked.mitems: x = false

proc folderStats*(m: FolderModel): tuple[files, folders: int; bytes: int64] =
  ## What the folder holds (all of it, not only what the filter shows).
  m.stats

proc makeFolder*(m: FolderModel; name: string): string =
  ## Creates the folder `name` here and selects it; the error ("" if none).
  let err = validName(name)
  if err.len > 0: return err
  let target = m.dir / name.strip
  if vExists(target): return name & tr(" already exists.")
  try: vMkdir(target)
  except OSError as e: return e.msg
  m.reload(name.strip)

proc makeFile*(m: FolderModel; name: string; content = ""): string =
  ## Creates the file `name` here and selects it; the error ("" if none).
  let err = validName(name)
  if err.len > 0: return err
  let target = m.dir / name.strip
  if vExists(target): return name & tr(" already exists.")
  try: vWriteFile(target, content)
  except IOError, OSError: return getCurrentExceptionMsg()
  m.reload(name.strip)

proc rename*(m: FolderModel; path, newName: string): string =
  ## Renames `path` to `newName` (in the same folder); the error ("" if none).
  let n = newName.strip
  let err = validName(n)
  if err.len > 0: return err
  if path.extractFilename == n: return ""
  let target = path.parentDir / n
  if vExists(target): return n & tr(" already exists.")
  try: discard vRename(path, n)
  except OSError, IOError: return getCurrentExceptionMsg()
  m.reload(n)

type CaseChange* = enum
  ## What `batchNames` does to the letters of the new names.
  ccKeep, ccLower, ccUpper, ccTitle   ## as they are, lower case, upper case, Each Word Capitalized

proc batchNames*(names: openArray[string]; pattern = "*"; find = "", replace = "";
                 start = 1; letters = ccKeep): seq[string] =
  ## New names for files renamed together (Rename with several selected):
  ## in `pattern`, `*` is the old name without its extension and a run of
  ## `#` the number, counted from `start` with as many digits as there are
  ## #s ("Holiday ###" -> Holiday 001.jpg, Holiday 002.jpg...); the
  ## extension stays. Then `find` becomes `replace` (every time it is
  ## there), and the letters change as `letters` says.
  var n = start
  for old in names:
    let (stem, ext) = block:
      let sp = splitFile(old)
      if sp.ext.len > 0 and sp.name.len > 0: (sp.name, sp.ext) else: (old, "")
    var t = ""
    var i = 0
    let pat = if pattern.strip.len == 0: "*" else: pattern
    while i < pat.len:
      if pat[i] == '*':
        t.add stem
        inc i
      elif pat[i] == '#':
        var k = 0
        while i < pat.len and pat[i] == '#':
          inc k
          inc i
        t.add align($n, k, '0')
      else:
        t.add pat[i]
        inc i
    t.add ext
    if find.len > 0: t = t.replace(find, replace)
    case letters
    of ccLower: t = t.toLowerAscii
    of ccUpper: t = t.toUpperAscii
    of ccTitle:
      var up = true
      for c in t.mitems:
        if c in Letters:
          if up: c = c.toUpperAscii else: c = c.toLowerAscii
          up = false
        else: up = c in {' ', '_', '-', '.'}
    of ccKeep: discard
    result.add t
    inc n

proc renameAll*(m: FolderModel; paths, newNames: openArray[string]): tuple[done: seq[(string, string)]; error: string] =
  ## Renames each of `paths` to the name beside it in `newNames` (all in
  ## their folders), names that swap places too -- through names of their
  ## own first. Stops at the first that cannot be (`error`); `done`: the
  ## renames made, old path -> new path (for undo).
  if paths.len != newNames.len: return (@[], "The names do not match the files.")
  var seen: HashSet[string]
  let leaving = toHashSet(@paths)
  for i, p in paths:
    let n = newNames[i].strip
    let err = validName(n)
    if err.len > 0: return (@[], n & ": " & err)
    let t = p.parentDir / n
    if t in seen: return (@[], "Two files would be named " & n & ".")
    seen.incl t
    if t != p and vExists(t) and t notin leaving: return (@[], n & tr(" already exists."))
  # (first out of the way, then to the new names)
  var moved: seq[(string, string, string)]          # old, temporary, new
  for i, p in paths:
    let n = newNames[i].strip
    if p.extractFilename == n: continue
    let tmp = ".renaming-" & $i & "-" & n
    try:
      moved.add (p, vRename(p, tmp), n)
    except OSError, IOError:
      result.error = getCurrentExceptionMsg()
      break
  for (old, tmp, n) in moved:
    try:
      result.done.add (old, vRename(tmp, n))
    except OSError, IOError:
      if result.error.len == 0: result.error = getCurrentExceptionMsg()
      try: discard vRename(tmp, old.extractFilename) except OSError, IOError: discard
  m.reload(if newNames.len > 0: newNames[0].strip else: "")

# ---- the file list ---------------------------------------------------------------------------

type
  FileView* = enum
    ## How a `fileList` shows the items.
    fvDetails      ## rows with columns: name, size, type, date
    fvIcons        ## large icons (pictures as thumbnails); see `iconSize`
    fvTiles        ## icons with the name, the kind and the size beside them
    fvSmallIcons   ## small icons with the name beside them, in rows (Explorer's "Small icons")
    fvColumns      ## columns: each folder of the way here a column, the picked file's preview at
                   ## the right (`fileColumns`; macOS Finder's and DeskFiles' view)
    fvList         ## small icons with the name beside them, down columns that go on to the
                   ## right, scrolled sideways (Explorer's "List")

  FileDrop* = object
    ## Files let go over a folder: move them there (copy if `copy`).
    paths*: seq[string]      ## the files dropped
    into*: string            ## the folder ("" when nothing was dropped)
    copy*: bool              ## Ctrl was held

  PreviewEvent* = object
    ## The buttons of a `filePreview` clicked this frame.
    open*, share*, properties*: bool  ## the button clicked
    item*: FileItem          ## the item the buttons are for

  FileListEvent* = object
    ## What happened in a `fileList` this frame.
    activated*: bool       ## double click, Enter (or a tap) on `item`
    item*: FileItem        ## the item activated or renamed
    selChanged*: bool      ## the selection changed
    sorted*: bool          ## a column header was clicked (`sortBy` changed)
    renamed*: bool         ## a name was edited in place (and renamed)
    newName*: string       ## ... to this name
    error*: string         ## ... why renaming failed ("" if it did not)
    drop*: FileDrop        ## files were dropped on a folder (or this one)
    zoom*: int             ## Ctrl + the wheel: +1 larger icons, -1 smaller
    middle*: bool          ## the middle button on `item` (open it in a new tab)
    preview*: PreviewEvent ## the column view's preview: its buttons clicked

proc dropped*(d: FileDrop): bool = d.into.len > 0
  ## Files were dropped (on the folder `d.into`).

proc jobFor*(d: FileDrop; trashKey = "::trash"): FileJob =
  ## The job a drop asks for (run it with `runJobDialog`): the files moved
  ## into `d.into`, copied when Ctrl was held, or sent to the trash when
  ## they were dropped on `trashKey`. nil when nothing was dropped.
  if not d.dropped or d.paths.len == 0: return nil
  if d.into == trashKey: newJob(jkTrash, d.paths)
  elif d.copy: newJob(jkCopy, d.paths, d.into)
  else: newJob(jkMove, d.paths, d.into)

proc jobTitle*(kind: JobKind): string =
  ## "Copying", "Moving"...: the title of a job's progress box.
  case kind
  of jkCopy: "Copying"
  of jkMove: "Moving"
  of jkDelete: "Deleting"
  of jkZip: "Compressing"
  of jkUnzip: "Extracting"
  of jkMeasure: "Measuring"
  of jkTrash: "Moving to the trash"

proc shownName*(m: FolderModel; f: FileItem): string =
  ## The name as the list shows it (without the extension when
  ## `showExtensions` is off).
  if m.showExtensions or f.isDir: return f.name
  let dot = f.name.rfind('.')
  if dot > 0: f.name[0 ..< dot] else: f.name

proc canTake(m: FolderModel; into: string): bool =
  ## The files dragged may go into the folder `into` (not into themselves,
  ## not where they already are).
  if not dragging("files") or into.len == 0: return false
  var allHere = true
  for p in ui.drag.items:
    if p == into or into.startsWith(p & DirSep): return false
    if p.parentDir != into: allHere = false
  not allHere

proc takeDrop(into: string): FileDrop =
  FileDrop(paths: ui.drag.items, into: into, copy: dragCopies())

proc accessState(m: FolderModel; h: int) =
  ## In place of the files of another app's folder not given yet: why, and
  ## a button that asks for it.
  let app = m.accessApp
  let r = canvas(0, h)
  fill(r, th.field)
  fieldFrame(r)
  let lines = wrapLines(app & " keeps its files to itself.", r.w - dp(16))
  let more = wrapLines((if m.askedAt != 0:
                          "In the folder picker, choose \"Use this folder\", then \"Allow\"."
                        else: "To see them here, choose Allow access, then \"Use this " &
                          "folder\" in the picker that opens. It is asked once."), r.w - dp(16))
  let gh = dp(32)
  let need = gh + dp(8) + FontH * (lines.len + more.len) + dp(10) + CtrlH
  var y = r.y + max(dp(6), (r.h - need) div 2)
  if r.h > need:
    image(r.x + (r.w - gh) div 2, y, glyphIcon(retroOr(pxLock, nfLock), th.text, gh))
    y += gh + dp(8)
  for line in lines:
    drawLabel(r.x + (r.w - textWidth(line, true)) div 2, y, line, th.text, bold = true)
    y += FontH
  for line in more:
    text(r.x + (r.w - textWidth(line)) div 2, y, line, th.gray)
    y += FontH
  y += dp(10)
  let label = if m.askedAt != 0: "Ask &again" else: "&Allow access"
  let bw = max(dp(110), labelWidth(label) + dp(24))
  if y + CtrlH <= r.y + r.h:
    pushFrame(rect(r.x + (r.w - bw) div 2, y, bw, CtrlH))
    if button(label, isDefault = true, w = bw): m.askAccess()
    discard popFrame()
  ui.lastRect = r

# ---- the column view ---------------------------------------------------------------------------------------

proc filePreview*(m: FolderModel; buttons = true; height = -1;
                  followHover = true): PreviewEvent
  ## The details pane of `m`: the item the mouse rests on (`followHover`),
  ## else what is selected, else the folder (see the `filePreview` of
  ## items for what it shows; `buttons`: Open / Share / Properties;
  ## `height`: -1 the rest of the column).

type ColumnsState = ref object
  parents: Table[string, FolderModel]   ## the folders above the one shown, listed
  keyPicked: string                     ## the folder picked with the keys (shown ahead)
  follow: bool                          ## (scroll the item picked into view)
  typed: string                         ## the name being typed (type-ahead)
  typedAt: int
  shownKey: string                      ## (the columns shown: when they change, the last in view)
  seen: int                             ## (the frame it was last drawn in)
var columnStates: Table[string, ColumnsState]

proc countsText(items: openArray[FileItem]): string =
  var dirs, files = 0
  for it in items:
    if it.isDir: inc dirs else: inc files
  $dirs & (if dirs == 1: " folder" else: " folders") & " · " & $files & (if files == 1: " file" else: " files")

proc fileColumns*(m: FolderModel; root = ""; height = -1; key = ""; preview = true;
                  thumbnails = true): FileListEvent =
  ## The column view: each folder from `root` (else the top) down to the
  ## one `m` shows is a column -- its name, how many items, a button that
  ## sorts it, its items (folders with an arrow; pictures as small
  ## pictures), "so many folders · so many files" under it -- and, when a
  ## file is picked, its preview in a column of its own at the right. A
  ## click on a folder opens it in the next column; on a file picks it;
  ## a double click (or Enter) activates it. Left goes up a column, Right
  ## into the folder picked, Up and Down along the column.
  m.update()
  result.item = FileItem()
  # (the state is the model's: two models drawn with one `key` -- two
  # folder windows -- each keep their own columns, rather than listing
  # each other's folders again every frame; a state not drawn for a while
  # is let go, with its listings)
  if (ui.frameNo and 1023) == 0:
    var old: seq[string]
    for sk, s in columnStates:
      if ui.frameNo - s.seen > 1024: old.add sk
    for sk in old:
      for _, pm in columnStates[sk].parents: pm.forget()
      columnStates.del sk
  let k = (if key.len > 0: key else: "cols") & "#" & $m.group
  var st = columnStates.getOrDefault(k)
  if st == nil:
    st = ColumnsState()
    columnStates[k] = st
  st.seen = ui.frameNo
  let fullH = if height >= 0: height else: remainingH()
  # the folders of the way here
  var chain: seq[string]
  var p = m.dir
  while p.len > 0 and chain.len < 24:
    chain.insert(p, 0)
    if root.len > 0 and p == root: break
    let up = p.parentDir
    if up == p or up.len == 0: break
    p = up
  if chain.len == 0: chain.add m.dir
  let cur = m.current
  # a folder picked (with the keys) shows what is in it in the next column
  let curPicked = m.sel in 0 ..< min(m.items.len, m.marked.len) and m.marked[m.sel]
  let peek = if curPicked and cur.isDir and cur.path == st.keyPicked: cur.path
             else: ""
  if peek.len > 0: chain.add peek
  # (the other columns' listings: kept while on the way, the others let go)
  for ci, d in chain:
    if d == m.dir and ci == chain.high - ord(peek.len > 0): continue
    if d notin st.parents:
      let pm = newFolderModel("", m.showHidden)
      pm.sortBy = m.sortBy
      pm.descending = m.descending
      pm.patterns = m.patterns
      pm.showExtensions = m.showExtensions
      pm.open(d)
      st.parents[d] = pm
    st.parents[d].update()
  var gone: seq[string]
  for d, _ in st.parents:
    if d notin chain or d == m.dir: gone.add d
  for d in gone:
    st.parents[d].forget()
    st.parents.del d
  let curCol = chain.high - (if peek.len > 0: 1 else: 0)   # (the column of `m`)
  let showPv = preview and curPicked and not cur.isDir
  let room = available()
  let colW = if isCompact(): max(dp(150), room div 2 - dp(4)) else: dp(240)
  # every column side by side, as wide as they are; when they are wider
  # than their room, a scroll bar under them goes along (the newest in
  # view). The preview stays where it is, at the right: it does not scroll.
  var widths: seq[int]
  for _ in 0 ..< chain.len: widths.add colW
  let total = max(1, chain.len * colW + max(0, chain.len - 1) * Gap)
  var pvW = 0
  if showPv:
    let least = if isCompact(): max(dp(150), room div 2) else: max(dp(280), colW + dp(40))
    pvW = clamp(room - total - Gap, least, max(least, room - Gap - min(colW, room div 2)))
    pvW = min(pvW, room - Gap - dp(60))
  let colsRoom = if showPv: room - pvW - Gap else: room
  let maxX = max(0, total - colsRoom)
  let barH = if maxX > 0: SbW else: 0
  let area = place(room, fullH)
  let colsH = fullH - barH
  let sid = idOf(k & ":columns-x")
  var sx = state(sid).scrollX
  let shownKey = chain.join("\n") & (if showPv: "\n+" else: "")
  if shownKey != st.shownKey:
    st.shownKey = shownKey
    sx = maxX                            # (opened, picked: the newest column in view)
  sx = clamp(sx, 0, maxX)
  var openDir = ""
  var openKeep = ""
  var activate = false
  let rowH = max(ItemH, FontH + dp(10))
  # the keyboard: one stop of Tab for all the columns; a click in one takes it
  let areaId = idOf(k & ":area")
  let hasKeys = tabStop(areaId, rect(0, 0, 0, 0))
  let h = colsH
  pushClip(rect(area.x, area.y, colsRoom, colsH))
  beginClipped()
  pushFrame(rect(area.x - sx, area.y, total, colsH))
  row(widths):
    for ci in 0 ..< chain.len:
      let dir = chain[ci]
      let mm = if ci == curCol: m else: st.parents[dir]
      let wantName = if ci < curCol: chain[ci + 1].extractFilename else: ""
      col:
        # the head: the folder, how many, the sort
        let hr = place(available(), CtrlH + dp(4))
        fill(hr, th.face)
        hline(hr.x, hr.y + hr.h - 1, hr.w, th.shadow)
        let nm = if dir.extractFilename.len > 0: dir.extractFilename else: dir
        let cnt = $mm.items.len
        let sortW = dp(22)
        let cw = textWidth(cnt)
        text(hr.x + dp(6), hr.y + (hr.h - FontH) div 2,
             ellipsize(nm, hr.w - cw - sortW - dp(18)), if ci == curCol: th.select else: th.text, true)
        text(hr.x + hr.w - sortW - cw - dp(6), hr.y + (hr.h - FontH) div 2, cnt, th.gray)
        let sr = rect(hr.x + hr.w - sortW - dp(2), hr.y + dp(2), sortW, hr.h - dp(4))
        let sid = idOf(k & ":sort:" & dir)
        let sh = interact(sid, sr, focusable = false)
        if accessOn:
          accessBegin(arList, nm, rect(hr.x, hr.y, hr.w, h), idOf(k & ":col:" & dir))
          accessNode(arButton, "Sort", id = sid, r = sr,
                     help = ["name", "size", "type", "date"][(ord(mm.sortBy) + 1) mod 4])
        if sh.hover: fill(sr, hoverColor())
        text(sr.x + (sr.w - textWidth("↕")) div 2, sr.y + (sr.h - FontH) div 2, "↕", th.text)
        if sh.hover: ui.tip = "Sort by " & ["name", "size", "type", "date"][(ord(mm.sortBy) + 1) mod 4]
        if sh.clicked:
          mm.sortBy = SortKey((ord(mm.sortBy) + 1) mod (ord(SortKey.high) + 1))
          mm.applyView(if ci == curCol: m.current.name else: wantName)
          result.sorted = ci == curCol
        # the items
        let listH = h - hr.h - FontH - dp(10)
        let pitch = rowH + Gap
        let scrollKey = k & ":list:" & dir
        if ci == curCol and st.follow and m.sel >= 0:
          # (the item picked with the keys kept in view)
          st.follow = false
          let sid = makeId(fnv("scroll-panel" & scrollKey))
          let top = m.sel * pitch
          var y = state(sid).scrollY
          if top < y: y = top
          elif top + rowH + 2 * Pad > y + listH - 2: y = top + rowH + 2 * Pad - (listH - 2)
          state(sid).scrollY = max(0, y)
        beginScroll(listH, scrollKey)
        if mm.items.len == 0:
          label(if mm.loading: "..." else: "(empty)", color = th.gray)
        # only the rows in view are made (a folder of 50 000 files scrolls as one of 50)
        let y0 = beginCell(0, true).y
        let clip = clipRect()
        let firstVis = clamp((clip.y - y0) div pitch, 0, mm.items.len)
        let lastVis = clamp((clip.y + clip.h - y0) div pitch + 1, firstVis - 1, mm.items.high)
        if firstVis > 0: discard place(available(), firstVis * pitch - Gap)
        for i in firstVis .. lastVis:
          let it = mm.items[i]
          let r = place(available(), rowH)
          let rid = idOf(k & ":row:" & it.path)
          let hit = interact(rid, r, focusable = false)
          let picked = if ci == curCol: i == m.sel and curPicked else: it.name == wantName
          if accessOn:
            let n = accessNode(arListItem, it.name, id = rid, r = r,
                               states = (if picked: {asSelected} else: {}) +
                                        (if it.isDir: {asExpandable} else: {}),
                               help = (if it.isDir: "folder" else: ""))
            accessItem(n, i + 1, mm.items.len)
            if picked and ci == curCol and hasKeys: accessFocus(n)
          if picked:
            fill(r, if ci == curCol: th.select else: th.shadow)
          elif hit.hover: fill(r, hoverColor())
          let tc = if picked: th.selectText else: th.text
          let ic = rowH - dp(6)
          let ir = rect(r.x + dp(4), r.y + dp(3), ic, ic)
          var drawn = false
          if thumbnails and not it.isDir and isPicture(it):
            drawn = drawPicture(ir, it.path, it.modified.toUnix, priority = 1, enlarge = false)
          if not drawn:
            let (g, gc) = fileGlyph(it)
            text(ir.x, r.y + (r.h - FontH) div 2, g, if picked: th.selectText else: gc)
          let tx = ir.x + ic + dp(6)
          let arrowW = if it.isDir: dp(14) else: 0
          text(tx, r.y + (r.h - FontH) div 2, ellipsize(it.name, r.x + r.w - tx - arrowW - dp(4)), tc)
          if it.isDir:
            text(r.x + r.w - arrowW, r.y + (r.h - FontH) div 2, "›", tc, true)
          if tapped(rid, hit):
            ui.focus = areaId
            let dbl = not finger() and ui.clicks >= 2
            if it.isDir:
              openDir = it.path
            elif ci > curCol:
              # (a file in the folder peeked into: that folder, the file picked)
              openDir = dir
              openKeep = it.name
            elif ci == curCol:
              let was = m.sel == i and curPicked
              if not was:
                m.sel = i
                for x in m.marked.mitems: x = false
                if i < m.marked.len: m.marked[i] = true
                result.selChanged = true
              if dbl or (finger() and was): activate = true
            else:
              openDir = dir
              openKeep = it.name
          if hit.hover and ui.rpressed and ci == curCol and m.sel != i:
            m.sel = i
            result.selChanged = true
        if lastVis < mm.items.high: discard place(available(), (mm.items.high - lastVis) * pitch - Gap)
        endScroll()
        if accessOn: accessEnd()
        label(countsText(mm.items), color = th.gray)
  discard popFrame()
  endClipped()
  popClip()
  # the preview, beside the columns' room (the whole height)
  if showPv:
    pushFrame(rect(area.x + colsRoom + Gap, area.y, pvW, fullH))
    result.preview = filePreview(m, buttons = true, height = fullH, followHover = false)
    if result.preview.open: activate = true
    discard popFrame()
  # going along: the bar, Shift + the wheel (or a sideways wheel), a finger
  let colsArea = rect(area.x, area.y, colsRoom, colsH)
  if maxX > 0 and canInput():
    scrollWheel(sid, sx, maxX, colsArea, colW div 2, sideways = true)
    scrollPan(sid, sx, maxX, colsArea, sideways = true)
  scrollTick(sid, sx, maxX)
  if maxX > 0:
    scrollBarFor(sid + 9, sid, rect(area.x, area.y + colsH, colsRoom, SbW), false, sx, maxX,
                 colsRoom, max(ItemH, colW div 4))
  state(sid).scrollX = sx
  ui.lastRect = area
  # the keys: along the column, up and into folders
  if hasKeys and canInput() and m.items.len > 0:
    if not ui.touch: ui.takesText = true     # (type-ahead; no keyboard pops up)
    if ui.typed.len > 0 and ui.typed[0] > ' ':
      # type the first letters of a name to go to it
      if ui.now - st.typedAt > 1000: st.typed = ""
      st.typed.add ui.typed.toLowerAscii
      st.typedAt = ui.now
      let start = if not curPicked: 0 elif st.typed.len == 1: m.sel + 1 else: max(0, m.sel)
      for j in 0 ..< m.items.len:
        let i = (start + j) mod m.items.len
        if m.items[i].name.toLowerAscii.startsWith(st.typed):
          if i != m.sel:
            m.sel = i
            for x in m.marked.mitems: x = false
            m.marked[i] = true
            result.selChanged = true
            st.keyPicked = m.items[i].path
            st.follow = true
          break
  if hasKeys and not ui.keyUsed and ui.key != KeyNone and canInput():
    case ui.key
    of KeyUp, KeyDown:
      if m.items.len > 0:
        let ns = if not curPicked: 0 else: clamp(m.sel + (if ui.key == KeyUp: -1 else: 1), 0, m.items.high)
        if ns != m.sel or not curPicked:
          m.sel = ns
          for x in m.marked.mitems: x = false
          m.marked[ns] = true
          result.selChanged = true
          st.keyPicked = m.items[ns].path
          st.follow = true
      ui.keyUsed = true
    of KeyLeft:
      if m.canGoUp and (root.len == 0 or m.heading != root):
        st.keyPicked = m.heading             # (the folder left, shown ahead)
        m.goUp()
        ui.keyUsed = true
    of KeyRight:
      if curPicked and cur.isDir:
        openDir = cur.path
        ui.keyUsed = true
    of KeyEnter:
      if curPicked:
        if cur.isDir: openDir = cur.path else: activate = true
        ui.keyUsed = true
    else: discard
  if openDir.len > 0:
    m.open(openDir, openKeep)
    result.selChanged = true
  elif activate and cur.name.len > 0:
    result.activated = true
    result.item = m.current

proc fileList*(m: FolderModel; view = fvDetails; thumbnails = true; bigIcons = true;
               tapActivates = false; checkboxes = false; height = -1;
               iconSize = 0; dragDrop = true): FileListEvent =
  ## The items of `m` as rows with columns (`fvDetails`), large icons
  ## (`fvIcons`, `iconSize` design pixels; pictures as thumbnails decoded
  ## in the background) or tiles. Click, Ctrl+click, Shift+click, a
  ## selection rectangle, arrows, type-ahead and (on phones) check boxes
  ## select; double click, Enter or (with `tapActivates`) a tap activates;
  ## headers sort; F2 or a slow second click edits a name. With `dragDrop`,
  ## the selection can be dragged (onto folders here, in another list, in
  ## a `folderTree`, a `pathBar`...), and files dragged here are reported
  ## in `drop`. `height` in pixels (-1: the room left). `fvColumns`:
  ## `fileColumns`.
  if view == fvColumns:
    return fileColumns(m, height = height, thumbnails = thumbnails,
                       key = "cols" & $cast[uint](m))
  m.update()
  if height >= 0:
    # a given height (in pixels): the list fills a cell that tall
    let cell = place(0, height, fill = true)
    pushFrame(cell)
    result = fileList(m, view, thumbnails, bigIcons, tapActivates, checkboxes,
                      iconSize = iconSize, dragDrop = dragDrop)
    discard popFrame()
    ui.lastRect = cell
    return
  let h = remainingH()
  template keepFocus() =
    # (while it reads its folder, or shows it empty, the list is still a
    # stop of Tab and keeps the focus: the keys go on in it once it is
    # filled, not to the tree beside it)
    discard interact(idOf(m.sel, if view in {fvIcons, fvTiles, fvSmallIcons, fvList} and
                                    not m.searching: "iconview"
                               else: "grid"),
                     ui.lastRect, focusable = true)
  if m.needsAccess:
    accessState(m, h)
    keepFocus()
    return
  if m.items.len == 0:
    if m.ticket != 0 and m.loadingFor > 150:
      busyState(tr("Reading ") & m.loadPath.extractFilename & "...", h)
    elif m.searchBusy: busyState("Searching...", h)
    elif m.searching or m.filter.len > 0:
      emptyState(retroOr(pxSearch, nfSearch), tr("Nothing matches \"") & m.filter & "\".", h)
    elif m.ticket != 0: emptyState("", "", h)
    elif m.error.len > 0 and m.dir.len == 0: emptyState(retroOr(pxWarning, nfWarning), m.error, h)
    else: emptyState(retroOr(pxFolderOpen, nfFolderOpen), "This folder is empty.", h)
    keepFocus()
    # an empty folder still takes files
    if dragDrop and m.canTake(m.dir):
      case dropTarget(ui.lastRect, "files")
      of dsOver: dropHighlight(ui.lastRect)
      of dsDropped: result.drop = takeDrop(m.dir)
      else: discard
    return
  var ev: GridEvent
  if m.marked.len != m.items.len: m.marked.setLen(m.items.len)
  var dropOk: proc (i: int): bool = nil
  if dragDrop:
    dropOk = proc (i: int): bool =
      if i < 0: m.canTake(m.dir)
      else: m.items[i].isDir and m.canTake(m.items[i].path)
  # Ctrl + the wheel: the size of the icons
  if canInput() and ui.wheel != 0 and not ui.wheelUsed and CtrlPressed in ui.mods and
     mouseIn(rect(0, 0, ui.w, ui.h)):
    result.zoom = (if ui.wheel > 0: 1 else: -1)
    ui.wheelUsed = true
  if view in {fvIcons, fvTiles, fvSmallIcons, fvList} and not m.searching:
    let pic = if view in {fvSmallIcons, fvList}: (if fingers(): 24 else: 16)
              elif iconSize > 0: iconSize
              elif view == fvTiles: 48
              elif bigIcons: 72 else: 48
    ev = iconView(m.items.len, proc (i: int): string = m.shownName(m.items[i]),
      proc (i: int; r: Rect) =
        let f = addr m.items[i]
        if thumbnails and not f.stub and isPicture(f[]) and
           drawPicture(r, f.path, f.modified.toUnix, priority = 1, group = m.group):
          return
        image(r.x, r.y, fileIcon(f[], min(r.w, r.h))),
      m.sel, m.marked, height = -1, tapActivates = tapActivates,
      checkboxes = checkboxes,
      tile = (if view in {fvSmallIcons, fvList}: 180 elif view == fvTiles: max(220, pic * 4)
              else: max(76, pic + 40)),
      picSize = pic, oneLine = view in {fvSmallIcons, fvList}, columnWise = view == fvList,
      detail = (if view == fvTiles:
                  proc (i: int): string =
                    let f = addr m.items[i]
                    kindText(f[]) & "\n" &
                      (if f.isDir: dateText(f.modified) else: sizeText(f.size))
                else: nil),
      dragItems = dragDrop, dropOk = dropOk)
  else:
    let narrow = isCompact()
    var c = if narrow: m.phoneColumns else: m.columns
    # the name column takes the room the others leave
    var others = 0
    for i in 1 ..< c.len: others += c[i].width
    let room = int(float(available()) / max(0.1, ui.k)) - others -
               (if checkboxes: 34 else: 0) - 24
    c[0].width = clamp(room, 120, 520)
    if m.searching and not narrow: c.add column("Folder", 260)
    let small = min(ItemH - 2, FontH + 8)
    ev = grid(c, m.items.len, proc (r, col: int): string =
      let f = addr m.items[r]
      case col
      of 0: m.shownName(f[])
      of 1: (if f.isDir or f.stub: "" else: sizeText(f.size))
      of 2: kindText(f[])
      of 3: (if f.stub: "" else: dateText(f.modified))
      else: f.path.parentDir
    , m.sel, m.marked, height = -1,
      sortColumn = (if m.searching: -1 elif narrow and m.sortBy > bySize: -1
                    else: ord(m.sortBy)),
      sortDescending = m.descending,
      icon = proc (r: int): Icon = fileIcon(m.items[r], small),
      typeToEdit = false, tapActivates = tapActivates, checkboxes = checkboxes,
      dragRows = dragDrop, dropOk = dropOk)
    if narrow:
      for i in 1 ..< min(m.phoneColumns.len, c.len): m.phoneColumns[i].width = c[i].width
    else:
      for i in 1 ..< min(m.columns.len, c.len): m.columns[i].width = c[i].width
  result.selChanged = ev.selChanged
  if ev.activated:
    let i = if ev.row >= 0: ev.row else: m.sel
    if i >= 0 and i < m.items.len:
      result.activated = true
      result.item = m.items[i]
  if ev.sorted and ev.sortColumn in 0 .. 3 and not m.searching:
    m.sortBy = SortKey(ev.sortColumn)
    m.descending = ev.sortDescending
    m.applyView()
    result.sorted = true
  if ev.edited and ev.col == 0 and ev.row in 0 ..< m.items.len:
    result.renamed = true
    let f = m.items[ev.row]
    result.item = f
    # (with the extensions hidden, the name typed has none: keep the old one)
    let ext = if m.showExtensions or f.isDir: "" else: f.name.splitFile.ext
    result.newName = ev.text.strip & ext
    result.error = m.rename(f.path, result.newName)
  # dragging: the selection if the item is in it, else just the item
  if ev.dragStarted and ev.row in 0 ..< m.items.len:
    var paths: seq[string]
    if m.marked[ev.row]:
      for i, mk in m.marked:
        if mk: paths.add m.items[i].path
    else: paths.add m.items[ev.row].path
    let f = m.items[ev.row]
    startDrag("files", paths, if paths.len == 1: f.name else: countText(paths.len, "item"),
              fileGlyph(f).glyph)
  if ev.dropped:
    let into = if ev.row >= 0 and ev.row < m.items.len: m.items[ev.row].path else: m.dir
    result.drop = takeDrop(into)
  # where the mouse rests: what the preview shows (after a moment, so
  # passing over items on the way to somewhere does not count)
  m.hot = ev.hot
  if ev.hot >= 0 and ev.hot < m.items.len and middleClicked(rect(0, 0, ui.w, ui.h)):
    result.middle = true
    result.item = m.items[ev.hot]
  if ev.selChanged:
    m.attention = ""
  if ev.hot >= 0 and ev.hot < m.items.len:
    let p = m.items[ev.hot].path
    if p != m.hoverPath:
      m.hoverPath = p
      m.hoverSince = ui.now
      wakeIn(200)
    elif ui.now - m.hoverSince >= 180 and m.attention != p:
      m.attention = p
      m.attentionAt = ev.hot
  else:
    m.hoverPath = ""

proc editName*(m: FolderModel) =
  ## Starts editing the current item's name in the details view (F2); the
  ## extension is left out of the selection.
  let f = m.current
  if f.name.len == 0: return
  let n = m.shownName(f)
  let dot = n.rfind('.')
  gridEdit(m.sel, 0, if dot > 0 and not f.isDir: dot else: -1)

# ---- facts and the preview --------------------------------------------------------------------

var pv: tuple[key: string; text: string; job: FileJob; size: tuple[w, h: int]]

proc permissionsText*(path: string): string =
  ## "rwxr-xr-x" ("" on Windows or when it cannot be read).
  when not defined(windows):
    let perms = try: getFilePermissions(path) except OSError: return ""
    for (p, c) in [(fpUserRead, 'r'), (fpUserWrite, 'w'), (fpUserExec, 'x'),
                   (fpGroupRead, 'r'), (fpGroupWrite, 'w'), (fpGroupExec, 'x'),
                   (fpOthersRead, 'r'), (fpOthersWrite, 'w'), (fpOthersExec, 'x')]:
      result.add(if p in perms: c else: '-')

proc filePreview*(items: openArray[FileItem]; folder = ""; folderStats =
                  (files: 0, folders: 0, bytes: 0'i64); buttons = true;
                  height = -1): PreviewEvent =
  ## The details pane: for one item its picture (decoded in the background)
  ## or the start of its text, its size (a folder's is measured as you
  ## look), dates and kind, and Open / Share / Properties; for several
  ## items their count and size; for none the `folder` and `folderStats`.
  ## Tall, the picture is above the details; wide (under a list on a
  ## phone), at their left.
  let one = items.len == 1
  let f = if one: items[0] else: FileItem()
  let n = items.len
  let key = if one: f.path & "\0" & $f.modified.toUnix
            else: "\0" & folder & "\0" & $n
  if key != pv.key:
    pv.key = key
    pv.text = ""
    if pv.job != nil: pv.job.cancel()
    pv.job = nil
    pv.size = (0, 0)
    if one:
      if isPicture(f): pv.size = pictureSize(f.path)
      elif isTextFile(f) and f.size > 0:
        try:
          var fh = vOpen(f.path, fmRead)         # (another app's documents too)
          var buf = newString(4096)
          buf.setLen(fh.readBuffer(addr buf[0], 4096))
          fh.close()
          pv.text = buf
        except IOError, OSError: discard
      elif f.isDir:
        pv.job = newJob(jkMeasure, @[f.path])
  if pv.job != nil and pv.job.state == jsRunning:
    pv.job.run(4)
    wakeIn(1)
  let whole = canvas(0, if height < 0: remainingH() else: height)
  fill(whole, th.field)
  fieldFrame(whole)
  # more than fits: it scrolls, with the standard scroll bar
  let sid = makeId(fnv("file-preview"))
  var sst = state(sid)
  let scrolls = sst.aux > whole.h
  let r = if scrolls: rect(whole.x, whole.y, whole.w - SbW + 1, whole.h) else: whole
  let off = if scrolls: clamp(sst.scrollY, 0, sst.aux - whole.h) else: 0
  pushClip(inset(r, 1))
  let pad = dp(10)
  let wide = r.w > r.h * 3 div 2
  var pr: Rect
  var x, y, w: int
  if wide:
    let side = min(r.h - 2 * pad, r.w * 2 div 5)
    pr = rect(r.x + pad, r.y + pad, side, r.h - 2 * pad)
    pr.y -= off
    x = pr.x + pr.w + pad
    y = r.y + pad - off
    w = r.x + r.w - pad - x
  else:
    x = r.x + pad
    y = r.y + pad - off
    w = r.w - 2 * pad
    pr = rect(x, y, w, min(w * 3 div 4, r.h div 2))
    y += pr.h + pad
  # the picture, the start of the text, or a big icon
  var shown = false
  if one and isPicture(f):
    shown = drawPicture(pr, f.path, f.modified.toUnix, priority = 3)
    if not shown and not pictures().failed(f.path, f.modified.toUnix):
      drawSpinner(pr.x + pr.w div 2, pr.y + pr.h div 2, min(FontH * 2, pr.h div 2))
      shown = true
  elif one and pv.text.len > 0:
    fill(pr, th.window)
    box(pr, th.face)
    pushClip(inset(pr, 1))
    let st = style(mono = true, size = (if wide: 0.7 else: 0.85))
    let lh = lineHeight(st)
    var ty = pr.y + dp(4)
    for line in pv.text.splitLines:
      if ty > pr.y + pr.h: break
      text(pr.x + dp(4), ty, line.replace("\t", "  "), th.fieldText, st)
      ty += lh
    popClip()
    shown = true
  if not shown:
    let (g, c) = if one: fileGlyph(f) elif n > 1: (retroOr(pxCopy, nfFiles), folderColor)
                 else: (retroOr(pxFolderOpen, nfFolderOpen), folderColor)
    let st = style(size = float(min(pr.h, pr.w)) * 0.55 / float(FontH))
    text(pr.x + (pr.w - textWidth(g, st)) div 2, pr.y + (pr.h - lineHeight(st)) div 2,
         g, c, st)
  # the name and the facts
  let title = if one: f.name elif n > 1: countText(n, "item") & tr(" selected")
              else: folder.extractFilename
  for line in wrapLines(title, w, true):
    text(x, y, line, th.fieldText, true)
    y += FontH
  let kind = if one: kindText(f) elif n > 1: "" else: tr("File folder")
  if kind.len > 0:
    text(x, y, kind, th.gray)
    y += FontH
  y += dp(4)
  hline(x, y, w, th.face)
  y += dp(4)
  var facts: seq[(string, string)]
  if one:
    if not f.isDir: facts.add ("Size", sizeText(f.size))
    elif pv.job != nil:
      let busy = pv.job.state == jsRunning
      facts.add ("Size", sizeText(pv.job.totalBytes) & (if busy: "..." else: ""))
      facts.add ("Contains", countText(pv.job.files, "file") & tr(", ") &
                 countText(max(0, pv.job.folders - 1), "folder"))
    facts.add ("Modified", dateText(f.modified))
    if pv.size.w > 0:
      facts.add ("Picture", $pv.size.w & " x " & $pv.size.h & tr(" pixels"))
    if f.readOnly: facts.add ("Access", tr("read only"))
    if f.isLink: facts.add ("Link to", (let t = linkTarget(f.path); if t.len > 0: t else: "?"))
    if not wide: facts.add ("Location", f.path.parentDir)
  elif n > 1:
    var bytes = 0'i64
    var nf, nd = 0
    for it in items:
      if it.isDir: inc nd
      else:
        inc nf
        bytes += it.size
    facts.add ("Files", countText(nf, "file") & " (" & sizeText(bytes) & ")")
    if nd > 0: facts.add ("Folders", countText(nd, "folder"))
  elif folder.len > 0:
    facts.add ("Contains", countText(folderStats.files, "file") & ", " &
               countText(folderStats.folders, "folder"))
    if folderStats.files > 0: facts.add ("Files", sizeText(folderStats.bytes))
    let sp = diskSpaceCached(folder)
    if sp.total > 0: facts.add ("Free", sizeText(sp.free) & tr(" of ") & sizeText(sp.total))
    if not wide: facts.add ("Location", folder)
  let factsEnd = drawFacts(x, y, w, facts)
  # the buttons at the bottom; when it scrolls, under the facts
  let btnY = if scrolls: factsEnd + dp(6) else: r.y + r.h - CtrlH - pad
  var need = factsEnd + off - r.y + pad
  if one and buttons: need += dp(6) + CtrlH
  if wide: need = max(need, pr.h + 2 * pad)
  popClip()
  if one: result.item = f
  if one and buttons and btnY + CtrlH > r.y and btnY < r.y + r.h:
    pushClip(inset(r, 1))
    pushFrame(rect(x, btnY, w, 0))
    row:
      if wide:
        if toolButton(retroOr(pxOpenWith, nfExternalLink), "Open", size = 1.2): result.open = true
        if not f.isDir and platformName() == "android":
          if toolButton(retroOr(pxShare, nfShare), "Share", size = 1.2): result.share = true
        if toolButton(retroOr(pxProperties, nfInfoOutline), "Properties", size = 1.2): result.properties = true
      else:
        if button("&Open"): result.open = true
        if not f.isDir and platformName() == "android":
          if button("S&hare"): result.share = true
        if button("Propert&ies"): result.properties = true
    discard popFrame()
    popClip()
  # the scroll bar, the wheel, a finger
  var o = off
  if scrolls:
    let maxO = max(0, need - whole.h)
    scrollWheel(sid, o, maxO, whole, 3 * ItemH)
    scrollPan(sid, o, maxO, whole)
    scrollTick(sid, o, maxO)
    scrollBarFor(sid + 9, sid, rect(whole.x + whole.w - SbW, whole.y, SbW, whole.h),
                 true, o, maxO, max(ItemH, whole.h - 2 * ItemH), ItemH)
  if need != sst.aux or o != sst.scrollY:
    if (need > whole.h) != scrolls: ui.redraw = true
    sst.aux = need
    sst.scrollY = clamp(o, 0, max(0, need - whole.h))
    ui.redraw = ui.redraw or o != off
  state(sid) = sst
  ui.lastRect = whole

proc filePreview*(m: FolderModel; buttons = true; height = -1;
                  followHover = true): PreviewEvent =
  ## The details pane of `m`: the item the mouse rests on (`followHover`),
  ## else what is selected, else the folder.
  var shown: seq[FileItem]
  if followHover and m.attention.len > 0:
    var i = m.attentionAt
    if i < 0 or i >= m.items.len or m.items[i].path != m.attention:
      i = -1
      for k, it in m.items:
        if it.path == m.attention:
          i = k
          break
      m.attentionAt = i
    if i >= 0: shown.add m.items[i]
    else: m.attention = ""
  if shown.len == 0 and m.marked.len == m.items.len:
    # the current item first when it is one of them
    if m.sel >= 0 and m.sel < m.items.len and m.marked[m.sel]: shown.add m.items[m.sel]
    for i, mk in m.marked:
      if mk and i != m.sel: shown.add m.items[i]
  filePreview(shown, m.dir, m.stats, buttons, height)

# ---- the folder tree -----------------------------------------------------------------------

var tree: tuple[open: Table[string, bool]; kids: Table[string, seq[string]];
                hasKids: Table[string, bool]; places: seq[tuple[name, path: string]];
                placesAt: int]
tree.placesAt = -100_000

proc forgetFolderTree*() =
  ## The tree reads the folders again (after folders were made or removed).
  tree.kids.clear()
  tree.hasKids.clear()

proc placeList*(): seq[tuple[name, path: string]] =
  ## `places()`, asked at most every 5 seconds (it can be slow).
  if ui.now - tree.placesAt > 5000:
    tree.places = places()
    when androidApp:
      # Termux's home, given through its documents provider (docfs)
      if systemCall("installed", "com.termux") == "1":
        tree.places.add ("Termux", "/data/data/com.termux/files/home")
    tree.placesAt = ui.now
  tree.places

type DriveBarEvent* = object
  ## What happened in a `driveBar` this frame.
  picked*: string          ## the place clicked ("" if none)
  drop*: FileDrop          ## files were dropped on a place

proc driveBar*(current: string; favorites: openArray[string] = [];
               extra: openArray[tuple[label, glyph, id: string]] = [];
               key = ""): DriveBarEvent =
  ## The drive bar of the 1990s file managers, for today's places: a strip
  ## of small buttons (home, documents, downloads, the disks and cards,
  ## the `favorites`, the `extra` ones such as the trash), the one holding
  ## `current` framed. A click goes there; files dropped on one go there.
  ## It scrolls (the wheel, a finger) when it does not fit.
  let h = (if fingers(): CtrlH else: ItemH + dp(6))
  let r = place(0, h, fill = true)
  let id = idOf("drivebar:" & key)
  var st = state(id)
  fill(r, th.face)
  hline(r.x, r.y + r.h - 1, r.w, th.shadow)
  var items: seq[tuple[label, glyph, id: string]]
  for (name, path) in placeList():
    items.add (tr(name), placeGlyph(name), path)    # (the places' names translated; favorites' not)
  for f in favorites:
    items.add (f.extractFilename, retroOr(pxFolderStar, nfFolderStar), f)
  for e in extra: items.add (tr(e.label), e.glyph, e.id)
  # the place holding `current`: the longest path that starts it
  var best = -1
  for i, it in items:
    if current == it.id or current.startsWith(it.id & DirSep) or
       (it.id == "/" and current.startsWith("/")):
      if best < 0 or it.id.len > items[best].id.len: best = i
  let pad = dp(6)
  var widths: seq[int]
  var total = 0
  for it in items:
    widths.add textWidth(it.glyph) + dp(4) + textWidth(it.label) + 2 * pad
    total += widths[^1] + dp(2)
  # more than fits: two arrow buttons at the end scroll it (as tabs do),
  # and the wheel and a finger
  let aw = if fingers(): CtrlH else: SbW
  let over = total + dp(4) > r.w
  let strip = if over: rect(r.x, r.y, r.w - 2 * aw - dp(4), r.h) else: r
  let maxOff = max(0, total - strip.w + dp(4))
  var off = clamp(st.scrollX, 0, maxOff)
  if maxOff > 0:
    let step = max(dp(60), strip.w div 3)
    for k in 0 .. 1:
      let ar = rect(strip.x + strip.w + dp(2) + k * aw, r.y + dp(2), aw, r.h - dp(5))
      let can = if k == 0: off > 0 else: off < maxOff
      let hit = interact(id + uint32(1000 + k), ar, focusable = false, enabled = can)
      if hit.clicked:
        scrollBy(id, off, if k == 0: -step else: step, maxOff)      # (it glides)
      elif hit.down and heldFor() > 400:
        scrollStop(id)
        off = clamp(off + (if k == 0: -step else: step) div 8, 0, maxOff)
        wakeIn(40)
      buttonFace(ar, hit.down, rounded = false, bevel = 1, hot = can and hovered(ar))
      arrow(ar.x + ar.w div 2, ar.y + ar.h div 2, if k == 0: dLeft else: dRight,
            if can: th.frame else: th.gray)
    if canInput():
      scrollPan(id, off, maxOff, strip, sideways = true)
      if mouseIn(r) and ui.wheel != 0 and not ui.wheelUsed:   # (either way: sideways)
        ui.wheelUsed = true
        scrollBy(id, off, -ui.wheel * dp(60), maxOff)
  scrollTick(id, off, maxOff)
  pushClip(strip)
  var x = r.x + dp(2) - off
  if accessOn: accessBegin(arToolBar, "Places", r)
  for i, it in items:
    let br = rect(x, r.y + dp(2), widths[i], r.h - dp(5))
    x += widths[i] + dp(2)
    if br.x + br.w < strip.x or br.x > strip.x + strip.w: continue
    let hit = interact(id + uint32(i + 1), br, focusable = false)
    if accessOn:
      accessNode(arButton, it.label, id = id + uint32(i + 1), r = br,
                 states = (if i == best: {asSelected} else: {}), help = it.id)
    if hit.showsHover: fill(br, hoverColor())
    if hit.down: sunken(br)
    if i == best: box(br, th.frame)                 # the current one, framed
    let ty = br.y + (br.h - FontH) div 2
    text(br.x + pad, ty, it.glyph, th.text)
    text(br.x + pad + textWidth(it.glyph) + dp(4), ty, it.label, th.text)
    if hit.clicked: result.picked = it.id
    if it.label.len > 0: tooltip(it.id)
    if dragging("files") and not it.id.startsWith("::") or it.id == "::trash":
      case dropTarget(br, "files")
      of dsOver: dropHighlight(br)
      of dsDropped: result.drop = takeDrop(it.id)
      else: discard
  if accessOn: accessEnd()
  popClip()
  st.scrollX = off
  state(id) = st
  ui.lastId = id
  ui.lastRect = r

type FolderTreeEvent* = object
  ## What happened in a `folderTree` this frame.
  picked*: bool            ## the user picked a folder: `selected`
  drop*: FileDrop          ## files were dropped on a folder

const FavId = "::fav:"       # the tree ids of favorites

var springAt: tuple[path: string; since: int]
  ## A closed folder a drag rests on opens after a moment.

proc folderNode(path, label: string; pic: Icon; hidden: bool; ev: var FolderTreeEvent;
                id = "") =
  var open = tree.open.getOrDefault(path, false)
  if not tree.hasKids.hasKey(path):
    tree.hasKids[path] = try: hasSubFolders(path, hidden) except OSError: false
  let has = open or tree.hasKids[path]
  let shown = beginNode(label, open, pic = pic, id = (if id.len > 0: id else: path),
                        hasKids = has)
  # files dragged onto the folder
  let nr = nodeRect()
  if nr.w > 0 and dragging("files"):
    var ok = true
    for p in ui.drag.items:
      if p == path or path.startsWith(p & DirSep) or p.parentDir == path: ok = false
    if ok:
      case dropTarget(nr, "files")
      of dsOver:
        dropHighlight(nr)
        if not open and has:
          if springAt.path != path: springAt = (path, ui.now)
          elif ui.now - springAt.since > 800: open = true
          wakeIn(100)
      of dsDropped: ev.drop = FileDrop(paths: ui.drag.items, into: path, copy: dragCopies())
      else: discard
  if shown:
    if not tree.kids.hasKey(path):
      tree.kids[path] = try: subFolders(path, hidden) except OSError: @[]
      tree.kids[path].sort(proc (a, b: string): int =
        cmpNatural(a.extractFilename, b.extractFilename))
    let k = if retroIcons: max(16, ItemH - 1) else: min(ItemH - 3, FontH + 3)
    for sub in tree.kids[path]:
      folderNode(sub, sub.extractFilename, glyphIcon(retroOr(pxFolder, nfFolder), folderColor, k), hidden, ev)
  endNode()
  if open != tree.open.getOrDefault(path, false):
    tree.open[path] = open
    if not open:
      tree.kids.del path
      tree.hasKids.del path

proc folderTree*(selected: var string; favorites: openArray[string] = [];
                 showHidden = false; rows = -1;
                 extra: openArray[tuple[label, glyph, id: string]] = [];
                 padding = 0): FolderTreeEvent {.discardable.} =
  ## The places of the device (home, documents, storage, drives...) and
  ## `favorites`, each opening into its folders (read when opened). Files
  ## can be dragged onto its folders (a closed one opens when a drag rests
  ## on it). `picked` when the user picked a folder: `selected`. `extra`
  ## nodes come first (`("This device", nfDesktop, "::device")`); picking
  ## one sets `selected` to its id. `padding`: room inside its frame.
  # a folder that is both a place and a favorite is highlighted once: as
  # the place (favorites have ids of their own)
  let places = placeList()
  var picked = selected
  if not places.anyIt(it.path == selected):
    for f in favorites:
      if f == selected: picked = FavId & f
  let shownSel = picked
  beginTree(picked, rows = rows, padding = padding)
  let k = if retroIcons: max(16, ItemH - 1) else: min(ItemH - 3, FontH + 3)
  for (label, glyph, id) in extra:
    var no = false
    discard beginNode(tr(label), no, pic = glyphIcon(glyph, color(70, 110, 170), k), id = id,
                      hasKids = false)
    if id == "::trash" and dragging("files"):
      let nr = nodeRect()
      case dropTarget(nr, "files")
      of dsOver: dropHighlight(nr)
      of dsDropped: result.drop = FileDrop(paths: ui.drag.items, into: "::trash")
      else: discard
    endNode()
  if favorites.len > 0:
    var favOpen = tree.open.getOrDefault("::favorites", true)
    if beginNode("Favorites", favOpen, pic = glyphIcon(retroOr(pxStar, nfStar), color(230, 170, 0), k),
                 id = "::favorites", hasKids = true):
      for f in favorites:
        folderNode(f, f.extractFilename, glyphIcon(retroOr(pxFolderStar, nfFolderStar), color(230, 170, 0), k),
                   showHidden, result, id = FavId & f)
    endNode()
    tree.open["::favorites"] = favOpen
  for (name, path) in places:
    folderNode(path, tr(name), glyphIcon(placeGlyph(name), color(70, 110, 170), k),
               showHidden, result)
  endTree()
  if picked != shownSel:
    if picked.startsWith(FavId): picked = picked[FavId.len .. ^1]
    var special = false
    for e in extra:
      if e.id == picked: special = true
    if picked != selected and (special or not picked.startsWith("::")):
      selected = picked
      result.picked = true

# ---- the path bar --------------------------------------------------------------------------

type
  PathBarEvent* = object
    ## What happened in a `pathBar` this frame.
    go*: string            ## a folder to show ("" none)
    drop*: FileDrop        ## files were dropped on one of the folders
    error*: string         ## a path typed that is not there
  PathBarState = ref object
    editing: bool
    buf: string
    suggestFor: string
    suggestions: seq[string]
    takeFocus: bool
    menuFor: int                 # the folder whose subfolders drop down (-1: the hidden ones)
    menuItems: seq[string]

var pathBars: Table[string, PathBarState]

proc pathParts(path: string): seq[tuple[name, path: string]] =
  var p = path
  while p.len > 0:
    let name = p.extractFilename
    let shown = if name.len == 0: p else: name
    result.insert((shown, p), 0)
    let up = p.parentDir
    if up.len == 0 or up == p: break
    p = up

proc pathBar*(path: string; key = ""; editNow = false; w = 0): PathBarEvent =
  ## The folder `path` as a row of its folders, as in Windows Explorer:
  ## click one to go there, click the arrow after it for a menu of the
  ## folders in it, "<<" for the folders that do not fit, drop files on one
  ## to move them there (`ev.go` / `ev.drop`); a click on the empty part, or
  ## `editNow` (F4, Alt+D, Ctrl+L), turns it into a box to type a path in,
  ## with the folders that match suggested. `key` tells several apart.
  var st = pathBars.getOrDefault(key, nil)
  if st == nil:
    st = PathBarState()
    pathBars[key] = st
  if editNow:
    st.takeFocus = true
    if not st.editing:
      st.editing = true
      st.buf = path
  if st.editing:
    # the folders that go on from what is typed
    let parent = if st.buf.endsWith(DirSep) or st.buf.endsWith('/'): st.buf
                 else: st.buf.parentDir
    if parent != st.suggestFor:
      st.suggestFor = parent
      st.suggestions = try: subFolders(parent) except OSError: @[]
    var shown: seq[string]
    let part = if parent == st.buf: "" else: st.buf.extractFilename.toLowerAscii
    for f in st.suggestions:
      if part.len == 0 or f.extractFilename.toLowerAscii.startsWith(part): shown.add f
      if shown.len >= 50: break
    let focusNow = st.takeFocus
    if focusNow: focusNext()         # the box below takes the keyboard
    st.takeFocus = false
    let changed = comboEdit(st.buf, shown, w = (if w > 0: w else: available()))
    let editId = ui.lastId
    let r = ui.lastRect
    if focusNow:                     # all of the path selected: typing replaces it
      var es = state(editId)
      es.anchor = 0
      es.caret = st.buf.len
      state(editId) = es
    if ui.focus == editId and canInput():
      ui.takesEnter = true                # (Enter goes there: #9)
      # Enter on what is typed, or on a suggestion picked with Down
      if keyHit(KeyEnter) or (changed and ui.key == KeyEnter):
        let p = st.buf.strip.expandTilde
        st.editing = false
        if vIsDir(p) or dirExists(p): result.go = cleanPath(p)
        elif vExists(p): result.go = cleanPath(p.parentDir)
        else: result.error = "There is no folder " & p & "."
      elif keyHit(KeyEsc): st.editing = false
    elif ui.focus != editId and ui.focus != 0 and not focusNow:
      st.editing = false             # clicked somewhere else
    elif ui.pressed and not mouseIn(r) and not mouseIn(ui.overlay): st.editing = false
    return
  let parts = pathParts(path)
  let r = place(if w > 0: w else: 0, EditH, fill = w <= 0)
  let id = idOf("pathbar:" & key)
  fill(r, th.field)
  fieldFrame(r)
  let menuKey = "pathbar-menu:" & key
  let sep = nfChevronRight
  let pad = if fingers(): dp(8) else: dp(4)
  let sepW = textWidth(sep) + 2 * (if fingers(): dp(6) else: dp(3))
  var widths: seq[int]
  # (a short name, as "/", still as wide as a finger)
  for p in parts: widths.add max(textWidth(p.name, true) + 2 * pad, if fingers(): dp(32) else: 0)
  var first = 0
  var total = 0
  let lead = textWidth(retroOr(pxFolderOpen, nfFolderOpen)) + dp(8)
  for i in countdown(parts.high, 0):
    total += widths[i] + sepW
    if total > r.w - lead - dp(40) - textWidth("<<") - 2 * pad - sepW:
      first = i + 1
      break
  first = min(first, max(0, parts.high))
  pushClip(inset(r, 1))
  text(r.x + dp(4), r.y + (r.h - FontH) div 2, retroOr(pxFolderOpen, nfFolderOpen), folderColor)
  var x = r.x + lead
  let ty = r.y + (r.h - FontH) div 2
  proc face(h: Hit; br: Rect; open = false) =
    if h.showsHover or h.down or open:
      fill(br, th.face)
      if h.down or open: sunken(br) else: raised(br, 1)
  # the folders that do not fit: "<<" drops them down (as Windows does)
  if accessOn: accessBegin(arToolBar, "", r, takesLabel = true)
  if first > 0:
    let br = rect(x, r.y + 2, textWidth("<<") + 2 * pad, r.h - 4)
    let h = interact(id + 99, br, focusable = false)
    if accessOn: accessNode(arButton, "Folders above", id = id + 99, r = br, states = {asExpandable})
    let open = popupMenuOpen(menuKey) and st.menuFor == -1
    face(h, br, open)
    text(br.x + pad, ty, "<<", th.fieldText, true)
    if h.clicked:
      st.menuFor = -1
      st.menuItems.setLen(0)
      for i in countdown(first - 1, 0): st.menuItems.add parts[i].path
      openPopupMenu(menuKey, br.x, br.y + br.h + 1)
    x += br.w
  for i in first .. parts.high:
    # the folder: a click goes there
    let br = rect(x, r.y + 2, widths[i], r.h - 4)
    let h = interact(id + uint32(i + 1), br, focusable = false)
    let lastOne = i == parts.high
    if accessOn:
      accessNode(arButton, parts[i].name, id = id + uint32(i + 1), r = br,
                 states = (if lastOne: {asSelected} else: {}), help = parts[i].path)
    face(h, br)
    if dragging("files"):
      var ok = true
      for p in ui.drag.items:
        if p == parts[i].path or parts[i].path.startsWith(p & DirSep) or
           p.parentDir == parts[i].path: ok = false
      if ok:
        case dropTarget(br, "files")
        of dsOver: dropHighlight(br)
        of dsDropped:
          result.drop = FileDrop(paths: ui.drag.items, into: parts[i].path,
                                 copy: dragCopies())
        else: discard
    text(br.x + (br.w - textWidth(parts[i].name, true)) div 2, ty, parts[i].name, th.fieldText, lastOne)
    if h.clicked and not lastOne: result.go = parts[i].path
    x += br.w
    # the arrow after it: its subfolders drop down
    let ar = rect(x, r.y + 2, sepW, r.h - 4)
    let ah = interact(id + uint32(1000 + i), ar, focusable = false)
    let open = popupMenuOpen(menuKey) and st.menuFor == i
    if accessOn:
      accessNode(arButton, "Folders in " & parts[i].name, id = id + uint32(1000 + i), r = ar,
                 states = {asExpandable} + (if open: {asExpanded} else: {}))
    face(ah, ar, open)
    text(ar.x + (ar.w - textWidth(sep)) div 2, ty,
         if open: nfChevronDown else: sep, if ah.showsHover or open: th.text else: th.gray)
    if ah.clicked:
      st.menuFor = i
      st.menuItems = subFolders(parts[i].path)
      openPopupMenu(menuKey, ar.x, ar.y + ar.h + 1)
    x += ar.w
  popClip()
  # a click on the empty part: type a path (after the parts took theirs)
  let hit = interact(id, r, focusable = false)
  if accessOn:
    accessNode(arButton, "Type a path", id = id, r = rect(x, r.y, max(0, r.x + r.w - x), r.h))
    accessEnd()
  if accessPressed == id: ui.mx = r.x + r.w - 1      # (pressed by a screen reader: the empty part)
  if hit.clicked and ui.mx > x:
    st.editing = true
    st.takeFocus = true
    st.buf = path
    ui.redraw = true
  # the drop-down of subfolders (or of the folders that do not fit)
  popupMenu(menuKey):
    let most = max(3, (ui.h - r.y - r.h) div max(1, MenuH) - 2)
    if st.menuItems.len == 0: discard menuItem("(no folders)", enabled = false)
    for k, p in st.menuItems:
      if k >= most:
        if menuItem("More...") and st.menuFor >= 0: result.go = parts[st.menuFor].path
        break
      let name = (if st.menuFor == -1 and p == "/": "/" else: p.extractFilename)
      if menuItem(retroOr(pxFolder, nfFolder) & " " & name.replace("&", "&&")):
        result.go = p
  ui.lastId = id
  ui.lastRect = r

# ---- texts and hex of any size -----------------------------------------------------------------

proc textFileView*(t: TextFile; sel: var int; numbers = true; height = -1;
                   w = 0): LineViewEvent {.discardable.} =
  ## The lines of a `TextFile` (any size): its lines are counted a few
  ## milliseconds a frame while the first ones are shown already.
  if t == nil: return
  t.index(6)
  if not t.done: wakeIn(1)
  lineView(t.lineCount, proc (i: int): string = t.line(i), sel, height, w,
           numbers = numbers)

proc hexFileView*(h: HexFile; sel: var int; height = -1; w = 0): LineViewEvent {.discardable.} =
  ## Any file as hex dump lines (read as they are shown).
  if h == nil: return
  lineView(h.lineCount, proc (i: int): string = h.line(i), sel, height, w)

proc textFileStatus*(t: TextFile): string =
  ## "12,345 lines, 1.2 MB", or "counting lines... 40%" while it counts.
  if t == nil: ""
  elif t.done: countText(t.lineCount, "line") & tr(", ") & sizeText(t.size)
  else: tr("counting lines... ") & $int(t.progress * 100) & "%"

# ---- dialogs ----------------------------------------------------------------------------------

proc durationText*(seconds: int): string =
  ## 75 -> "1 min 15 s", 4000 -> "1 h 7 min".
  if seconds < 60: $seconds & tr(" s")
  elif seconds < 3600: $(seconds div 60) & tr(" min ") & $(seconds mod 60) & tr(" s")
  else: $(seconds div 3600) & tr(" h ") & $(seconds mod 3600 div 60) & tr(" min")

type JobBoxes = ref object
  ## What the dialogs of a running job are bound to: kept on the heap, so
  ## their ids stay the same from frame to frame (a local variable's address
  ## need not).
  ask, box, forAll: bool
var jobBoxes: Table[pointer, JobBoxes]

proc runJobDialog*(job: FileJob; title: string): bool {.discardable.} =
  ## Runs `job` a slice a frame with a progress box (Cancel stops it) and,
  ## when a name is taken, asks "Replace / Keep both / Skip" (for all the
  ## others too if wanted). True once the job is over (done or cancelled).
  if job == nil: return false
  let key = cast[pointer](job)
  var d = jobBoxes.getOrDefault(key, nil)
  if d == nil:
    d = JobBoxes()
    jobBoxes[key] = d
  if job.state == jsRunning:
    job.run(14)
    wakeIn(1)
  case job.state
  of jsAsking:
    d.ask = true
    dialog(d.ask, "Name taken", 420):
      row:
        icon(retroOr(pxWarning, nfWarning), color(220, 160, 0), 2.0)
        col:
          paragraph "There is already an item named \"" & job.conflict &
                    "\" in the folder " & job.dest.extractFilename & "."
      space()
      checkbox("Do this for &all the others", d.forAll)
      row:
        spring()
        if button("&Replace", isDefault = true): job.resolve(cfReplace, d.forAll)
        if button("&Keep both"): job.resolve(cfKeepBoth, d.forAll)
        if button("&Skip"): job.resolve(cfSkip, d.forAll)
        if button("Cancel"): job.cancel()
    if not d.ask: job.cancel()
  of jsRunning:
    d.box = true
    var msg = tr(title) & " " & $job.doneItems & tr(" of ") & $max(job.totalItems, job.doneItems) &
              tr(" items")
    if job.kind in {jkCopy, jkZip, jkUnzip}:
      msg.add " (" & sizeText(job.doneBytes) & tr(" of ") & sizeText(job.totalBytes) & ")"
      let bps = job.bytesPerSecond
      if bps > 0:
        msg.add "\n" & sizeText(int64(bps)) & tr("/s")
        let left = job.secondsLeft
        if left >= 0: msg.add tr(", about ") & durationText(left) & tr(" left")
    if progressBox(d.box, title, msg, job.progressOf, job.current.extractFilename):
      job.cancel()
  else: discard
  if job.state in {jsDone, jsCancelled}:
    jobBoxes.del key
    result = true

proc jobSummary*(job: FileJob): string =
  ## "Copied 12 items", or what went wrong.
  if job.errors.len > 0:
    return countText(job.errors.len, "item") & tr(" could not be done:") & "\n" &
           job.errors[0 ..< min(6, job.errors.len)].join("\n")
  if job.state == jsCancelled: return tr("Cancelled.")
  let what = case job.kind
    of jkCopy: "Copied"
    of jkMove: "Moved"
    of jkDelete: "Deleted"
    of jkZip: "Compressed"
    of jkUnzip: "Extracted"
    of jkMeasure: "Measured"
    of jkTrash: "Moved to the trash:"
  tr(what) & " " & countText(job.doneItems, "item")

var props: tuple[items: seq[FileItem]; job: FileJob; dirs: int]

proc propertiesDialog*(open: var bool; items: openArray[FileItem]): bool {.discardable.} =
  ## The properties of `items` while `open`: location, size (folders are
  ## measured while it is open), what they contain, dates, permissions,
  ## where a link goes. True the frame it closes.
  if not open:
    if props.job != nil:
      props.job.cancel()
      props.job = nil
      props.items.setLen(0)
    return false
  var same = props.items.len == items.len
  if same:
    for i in 0 ..< items.len:
      if items[i].path != props.items[i].path: same = false
  if not same:
    props.items = @items
    if props.job != nil: props.job.cancel()
    var paths: seq[string]
    props.dirs = 0
    for f in items:
      paths.add f.path
      if f.isDir: inc props.dirs
    props.job = if paths.len > 0: newJob(jkMeasure, paths) else: nil
  if props.job != nil and props.job.state == jsRunning:
    props.job.run(10)
    wakeIn(1)
  let n = props.items.len
  if n == 0:
    open = false
    return true
  let f = props.items[0]
  dialog(open, "Properties", 420):
    row:
      image(fileIcon(f, dp(40)))
      col:
        label(if n > 1: countText(n, "item") else: f.name, bold = true)
        label(if n > 1: "Several kinds" else: kindText(f), color = th.gray)
    separator()
    form(0):
      field "Location:": label f.path.parentDir
      if props.job != nil:
        let busy = props.job.state == jsRunning
        field "Size:":
          label sizeText(props.job.totalBytes) & " (" &
                insertSep($props.job.totalBytes, ',') & " bytes)" &
                (if busy: "..." else: "")
        if f.isDir or n > 1:
          field "Contains:":
            label countText(props.job.files, "file") & ", " &
                  countText(max(0, props.job.folders - props.dirs), "folder")
      if n == 1:
        field "Modified:": label dateText(f.modified)
        let perms = permissionsText(f.path)
        if perms.len > 0:
          field "Permissions:": label perms
        if f.isLink:
          field "Link to:": label((let t = linkTarget(f.path); if t.len > 0: t else: "?"))
    row:
      spring()
      if button("OK", isDefault = true): open = false
  if not open:
    if props.job != nil: props.job.cancel()
    props.job = nil
    props.items.setLen(0)
    result = true

var picker: tuple[model: FolderModel; name: string; msg: string; opened: bool;
                  pattern: int; focusName: bool; key: string]

proc picturesDir*(): string =
  ## Where pictures are kept: the phone's Pictures folder (with the access
  ## to all files, `storageAccess`; else the app's own folder), the user's
  ## Pictures on a desktop (else the home folder).
  if platformName() == "android":
    if storageAccess():
      for d in ["/storage/emulated/0/Pictures", "/storage/emulated/0/DCIM", "/storage/emulated/0"]:
        if dirExists(d): return d
    return dataDir("")
  if platformName() == "ios": return dataDir("")
  for name in ["Pictures", "Images"]:
    let d = getHomeDir() / name
    if dirExists(d): return d
  getHomeDir()

var storageAsk: tuple[open: bool; app, why: string; then: proc ()]

proc askStorage*(app, why: string; then: proc () = nil): bool =
  ## True when the user's files can be used now (always, but on Android
  ## without "All files access"). Else opens `storageDialog`, which asks
  ## for it and explains `why`; `then` runs when the user goes on without
  ## it (to work in the app's own folder).
  if platformName() != "android" or storageAccess(): return true
  storageAsk = (true, app, why, then)
  false

proc storageDialog*() =
  ## The dialog of `askStorage` (draw it every frame, with the others).
  if not storageAsk.open: return
  dialog(storageAsk.open, "Access to your files", 460):
    paragraph(storageAsk.why)
    paragraph("Android asks once: turn on \"Allow access to manage all files\" for " & storageAsk.app &
              ", then come back.", color = th.gray)
    row:
      spring()
      if button("&Allow...", isDefault = true):
        requestStorageAccess()
        storageAsk.open = false
      if button("&Not Now"):
        storageAsk.open = false
        if storageAsk.then != nil: storageAsk.then()

proc filePicker*(open: var bool; path: var string; mode = fmOpen;
                 patterns: openArray[string] = []; title = ""; preview = true): bool =
  ## A modern Open / Save dialog while `open` (the whole screen on a
  ## phone): places, a path bar, the folder as a list (listed in the
  ## background, folders first, natural order), and for saving a name. True
  ## once, with `path` set, when the user picks a file. `patterns` limits
  ## the files shown (`["*.png", "*.jpg"]`). `fmFolder` picks a folder
  ## instead: only folders are shown, and Choose takes the one selected (or
  ## the one open). With `preview` (opening) the file picked -- or the one
  ## the mouse rests on -- is shown beside the list (under it on a phone):
  ## its picture or the start of its text, its size and dates.
  # (a program may have several pickers -- Open, Save As, Place -- that
  # share this state: the one open keeps it)
  let key = $mode & ":" & title
  when defined(wasm):
    # (a web page: the browser's file chooser; saving through /downloads)
    if mode != fmFolder: return webFileDialog(open, path, mode, patterns, key)
  if not open:
    if picker.key == key: picker.opened = false
    return false
  if not picker.opened or picker.key != key:
    picker.key = key
    picker.opened = true
    picker.msg = ""
    picker.focusName = mode == fmSave and not ui.touch  # (saving: the name is typed first)
    let start = if path.len > 0 and dirExists(path): path
                elif path.len > 0 and path.parentDir.len > 0 and dirExists(path.parentDir):
                  path.parentDir
                elif platformName() in ["android", "ios"]: dataDir("")
                else: getHomeDir()
    picker.name = if path.len > 0 and not dirExists(path): path.extractFilename else: ""
    if picker.model == nil: picker.model = newFolderModel()
    picker.model.patterns = if mode == fmFolder: @["\0"] else: @patterns   # (folders only)
    if mode == fmFolder: picker.name = ""
    picker.model.open(start, picker.name)
    # what was selected the last time is not a selection now (on a phone
    # a tap would only add to it instead of picking)
    for x in picker.model.marked.mitems: x = false
  let m = picker.model
  let ttl = if title.len > 0: title elif mode == fmOpen: "Open" elif mode == fmFolder: "Choose a Folder"
            else: "Save As"
  let showPreview = preview and mode == fmOpen
  let width = if isCompact(): ui.w
              elif showPreview: min(ui.w - dp(40), dp(860))
              else: min(ui.w - dp(40), dp(640))
  template accept(f: FileItem) =
    if f.isDir:
      m.open(f.path)
    elif mode == fmOpen and not fileExists(f.path):
      picker.msg = f.name & ": file not found."
    else:
      path = f.path
      open = false
      result = true
  if beginDialog(open, ttl, width):
    row:
      if toolButton(retroOr(pxUp, nfArrowUp), "Up one folder", size = 1.2, enabled = m.canGoUp): m.goUp()
      if toolButton(retroOr(pxHome, nfHome), "Home", size = 1.2):
        m.open(if platformName() in ["android", "ios"]: dataDir("") else: getHomeDir())
      var parts: seq[string]
      var p = m.dir
      while p.len > 0:
        parts.insert(if p.extractFilename.len > 0: p.extractFilename else: p, 0)
        let up = p.parentDir
        if up == p or up.len == 0: break
        p = up
      let hit = breadcrumb(parts)
      if hit >= 0:
        var target = m.dir
        for _ in 0 ..< parts.len - 1 - hit: target = target.parentDir
        m.open(target)
    let compactPv = showPreview and isCompact()
    let listH = if isCompact(): max(dp(160), ui.h - dp(250) - (if compactPv: dp(120) else: 0))
                else: dp(330)
    var ev: FileListEvent
    if showPreview and not isCompact():
      # (the list, and beside it what is picked: seen before it is opened)
      row([-1, 250]):
        col:
          ev = fileList(m, fvDetails, height = listH, tapActivates = ui.touch)
        col:
          discard filePreview(m, buttons = false, height = listH)
    else:
      ev = fileList(m, fvDetails, height = listH, tapActivates = ui.touch)
      if compactPv and m.current.name.len > 0 and not m.current.isDir:
        discard filePreview(m, buttons = false, height = dp(112), followHover = false)
    if ev.selChanged:
      let f = m.current
      if not f.isDir: picker.name = f.name
    if ev.activated: accept(ev.item)
    if mode == fmFolder:
      let f = m.current
      label("Folder: " & ellipsize(if f.isDir and f.name.len > 0: f.path else: m.dir, available() - dp(60)),
            color = th.gray)
      if picker.msg.len > 0: label picker.msg, color = color(192, 0, 0)
      case buttonRow(["Choose", "Cancel"])
      of 1:
        path = if f.isDir and f.name.len > 0: f.path else: m.dir
        open = false
        result = true
      of 2: open = false
      else: discard
      endDialog()
      return
    if mode == fmSave or not ui.touch:
      row:
        label "File &name:"
        if picker.focusName and canInput():
          focusFirstText()
          picker.focusName = false
        edit picker.name
    if picker.msg.len > 0: label picker.msg, color = color(192, 0, 0)
    case buttonRow([if mode == fmOpen: "Open" else: "Save", "Cancel"])
    of 1:
      let n = picker.name.strip
      if n.len > 0:
        let full = if isAbsolute(n): n else: m.dir / n
        if dirExists(full): m.open(full)
        else: accept(infoOf(full))
      elif m.current.name.len > 0: accept(m.current)
    of 2: open = false
    else: discard
    endDialog()

# ---- this device: places and drives ------------------------------------------------------

proc placeTile(name, path, glyph: string; tint: Color): bool =
  ## A place as a tile: its icon, its name, and how full its disk is.
  let sp = diskSpaceCached(path)
  let h = 2 * FontH + dp(26)
  let r = place(0, h, fill = true)
  let id = idOf("place:" & path)
  var hit = interact(id, r)
  spaceKey(id, hit)
  fill(r, if hit.showsHover: hoverColor() else: th.field)
  box(r, if hit.focused: th.select else: th.face)
  let st = style(size = 2.0)
  text(r.x + dp(10), r.y + (h - lineHeight(st)) div 2, glyph, tint, st)
  let x = r.x + dp(14) + textWidth(glyph, st)
  let w = r.x + r.w - dp(10) - x
  text(x, r.y + dp(6), ellipsize(name, w), th.fieldText, true)
  if sp.total > 0:
    let used = sp.total - sp.free
    pushFrame(rect(x, r.y + dp(8) + FontH, w, 0))
    usageBar(used, sp.total, w = w)
    discard popFrame()
    text(x, r.y + dp(14) + FontH + dp(8), ellipsize(sizeText(sp.free) & " free of " &
         sizeText(sp.total), w), th.gray)
  if dropTarget(r, "files") == dsOver: dropHighlight(r)
  if accessOn:
    accessNode(arButton, name, id = id, r = r,
               help = (if sp.total > 0: sizeText(sp.free) & " free of " & sizeText(sp.total) else: path))
  ui.lastRect = r
  if hit.focused: ui.takesEnter = true
  hit.clicked or (hit.focused and keyHit(KeyEnter))

proc placesView*(favorites: openArray[string] = []; height = -1; key = ""): string =
  ## "This device": the places (home, documents, storage, drives) and the
  ## `favorites` as tiles with how full their disks are; the folder
  ## clicked, "" if none.
  beginScroll(if height < 0: remainingH() else: height, "places" & key)
  heading("Places", 3)
  adaptive(dp(240)):
    for (name, path) in placeList():
      if placeTile(name, path, placeGlyph(name), color(70, 110, 170)): result = path
  if favorites.len > 0:
    heading("Favorites", 3)
    adaptive(dp(240)):
      for f in favorites:
        if placeTile(f.extractFilename, f, retroOr(pxFolderStar, nfFolderStar), color(230, 170, 0)): result = f
  endScroll()

# ---- the trash ---------------------------------------------------------------------------

type
  TrashList* = ref object
    ## What is in the trash, as a list (`trashList`).
    items*: seq[TrashItem]   ## what is in the trash (`reload` reads it again)
    sel*: int                ## the current row
    marked*: seq[bool]       ## the selected rows
    cols: seq[Column]
    loaded: bool
  TrashEvent* = object
    ## What `trashList` did this frame.
    changed*: bool         ## items were restored or deleted (folders changed)
    restored*: seq[string] ## where restored items went back to
    error*: string         ## what went wrong ("" when nothing did)

proc newTrashList*(): TrashList =
  ## An empty trash list (fill it with `reload`).
  TrashList(cols: @[column("Name", 220), column("Original location", 260),
                    column("Deleted", 140), column("Size", 80, alRight)])

proc reload*(t: TrashList) =
  ## Reads the trash again.
  t.items = trashItems()
  t.marked = newSeq[bool](t.items.len)
  t.sel = clamp(t.sel, 0, max(0, t.items.high))
  t.loaded = true

proc trashList*(t: TrashList; height = -1): TrashEvent =
  ## The trash: its items (name, where they were, when deleted, size) with
  ## Restore, Delete forever and Empty the trash. Files dropped on it go to
  ## the trash (reported in `changed`).
  if not t.loaded: t.reload()
  var picked: seq[int]
  for i, m in t.marked:
    if m: picked.add i
  if picked.len == 0 and t.sel in 0 ..< t.items.len: picked.add t.sel
  var errors: seq[string]
  row:
    if button(retroOr(pxUndo, nfUndo) & " &Restore", enabled = picked.len > 0):
      for i in picked:
        let err = restore(t.items[i])
        if err.len > 0: errors.add err
        else: result.restored.add t.items[i].original
      result.changed = true
    if button(retroOr(pxDelete, nfTimes) & " &Delete forever", enabled = picked.len > 0):
      for i in picked:
        let err = deleteForever(t.items[i])
        if err.len > 0: errors.add err
      result.changed = true
    if button(retroOr(pxTrash, nfTrash) & " &Empty the trash", enabled = t.items.len > 0):
      let n = emptyTrash()
      if n > 0: errors.add countText(n, "item") & " could not be deleted."
      result.changed = true
    spring()
    label countText(t.items.len, "item"), color = th.gray
  if t.items.len == 0:
    emptyState(retroOr(pxTrash, nfTrash), "The trash is empty.", if height < 0: remainingH() else: height)
  else:
    let small = min(ItemH - 2, FontH + 8)
    discard grid(t.cols, t.items.len, proc (r, c: int): string =
      let it = addr t.items[r]
      case c
      of 0: it.original.extractFilename
      of 1: it.original.parentDir
      of 2: dateText(it.deleted)
      else: (if it.isDir: "" else: sizeText(it.size))
    , t.sel, t.marked, height = -1,
      icon = proc (r: int): Icon =
        fileIcon(FileItem(name: t.items[r].original.extractFilename,
                          isDir: t.items[r].isDir), small),
      typeToEdit = false)
  # files dragged here go to the trash
  if dragging("files"):
    case dropTarget(ui.lastRect, "files")
    of dsOver: dropHighlight(ui.lastRect)
    of dsDropped:
      for p in ui.drag.items:
        let err = moveToTrash(p)
        if err.len > 0: errors.add err
      result.changed = true
    else: discard
  if result.changed: t.reload()
  result.error = errors.join("\n")

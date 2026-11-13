## Retro Files -- a full file manager in the style of the Windows 3.1 File
## Manager, with what Explorer has today: tabs, two panes side by side, an
## address bar you can type in, a folder tree, details, tiles and icons of
## any size with picture thumbnails, a preview pane that follows the
## mouse, drag and drop, multi-select with selection rectangles, cut /
## copy / paste in the background with progress, speed and "Replace or
## keep both?", the trash (restore, empty), undo, rename in place, new
## folders and files, zip and unzip, search (also in all subfolders),
## favorites, "This device" with how full each disk is, properties with
## the size of whole folders, settings, and viewers for text of any size
## (with editing), Markdown, pictures, zip archives and any file as hex.
##
## Version 3: thumbnails of almost every picture there is (camera raw
## photos, Photoshop and Retro Photo documents, SVG, JPEG XL, WebP, TIFF,
## EXR, HEIC/AVIF) kept on disk so a folder opens at once the second time;
## caches that follow the device's memory and let go when it runs short or
## the app goes to the background; an Arabic interface (mirrored); Folder
## Sizes; Copy To / Move To; Share; Report a Problem; the folders in
## windows of their own (MDI, as the 3.1 File Manager had them) instead of
## tabs, each one can be kept on top.
##
## Almost all of it is the toolkit's (`retroui/filewidgets`, `retroui/files`):
## this file is the app -- its menus, its commands and its viewer.
##
## One source for desktops, tablets and phones:
##
##   nim c -r examples/filemanager.nim                       (desktop)
##   retroapk examples/filemanager.nim --storage --install   (Android)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, times, algorithm, monotimes]
import retroui, retroui/[pdfview, morepictures, lang_ar]
import filemanager/lang_ar as filesLang

const TermuxHome = "/data/data/com.termux/files/home"

const
  AppTitle = "Retro Files"
  AppId = "RetroFiles"
  AppVersion = "3.3.10"

type
  ViewerKind = enum vkNone, vkText, vkMarkdown, vkImage, vkHex, vkZip, vkPdf, vkVideo, vkAudio
  NameAction = enum naNone, naNewFolder, naNewFile, naRename, naZip
  StartIn = enum siLast, siHome, siStorage
  Special = enum spFolder, spDevice, spTrash
  Tab = ref object
    m: FolderModel
    special: Special
    win: MdiWindow                 # (View > Folders in Windows) its window
    searchOpen: bool               # (a narrow window) its search box shown, under the address bar
  Pane = object
    tabs: seq[Tab]
    at: int
    query: string                  # the search box
    deep: bool                     # ... through the subfolders
    editPath: bool                 # the path bar becomes a text box
    findNow: bool                  # the search box takes the keyboard
    menuTab: int                   # the tab whose menu is open

const
  viewSteps = [(fvDetails, 0, "&Details"), (fvTiles, 48, "&Tiles"),
               (fvIcons, 48, "&Medium icons"), (fvIcons, 72, "&Large icons"),
               (fvIcons, 128, "E&xtra large icons"), (fvIcons, 200, "&Huge icons"),
               (fvSmallIcons, 16, "&Small icons"), (fvColumns, 0, "C&olumns"),
               (fvList, 16, "L&ist")]
  viewOrder = [0, 7, 1, 2, 3, 4, 5, 6, 8]   ## (the order of the Views menu)
  columnsStep = 7
  zoomSteps = 5                    ## (Ctrl+wheel steps through the views up to here)
  deviceId = "::device"
  trashId = "::trash"

var
  panes: array[2, Pane]
  active = 0
  trashBox = newTrashList()
  # settings
  prefs: Settings
  viewStep = 3
  lastIconStep = 3                 # (the icons button of the address bar goes back to it)
  sortKey = byName
  sortDesc = false
  showHidden = false
  showExt = true
  showTree = true
  showDrives = true                # the drive bar under the tool bar
  showToolbar = true               # View > Toolbars > Standard Buttons
  showStatus = true                # View > Status Bar
  webView = true                   # View > as Web Page: the folder and the selection described at the left
  webW = 190                       # (its width)
  showPreview = true
  followHover = true
  dual = false
  inWindows* = false               # the folders in windows of their own (MDI), not tabs
  winGrip = 2                      # ... their size grip: 0 none, 1 small, 2 medium, 3 large
  thumbsOn = true
  diskThumbs = true                # thumbnails kept on disk (retroui/thumbcache)
  diskThumbMB = 96                 # ... at most
  language* = 0                    # 0 English, 1 Arabic (mirrored)
  confirmDelete = true
  useTrash = true
  singleTap = true
  startIn = siLast
  treeW = 230
  previewW = 290
  previewH = 150
  dualAt = 0
  favorites: seq[string]
  selectMode = false
  # clipboard and jobs
  clipPaths: seq[string]
  clipCut = false
  job: FileJob
  jobTitle = ""
  # dialogs
  nameOpen = false
  nameAction = naNone
  nameText = ""
  nameTarget = ""
  askDelete = false
  askForever = false
  askEmptyTrash = false            # (the folder tree's menu on the Trash)
  propsOpen = false
  propsItems: seq[FileItem]
  settingsOpen* = false
  aboutOpen* = false
  keysOpen* = false
  errorOpen = false
  errorText = ""
  placesOpen = false
  treeSel = ""
  batchOpen = false                # Rename with several selected
  batchItems: seq[FileItem]
  batchPattern = "*"
  batchFind = ""
  batchReplace = ""
  batchStart = 1
  batchCase = 0
  matchOpen = false                # Edit > Select Matching
  pickOpen = false                 # Edit > Copy To Folder / Move To Folder
  pickMove = false
  pickPath = ""
  sizesOpen* = false               # Tools > Folder Sizes
  sizesDir = ""
  sizesRows: seq[tuple[item: FileItem; job: FileJob]]
  sizesLoose = 0'i64               # (the files of the folder itself)
  sizesSel = 0
  sizesCols = @[column("Name", 220), numberColumn("Size", 90), progressColumn("", 120),
                numberColumn("Files", 70)]
  thumbBytes = -1'i64              # (Settings: what the disk cache holds; -1: not measured)
  matchText = "*.jpg"
  slideOn = false                  # the picture viewer's slide show
  slideAt = 0
  # the viewer
  viewer = vkNone
  viewInfo: FileItem
  viewSrc: string          ## the file read: the file shown, or a copy of another app's
  viewText = ""                    # a small text being edited
  viewSaved = ""
  editing = false
  askSave = false
  bigText: TextFile
  hexFile: HexFile
  viewSel = 0
  viewPic: Bitmap
  viewPicFull = false
  viewPdf: PdfView                 # a PDF being read
  pdfPageNum = 1                   # (the page box)
  pdfFocus = false                 # (the pages take the keys once shown)
  viewTicket = 0
  viewFailed = false
  viewZoom = 0.0
  viewEntries: seq[ZipEntry]
  viewEntrySel = 0
  mdSource = false
  # house-keeping
  savedDir = ""
  pausedSaved = false
  accessCache = true
  accessAt = -100_000

# ---- tabs and panes ---------------------------------------------------------------------------

template tab: Tab = panes[active].tabs[panes[active].at]
template folder: FolderModel = tab.m
  ## The folder of the tab shown in the active pane: what the commands act on.

const FilesIconPng = staticRead("assets/filemanager-icon.png")   ## (the About box's icon)

proc twoPanes(): bool =
  ## Two panes are shown (asked for, and the window is wide enough).
  dual and not isCompact() and not inWindows and panes[1].tabs.len > 0

proc windowsShown(): bool =
  ## The folders are windows of their own (asked for; not on a phone).
  inWindows and not isCompact()

proc other(): FolderModel =
  ## The other pane's folder (two panes), else nil.
  if not twoPanes(): return nil
  let p = addr panes[1 - active]
  let t = p.tabs[p.at]
  if t.special == spFolder: t.m else: nil

proc configure(m: FolderModel) =
  m.sortBy = sortKey
  m.descending = sortDesc
  m.showHidden = showHidden
  m.showExtensions = showExt

proc newTab(where: string): Tab =
  result = Tab(m: newFolderModel(), win: MdiWindow(open: true, flush: true))
  configure(result.m)
  case where
  of deviceId: result.special = spDevice
  of trashId: result.special = spTrash
  else: result.m.open(if where.len > 0 and dirExists(where): where else: getHomeDir())

proc tabKey(t: Tab): string =
  case t.special
  of spDevice: deviceId
  of spTrash: trashId
  of spFolder: (if t.m.loading: t.m.loadingPath else: t.m.dir)

proc tabLabel(t: Tab): (string, string) =
  case t.special
  of spDevice: (pxComputer, tr("This device"))
  of spTrash: (pxTrash, tr("Trash"))
  of spFolder:
    let p = tabKey(t)
    let n = p.extractFilename
    (pxFolder, if n.len > 0: n else: p)

proc eachModel(body: proc (m: FolderModel)) =
  for p in panes.mitems:
    for t in p.tabs: body(t.m)

proc syncQuery(p: int) =
  let m = panes[p].tabs[panes[p].at].m
  panes[p].query = m.filter
  panes[p].deep = m.searching

proc addTab(p: int; where: string) =
  panes[p].tabs.add newTab(where)
  panes[p].at = panes[p].tabs.high
  active = p
  syncQuery(p)

proc closeTab(p: int; i: int) =
  if panes[p].tabs.len <= 1: return
  panes[p].tabs.delete(i)
  panes[p].at = clamp(if panes[p].at > i: panes[p].at - 1 else: panes[p].at, 0,
                      panes[p].tabs.high)
  syncQuery(p)

# ---- settings ----------------------------------------------------------------------------------

proc saveSettings() =
  prefs.put "viewstep", viewStep
  prefs.put "sort", ord(sortKey)
  prefs.put "desc", sortDesc
  prefs.put "hidden", showHidden
  prefs.put "extensions", showExt
  prefs.put "tree", showTree
  prefs.put "drives", showDrives
  prefs.put "toolbar", showToolbar
  prefs.put "statusbar", showStatus
  prefs.put "webview", webView
  prefs.put "webw", webW
  prefs.put "barlook", ord(toolbarLook)
  prefs.put "preview", showPreview
  prefs.put "followhover", followHover
  prefs.put "dual", dual
  prefs.put "windows", inWindows
  prefs.put "wingrip", winGrip
  prefs.put "thumbs", thumbsOn
  prefs.put "diskthumbs", diskThumbs
  prefs.put "thumbmb", diskThumbMB
  prefs.put "language", language
  prefs.put "confirm", confirmDelete
  prefs.put "trash", useTrash
  prefs.put "singletap", singleTap
  prefs.put "start", ord(startIn)
  prefs.put "treew", treeW
  prefs.put "previeww", previewW
  prefs.put "previewh", previewH
  prefs.put "dualat", dualAt
  prefs.put "favorites", favorites.join("\n")
  for p in 0 .. 1:
    var keys: seq[string]
    for t in panes[p].tabs: keys.add tabKey(t)
    prefs.put "tabs" & $p, keys.join("\n")
    prefs.put "tab" & $p, panes[p].at
  prefs.put "active", active
  prefs.put "dir", (if tab.special == spFolder: folder.dir else: "")
  storeAppearance(prefs)
  saveSettings(AppId, prefs)

proc loadSettings(): string =
  ## Reads the settings; returns the folder last shown.
  prefs = loadSettings(AppId)
  if prefs.len == 0:
    # Retro Files 1.2 kept its settings in settings.txt
    try:
      for line in lines(dataDir(AppId) / "settings.txt"):
        let k = line.find('=')
        if k <= 0: continue
        let (key, v) = (line[0 ..< k], line[k + 1 .. ^1])
        case key
        of "fav": favorites.add v
        of "split": prefs["treew"] = v
        of "striph": prefs["previewh"] = v
        of "theme": prefs["look.colors"] = v
        of "scale": prefs["look.size"] = v
        of "textscale": prefs["look.text"] = v
        of "pixelfont": discard            # (an old setting: the font is chosen in Settings)
        of "view": prefs["viewstep"] = (if v == "1": "3" else: "0")
        of "desc", "hidden", "tree", "preview", "thumbs", "confirm", "singletap":
          prefs[key] = $(v == "1")
        else: prefs[key] = v
    except IOError, OSError: discard
  if prefs.hasKey("view") and not prefs.hasKey("viewstep"):       # (1.3)
    prefs["viewstep"] = if prefs.get("view") == "1": "3" else: "0"
  viewStep = clamp(prefs.getInt("viewstep", 3), 0, viewSteps.high)
  sortKey = SortKey(clamp(prefs.getInt("sort", 0), 0, 3))
  sortDesc = prefs.getBool("desc")
  showHidden = prefs.getBool("hidden")
  showExt = prefs.getBool("extensions", true)
  showTree = prefs.getBool("tree", true)
  showDrives = prefs.getBool("drives", true)
  showToolbar = prefs.getBool("toolbar", true)
  showStatus = prefs.getBool("statusbar", true)
  webView = prefs.getBool("webview", true)
  webW = clamp(prefs.getInt("webw", 190), 120, 600)
  # (the tool bar's labels: under the icons, as Explorer 98 had them)
  setToolbarLook(ButtonLook(clamp(prefs.getInt("barlook", ord(blTextBelow)), 0, ord(ButtonLook.high))))
  showPreview = prefs.getBool("preview", true)
  followHover = prefs.getBool("followhover", true)
  dual = prefs.getBool("dual")
  inWindows = prefs.getBool("windows")
  winGrip = clamp(prefs.getInt("wingrip", 2), 0, 3)
  thumbsOn = prefs.getBool("thumbs", true)
  diskThumbs = prefs.getBool("diskthumbs", true)
  diskThumbMB = clamp(prefs.getInt("thumbmb", 96), 16, 2048)
  language = clamp(prefs.getInt("language", 0), 0, 1)
  confirmDelete = prefs.getBool("confirm", true)
  useTrash = prefs.getBool("trash", true)
  singleTap = prefs.getBool("singletap", true)
  startIn = StartIn(clamp(prefs.getInt("start", 0), 0, 2))
  treeW = clamp(prefs.getInt("treew", 230), 80, 900)
  previewW = clamp(prefs.getInt("previeww", 290), 120, 900)
  previewH = clamp(prefs.getInt("previewh", 150), 60, 900)
  dualAt = prefs.getInt("dualat", 0)
  for f in prefs.get("favorites").split('\n'):
    if f.len > 0 and f notin favorites: favorites.add f
  restoreAppearance(prefs)
  result = prefs.get("dir")

proc canSeeFiles(): bool =
  if ui.now - accessAt > 1000:
    accessCache = storageAccess()
    accessAt = ui.now
  accessCache

# ---- the folder --------------------------------------------------------------------------------

proc showError(msg: string) =
  errorText = msg
  errorOpen = true

proc go*(path: string) =
  ## Shows the folder `path` in the active tab (or "This device", "Trash").
  if path == deviceId or path == trashId:
    tab.special = if path == deviceId: spDevice else: spTrash
    if path == trashId: trashBox.reload()
    return
  if not (dirExists(path) or vIsDir(path) or needsDocAccess(path)):
    showError(tr("The folder ") & path & tr(" does not exist."))
    return
  tab.special = spFolder
  folder.open(path)
  panes[active].query = ""
  panes[active].deep = false

proc refreshAll() =
  ## Every tab lists its folder again (after files changed).
  forgetFolderTree()
  eachModel(proc (m: FolderModel) =
    if m.dir.len > 0: m.reload())
  trashBox.reload()

# ---- jobs --------------------------------------------------------------------------------------

var jobGuard*: proc (kind: JobKind; sources: seq[string]; dest: string): bool
  ## (the tests: a job is refused when it says no)

proc currentFolder*(): tuple[dir: string; loading: bool] =
  ## The folder shown in the active tab, and whether it is still being read.
  if tab.special != spFolder: ("", false) else: (folder.dir, folder.loading)

proc startJob(kind: JobKind; sources: seq[string]; dest, title: string) =
  if sources.len == 0: return
  if jobGuard != nil and not jobGuard(kind, sources, dest): return
  if job != nil:
    showError("Another job is running; wait for it to end.")
    return
  job = newJob(kind, sources, dest)
  jobTitle = title

proc dropFiles(d: FileDrop) =
  ## Files dragged somewhere: moved there (copied with Ctrl), or trashed.
  if not d.dropped or d.paths.len == 0: return
  if d.into == trashId: startJob(jkTrash, d.paths, "", "Moving to the trash")
  elif d.copy: startJob(jkCopy, d.paths, d.into, "Copying")
  else: startJob(jkMove, d.paths, d.into, "Moving")

proc paste() =
  if clipPaths.len == 0 or tab.special != spFolder: return
  if clipCut:
    startJob(jkMove, clipPaths, folder.dir, "Moving")
    clipPaths.setLen(0)
  else:
    startJob(jkCopy, clipPaths, folder.dir, "Copying")

proc pasteShortcut() =
  ## Edit > Paste Shortcut: a shortcut here to each item copied (a link;
  ## on Windows a ".url" Explorer opens too).
  if clipPaths.len == 0 or tab.special != spFolder: return
  let r = makeShortcuts(clipPaths, folder.dir)
  if r.made.len > 0:
    folder.selectAfterLoad(r.made)
    refreshAll()
  if r.error.len > 0: showError(tr("Some shortcuts could not be made:\n") & r.error)

proc toOther(move: bool) =
  ## Two panes: the selection copied (or moved) to the other pane's folder.
  let o = other()
  if o == nil or o.dir.len == 0 or tab.special != spFolder: return
  startJob(if move: jkMove else: jkCopy, folder.selectedPaths, o.dir,
           if move: "Moving" else: "Copying")

proc runJob() =
  ## The running job's progress (and questions); its results when it ends.
  if runJobDialog(job, jobTitle):
    let j = job
    job = nil
    remember(j)                                   # for Edit > Undo
    if j.created.len > 0 and j.kind in {jkCopy, jkMove, jkZip, jkUnzip}:
      # what was made is selected where it went (a drop may be on the other pane)
      let into = if j.kind == jkZip: j.dest.parentDir else: j.dest
      eachModel(proc (m: FolderModel) =
        if m.dir == into: m.selectAfterLoad(j.created))
    refreshAll()
    if j.errors.len > 0: showError(jobSummary(j))
    elif j.state == jsDone:
      toast(jobSummary(j), glyph = pxCheck, title = AppTitle)

proc undoLast() =
  if not canUndo(): return
  let label = undoLabel()
  let u = undo()
  refreshAll()
  if u.error.len > 0: showError(u.error)
  else: toast(label & tr(" -- done."), glyph = pxUndo)

# ---- names: new folder, new file, rename, zip ---------------------------------------------------

proc askName(action: NameAction; initial = ""; target = "") =
  nameAction = action
  nameText = initial
  nameTarget = target
  nameOpen = true

proc doName(name: string) =
  let name = name.strip
  var err = ""
  case nameAction
  of naNewFolder:
    err = folder.makeFolder(name)
    if err.len == 0: remember UndoStep(kind: ukCreate, paths: @[folder.dir / name],
                                       what: tr("New folder ") & name)
    forgetFolderTree()
  of naNewFile:
    err = folder.makeFile(name)
    if err.len == 0: remember UndoStep(kind: ukCreate, paths: @[folder.dir / name],
                                       what: tr("New file ") & name)
  of naRename:
    err = folder.rename(nameTarget, name)
    if err.len == 0:
      remember UndoStep(kind: ukRename, pairs: @[(nameTarget, nameTarget.parentDir / name)],
                        what: tr("Rename ") & nameTarget.extractFilename)
    forgetFolderTree()
  of naZip:
    err = validName(name)
    if err.len == 0:
      var zipName = name
      if not zipName.toLowerAscii.endsWith(".zip"): zipName.add ".zip"
      startJob(jkZip, folder.selectedPaths, folder.dir / uniqueName(folder.dir, zipName),
               "Compressing")
  of naNone: discard
  if err.len > 0: showError(err)

proc nameDialog() =
  if not nameOpen: return
  let (title, prompt) = case nameAction
    of naNewFolder: ("New Folder", "Name of the new folder:")
    of naNewFile: ("New File", "Name of the new file:")
    of naRename: ("Rename", "New name:")
    of naZip: ("Compress", "Name of the zip file:")
    of naNone: ("", "")
  if inputBox(nameOpen, title, prompt, nameText, width = 380) == 1:
    doName(nameText)

proc rename() =
  if tab.special != spFolder: return
  let list = folder.selectedItems
  if list.len > 1:
    # several: renamed together, by a pattern
    batchItems = list
    batchOpen = true
    return
  if list.len != 1: return
  if viewSteps[viewStep][0] == fvDetails and not folder.searching: folder.editName()
  else: askName(naRename, list[0].name, list[0].path)

proc zipSelected() =
  let list = folder.selectedItems
  if list.len == 0: return
  let base = if list.len == 1: list[0].name.changeFileExt("")
             else: folder.dir.extractFilename
  askName(naZip, base & ".zip")

proc unzipSelected() =
  var zips: seq[string]
  for f in folder.selectedItems:
    if extOf(f.name) == "zip": zips.add f.path
  if zips.len > 0: startJob(jkUnzip, zips, folder.dir, "Extracting")

proc showProperties() =
  ## The selection's properties (nothing selected: the folder's, as
  ## Explorer does).
  if tab.special != spFolder: return
  propsItems = folder.selectedItems
  if propsItems.len == 0 and folder.dir.len > 0: propsItems = @[infoOf(folder.dir)]
  propsOpen = propsItems.len > 0

proc deleteSelected(forever = false) =
  ## To the trash (Shift+Del: for good, after asking).
  if tab.special != spFolder or folder.selectedItems.len == 0: return
  if forever or not useTrash or isDocPath(folder.dir): askForever = true   # (no trash there)
  elif confirmDelete: askDelete = true
  else: startJob(jkTrash, folder.selectedPaths, "", "Moving to the trash")

proc copySel(cut: bool) =
  if tab.special != spFolder: return
  let p = folder.selectedPaths
  if p.len == 0: return
  clipPaths = p
  clipCut = cut
  toast((if cut: tr("Cut ") else: tr("Copied ")) & countText(p.len, "item") &
        tr(". Paste them in another folder."), glyph = if cut: pxCut else: pxCopy,
        title = tr("Clipboard"))

# ---- the viewer ----------------------------------------------------------------------------------

proc screenSize(): int = max(1024, max(ui.w, ui.h) * pxScale)

proc closeFiles() =
  if bigText != nil: bigText.close()
  if hexFile != nil: hexFile.close()
  bigText = nil
  hexFile = nil

proc askPicture(path: string; size: int) =
  ## Decodes the picture of the viewer on a worker thread.
  let ticket = pictureAsync(path, size, size, priority = 5,
    onDone = proc (r: var TaskResult) =
      if r.ticket != viewTicket or r.cancelled: return
      viewTicket = 0
      let b = toBitmap(move r)
      if b != nil: viewPic = b
      elif viewPic == nil: viewFailed = true)
  viewTicket = ticket

proc cacheDir(): string = dataDir(AppId) / "cache"
  ## Copies of other apps' documents being shown (emptied at the start).

proc stopMedia() =
  ## The PDF, the video or the sound shown before let go.
  if viewPdf != nil:
    closePdfView(viewPdf)
    viewPdf = nil
  if viewer in {vkVideo, vkAudio}: closeVideo("viewer")

proc dropBigCopy() =
  ## A big copy of another app's document (a video from a phone's
  ## provider) deleted once it is no longer shown: the cache keeps only
  ## small ones, to show them again at once.
  if viewSrc.len == 0 or not viewSrc.startsWith(cacheDir()): return
  if job != nil and viewSrc in job.sources: return
  try:
    if getFileSize(viewSrc) > 64 * 1024 * 1024: removeFile(viewSrc)
  except OSError: discard

var focusBeforeViewer: Id       # (the list that opened the viewer: the focus goes back to it)

proc openViewer(f: FileItem; kind: ViewerKind) =
  focusBeforeViewer = ui.focus
  closeFiles()
  stopMedia()
  dropBigCopy()
  viewSrc = localCopy(f.path, cacheDir(),
                      maxBytes = if kind in {vkVideo, vkAudio}: 4 shl 30 else: 256 shl 20)
  if viewSrc.len == 0:
    showError(tr("Cannot read ") & f.name & tr(" (it may be too big to show here)."))
    return
  viewInfo = f
  viewer = kind
  viewSel = 0
  viewZoom = 0
  viewPic = nil
  viewFailed = false
  viewPicFull = false
  mdSource = false
  editing = false
  viewText = ""
  viewSaved = ""
  try:
    case kind
    of vkText: bigText = openTextFile(viewSrc)
    of vkMarkdown:
      if f.size > 2_000_000:
        viewer = vkText
        bigText = openTextFile(viewSrc)
      else:
        viewText = readFile(viewSrc)
        viewSaved = viewText
    of vkHex: hexFile = openHexFile(viewSrc)
    of vkImage: askPicture(viewSrc, screenSize())
    of vkZip:
      viewEntries = zipEntries(viewSrc)
      viewEntrySel = 0
    of vkPdf:
      viewPdf = openPdfView(viewSrc)
      pdfFocus = true
    of vkVideo, vkAudio, vkNone: discard
  except CatchableError as e:
    viewer = vkNone
    showError(tr("Cannot open ") & f.name & ":\n" & e.msg)

proc openItem(f: FileItem) =
  ## Enter, a double click or a tap: into a folder, or the file in a viewer
  ## (or the app the system has for it); a shortcut, what it leads to.
  if f.isDir: go(f.path)
  elif extOf(f.name) == "url" and shortcutTarget(f.path).len > 0:
    # (Windows' Internet shortcut to a file or a folder: Paste Shortcut's)
    let t = shortcutTarget(f.path)
    if dirExists(t): go(t)
    elif fileExists(t): openItem(infoOf(t))
    else: showError(tr("What this shortcut leads to is not there:\n") & t)
  elif extOf(f.name) == "zip": openViewer(f, vkZip)
  elif isMarkdown(f): openViewer(f, vkMarkdown)
  elif extOf(f.name) in ["pdf", "ai"]: openViewer(f, vkPdf)
  elif kindOf(f) == fkVideo and videoPlaysInWindow(): openViewer(f, vkVideo)
  elif kindOf(f) == fkAudio: openViewer(f, vkAudio)
  elif isPicture(f) and kindOf(f) != fkVideo: openViewer(f, vkImage)
  elif isTextFile(f): openViewer(f, vkText)
  elif not openFile(f.path): openViewer(f, vkHex)

proc closeViewer(force = false) =
  if not force and editing and viewText != viewSaved:
    askSave = true
    return
  closeFiles()
  stopMedia()
  dropBigCopy()
  viewer = vkNone
  slideOn = false
  viewPic = nil
  viewText = ""
  editing = false
  folder.reload(viewInfo.name)
  # (back on the file that was opened, in the list it was opened from: the
  # arrows go on from it)
  if focusBeforeViewer != 0: ui.focus = focusBeforeViewer
  ui.redraw = true

proc saveViewer() =
  try:
    vWriteFile(viewInfo.path, viewText)          # (another app's document too)
    if viewSrc != viewInfo.path: writeFile(viewSrc, viewText)
    viewSaved = viewText
    toast(tr("Saved ") & viewInfo.name, glyph = pxSave)
  except IOError, OSError:
    showError(tr("Cannot save:\n") & getCurrentExceptionMsg())

proc startEditing() =
  ## A text small enough to edit is read whole.
  if viewInfo.size > 1_000_000:
    showError("This file is too big to edit here (more than 1 MB).")
    return
  try:
    viewText = readFile(viewSrc)
    viewSaved = viewText
    editing = true
  except IOError:
    showError(tr("Cannot read ") & viewInfo.path & ".")

proc siblingPicture(step: int) =
  ## The next (or previous) picture of the folder in the image viewer.
  var pics: seq[FileItem]
  for it in folder.items:
    if isPicture(it) and kindOf(it) notin {fkVideo, fkAudio} and extOf(it.name) notin ["pdf", "ai"]:
      pics.add it
  if pics.len == 0: return
  var at = -1
  for i, p in pics:
    if p.path == viewInfo.path: at = i
  openViewer(pics[(at + step + pics.len) mod pics.len], vkImage)

proc siblingOf(step: int) =
  ## The next (or previous) file of the same kind (video, sound, PDF).
  let want = viewer
  var list: seq[FileItem]
  for it in folder.items:
    if it.isDir: continue
    let k = case kindOf(it)
            of fkVideo: vkVideo
            of fkAudio: vkAudio
            else: (if extOf(it.name) in ["pdf", "ai"]: vkPdf else: vkNone)
    if k == want: list.add it
  if list.len == 0: return
  var at = -1
  for i, p in list:
    if p.path == viewInfo.path: at = i
  openViewer(list[(at + step + list.len) mod list.len], want)

proc viewerScreen() =
  ## The viewer takes the window: a bar with Back and the file's commands.
  let name = viewInfo.name
  let s = 1.3
  toolbar:
    if toolButton(pxBack, "Back (Esc)", size = s): closeViewer()
    toolSeparator()
    case viewer
    of vkText, vkMarkdown:
      if editing:
        if toolButton(pxSave, "Save (Ctrl+S)", size = s,
                      enabled = viewText != viewSaved): saveViewer()
        if toolButton(pxEye, "Stop editing", size = s):
          if viewText != viewSaved: askSave = true
          else:
            editing = false
            if viewer == vkText:
              closeFiles()
              try: bigText = openTextFile(viewSrc) except IOError: discard
      elif toolButton(pxRename, "Edit", size = s, enabled = viewInfo.size <= 1_000_000):
        startEditing()
      if viewer == vkMarkdown and not editing:
        if toolButton(if mdSource: pxEye else: pxCode,
                      if mdSource: "Preview" else: "Show the source", size = s):
          mdSource = not mdSource
    of vkImage:
      if toolButton(pxBack, "Previous picture", size = s): siblingPicture(-1)
      if toolButton(pxForward, "Next picture", size = s): siblingPicture(1)
      if toolButton(pxPlay, "Slide show (a picture every 3 seconds)", size = s, down = slideOn):
        slideOn = not slideOn
        slideAt = ui.now
      toolSeparator()
      if toolButton(pxFit, "Fit to the window", size = s, down = viewZoom == 0):
        viewZoom = 0
      if toolButton("1:1", "Actual size", down = viewZoom == 1.0):
        viewZoom = 1.0
        if not viewPicFull:
          viewPicFull = true
          askPicture(viewSrc, if ui.touch: 4096 else: 8192)
    of vkZip:
      if toolButton(pxFolderOpen, "Extract all here", size = s):
        startJob(jkUnzip, @[viewSrc], viewInfo.path.parentDir, "Extracting")
    of vkPdf:
      if viewPdf != nil:
        if toolButton(pxBack, "Previous page (Left)", size = s, enabled = viewPdf.page > 0):
          viewPdf.goToPage(viewPdf.page - 1)
        if toolButton(pxForward, "Next page (Right)", size = s, enabled = viewPdf.page < viewPdf.count - 1):
          viewPdf.goToPage(viewPdf.page + 1)
        toolSeparator()
        if toolButton(pxZoomOut, "Smaller (Ctrl+wheel, -)", size = s): viewPdf.zoomOut()
        if toolButton(pxZoomIn, "Larger (Ctrl+wheel, +)", size = s): viewPdf.zoomIn()
        if toolButton(pxFit, "As wide as the window (0)", size = s, down = viewPdf.zoom == 0):
          viewPdf.fitWidth()
        if toolButton("100%", "Actual size", down = viewPdf.zoom == 1.0):
          viewPdf.setZoom(1.0)
    of vkVideo, vkAudio:
      if toolButton(pxBack, "Previous", size = s): siblingOf(-1)
      if toolButton(pxForward, "Next", size = s): siblingOf(1)
    else: discard
    if toolButton(pxOpenWith, "Open with another app", size = s):
      if not openFile(viewInfo.path): showError(tr("No app to open ") & name & ".")
    if platformName() == "android":
      if toolButton(pxShare, "Share", size = s): discard shareFile(viewInfo.path)
  setTitle(name & " - " & AppTitle)
  let dirty = editing and viewText != viewSaved
  row:
    let (g, c) = fileGlyph(viewInfo)
    iconLabel(g, name & (if dirty: " *" else: ""), bold = true, iconColor = c)
    spring()
    let info = case viewer
      of vkImage: (if viewPic != nil: $viewPic.w & " x " & $viewPic.h & tr(" pixels") else: "")
      of vkZip: countText(viewEntries.len, "entry", "entries")
      of vkText: (if editing: sizeText(viewText.len) else: textFileStatus(bigText))
      of vkHex: (if hexFile != nil: sizeText(hexFile.size) else: "")
      of vkPdf: (if viewPdf != nil: $viewPdf.zoomPercent & "%" else: "")
      else: sizeText(viewInfo.size)
    if viewer == vkPdf and viewPdf != nil:
      # the page: typed to go there
      label "Page", color = ui.theme.gray
      pdfPageNum = viewPdf.page + 1
      if spin(pdfPageNum, 1, max(1, viewPdf.count), w = dp(76)):
        viewPdf.goToPage(pdfPageNum - 1)
      label tr("of ") & $viewPdf.count & "   ", color = ui.theme.gray
    label info, color = ui.theme.gray
  case viewer
  of vkText:
    if editing: discard editArea(viewText, lines = -1)
    else: textFileView(bigText, viewSel)
  of vkMarkdown:
    if editing: discard editArea(viewText, lines = -1)
    elif mdSource:
      let lines = viewText.splitLines
      discard lineView(lines.len, proc (i: int): string = lines[i], viewSel, numbers = true)
    else:
      let ev = markdownView(viewText, baseDir = viewInfo.path.parentDir)
      if ev.task >= 0:
        startEditing()
        if editing: toggleTask(viewText, ev.task)
      if ev.link.len > 0:
        let target = viewInfo.path.parentDir / ev.link
        if fileExists(target): openItem(infoOf(target))
        else: discard openUrl(ev.link)
  of vkHex: hexFileView(hexFile, viewSel)
  of vkImage:
    if slideOn:
      if ui.now - slideAt >= 3000:
        slideAt = ui.now
        siblingPicture(1)
      wakeIn(max(20, 3000 - (ui.now - slideAt)))
    if viewPic != nil: imageView(viewPic, viewZoom)
    elif viewFailed: emptyState(pxImage, tr("This picture cannot be shown here."))
    else: busyState(tr("Loading the picture..."))
  of vkZip:
    var zc = @[column(tr("Name"), 300), column(tr("Size"), 90, alRight),
               column(tr("Packed"), 90, alRight), column(tr("Modified"), 150)]
    discard grid(zc, viewEntries.len, proc (r, c: int): string =
      let e = viewEntries[r]
      case c
      of 0: e.name
      of 1: (if e.isDir: "" else: sizeText(e.size))
      of 2: (if e.isDir: "" else: sizeText(e.packed))
      else: timeText(e.time)
    , viewEntrySel, height = -1, icon = proc (r: int): Icon =
      fileIcon(FileItem(name: viewEntries[r].name, isDir: viewEntries[r].isDir),
               min(ItemH - 2, FontH + 8)))
  of vkPdf:
    if viewPdf != nil:
      if pdfFocus:
        focusNext()
        pdfFocus = false
      pdfView(viewPdf)
  of vkVideo:
    let ev = videoView(viewSrc, autoplay = true, key = "viewer")
    if ev.error.len > 0: label ev.error, color = ui.theme.gray
  of vkAudio:
    let ev = audioView(viewSrc, height = min(remainingH() div 2, dp(260)), autoplay = true, key = "viewer")
    # the folder's sounds, as a play list: the one playing picked
    var list: seq[FileItem]
    var at = -1
    for it in folder.items:
      if not it.isDir and kindOf(it) == fkAudio:
        if it.path == viewInfo.path: at = list.len
        list.add it
    if list.len > 1:
      var c = @[column(tr("Title"), 360), column(tr("Size"), 90, alRight), column(tr("Type"), 120)]
      var pick = at
      let gv = grid(c, list.len, proc (r, col: int): string =
        case col
        of 0: list[r].name.splitFile.name
        of 1: sizeText(list[r].size)
        else: kindName(list[r])
      , pick, height = -1, icon = proc (r: int): Icon =
        fileIcon(list[r], min(ItemH - 2, FontH + 8)))
      if (gv.activated or (pick != at and gv.selChanged)) and pick in 0 ..< list.len:
        openViewer(list[pick], vkAudio)
    if ev.ended: siblingOf(1)               # (the folder plays on, as a player does)
  of vkNone: discard
  if canInput():
    if keyHit(KeyEsc): closeViewer()
    if CtrlPressed in ui.mods and ui.key == KeyS and not ui.keyUsed and editing:
      ui.keyUsed = true
      saveViewer()
    if viewer == vkImage:
      if keyHit(KeyRight) or keyHit(KeyPageDown): siblingPicture(1)
      elif keyHit(KeyLeft) or keyHit(KeyPageUp): siblingPicture(-1)
  case msgBox(askSave, "Save changes?", tr("Save the changes to ") & name & tr("?"),
              ["&Save", "&Don't save", "Cancel"], miQuestion)
  of 1:
    saveViewer()
    editing = false
  of 2:
    viewText = viewSaved
    editing = false
  else: discard

# ---- panes -------------------------------------------------------------------------------------

proc applyLanguage*() =
  ## The interface in English, or in Arabic (right to left: mirrored).
  if language == 1: setUiLanguage("ar", @toolkitArabic, @filesArabic)
  else: setUiLanguage("")

proc applyThumbCache() =
  ## Thumbnails of slow files kept on disk (Settings > Work), no more than
  ## the limit chosen.
  if diskThumbs and thumbsOn:
    useThumbCache(thumbCacheFolder(AppTitle), int64(diskThumbMB) * 1024 * 1024)
  else:
    useThumbCache("")
  thumbBytes = -1

proc copyTo*(move: bool) =
  ## Edit > Copy To Folder / Move To Folder: the selection, to a folder
  ## picked.
  if tab.special != spFolder or folder.selectedItems.len == 0: return
  pickMove = move
  pickPath = folder.dir
  pickOpen = true

proc pickDialog() =
  if not pickOpen: return
  if filePicker(pickOpen, pickPath, fmFolder,
                title = (if pickMove: "Move To Folder" else: "Copy To Folder"), preview = false):
    let srcs = folder.selectedPaths
    if srcs.len > 0 and dirExists(pickPath):
      startJob(if pickMove: jkMove else: jkCopy, srcs, pickPath,
               if pickMove: "Moving" else: "Copying")

proc shareSelected() =
  ## The file selected, to another app (Android's Share; elsewhere the
  ## system's way of sending it, when it has one).
  let list = folder.selectedItems
  if list.len != 1 or list[0].isDir: return
  if not shareFile(list[0].path): showError(tr("No app to share ") & list[0].name & tr(" with."))

proc openSizes*() =
  ## Tools > Folder Sizes: what takes the room in this folder.
  if tab.special != spFolder or folder.dir.len == 0: return
  for r in sizesRows:
    if r.job != nil: r.job.cancel()
  sizesRows.setLen(0)
  sizesLoose = 0
  sizesDir = folder.dir
  for f in folder.all:
    if f.isDir: sizesRows.add (f, newJob(jkMeasure, [f.path]))
    else: sizesLoose += f.size
  sizesOpen = true

proc sizesDialog() =
  if not sizesOpen:
    if sizesRows.len > 0:
      for r in sizesRows:
        if r.job != nil and r.job.state == jsRunning: r.job.cancel()
      sizesRows.setLen(0)
    return
  # (measured a little each frame: a few milliseconds, shared)
  var busy = 0
  let t0 = getMonoTime()
  for r in sizesRows.mitems:
    if r.job != nil and r.job.state == jsRunning:
      inc busy
      if (getMonoTime() - t0).inMilliseconds < 10: r.job.run(4)
  if busy > 0: wakeIn(1)
  proc bytesOf(r: tuple[item: FileItem; job: FileJob]): int64 =
    if r.job == nil: 0'i64 else: r.job.totalBytes
  var order = newSeq[int](sizesRows.len)
  for i in 0 ..< order.len: order[i] = i
  order.sort(proc (a, b: int): int = cmp(bytesOf(sizesRows[b]), bytesOf(sizesRows[a])))
  var most = max(1'i64, sizesLoose)
  var total = sizesLoose
  for r in sizesRows:
    most = max(most, bytesOf(r))
    total += bytesOf(r)
  dialog(sizesOpen, "Folder Sizes", 560):
    label(sizesDir, bold = true)
    label((if busy > 0: tr("Measuring...") & " " else: "") & sizeText(total) & tr(" in all"),
          color = ui.theme.gray)
    # (the files of the folder itself: the first row)
    let rows = sizesRows.len + 1
    proc rowBytes(r: int): int64 =
      if r == 0: sizesLoose else: bytesOf(sizesRows[order[r - 1]])
    let ev = grid(sizesCols, rows, proc (r, c: int): string =
      case c
      of 0:
        if r == 0: tr("(the files here)") else: sizesRows[order[r - 1]].item.name
      of 1:
        let running = r > 0 and sizesRows[order[r - 1]].job != nil and
                      sizesRows[order[r - 1]].job.state == jsRunning
        sizeText(rowBytes(r)) & (if running: "..." else: "")
      of 2: formatFloat(rowBytes(r).float / most.float, ffDecimal, 3)
      else:
        if r == 0: "" else: $sizesRows[order[r - 1]].job.files
    , sizesSel, height = 12, icon = proc (r: int): Icon =
        if r == 0: Icon() else: fileIcon(sizesRows[order[r - 1]].item, min(ItemH - 2, FontH + 8)))
    if ev.activated and sizesSel > 0 and sizesSel <= sizesRows.len:
      let path = sizesRows[order[sizesSel - 1]].item.path
      sizesOpen = false
      go(path)
    row:
      label("Double-click a folder to open it.", color = ui.theme.gray)
      spring()
      if button("OK", isDefault = true, w = dp(80)): sizesOpen = false

proc contextMenu() =
  contextMenu:
    let list = folder.selectedItems
    let one = list.len == 1
    if menuItem("&Open", "Enter", enabled = list.len > 0) and list.len > 0:
      openItem(list[0])
    if menuItem("Open in new &tab", enabled = one and list[0].isDir):
      addTab(active, list[0].path)
    if twoPanes() and menuItem("Open in the other &pane", enabled = one and list[0].isDir):
      let p = 1 - active
      panes[p].tabs[panes[p].at].special = spFolder
      panes[p].tabs[panes[p].at].m.open(list[0].path)
    if menuItem("Open &with app...", enabled = one and not list[0].isDir):
      if not openFile(list[0].path): showError(tr("No app to open ") & list[0].name & ".")
    if menuItem("View as te&xt", enabled = one and not list[0].isDir):
      openViewer(list[0], vkText)
    if menuItem("View as he&x", enabled = one and not list[0].isDir):
      openViewer(list[0], vkHex)
    if platformName() in ["android", "ios"]:
      if menuItem("S&hare...", enabled = one and not list[0].isDir): shareSelected()
    menuSeparator()
    if menuItem("Cu&t", "Ctrl+X", enabled = list.len > 0): copySel(true)
    if menuItem("&Copy", "Ctrl+C", enabled = list.len > 0): copySel(false)
    if menuItem("&Paste", "Ctrl+V", enabled = clipPaths.len > 0): paste()
    if menuItem("Paste &Shortcut", enabled = clipPaths.len > 0 and not clipCut): pasteShortcut()
    if twoPanes():
      if menuItem("Copy to the other pane", enabled = list.len > 0 and other() != nil):
        toOther(false)
      if menuItem("Move to the other pane", enabled = list.len > 0 and other() != nil):
        toOther(true)
    if menuItem("Copy To &Folder...", enabled = list.len > 0): copyTo(false)
    if menuItem("Mo&ve To Folder...", enabled = list.len > 0): copyTo(true)
    menuSeparator()
    if menuItem("&Delete", "Del", enabled = list.len > 0): deleteSelected()
    if menuItem("Rena&me", "F2", enabled = one): rename()
    menuSeparator()
    if menuItem("Compress to &ZIP...", enabled = list.len > 0): zipSelected()
    var anyZip = false
    for f in list:
      if extOf(f.name) == "zip": anyZip = true
    if menuItem("E&xtract here", enabled = anyZip): unzipSelected()
    menuSeparator()
    if menuItem("Copy as pat&h"):
      putClipboardText(if list.len > 0: folder.selectedPaths.join("\n") else: folder.dir)
    if menuItem("Pin to &favorites", enabled = one and list[0].isDir and
                list[0].path notin favorites):
      favorites.add list[0].path
      saveSettings()
    if menuItem("&New folder...", "Ctrl+Shift+N"): askName(naNewFolder, tr("New folder"))
    if menuItem("Propert&ies", "Alt+Enter", enabled = list.len > 0): showProperties()

proc folderBody(p: int; t: Tab) =
  ## A folder's files, as the view chosen says.
  let (view, size, _) = viewSteps[viewStep]
  let ev = if view == fvColumns:
             # (the columns start at the place the folder is in: Home, a card...;
             # the widest of them but the whole computer)
             var root = ""
             for (_, path) in placeList():
               if (t.m.dir == path or t.m.dir.startsWith(path & DirSep)) and
                  (root.len == 0 or (path.len < root.len and path != "/") or root == "/"):
                 root = path
             fileColumns(t.m, root = root, thumbnails = thumbsOn, key = "cols" & $p)
           else:
             fileList(t.m, view, thumbnails = thumbsOn, iconSize = size,
                      tapActivates = singleTap and ui.touch, checkboxes = selectMode)
  if (ui.pressed or ui.rpressed) and mouseIn(ui.lastRect) or ev.selChanged:
    active = p
  if ev.activated:
    active = p
    openItem(ev.item)
  if ev.middle:                          # the middle button: in a new tab
    if ev.item.isDir:
      let back = panes[p].at
      addTab(p, ev.item.path)
      panes[p].at = back                 # (opened behind, as browsers do)
      syncQuery(p)
    else: openItem(ev.item)
  if ev.sorted:
    sortKey = t.m.sortBy
    sortDesc = t.m.descending
    saveSettings()
  if ev.renamed:
    if ev.error.len > 0: showError(ev.error)
    else:
      remember UndoStep(kind: ukRename, pairs: @[(ev.item.path,
                        ev.item.path.parentDir / ev.newName)],
                        what: tr("Rename ") & ev.item.name)
    forgetFolderTree()
  if ev.preview.share: discard shareFile(ev.preview.item.path)
  if ev.preview.properties:
    propsItems = @[ev.preview.item]
    propsOpen = true
  if ev.drop.dropped: dropFiles(ev.drop)
  if ev.zoom != 0:
    viewStep = if viewStep > zoomSteps: (if ev.zoom > 0: 2 else: 0)
               else: clamp(viewStep + ev.zoom, 0, zoomSteps)
    saveSettings()
  if p == active: contextMenu()

proc webPanel(t: Tab) =
  ## View > as Web Page, as Explorer 98 had it: at the left of the files,
  ## the folder's name large over a rule in the title bar's color, then
  ## what is selected described (its kind, size, date; a picture's preview).
  let m = t.m
  let r = canvas(0, remainingH())
  accessBegin(arPane, "Folder", r)     # (a screen reader reads its texts inside)
  defer: accessEnd()
  fill(r, ui.theme.window)
  let x = r.x + dp(10)
  let w = max(dp(40), r.w - dp(20))
  var y = r.y + dp(10)
  image(x, y, glyphIcon(retroOr(pxFolderOpen, nfFolderOpen), color(232, 178, 58), dp(40)))
  y += dp(46)
  let name = if m.dir.extractFilename.len > 0: m.dir.extractFilename else: m.dir
  let big = style(bold = true, size = 1.45)
  text(x, y, ellipsize(name, w, big), ui.theme.text, big)
  accessNode(arHeading, name, id = 0, r = rect(x, y, w, lineHeight(big)))
  y += lineHeight(big) + dp(4)
  # (the rule: the title bar's blue fading into the page)
  for i in 0 ..< w:
    vline(x + i, y, dp(3), mixColor(ui.theme.select, ui.theme.window, i / max(1, w)))
  y += dp(12)
  let sel = m.selectedItems
  let small = style(size = 0.92)
  template say(s: string; strong = false) =
    accessNode(arLabel, s, id = 0, r = rect(x, y, w, FontH))
    for line in wrapLines(s, w, strong):
      if y + FontH > r.y + r.h - dp(4): break
      drawLabel(x, y, line, ui.theme.text, strong)
      y += FontH
  template note(s: string) =
    accessNode(arLabel, s, id = 0, r = rect(x, y, w, FontH))
    for line in wrapLines(s, w):
      if y + FontH > r.y + r.h - dp(4): break
      text(x, y, line, ui.theme.gray, small)
      y += lineHeight(small) + 1
  if sel.len == 0:
    let st = m.folderStats
    note(tr("Select an item to view its description."))
    y += dp(6)
    note(countText(st.files, "file") & tr(", ") & countText(st.folders, "folder"))
    if st.bytes > 0: note(sizeText(st.bytes))
  elif sel.len == 1:
    let f = sel[0]
    say(f.name, strong = true)
    note(kindName(f))
    y += dp(4)
    if not f.isDir: note(tr("Size: ") & sizeText(f.size))
    note(tr("Modified: ") & timeText(f.modified))
    if f.readOnly: note(tr("Attributes: Read-only"))
    if isPicture(f) and y + dp(60) < r.y + r.h:
      let pw = min(w, dp(160))
      let pr = rect(x, y + dp(6), pw, min(pw * 3 div 4, r.y + r.h - y - dp(10)))
      if not drawPicture(pr, f.path, f.modified.toUnix, priority = 1):
        image(pr.x, pr.y, fileIcon(f, dp(48)))
  else:
    var bytes = 0'i64
    for f in sel: bytes += f.size
    say(countText(sel.len, "item") & tr(" selected."), strong = true)
    note(tr("Total file size: ") & sizeText(bytes))
  ui.lastRect = r

proc paneBody(p: int) =
  ## What the tab of pane `p` shows: a folder, "This device" or the trash.
  let t = panes[p].tabs[panes[p].at]
  if t.special == spFolder and webView and not isCompact() and not twoPanes() and available() > dp(560):
    # (as a Web page: the description at the left)
    let before = webW
    split(webW, -1):
      webPanel(t)
    do:
      folderBody(p, t)
    if webW != before: saveSettings()
    return
  case t.special
  of spDevice:
    let f = placesView(favorites, key = $p)
    if ui.pressed and mouseIn(ui.lastRect): active = p
    if f.len > 0:
      active = p
      go(f)
  of spTrash:
    let e = trashList(trashBox)
    if ui.pressed and mouseIn(ui.lastRect): active = p
    if e.changed: refreshAll()
    if e.error.len > 0: showError(e.error)
  of spFolder: folderBody(p, t)

proc preview() =
  if tab.special != spFolder:
    emptyState(pxInfo, if tab.special == spTrash: tr("Restore items, or empty the trash.")
                       else: tr("Pick a place to open it."))
    return
  let ev = filePreview(folder, followHover = followHover)
  if ev.open: openItem(ev.item)
  if ev.share: discard shareFile(ev.item.path)
  if ev.properties:
    propsItems = @[ev.item]
    propsOpen = true

proc setView*(step: int) =
  viewStep = clamp(step, 0, viewSteps.high)
  if viewSteps[viewStep][0] in {fvIcons, fvTiles, fvSmallIcons, fvList}: lastIconStep = viewStep
  saveSettings()

proc paneTop(p: int; strip = true; key = "") =
  ## The tabs, the path bar and the search box of pane `p` (`strip` false:
  ## no tabs -- a folder's window).
  let pane = addr panes[p]
  let key = if key.len > 0: key else: $p
  if twoPanes():
    # the active pane is the one with the colored line
    let r = canvas(0, dp(3))
    fill(r, if p == active: ui.theme.select else: ui.theme.face)
  if strip and (not isCompact() or pane.tabs.len > 1):
    var labels, glyphs: seq[string]
    for t in pane.tabs:
      let (g, l) = tabLabel(t)
      glyphs.add g
      labels.add l
    let ev = tabStrip(labels, pane.at, glyphs, closable = pane.tabs.len > 1,
                      dropKind = "files")
    if ev.selected:
      active = p
      syncQuery(p)
    if ev.closed >= 0: closeTab(p, ev.closed)
    if ev.added: addTab(p, tabKey(pane.tabs[pane.at]))
    if ev.menu >= 0: pane.menuTab = ev.menu
    contextMenu:                           # a tab's menu (right click, long press)
      let i = clamp(pane.menuTab, 0, pane.tabs.high)
      if menuItem("&Duplicate tab"):
        addTab(p, tabKey(pane.tabs[i]))
      if menuItem("&Close tab", "Ctrl+W", enabled = pane.tabs.len > 1):
        closeTab(p, i)
      if menuItem("Close &other tabs", enabled = pane.tabs.len > 1):
        let keep = pane.tabs[i]
        pane.tabs = @[keep]
        pane.at = 0
        syncQuery(p)
      if twoPanes() and menuItem("&Move to the other pane", enabled = pane.tabs.len > 1):
        let moved = pane.tabs[i]
        closeTab(p, i)
        panes[1 - p].tabs.add moved
        panes[1 - p].at = panes[1 - p].tabs.high
        active = 1 - p
        syncQuery(1 - p)
    if ev.dropOn >= 0:
      let t = pane.tabs[ev.dropOn]
      case t.special
      of spFolder: dropFiles(FileDrop(paths: ui.drag.items, into: t.m.dir, copy: dragCopies()))
      of spTrash: dropFiles(FileDrop(paths: ui.drag.items, into: trashId))
      else: discard
  let t = pane.tabs[pane.at]
  # (a narrow window -- a folder's window, tiled: the search box a button,
  # the box itself under the address bar when it is pressed or searching)
  let narrowBox = not isCompact() and t.special == spFolder and available() < dp(540)
  if narrowBox and pane.findNow: t.searchOpen = true
  let boxBelow = narrowBox and (t.searchOpen or pane.query.len > 0)
  let searchW = if isCompact() or t.special != spFolder: 0
                elif narrowBox: CtrlH + dp(2)
                else: clamp(available() div 4, dp(120), dp(200))
  let addrW = if isCompact(): 0 else: labelWidth("A&ddress") + dp(12)
  let switchW = if isCompact() or t.special != spFolder: 0 else: 3 * (CtrlH + 1) + 2 * Gap + dp(2)
  let cols = if addrW > 0: @[addrW, -1, switchW, searchW] else: @[-1, searchW]
  row(cols):
    if addrW > 0:
      # (Explorer's Address bar: Alt+D) -- its label in the middle of the bar's height
      let lr = canvas(addrW, EditH)
      drawLabel(lr.x + dp(4), lr.y + (lr.h - FontH) div 2, "A&ddress", ui.theme.text)
    case t.special
    of spFolder:
      let pb = pathBar(tabKey(t), key = key, editNow = pane.editPath)
      pane.editPath = false
      if pb.go.len > 0:
        active = p
        go(pb.go)
      if pb.drop.dropped: dropFiles(pb.drop)
      if pb.error.len > 0: showError(pb.error)
    else:
      let (g, l) = tabLabel(t)
      iconLabel(g, l, bold = true)
    if switchW > 0:
      # the views, as DeskFiles and Finder have them: list, icons, columns
      row:
        let v = viewSteps[viewStep][0]
        if toolButton(pixelIcon(pxDetails), "Details", down = v == fvDetails):
          active = p
          setView(0)
        if toolButton(pixelIcon(pxIcons), "Icons", down = v in {fvIcons, fvTiles, fvSmallIcons, fvList}):
          active = p
          if v notin {fvIcons, fvTiles, fvSmallIcons, fvList}: setView(lastIconStep)
        if toolButton(pixelIcon(pxColumns), "Columns", down = v == fvColumns):
          active = p
          setView(columnsStep)
    elif addrW > 0: discard canvas(0, 0)
    if narrowBox:
      # (the search, as a button: the box under the address bar)
      if toolButton(pixelIcon(pxSearch), "Search " & t.m.dir.extractFilename & " (F3)", down = boxBelow):
        active = p
        t.searchOpen = not boxBelow
        if t.searchOpen: pane.findNow = true
        elif pane.query.len > 0:
          pane.query = ""
          t.m.stopSearch()
          t.m.setFilter("")
    else:
      if searchW > 0 and pane.findNow:
        focusNext()
        pane.findNow = false
      if searchW > 0 and searchBox(pane.query, tr("Search ") & t.m.dir.extractFilename):
        active = p
        if pane.deep: t.m.search(pane.query) else: t.m.setFilter(pane.query)
  if boxBelow:
    row:
      if pane.findNow:
        focusNext()
        pane.findNow = false
      if searchBox(pane.query, tr("Search ") & t.m.dir.extractFilename):
        active = p
        if pane.deep: t.m.search(pane.query) else: t.m.setFilter(pane.query)
  if isCompact() and t.special == spFolder and pane.findNow:
    focusNext()
    pane.findNow = false
  if isCompact() and t.special == spFolder and searchBox(pane.query, tr("Search")):
    if pane.deep: t.m.search(pane.query) else: t.m.setFilter(pane.query)
  if t.special == spFolder and pane.query.len > 0:
    row:
      if checkbox("Search in all &subfolders", pane.deep):
        if pane.deep: t.m.search(pane.query) else: t.m.stopSearch()
      if t.m.searching:
        if t.m.searchBusy: spinner()
        label countText(t.m.items.len, "found", "found"), color = ui.theme.gray

proc terminalHere()
proc emptyTrashAsk()

proc treePane() =
  treeSel = if tab.special == spDevice: deviceId
            elif tab.special == spTrash: trashId
            else: folder.dir
  # (room inside its frame, round the folders)
  let ev = folderTree(treeSel, favorites, showHidden,
                      extra = [(tr("This device"), pxComputer, deviceId), (tr("Trash"), pxTrash, trashId)],
                      padding = dp(4))
  # its menu (a right click, a long press): on the folder clicked -- it is shown
  contextMenu:
    let path = treeSel
    let isDir = path.len > 0 and not path.startsWith("::")
    if menuItem(if windowsShown(): "Open in New &Window" else: "Open in New &Tab", enabled = isDir or
                path in [deviceId, trashId]):
      addTab(active, path)
    if twoPanes() and menuItem("Open in the &Other Pane", enabled = isDir):
      let p = 1 - active
      panes[p].tabs[panes[p].at].special = spFolder
      panes[p].tabs[panes[p].at].m.open(path)
    menuSeparator()
    if menuItem("New &Folder...", "Ctrl+Shift+N", enabled = isDir and tab.special == spFolder):
      askName(naNewFolder, tr("New folder"))
    if menuItem("&Paste Into It", enabled = isDir and clipPaths.len > 0): paste()
    menuSeparator()
    if path in favorites:
      if menuItem("&Remove from Favorites"):
        favorites.delete(favorites.find(path))
        saveSettings()
    elif menuItem("&Add to Favorites", enabled = isDir):
      favorites.add path
      saveSettings()
    if menuItem("Copy as Pat&h", enabled = isDir): putClipboardText(path)
    if canOpenTerminal() and menuItem("Open &Terminal Here", enabled = isDir and tab.special == spFolder):
      terminalHere()
    if menuItem("Folder &Sizes...", enabled = isDir and tab.special == spFolder): openSizes()
    if path == trashId:
      menuSeparator()
      if menuItem("&Empty the Trash"): emptyTrashAsk()
    menuSeparator()
    if menuItem("P&roperties", enabled = isDir):
      propsItems = @[infoOf(path)]
      propsOpen = true
  if ev.picked:
    # (go checks the folder: one of another app -- Termux's -- is not on
    # disk for this app, and is offered through that app)
    go(treeSel)
  if ev.drop.dropped: dropFiles(ev.drop)

proc batchDialog() =
  ## Rename with several selected: a pattern ("Holiday ###"), find and
  ## replace, the letters; the new names shown before they are given.
  if not batchOpen: return
  dialog(batchOpen, tr("Rename ") & $batchItems.len & tr(" Items"), 520):
    var names: seq[string]
    for it in batchItems: names.add it.name
    let fresh = batchNames(names, batchPattern, batchFind, batchReplace, batchStart,
                           CaseChange(batchCase))
    row([110, -1]):
      label "&Name pattern:"
      edit(batchPattern)
    label tr("* the name as it is, ### a number (as many digits as #s); the extension stays."),
          color = ui.theme.gray
    row([110, -1, 84, 110]):
      label "&Find:"
      edit(batchFind)
      label "Number &from"
      spin(batchStart, 0, 99999, w = dp(110))
    row([110, -1, 84, 110]):
      label "Replace &with:"
      edit(batchReplace)
      label "&Letters"
      combo([tr("As they are"), tr("lower"), tr("UPPER"), tr("Title Case")], batchCase, w = dp(110))
    var shown = 0
    var c = @[column(tr("Name now"), 230), column(tr("New name"), 230)]
    var sel = -1
    discard grid(c, names.len, proc (r, col: int): string =
      if col == 0: names[r] else: fresh[r]
    , sel, height = min(8, max(3, names.len)), typeToEdit = false)
    discard shown
    row:
      spring()
      if button("&Rename", isDefault = true):
        var paths: seq[string]
        for it in batchItems: paths.add it.path
        let (done, err) = folder.renameAll(paths, fresh)
        if done.len > 0:
          remember UndoStep(kind: ukRename, pairs: done, what: tr("Rename ") & $done.len & tr(" items"))
        forgetFolderTree()
        batchOpen = false
        if err.len > 0: showError(err)
      if button("Cancel"): batchOpen = false

proc matchDialog() =
  ## Edit > Select Matching: the items whose names match a pattern.
  case inputBox(matchOpen, "Select Matching",
                "Select the items named like (* any letters, ? one; several: *.jpg *.png):",
                matchText, width = 420)
  of 1:
    if tab.special == spFolder:
      let n = folder.selectMatching(matchText)
      if n == 0: toast(tr("Nothing matches ") & matchText)
  else: discard

proc duplicateSelected() =
  ## Copies of the selected items beside them ("name (2).txt").
  if tab.special != spFolder: return
  let p = folder.selectedPaths
  if p.len > 0: startJob(jkCopy, p, folder.dir, "Duplicating")

proc terminalHere() =
  if tab.special == spFolder and not isDocPath(folder.dir):
    if not openTerminal(folder.dir): showError("No terminal program was found.")

proc placesDialog() =
  ## Phones: the places and favorites, as a list to pick from.
  dialog(placesOpen, "Go to", 360):
    var names: seq[string]
    var paths: seq[string]
    names.add pxComputer & "  " & tr("This device")
    paths.add deviceId
    for (name, path) in placeList():
      names.add placeGlyph(name) & "  " & tr(name)
      paths.add path
    for f in favorites:
      names.add pxStar & "  " & f.extractFilename
      paths.add f
    names.add pxTrash & "  " & tr("Trash")
    paths.add trashId
    var pick = -1
    if listbox(names, pick, rows = min(12, names.len)) and pick >= 0:
      placesOpen = false
      go(paths[pick])
    row:
      spring()
      if button("Cancel"): placesOpen = false

# ---- dialogs ------------------------------------------------------------------------------------

proc deleteDialog() =
  if askDelete:
    let list = folder.selectedItems
    let what = if list.len == 1: "\"" & list[0].name & "\"" else: countText(list.len, "item")
    case msgBox(askDelete, "Delete", tr("Move ") & what & tr(" to the trash?"),
                ["&Delete", "Cancel"], miQuestion)
    of 1: startJob(jkTrash, folder.selectedPaths, "", "Moving to the trash")
    else: discard
  if askForever:
    let list = folder.selectedItems
    let what = if list.len == 1: "\"" & list[0].name & "\"" else: countText(list.len, "item")
    case msgBox(askForever, "Delete for good",
                tr("Delete ") & what & tr(" for good?\nThis cannot be undone."),
                ["&Delete", "Cancel"], miWarning)
    of 1: startJob(jkDelete, folder.selectedPaths, "", "Deleting")
    else: discard
  if askEmptyTrash:
    case msgBox(askEmptyTrash, "Empty the Trash",
                tr("Delete everything in the trash for good?\nThis cannot be undone."),
                ["&Empty", "Cancel"], miWarning)
    of 1:
      let n = emptyTrash()
      if n > 0: showError(countText(n, "item") & tr(" could not be deleted."))
      refreshAll()
    else: discard

proc emptyTrashAsk() =
  ## (the folder tree's menu on the Trash: asked first)
  askEmptyTrash = true

proc toggleDual() =
  dual = not dual and not isCompact()
  if dual:
    inWindows = false
    if panes[1].tabs.len == 0: panes[1].tabs.add newTab(folder.dir)
  else: active = 0
  saveSettings()

proc toggleWindows*() =
  ## The folders in windows of their own, or in tabs again.
  inWindows = not inWindows
  if inWindows:
    dual = false
    active = 0
    syncQuery(0)
    # (each tab a window, cascaded, the one shown in front)
    for t in panes[0].tabs:
      t.win.r = rect(0, 0, 0, 0)
      t.win.open = true
      t.win.minimized = false
      t.win.maximized = false
    mdiActivate(tab.win, "files")
  saveSettings()

var settingsTab = 0


proc foldersInMenu(arrange = true) =
  ## The folders in tabs or in windows of their own (View > Folders In, the
  ## Window menu, the tool bar's Tabs / Windows); in windows: Cascade, Tile.
  if menuItem("Folders in &Tabs", checked = not inWindows):
    if inWindows: toggleWindows()
  if menuItem("Folders in &Windows", checked = inWindows):
    if not inWindows: toggleWindows()
  if arrange and inWindows:
    menuSeparator()
    if menuItem("&Cascade", "Shift+F5"): mdiCascade("files")
    if menuItem("T&ile", "Shift+F4"): mdiTile("files")

proc settingsDialog() =
  if not settingsOpen: return
  var changed = false
  dialog(settingsOpen, "Folder Options", 460):
    tabs settingsTab, ["&Look", "&Folders", "&Work"], sameHeight = true:
      case settingsTab
      of 0:
        var lang = language
        if settingChoice("Language", ["English", "العربية"], lang):
          language = lang
          applyLanguage()
          changed = true
        if appearanceSettings(): changed = true
      of 1:
        if settingToggle("Hidden files", showHidden, tr("Names that start with a dot")):
          eachModel(proc (m: FolderModel) = m.showHidden = showHidden)
          refreshAll()
          changed = true
        if settingToggle("File name extensions", showExt, tr("\"notes.txt\" or \"notes\"")):
          eachModel(proc (m: FolderModel) = m.showExtensions = showExt)
          changed = true
        if not isCompact():
          if settingToggle("Folder tree", showTree): changed = true
          if settingToggle("Drive bar", showDrives, tr("The places as buttons under the tool bar")):
            changed = true
          if settingToggle("Two panes", dual, tr("Two folders side by side (F9)")):
            if dual:
              inWindows = false
              if panes[1].tabs.len == 0: panes[1].tabs.add newTab(folder.dir)
            changed = true
          var w = ord(inWindows)
          if settingChoice("Folders open in", ["Tabs", "Windows"], w):
            if (w == 1) != inWindows: toggleWindows()
            changed = true
          var g = winGrip
          if settingChoice("Windows' size grip", ["None", "Small", "Medium", "Large"], g,
                           tr("At the lower right corner of each folder's window")):
            winGrip = g
            changed = true
        if settingToggle("Preview pane", showPreview,
                         tr("Beside the list, or under it on a phone (F3)")): changed = true
        if settingToggle("Preview follows the mouse", followHover,
                         tr("Shows the item the mouse rests on")): changed = true
        if settingToggle("Picture thumbnails", thumbsOn):
          applyThumbCache()
          changed = true
        var s = ord(startIn)
        if settingChoice("Start in", ["Last", "Home", "Storage"], s):
          startIn = StartIn(s)
          changed = true
        if needsDocAccess(TermuxHome) and
           settingButtons("Termux", ["Allow access"], tr("Its home folder, here too")) == 1:
          askDocAccess(TermuxHome)
      else:
        if settingToggle("Delete to the trash", useTrash,
                         tr("Deleted items can be restored (Shift+Del: for good)")):
          changed = true
        if settingToggle("Ask before deleting", confirmDelete): changed = true
        if settingToggle("Open with one tap", singleTap,
                         tr("On touch screens; a long press selects")): changed = true
        if settingToggle("Keep thumbnails on disk", diskThumbs,
                         tr("Folders of photos, videos and documents open at once the second time")):
          applyThumbCache()
          changed = true
        if diskThumbs:
          const limits = [32, 96, 256, 1024]
          var at = 1
          for i, l in limits:
            if l == diskThumbMB: at = i
          if settingChoice("At most", ["32 MB", "96 MB", "256 MB", "1 GB"], at):
            diskThumbMB = limits[at]
            applyThumbCache()
            changed = true
        if thumbBytes < 0: thumbBytes = thumbCacheBytes()
        if settingButtons("Thumbnails", ["Clear"],
                          (if diskThumbs: sizeText(thumbBytes) & tr(" kept on disk")
                           else: tr("Decoded again when they are shown"))) == 1:
          clearThumbCache()
          pictures().clear()
          thumbBytes = -1
        if settingButtons("Memory", ["Free now"], memoryReport(prefix = false)) == 1:
          releaseMemory(mpCritical)
        if settingButtons("Favorites", ["Clear"], countText(favorites.len, "folder")) == 1:
          favorites.setLen(0)
          changed = true
    row:
      spring()
      if button("OK", isDefault = true): settingsOpen = false
  if changed or not settingsOpen: saveSettings()

const keysHelp = """
# Keyboard

| Keys | What they do |
|---|---|
| Enter | Open the folder or file |
| Backspace, Alt+Up | Up one folder |
| Alt+Left / Alt+Right | Back / Forward |
| Ctrl+T / Ctrl+W | New tab / close the tab |
| Ctrl+Tab | The next tab |
| F4, Alt+D, Ctrl+L | Type a path |
| Ctrl+F | Search |
| F9 / F6 | Two panes / the other pane |
| Shift+F5 / Shift+F4 | Cascade / tile the folders' windows (View > Folders in Windows) |
| Ctrl+F6 / Ctrl+F4 | The next window / close it |
| Ctrl+C, Ctrl+X, Ctrl+V | Copy, cut, paste |
| Ctrl+Z | Undo |
| Del / Shift+Del | To the trash / delete for good |
| F2 | Rename (several selected: by a pattern, "Holiday ###") |
| Ctrl+D | Duplicate |
| F3 | Search |
| Alt+P | Preview pane |
| F5 | Refresh |
| Ctrl+A / Ctrl+Shift+A | Select all / select matching (*.jpg) |
| Ctrl+Alt+T | Open a terminal here |
| Ctrl+Shift+N | New folder |
| Alt+Enter | Properties |
| Ctrl+wheel | Larger or smaller icons |
| Ctrl+Plus / Ctrl+Minus / Ctrl+0 | Larger, smaller, normal size |

In the columns view: Left and Right go up and into folders, Up and Down
along the column; type the first letters of a name to go to it.

Viewers: pictures (Left / Right, a slide show), PDF documents (Page Up /
Down, + / -, 0 as wide as the window), videos and sounds (Space plays and
pauses), text, Markdown, zip files.

With a mouse: drag files onto a folder, a tab, the path or the tree to
move them there (hold Ctrl to copy); drag on the empty part of a list to
select with a rectangle.

On a phone: tap opens, a long press shows the menu (keep the finger down
and move it to drag the file somewhere), **Select** in the tool bar puts
check boxes on the rows, and Back goes back a folder.
"""

proc helpDialogs() =
  dialog(keysOpen, "Keyboard", 560):
    markdown(tr(keysHelp))
    row:
      spring()
      if button("OK", isDefault = true): keysOpen = false
  aboutBox(aboutOpen, AppTitle, AppVersion,
           [tr("A file manager made with Retro Nim UI: tabs, two panes, a tree, columns, " &
               "thumbnails of almost every picture, previews, viewers, zip archives and PDFs."),
            tr("Copyright (c) 2026 Sultan Al Isaiee. MIT licence.")],
           tagline = tr("Your files, as in 1994"),
           iconPng = FilesIconPng, glyph = pxFolderOpen,
           whatsNew = [tr("3.3.10: Left pressed twice in the columns (or Up twice) before the folder " &
                            "above is listed goes up two folders, and Back comes back the same way"),
                       tr("3.3.9: Edit > Paste Shortcut -- a link here to each item copied; the tool " &
                            "bar one stop of Tab (the arrows along it), F6 from part to part; emptying the " &
                            "trash no longer goes through a link to a folder"),
                       tr("3.3.8: View > List -- small icons in columns, scrolled sideways; every control " &
                            "reached by Tab and named for screen readers; Thai and Vietnamese names"),
                       tr("3.3.7: covered by another window it draws nothing; the caret rests after 10 " &
                            "seconds untouched; on Android, opened again it comes back as it was"),
                       tr("3.3.6: on a Mac it opens again (it stopped at the first click or key since " &
                            "0.29 of the kit); minimized, it draws nothing"),
                       tr("3.3.5: opens as an Android app again (it closed at its start: it asked for a " &
                            "command line, which an Android app does not have); a report of a fault says " &
                            "the version"),
                       tr("3.3.4: a picture zooms about the mouse; after the viewer (Esc) the keys go on " &
                            "from the file that was opened; a right click elsewhere moves an open menu there; " &
                            "Ctrl+Backspace takes a word; when Files stopped, the next start says why first"),
                       tr("3.3.3: the menus answer at once (a submenu waits only while the pointer heads for it); " &
                            "the letters drawn as before, Sharp text a choice; the Windows 3.1 frame on every desktop"),
                       tr("The menus by the keyboard: Alt (pressed and let go) or F10 opens them, the " &
                            "arrows go along and through them; a menu taller than the screen in even columns, submenus moved up to fit"),
                       tr("The folder tree: a right click (a long press) on a folder: open it in a new tab or " &
                            "window, new folder, paste into it, favorites, its path, terminal, sizes, properties; " &
                            "the pin (Always on Top) works again"),
                       tr("Tabs or Windows: from the tool bar, View > Folders In or the Window menu; each window " &
                            "with a size grip (Folder Options: none, small, medium, large); in a narrow window " &
                            "the search is a button"),
                       tr("Always on Top waits while a window is maximized; room inside the folder tree's frame"),
                       tr("View > Folders in Windows: each folder in a window of its own, as the 3.1 File " &
                            "Manager had them (Window > Cascade, Tile) -- or in tabs, as before"),
                       tr("Always on Top: a folder's window kept over the others (the pin in its title bar, " &
                            "or the Window menu)"),
                       tr("The About box's pages scroll inside their tab; on Windows a tooltip is no longer " &
                            "under the mouse pointer"),
                       tr("The memory no longer grows the longer it is used: what is let go of goes " &
                            "back to the system, the pictures kept follow the device's memory"),
                       tr("Very big pictures (gigapixel scans, huge maps) shown and thumbnailed a band " &
                            "at a time: a few MB instead of their whole size"),
                       tr("Arabic: lines that mix Arabic with numbers read right to left, in their order"),
                       tr("Thumbnails of camera raw photos (CR3, NEF, ARW, DNG...), Photoshop and " &
                            "Retro Photo documents, SVG, JPEG XL, WebP, TIFF, EXR, HEIC and AVIF"),
                       tr("Thumbnails kept on disk: a folder opens at once the second time " &
                            "(Folder Options > Work)"),
                       tr("Smart memory: the caches follow the device's memory and let go when it " &
                            "runs short or the app goes to the background"),
                       tr("Arabic interface, mirrored right to left (Folder Options > Look)"),
                       tr("Tools > Folder Sizes: what takes the room"),
                       tr("Copy To Folder, Move To Folder, Send To, Share, New Markdown Document"),
                       tr("Help > Report a Problem: a fault no longer closes the app"),
                       tr("Faster with very large folders")],
           credits = [RetroCredit & " -- " & RetroWebsite & " -- " & RetroEmail,
                      tr(RetroFontCredit),
                      tr("Icons: Nerd Fonts symbols (MIT / OFL) and Retro's pixel icons.")])
  problemBox(AppTitle, AppVersion)
  discard msgBox(errorOpen, AppTitle, errorText, ["OK"], miStop)
  if tab.special == spFolder and folder.error.len > 0:
    showError(folder.error)
    folder.error = ""

# ---- menus, tool bar, keys --------------------------------------------------------------------

proc setSort(k: SortKey) =
  if sortKey == k: sortDesc = not sortDesc
  else:
    sortKey = k
    sortDesc = false
  eachModel(proc (m: FolderModel) =
    m.sortBy = sortKey
    m.descending = sortDesc
    m.applyView())
  saveSettings()

proc exitApp() =
  saveSettings()
  quitApp()

proc viewsMenu() =
  ## The views, as a menu (the tool bar's Views, View in the menu bar).
  for i in viewOrder:
    if menuItem(viewSteps[i][2], checked = viewStep == i): setView(i)

proc menus() =
  menubar:
    menu "&File":
      let n = if tab.special == spFolder: folder.selectedItems.len else: 0
      if menuItem("&Open", "Enter", enabled = n > 0): openItem(folder.selectedItems[0])
      let oneFile = n == 1 and not folder.selectedItems[0].isDir
      if menuItem("Open &with app...", enabled = oneFile):
        if not openFile(folder.selectedItems[0].path):
          showError(tr("No app to open ") & folder.selectedItems[0].name & ".")
      if platformName() in ["android", "ios"] and menuItem("S&hare...", enabled = oneFile):
        shareSelected()
      submenu "Send &To":
        if menuItem("Compressed (&zipped) folder", enabled = n > 0): zipSelected()
        if menuItem("&Folder...", enabled = n > 0): copyTo(false)
        if twoPanes() and menuItem("The &other pane", enabled = n > 0 and other() != nil):
          toOther(false)
        if menuItem("F&avorites", enabled = n == 1 and folder.selectedItems[0].isDir and
                    folder.selectedItems[0].path notin favorites):
          favorites.add folder.selectedItems[0].path
          saveSettings()
      menuSeparator()
      if windowsShown():
        if menuItem("New &Window", "Ctrl+T"): addTab(active, tabKey(tab))
        if menuItem("&Close the Window", "Ctrl+W", enabled = panes[active].tabs.len > 1):
          closeTab(active, panes[active].at)
      else:
        if menuItem("New &tab", "Ctrl+T"): addTab(active, tabKey(tab))
        if menuItem("&Close the tab", "Ctrl+W", enabled = panes[active].tabs.len > 1):
          closeTab(active, panes[active].at)
      menuSeparator()
      submenu "Ne&w":
        if menuItem("&Folder", "Ctrl+Shift+N", enabled = tab.special == spFolder):
          askName(naNewFolder, tr("New folder"))
        menuSeparator()
        if menuItem("&Text Document", enabled = tab.special == spFolder):
          askName(naNewFile, tr("New Text Document.txt"))
        if menuItem("&Markdown Document", enabled = tab.special == spFolder):
          askName(naNewFile, tr("New Document.md"))
      menuSeparator()
      if menuItem(if n > 1: tr("Rena&me ") & $n & tr(" Items...") else: "Rena&me", "F2", enabled = n > 0): rename()
      if menuItem("D&uplicate", "Ctrl+D", enabled = n > 0): duplicateSelected()
      if menuItem("&Delete", "Del", enabled = n > 0): deleteSelected()
      if menuItem("Delete for &good...", "Shift+Del", enabled = n > 0): deleteSelected(true)
      if menuItem("Propert&ies", "Alt+Enter", enabled = n > 0): showProperties()
      menuSeparator()
      if menuItem("Compress to &ZIP...", enabled = n > 0): zipSelected()
      if menuItem("E&xtract here", enabled = n > 0): unzipSelected()
      menuSeparator()
      if menuItem("&Settings..."): settingsOpen = true
      menuSeparator()
      if menuItem("E&xit", "Alt+F4"): exitApp()
    menu "&Edit":
      if menuItem(undoLabel(), "Ctrl+Z", enabled = canUndo()): undoLast()
      menuSeparator()
      if menuItem("Cu&t", "Ctrl+X"): copySel(true)
      if menuItem("&Copy", "Ctrl+C"): copySel(false)
      if menuItem("&Paste", "Ctrl+V", enabled = clipPaths.len > 0): paste()
      if menuItem("Paste &Shortcut", enabled = clipPaths.len > 0 and not clipCut): pasteShortcut()
      if twoPanes():
        if menuItem("Copy to the &other pane", enabled = other() != nil): toOther(false)
        if menuItem("&Move to the other pane", enabled = other() != nil): toOther(true)
      menuSeparator()
      let any = tab.special == spFolder and folder.selectedItems.len > 0
      if menuItem("Copy To &Folder...", enabled = any): copyTo(false)
      if menuItem("Mo&ve To Folder...", enabled = any): copyTo(true)
      menuSeparator()
      if menuItem("Select &all", "Ctrl+A"): folder.selectAll()
      if menuItem("Select &none"): folder.clearSelection()
      if menuItem("&Invert selection"):
        for m in folder.marked.mitems: m = not m
      if menuItem("Select &Matching...", "Ctrl+Shift+A", enabled = tab.special == spFolder):
        matchOpen = true
      if menuItem("&Select with check boxes", checked = selectMode):
        selectMode = not selectMode
      menuSeparator()
      if menuItem("Copy as pat&h"):
        let p = folder.selectedPaths
        putClipboardText(if p.len > 0: p.join("\n") else: folder.dir)
    menu "&View":
      if not isCompact():
        submenu "&Toolbars":
          if menuItem("&Standard Buttons", checked = showToolbar):
            showToolbar = not showToolbar
            saveSettings()
          if menuItem("&Drive Bar", checked = showDrives):
            showDrives = not showDrives
            saveSettings()
          menuSeparator()
          for lk in [blTextBelow, blTextBeside, blIconOnly, blTextOnly]:
            let nm = case lk
                     of blTextBelow: "Text &Labels (under the icons)"
                     of blTextBeside: "Text &Beside the Icons"
                     of blIconOnly: "&No Text Labels"
                     else: "Text &Only"
            if menuItem(nm, checked = toolbarLook == lk):
              setToolbarLook(lk)
              saveSettings()
        if menuItem("Status &Bar", checked = showStatus):
          showStatus = not showStatus
          saveSettings()
        submenu "&Explorer Bar":
          if menuItem("&Folders", checked = showTree):
            showTree = not showTree
            saveSettings()
          if menuItem("&Preview", "Alt+P", checked = showPreview):
            showPreview = not showPreview
            saveSettings()
          if menuItem("Preview &Follows the Mouse", checked = followHover):
            followHover = not followHover
            saveSettings()
        if menuItem("As &Web Page", checked = webView):
          webView = not webView
          saveSettings()
        menuSeparator()
      viewsMenu()
      menuSeparator()
      submenu "Arrange &Icons":
        if menuItem("by &Name", checked = sortKey == byName): setSort(byName)
        if menuItem("by &Type", checked = sortKey == byKind): setSort(byKind)
        if menuItem("by Si&ze", checked = sortKey == bySize): setSort(bySize)
        if menuItem("by &Date", checked = sortKey == byDate): setSort(byDate)
      if not isCompact():
        if menuItem("T&wo Panes", "F9", checked = twoPanes()): toggleDual()
        submenu "&Folders In":
          foldersInMenu()
      if isCompact():
        if menuItem("&Preview pane", checked = showPreview):
          showPreview = not showPreview
          saveSettings()
      if menuItem("File Name E&xtensions", checked = showExt):
        showExt = not showExt
        eachModel(proc (m: FolderModel) = m.showExtensions = showExt)
        saveSettings()
      if menuItem("&Hidden Files", checked = showHidden):
        showHidden = not showHidden
        eachModel(proc (m: FolderModel) = m.showHidden = showHidden)
        refreshAll()
        saveSettings()
      menuSeparator()
      submenu "&Colors":
        for i, t in builtinThemes:
          if menuItem("&" & t.name, checked = themeIndex() == i):
            ui.theme = t.theme
            invalidate()
            saveSettings()
      if menuItem("&Larger", "Ctrl++"):
        setUiScale(scaleStep(1))
        saveSettings()
      if menuItem("S&maller", "Ctrl+-"):
        setUiScale(scaleStep(-1))
        saveSettings()
      if menuItem("&Normal Size", "Ctrl+0", checked = uiScale() == 100):
        setUiScale(100)
        saveSettings()
      menuSeparator()
      if menuItem("&Refresh", "F5"): refreshAll()
      if menuItem("Folder &Options..."): settingsOpen = true
    menu "&Go":
      if menuItem("&Back", "Alt+Left", enabled = folder.canGoBack): folder.goBack()
      if menuItem("&Forward", "Alt+Right", enabled = folder.canGoForward): folder.goForward()
      if menuItem("&Up", "Backspace", enabled = folder.canGoUp): folder.goUp()
      if menuItem("&Home"): go(getHomeDir())
      if menuItem("This &device"): go(deviceId)
      if menuItem("T&rash"): go(trashId)
      if menuItem("Go &to folder...", "Ctrl+L"): panes[active].editPath = true
      menuSeparator()
      for (name, path) in placeList():
        if menuItem(name): go(path)
    menu "F&avorites":
      let here = folder.dir
      if menuItem("&Add this folder", enabled = here.len > 0 and here notin favorites):
        favorites.add here
        saveSettings()
      if menuItem("&Remove this folder", enabled = here in favorites):
        favorites.delete(favorites.find(here))
        saveSettings()
      if favorites.len > 0: menuSeparator()
      for f in favorites:
        # (a name as it is: its "&" not taken for a mnemonic)
        if menuItem((f.extractFilename & "  (" & f.parentDir & ")").replace("&", "&&")): go(f)
    menu "&Tools":
      submenu "&Find":
        if menuItem("&Files or Folders...", "F3", enabled = tab.special == spFolder):
          panes[active].findNow = true
        if menuItem("In All &Subfolders...", enabled = tab.special == spFolder):
          panes[active].deep = true
          panes[active].findNow = true
      if menuItem("&Go to Folder...", "Ctrl+G"): panes[active].editPath = true
      if canOpenTerminal() and menuItem("Open &Terminal Here", "Ctrl+Alt+T",
                                        enabled = tab.special == spFolder):
        terminalHere()
      menuSeparator()
      if menuItem("Copy as Pat&h"):
        let p = folder.selectedPaths
        putClipboardText(if p.len > 0: p.join("\n") else: folder.dir)
      if menuItem("Compress to &ZIP...", enabled = tab.special == spFolder and folder.selectedItems.len > 0):
        zipSelected()
      menuSeparator()
      if menuItem("Folder &Sizes...", enabled = tab.special == spFolder): openSizes()
      if menuItem("Clear &Thumbnail Cache"):
        clearThumbCache()
        pictures().clear()
        thumbBytes = -1
      if menuItem("Free &Memory"):
        releaseMemory(mpCritical)
        toast(memoryReport(), title = tr("Memory freed"))
      menuSeparator()
      if menuItem("Folder &Options..."): settingsOpen = true
    if windowsShown():
      menu "&Window":
        if menuItem("&New Window", "Ctrl+T"): addTab(active, tabKey(tab))
        if menuItem("&Close the Window", "Ctrl+W", enabled = panes[active].tabs.len > 1):
          closeTab(active, panes[active].at)
        menuSeparator()
        foldersInMenu(arrange = false)
        menuSeparator()
        mdiWindowMenu("files")
    elif not isCompact():
      menu "&Window":
        if menuItem("New &Tab", "Ctrl+T"): addTab(active, tabKey(tab))
        if menuItem("&Close the Tab", "Ctrl+W", enabled = panes[active].tabs.len > 1):
          closeTab(active, panes[active].at)
        menuSeparator()
        foldersInMenu()
        if panes[active].tabs.len > 0: menuSeparator()
        for i, t in panes[active].tabs:
          if i >= 9: break
          let (_, l) = tabLabel(t)
          if menuItem("&" & $(i + 1) & " " & l.replace("&", "&&"), checked = i == panes[active].at):
            panes[active].at = i
            syncQuery(active)
    menu "&Help":
      if menuItem("&Keyboard", "F1"): keysOpen = true
      if menuItem("&What's New"): aboutOpen = true
      if menuItem("&Report a Problem..."): reportProblem()
      if menuItem("Retro Files on the &Web"): discard openUrl("https://" & RetroWebsite)
      menuSeparator()
      if menuItem("&About " & AppTitle): aboutOpen = true

proc selectionTools(s: float) =
  ## On a phone, while items are selected: what can be done with them.
  let n = folder.markedCount
  if toolButton(pxCheck, "Done (select none)", size = s):
    folder.clearSelection()
    selectMode = false
  if toolButton($n, countText(n, "item") & tr(" selected: select all"), bold = true,
                size = 1.1):
    folder.selectAll()
  toolSeparator()
  if toolButton(pxCut, "Cut", size = s): copySel(true)
  if toolButton(pxCopy, "Copy", size = s): copySel(false)
  if toolButton(pxTrash, "Delete", size = s): deleteSelected()
  if toolButton(pxRename, "Rename", size = s, enabled = n == 1): rename()
  if platformName() == "android" and
     toolButton(pxShare, "Share", size = s, enabled = n == 1 and not folder.selectedItems[0].isDir):
    discard shareFile(folder.selectedItems[0].path)
  if toolButton(pxProperties, "Properties", size = s): showProperties()

proc tools() =
  ## The tool bar: on a phone, icons; elsewhere Explorer 98's Standard
  ## Buttons -- the labels under the icons, beside them, or none (View >
  ## Toolbars > Text Labels).
  if not showToolbar and not isCompact(): return
  toolbar:
    let s = 1.3
    let narrow = isCompact()
    if narrow and tab.special == spFolder and folder.markedCount > 0:
      selectionTools(s)
    elif narrow:
      if toolButton(pxBack, "Back", size = s, enabled = folder.canGoBack): folder.goBack()
      if toolButton(pxUp, "Up one folder", size = s, enabled = folder.canGoUp): folder.goUp()
      if toolButton(pxHome, "Places", size = s): placesOpen = true
      if toolButton(pxFolderPlus, "New folder", size = s, enabled = tab.special == spFolder):
        askName(naNewFolder, tr("New folder"))
      if toolButton(pxCopy, "Copy", size = s): copySel(false)
      if toolButton(pxPaste, "Paste", size = s, enabled = clipPaths.len > 0): paste()
      if toolButton(pxTrash, "Delete (to the trash)", size = s): deleteSelected()
      if toolButton(pxUndo, undoLabel() & " (Ctrl+Z)", size = s, enabled = canUndo()): undoLast()
      if toolButton(if viewStep >= 2: pxDetails else: pxIcons, "View", size = s):
        setView(if viewStep >= 2: 0 else: 3)
      if toolButton(pxPreview, "Preview pane", size = s, down = showPreview):
        showPreview = not showPreview
        saveSettings()
      if ui.touch:
        if toolButton(pxSelect, "Select", size = s, down = selectMode):
          selectMode = not selectMode
      if toolButton(pxSettings, "Settings", size = s): settingsOpen = true
    else:
      let sel = tab.special == spFolder and folder.selectedItems.len > 0
      if barButton(pxBack, "Back", "Back (Alt+Left)", enabled = folder.canGoBack): folder.goBack()
      if barButton(pxForward, "Forward", "Forward (Alt+Right)", enabled = folder.canGoForward):
        folder.goForward()
      if barButton(pxUp, "Up", "Up one folder (Backspace)", enabled = folder.canGoUp): folder.goUp()
      toolSeparator()
      if barButton(pxCut, "Cut", "Cut (Ctrl+X)", enabled = sel): copySel(true)
      if barButton(pxCopy, "Copy", "Copy (Ctrl+C)", enabled = sel): copySel(false)
      if barButton(pxPaste, "Paste", "Paste (Ctrl+V)", enabled = clipPaths.len > 0): paste()
      toolSeparator()
      if barButton(pxUndo, "Undo", undoLabel() & " (Ctrl+Z)", enabled = canUndo()): undoLast()
      toolSeparator()
      if barButton(pxRename, "Rename", "Rename (F2; several: by a pattern)", enabled = sel): rename()
      if barButton(pxTrash, "Delete", "Delete: to the trash (Del)", enabled = sel): deleteSelected()
      if barButton(pxProperties, "Properties", "Properties (Alt+Enter)", enabled = sel or tab.special == spFolder):
        showProperties()
      toolSeparator()
      if barButton(pxRefresh, "Refresh", "Refresh (F5)"): refreshAll()
      if barButton(pxIcons, "Views", "Views: how the files are shown"):
        openPopupMenu("viewsbtn", ui.lastRect.x, ui.lastRect.y + ui.lastRect.h)
      popupMenu("viewsbtn"): viewsMenu()
      toolSeparator()
      if barButton(pxFolderPlus, "New Folder", "New folder (Ctrl+Shift+N)", enabled = tab.special == spFolder):
        askName(naNewFolder, tr("New folder"))
      if barButton(pxTree, "Folders", "The folder tree", down = showTree):
        showTree = not showTree
        saveSettings()
      if barButton(pxTwoPanes, "Two Panes", "Two panes (F9)", down = twoPanes()): toggleDual()
      # tabs or windows: the folders as tabs, or as windows of their own
      if barButton(pxWindow, (if inWindows: "Windows" else: "Tabs"),
                   "The folders in tabs, or in windows of their own"):
        openPopupMenu("foldersin", ui.lastRect.x, ui.lastRect.y + ui.lastRect.h)
      popupMenu("foldersin"): foldersInMenu()
      if barButton(pxPreview, "Preview", "Preview pane (Alt+P)", down = showPreview):
        showPreview = not showPreview
        saveSettings()
      if barButton(pxSearch, "Search", "Find files or folders (F3)", enabled = tab.special == spFolder):
        panes[active].findNow = true
      if barButton(pxSettings, "Options", "Folder options"): settingsOpen = true

proc keys() =
  if not canInput() or ui.keyUsed: return
  let ctrl = CtrlPressed in ui.mods
  let alt = AltPressed in ui.mods
  let shift = ShiftPressed in ui.mods
  case ui.key
  of KeyBackspace: folder.goUp(); ui.keyUsed = true
  of KeyUp:
    if alt: folder.goUp(); ui.keyUsed = true
  of KeyLeft:
    if alt: folder.goBack(); ui.keyUsed = true
  of KeyRight:
    if alt: folder.goForward(); ui.keyUsed = true
  of KeyDelete: deleteSelected(forever = shift); ui.keyUsed = true
  of KeyF2: rename(); ui.keyUsed = true
  of KeyF3:
    # (Explorer: Find)
    panes[active].findNow = true
    ui.keyUsed = true
  of KeyP:
    if alt:
      showPreview = not showPreview
      saveSettings()
      ui.keyUsed = true
  of KeyG:
    if ctrl:
      panes[active].editPath = true
      ui.keyUsed = true
  of KeyA:
    if ctrl and shift and tab.special == spFolder:
      matchOpen = true
      ui.keyUsed = true
    elif ctrl and tab.special == spFolder:
      folder.selectAll()
      ui.keyUsed = true
  of KeyF4:
    if shift and windowsShown(): mdiTile("files")
    else: panes[active].editPath = true
    ui.keyUsed = true
  of KeyF5:
    if shift and windowsShown(): mdiCascade("files")
    else: refreshAll()
    ui.keyUsed = true
  of KeyF6:
    if twoPanes(): active = 1 - active
    ui.keyUsed = true
  of KeyF9: toggleDual(); ui.keyUsed = true
  of KeyF1: keysOpen = true; ui.keyUsed = true
  of KeyEnter:
    if alt: showProperties(); ui.keyUsed = true
  of KeyC:
    if ctrl: copySel(false); ui.keyUsed = true
  of KeyX:
    if ctrl: copySel(true); ui.keyUsed = true
  of KeyV:
    if ctrl: paste(); ui.keyUsed = true
  of KeyZ:
    if ctrl: undoLast(); ui.keyUsed = true
  of KeyT, KeyN:
    if ctrl and alt and ui.key == KeyT and canOpenTerminal(): terminalHere(); ui.keyUsed = true
    elif ctrl and shift and ui.key == KeyN: askName(naNewFolder, tr("New folder")); ui.keyUsed = true
    elif ctrl: addTab(active, tabKey(tab)); ui.keyUsed = true
  of KeyW:
    if ctrl: closeTab(active, panes[active].at); ui.keyUsed = true
  of KeyL, KeyD:
    if (ctrl and ui.key == KeyL) or (alt and ui.key == KeyD):
      panes[active].editPath = true
      ui.keyUsed = true
    elif ctrl and ui.key == KeyD:
      duplicateSelected()
      ui.keyUsed = true
  of KeyF:
    if ctrl:
      panes[active].findNow = true
      ui.keyUsed = true
  else: discard

# ---- the window ----------------------------------------------------------------------------------

proc storageBanner(): bool =
  ## Android: until the user allows it, the app sees only its own folder.
  if canSeeFiles(): return false
  case banner(AppTitle & tr(" needs permission to show and manage the files on this " &
                            "device. Android asks once; you can change it later in the settings."),
              bkWarning, ["Allow access", "Use the app's folder"], closable = false)
  of 1: requestStorageAccess()
  of 2: go(dataDir(AppId))
  else: discard
  wakeIn(1000)
  emptyState(pxLock, tr("No access to the files yet."))
  true

proc status() =
  var left = ""
  case tab.special
  of spDevice: left = countText(placeList().len, "place")
  of spTrash: left = countText(trashBox.items.len, "item") & tr(" in the trash")
  of spFolder:
    left = countText(folder.items.len, "item")
    let n = folder.markedCount
    if n > 0:
      var bytes = 0'i64
      for f in folder.selectedItems: bytes += f.size
      left.add tr(", ") & $n & tr(" selected (") & sizeText(bytes) & ")"
    if folder.loadingFor > 150: left = tr("Reading the folder...")
  let space = if tab.special == spFolder: diskSpaceCached(folder.dir) else: (0'i64, 0'i64)
  let free = if space.total > 0: sizeText(space.free) & tr(" free of ") & sizeText(space.total)
             else: ""
  let clipInfo = if clipPaths.len > 0:
      (if clipCut: tr("Cut: ") else: tr("Copied: ")) & $clipPaths.len else: ""
  # (the zone, as Explorer's "My Computer": the place the folder is in)
  var zone = ""
  if tab.special == spFolder:
    var best = 0
    for (name, path) in placeList():
      if (folder.dir == path or folder.dir.startsWith(path & DirSep)) and path.len > best:
        best = path.len
        zone = tr(name)
  if isCompact(): statusbar(left)
  elif not showStatus: discard
  elif clipInfo.len > 0: statusbar(left, clipInfo, free, zone)
  else: statusbar(left, free, zone)

proc pane(p: int) =
  paneTop(p)
  paneBody(p)

proc driveStrip() =
  ## The places as a bar of buttons (as the drive bar of the old file
  ## managers); files dropped on one go there.
  if not showDrives or isCompact(): return
  let cur = if tab.special == spFolder: folder.dir
            elif tab.special == spTrash: trashId else: deviceId
  let ev = driveBar(cur, favorites, extra = [(tr("Trash"), pxTrash, trashId)])
  if ev.picked.len > 0: go(ev.picked)
  if ev.drop.dropped: dropFiles(ev.drop)

proc folderWindows() =
  ## The folders as windows of their own (View > Folders in Windows): each
  ## tab of the first pane a window -- its address bar, its files, its
  ## preview; the one in front is the one the commands act on.
  let first = panes[0].tabs[clamp(panes[0].at, 0, panes[0].tabs.high)]
  let edit = panes[0].editPath
  let find = panes[0].findNow
  var q = panes[0].query                 # (the search box of the one in front, as it is)
  var deep = panes[0].deep
  var shut: seq[Tab]
  var wantsFind: Tab                   # (a window whose search is to take the keys: its button pressed)
  let all = panes[0].tabs              # (a window may open or close one while it is drawn)
  mdiArea(-1, "files"):
    let a = mdiAreaRect("files")
    for t in all:
      let k = panes[0].tabs.find(t)
      if k < 0: continue
      let (g, l) = tabLabel(t)
      t.win.title = if t.special == spFolder and tabKey(t).len > 0: tabKey(t) else: l   # (3.1's: the path)
      t.win.glyph = g
      t.win.flush = true
      # (the size grip at the lower right: always there, as big as asked -- Folder Options)
      t.win.grip = winGrip > 0
      t.win.gripSize = dp([0, 12, 18, 26][clamp(winGrip, 0, 3)])
      if t.win.r.w <= 0 and a.w > 0:
        # (a new one: cascaded from the others, three quarters of the room)
        let step = FontH + dp(9)
        let n = k mod 6
        t.win.r = rect(n * step, n * step, max(dp(260), a.w * 3 div 4), max(dp(200), a.h * 3 div 4))
      # (drawn as the tab shown: its own address bar and search)
      panes[0].at = k
      if t == first:
        panes[0].query = q
        panes[0].deep = deep
      else: syncQuery(0)
      panes[0].editPath = edit and t == first
      panes[0].findNow = find and t == first
      mdiWindow(t.win):
        withId("win" & $cast[uint](t)):
          paneTop(0, strip = false, key = "w" & $cast[uint](t))
          let show = showPreview and viewSteps[viewStep][0] != fvColumns and
                     (paneBeside(previewW) or folder.markedCount > 0)
          sidePane(show, previewW, previewH):
            paneBody(0)
          do:
            preview()
      if t == first:
        q = panes[0].query
        deep = panes[0].deep
      if panes[0].findNow: wantsFind = t
      if not t.win.open: shut.add t
  # closed by its box (Ctrl+F4): the last one stays
  for t in shut:
    let k = panes[0].tabs.find(t)
    if k < 0: continue
    if panes[0].tabs.len > 1: closeTab(0, k)
    else: t.win.open = true
  # the window in front: the folder of the commands
  var now = -1
  for k, t in panes[0].tabs:
    if mdiIsActive(t.win, "files"): now = k
  if now < 0: now = panes[0].tabs.find(first)
  panes[0].at = clamp(now, 0, panes[0].tabs.high)
  panes[0].editPath = false
  panes[0].findNow = (wantsFind != nil and wantsFind == tab) or (find and tab.special != spFolder)
  if tab == first:
    panes[0].query = q
    panes[0].deep = deep
  else: syncQuery(0)

proc content() =
  ## The tree, the panes and the preview, as the room allows: the preview
  ## beside the list when there is room, else under it (then only for what
  ## is selected); two panes leave the preview out.
  driveStrip()
  let tree = showTree and not isCompact()
  template main() =
    if windowsShown():
      folderWindows()
    elif twoPanes():
      if dualAt <= 0: dualAt = available() div 2
      split(dualAt, -1):
        pane(0)
      do:
        pane(1)
    else:
      paneTop(active)
      let show = showPreview and viewSteps[viewStep][0] != fvColumns and
                 (paneBeside(previewW) or folder.markedCount > 0)
      sidePane(show, previewW, previewH):
        paneBody(active)
      do:
        preview()
  if tree:
    split(treeW, -1):
      treePane()
    do:
      main()
  else:
    main()

proc startFolder(saved: string): string =
  # (a folder on the command line -- a desktop's "open this folder", a
  # file's folder -- first)
  # (an Android app has no command line: appArguments, not paramCount)
  let args = appArguments()
  if args.len >= 1:
    let arg = args[0]
    if dirExists(arg): return absolutePath(arg)
    if fileExists(arg): return absolutePath(arg).parentDir
  let storage = "/storage/emulated/0"
  let android = platformName() == "android"
  case startIn
  of siLast:
    if saved.len > 0 and dirExists(saved): return saved
  of siHome:
    if not android: return getHomeDir()
  of siStorage: discard
  if android:
    if storageAccess() and dirExists(storage): storage
    else: dataDir(AppId)                      # the one folder it may see
  elif platformName() == "ios": dataDir(AppId)
  else: getHomeDir()

proc restoreTabs(saved: string; fresh = false) =
  ## (`fresh`: the last run stopped and the user chose to start without
  ## what was open -- the start folder alone)
  for p in 0 .. 1:
    if fresh: break
    for key in prefs.get("tabs" & $p).split('\n'):
      if key.len == 0: continue
      if key == deviceId or key == trashId or (startIn == siLast and (dirExists(key) or isDocPath(key))):
        panes[p].tabs.add newTab(key)
    panes[p].at = clamp(prefs.getInt("tab" & $p, 0), 0, max(0, panes[p].tabs.high))
  if panes[0].tabs.len == 0: panes[0].tabs.add newTab(startFolder(if fresh: "" else: saved))
  elif startIn != siLast:
    panes[0].tabs[panes[0].at].m.open(startFolder(saved))
  if dual and panes[1].tabs.len == 0: panes[1].tabs.add newTab(startFolder(saved))
  active = if dual: clamp(prefs.getInt("active", 0), 0, 1) else: 0
  for p in 0 .. 1:
    if panes[p].tabs.len > 0: syncQuery(p)

var hadAccess = false            # (Android: whether the files could be seen the last frame)
var savedAtStart = ""            # (the folder last shown: brought back after the "stopped" screen)
var tabsWaiting = false          # (the last run stopped: its tabs wait for Start)

proc filesStart*() =
  ## The window opened, the settings read, the tabs restored (the tests
  ## call it, and then `filesFrame` for each frame).
  const iconPng = staticRead("assets/filemanager-icon.png")
  windowIcon = windowIconFromPng(iconPng)   # (the taskbar's picture)
  addPdfPreviews()                          # (PDFs' first pages as their pictures)
  addMorePictures()                         # (raw photos, PSD, SVG, JPEG XL, WebP...)
  reportedVersion = AppVersion
  reportedVersion = AppVersion           # (for a fault's report)
  startApp(AppTitle, 1100, 700)
  addVideoPreviews()                        # (videos' pictures, where they can be had)
  let saved = loadSettings()
  applyLanguage()
  applyThumbCache()
  try: removeDir(cacheDir()) except OSError: discard
  # (the last run stopped: what it had open waits for the "stopped" screen's
  # Start -- one of them may be what stopped it)
  if stoppedPending():
    savedAtStart = saved
    tabsWaiting = true
  else:
    restoreTabs(saved)
  hadAccess = storageAccess()

proc filesFrame*() =
  ## One frame of the program (between `beginFrame` and `endFrame`).
  if stoppedFrame(): return
  if tabsWaiting:
    tabsWaiting = false
    restoreTabs(savedAtStart, fresh = startFresh())
  captionBar()
  if canSeeFiles() != hadAccess:
    hadAccess = canSeeFiles()
    forgetFolderTree()
    if hadAccess and dirExists("/storage/emulated/0"): go("/storage/emulated/0")
  if (dual and isCompact()) or windowsShown(): active = 0
  runJob()
  if tabKey(tab) != savedDir or (ui.paused and not pausedSaved):
    # phones may end the app without asking: keep the settings current
    savedDir = tabKey(tab)
    pausedSaved = ui.paused
    saveSettings()
  if not ui.paused: pausedSaved = false
  # the mouse's side buttons: back and forward
  if mouseBack():
    if viewer != vkNone: closeViewer()
    elif tab.special == spFolder: folder.goBack()
  if mouseForward() and viewer == vkNone and tab.special == spFolder:
    folder.goForward()
  # (a fault of the program: written in its fault log, the frame put back
  # -- it goes on: Help > Report a Problem)
  guarded("Retro Files " & AppVersion):
    if viewer != vkNone:
      viewerScreen()
    else:
      let (_, l) = tabLabel(tab)
      setTitle(l & " - " & AppTitle)
      menus()
      tools()
      status()
      if not storageBanner(): content()
      keys()
  guarded("Retro Files dialogs"):
    nameDialog()
    deleteDialog()
    propertiesDialog(propsOpen, propsItems)
    settingsDialog()
    placesDialog()
    batchDialog()
    matchDialog()
    pickDialog()
    sizesDialog()
  helpDialogs()
  if ui.lastFault.len > 0:
    toast(tr("Something went wrong -- kept in the fault log: Help > Report a Problem"),
          title = ui.lastFault)
    ui.lastFault = ""
  # the phone's Back: out of the viewer, then back through the folders;
  # Exit and the close box end the app
  if backPressed():
    if viewer != vkNone:
      cancelClose()
      closeViewer()
    elif tab.special != spFolder and folder.dir.len > 0:
      cancelClose()
      tab.special = spFolder
    elif folder.canGoBack:
      cancelClose()
      folder.goBack()

proc filesStop*() =
  ## The settings kept, the window closed.
  saveSettings()
  stopApp()

proc main() =
  filesStart()
  while beginFrame():
    filesFrame()
    endFrame()
  filesStop()

when isMainModule: main()

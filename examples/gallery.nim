## Every retro control in one window.
##
##   nimble gallery            (or: nim c -r examples/gallery.nim)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, os, json, math]
import retroui
import retroui/tilemap

const
  languages = ["English", "Deutsch", "Français", "Español", "Italiano",
               "Português", "Nederlands", "Svenska", "Suomi", "Dansk"]
  files = ["AUTOEXEC.BAT\t1 KB\t10/26/26", "CONFIG.SYS\t1 KB\t10/26/26",
           "README.TXT\t4 KB\t10/24/26", "GALLERY.NIM\t9 KB\t10/27/26",
           "RETRO.NIM\t1 KB\t10/27/26", "WIDGETS.NIM\t38 KB\t10/27/26",
           "CORE.NIM\t21 KB\t10/27/26", "GFX.NIM\t11 KB\t10/27/26",
           "FONT.NIM\t44 KB\t10/27/26", "ICONS.NIM\t4 KB\t10/27/26",
           "LICENSE\t2 KB\t10/27/26", "NOTES.TXT\t1 KB\t10/20/26"]
  palette = [color(0, 0, 0), color(128, 0, 0), color(0, 128, 0),
             color(128, 128, 0), color(0, 0, 128), color(128, 0, 128),
             color(0, 128, 128), color(192, 192, 192), color(128, 128, 128),
             color(255, 0, 0), color(0, 255, 0), color(255, 255, 0),
             color(0, 0, 255), color(255, 0, 255), color(0, 255, 255),
             color(255, 255, 255)]

var
  wellColor = color(0, 128, 128)
  priceLo = 50
  priceHi = 300
  tagList = @["nim", "retro"]
  tagText = ""
  acCity = ""
  volumeKnob = 60
  openSection = 0
  tab = (try: parseInt(getEnv("GALLERY_TAB", "0")) except ValueError: 0)
    ## the page shown first (GALLERY_TAB=10 starts on Records: for screenshots)
  name = "Untitled project"
  secret = "hunter2"
  copies = 2
  notes = "Windows 3.1 style widgets\nfor Nim, drawn by retro.\n\n" &
          "Fast, tiny, and pixel-\nidentical on Windows,\nmacOS and Linux.\n\n" &
          "Try the keyboard: Tab,\nAlt + underlined letters,\nF10, arrows, Space."
  autoSave = true
  showGrid = false
  backups = true
  size = 1
  volume = 40
  zoomLevel = 3
  scrollPos = 30
  lang = 0
  fileSel = 3
  progress = 0.62
  running = false
  boldOn = true
  italicOn = false
  scheme = 0
  showAbout = false
  showLook = false          # View > Appearance
  showConfirm = false
  showDelete = false
  status = "Ready"
  colorSel = 4

var
  wifi = true
  bluetooth = false
  period = 1
  stars = 4
  query = ""
  tags = @["nim", "retro", "ui", "android"]
  tagOn = @[true, false, true, false]
  pickColor = color(0, 128, 128)
  hour = 9
  minute = 30
  advancedOpen = false
  expert = false
  mdText = """
# Markdown

Text with **bold**, *italic*, ~~strike~~, `code` and a [link](https://nim-lang.org).

- [x] Headings, lists and task lists
- [ ] Tables, quotes and code blocks
- Nested lists
  1. one
  2. two

> A quote.

| File | Size |
|:-----|-----:|
| notes.txt | 1 KB |
| photo.png | 2 MB |

```nim
echo "Hello"
```

مرحبا **بالعالم** -- Arabic paragraphs read right to left.
"""

var
  orderCols = @[column("Order", 60, alRight), column("Customer", 150),
                column("Due", 84), column("Total", 90, alRight, editable = true)]
  orders = @[@["1001", "Al Noor Trading", "03/01/2026", "1,541.45"],
             @["1002", "Salalah Fisheries", "09/01/2026", "122.82"],
             @["1003", "Gulf Print House", "20/01/2026", "738.93"],
             @["1004", "Muscat Office Supply", "02/02/2026", "1,958.63"],
             @["1005", "Ibri Builders", "22/02/2026", "1,583.32"],
             @["1006", "Nizwa Dates Co.", "06/03/2026", "821.29"],
             @["1007", "Sohar Steel", "05/04/2026", "1,441.98"],
             @["1008", "Sur Boatworks", "04/05/2026", "769.30"],
             @["1009", "Al Noor Trading", "13/07/2026", "306.17"],
             @["1010", "Gulf Print House", "21/08/2026", "1,839.11"]]
  orderSel = 0
  orderSort = (col: 0, desc: false)
  treeSel = "Company/Sales/Invoices"
  open1, open2 = true
  open3 = false
  due = today()
  amount = 1234.5
  qty = 12
  city = ""
  cities = ["Muscat", "Salalah", "Sohar", "Nizwa", "Sur", "Ibri", "Barka",
            "Rustaq", "Bahla", "Khasab"]
  channels = ["Email", "Phone", "Post", "Fax", "Visit"]
  channelOn = @[true, false, true, false, false]
  sales = [12.0, 19, 8, 15, 22, 17]
  months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]

var
  notify = true
  syncEvery = 1
  brightness = 70
  step = 1
  page = 3
  navSel = 0
  phoneBars = false
  pickOpen = false
  picked = ""
  bannerShown = true
  lookOpen = false

# ---- the Files tab: the file widgets on a sandbox folder of their own -------------

var
  filesMode = 0
  sandbox = ""
  leftM, rightM, focusM: FolderModel
  boxSel = 0
  zoomStep = 1                 # Details, Tiles, Icons 48, 72, 128
  sideOn = true
  sideW = 230
  sideH = 170
  listsAt = 0
  placesAt = 0
  placesSel = ""
  fJob: FileJob
  trash: TrashList

const
  boxNames = ["Inbox", "Archive", "Pictures"]
  zoomSteps = [(fvDetails, 0), (fvTiles, 0), (fvIcons, 48), (fvIcons, 72), (fvIcons, 128)]

const GalleryIconPng = staticRead("assets/gallery-icon.png")   ## (the About box's icon)

proc samplePicture(w, h, seed: int): Bitmap =
  ## A made-up photo: a gradient with bubbles.
  result = newBitmap(w, h)
  const bases = [(40, 110, 200), (200, 70, 60), (120, 60, 180), (30, 140, 90)]
  const dots = [0xFFFFD34E'u32, 0xFFFFFFFF'u32, 0xFF1B1B3A'u32, 0xFFFF8FA3'u32]
  let (r0, g0, b0) = bases[seed mod bases.len]
  for y in 0 ..< h:
    for x in 0 ..< w:
      let t = (x + y) * 70 div (w + h)
      result.px[y * w + x] = 0xFF000000'u32 or uint32(min(255, r0 + t)) shl 16 or
                             uint32(min(255, g0 + t)) shl 8 or uint32(min(255, b0 + t))
  var s = uint32(seed * 7919 + 13)
  template rnd(n: int): int =
    s = s * 1103515245'u32 + 12345'u32
    int((s shr 8) mod uint32(n))
  for k in 0 ..< 10:
    let cx = rnd(w)
    let cy = rnd(h)
    let rad = 8 + rnd(h div 4)
    let c = dots[rnd(dots.len)]
    for y in max(0, cy - rad) ..< min(h, cy + rad):
      for x in max(0, cx - rad) ..< min(w, cx + rad):
        if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= rad * rad: result.px[y * w + x] = c
  result.changed()

proc makeSandbox(reset = false) =
  ## A few folders and files to drag around, in the gallery's own folder.
  sandbox = dataDir("gallery") / "Sandbox"
  try:
    createDir(sandbox)
    if not fileExists(sandbox.parentDir / "sample.png"):
      savePng(samplePicture(160, 160, 2), sandbox.parentDir / "sample.png")
    if reset and dirExists(sandbox): removeDir(sandbox)
    if dirExists(sandbox / boxNames[0]): return
    for b in boxNames: createDir(sandbox / b)
    writeFile(sandbox / "Inbox" / "Welcome.md", "# Welcome\n\nDrag this file to the " &
      "**Archive** list, onto a tab, or onto a folder of the path bar.\n\n" &
      "- Hold *Ctrl* to copy instead of moving\n- *Delete* sends it to the trash\n" &
      "- *Undo* puts it back\n")
    writeFile(sandbox / "Inbox" / "Shopping list.txt", "Dates\nCardamom\nCoffee\nSaffron\n")
    writeFile(sandbox / "Inbox" / "Budget 2026.csv", "Month,Amount\nJan,120\nFeb,95\nMar,140\n")
    createDir(sandbox / "Inbox" / "Projects")
    writeFile(sandbox / "Inbox" / "Projects" / "Plan.txt", "1. Sketch\n2. Build\n3. Ship\n")
    writeFile(sandbox / "Archive" / "Old notes.txt", "Written in 2025.\n")
    createDir(sandbox / "Archive" / "2025")
    for i, n in ["Beach", "Sunset", "Garden", "Night"]:
      savePng(samplePicture(320, 220, i), sandbox / "Pictures" / (n & ".png"))
  except OSError, IOError:
    discard

proc refreshFiles() =
  if leftM != nil: leftM.reload()
  if rightM != nil: rightM.reload()
  if trash != nil: trash.reload()

proc startFilesJob(j: FileJob) =
  if j != nil and fJob == nil: fJob = j

proc filesJob() =
  ## The running copy / move / trash: its progress box, then a balloon.
  if fJob != nil and runJobDialog(fJob, jobTitle(fJob.kind)):
    let j = fJob
    fJob = nil
    remember(j)                                   # for Undo
    refreshFiles()
    if j.errors.len > 0: toast(jobSummary(j), glyph = pxWarning, title = "Files")
    elif j.state == jsDone: toast(jobSummary(j), glyph = pxCheck, title = "Files")

proc fileListOf(m: FolderModel; key: string) =
  ## A path bar over a file list; both take dropped files.
  let pb = pathBar(m.dir, key = key)
  if pb.go.len > 0: m.open(pb.go)
  if pb.drop.dropped: startFilesJob(jobFor(pb.drop))
  if pb.error.len > 0: toast(pb.error, glyph = pxWarning, title = "Path")
  let (view, px) = zoomSteps[zoomStep]
  let ev = fileList(m, view, iconSize = px, tapActivates = ui.touch)
  if ev.activated:
    if ev.item.isDir: m.open(ev.item.path)
    else: discard openFile(ev.item.path)
  if ev.zoom != 0: zoomStep = clamp(zoomStep + ev.zoom, 0, zoomSteps.high)
  if ev.drop.dropped: startFilesJob(jobFor(ev.drop))
  if ev.renamed and ev.error.len > 0: toast(ev.error, glyph = pxWarning, title = "Rename")
  if ev.selChanged or m.hot >= 0 or (ui.pressed and mouseIn(ui.lastRect)): focusM = m

proc filesTab() =
  if leftM == nil:
    makeSandbox()
    leftM = newFolderModel(sandbox / boxNames[0])
    rightM = newFolderModel(sandbox / boxNames[1])
    focusM = leftM
    trash = newTrashList()
  if segmented(["Two lists", "This device", "Trash"], filesMode) and filesMode == 2:
    trash.reload()
  case filesMode
  of 0:
    row:
      var seg = min(zoomStep, 2)
      if segmented(["Details", "Tiles", "Icons"], seg): zoomStep = seg
      let some = focusM.selectedPaths.len > 0
      if button(pxTrash & " Delete", enabled = some):
        startFilesJob(newJob(jkTrash, focusM.selectedPaths))
      tooltip "To the trash (Undo brings it back)"
      if button(pxUndo & " Undo", enabled = canUndo()):
        let u = undo()
        refreshFiles()
        if u.error.len > 0: toast(u.error, glyph = pxWarning, title = "Undo")
      if not isCompact(): checkbox("Details pane", sideOn)
      if button("Reset"):
        makeSandbox(reset = true)
        leftM.open(sandbox / boxNames[boxSel])
        rightM.open(sandbox / boxNames[1])
    paragraph(if ui.touch: "Hold a file until its menu opens, then drag it to the " &
                           "other list, a tab or a folder of the path."
              else: "Drag files between the lists, onto a tab or a folder of the path " &
                    "(Ctrl copies). Ctrl + wheel sizes the icons; resting the mouse on a " &
                    "file shows it in the details pane.", color = ui.theme.gray)
    let tv = tabStrip(boxNames, boxSel, [pxInbox, pxArchive, pxPictures],
                      closable = false, addButton = false, dropKind = "files")
    if tv.selected: leftM.open(sandbox / boxNames[boxSel])
    if tv.dropOn >= 0:
      startFilesJob(jobFor(FileDrop(paths: ui.drag.items, into: sandbox / boxNames[tv.dropOn],
                                    copy: dragCopies())))
    sidePane(sideOn and not isCompact(), sideW, sideH):
      if isCompact():
        fileListOf(leftM, "gallery-left")
      else:
        if listsAt <= 0: listsAt = available() div 2
        split(listsAt, -1):
          col:
            fileListOf(leftM, "gallery-left")
        do:
          col:
            fileListOf(rightM, "gallery-right")
    do:
      discard filePreview(focusM, buttons = false)
  of 1:
    if isCompact():
      let f = placesView([sandbox], key = "gallery")
      if f.len > 0:
        leftM.open(f)
        filesMode = 0
    else:
      if placesAt <= 0: placesAt = dp(220)
      split(placesAt, -1):
        # (room inside its frame; a right click or a long press: its menu)
        let ev = folderTree(placesSel, [sandbox], padding = dp(4))
        # (a right click picks the folder for its menu: the lists wait)
        if ev.picked and dirExists(placesSel) and not ui.rpressed and not longPressed():
          leftM.open(placesSel)
          filesMode = 0
        if ev.drop.dropped: startFilesJob(jobFor(ev.drop))
        contextMenu:
          let isDir = dirExists(placesSel)
          if menuItem("&Open in the Left List", enabled = isDir):
            leftM.open(placesSel)
            filesMode = 0
          if menuItem("Open in the &Right List", enabled = isDir):
            rightM.open(placesSel)
            filesMode = 0
          menuSeparator()
          if menuItem("&Copy as Path", enabled = placesSel.len > 0):
            putClipboardText(placesSel)
            toast("Copied " & placesSel, glyph = pxCopy)
      do:
        let f = placesView([sandbox], key = "gallery")
        if f.len > 0:
          leftM.open(f)
          filesMode = 0
  else:
    paragraph("The system's trash: what Delete sends there. Restore items, or " &
              "delete them for good.", color = ui.theme.gray)
    let te = trashList(trash)
    if te.changed: refreshFiles()
    if te.error.len > 0: toast(te.error, glyph = pxWarning, title = "Trash")


# ---- the Charts page ----------------------------------------------------------------------------

const chMonths = ["Jan", "Feb", "Mar", "Apr", "May", "Jun"]
var chKind = 0
var chEvent = "Hover or click a chart."

# ---- the Records page: business data controls ---------------------------------------------------

var
  ordCols = @[column("Order", 150), column("Date", 80), numberColumn("Amount", 80),
                colorColumn("DA", 30), colorColumn("PD", 30), colorColumn("MA", 30),
                checkColumn("S", 30),
                choiceColumn("Store", ["Engineering", "Kitchen", "Cafeteria", "Banquet"], 110),
                progressColumn("Paid", 80), buttonColumn("", 60)]
  ordRows = @[
    @["Pool area glass door", "01/10/2026", "70.000", "green", "green", "orange", "1", "Engineering", "1", "Open"],
    @["Stewarding general", "13/10/2026", "51.800", "green", "blue", "orange", "0", "Kitchen", "0.25", "Open"],
    @["Order for a la carte", "19/10/2026", "173.800", "green", "green", "orange", "0", "Kitchen", "0.5", "Open"],
    @["Replacement for dishes", "18/10/2026", "65.400", "green", "green", "orange", "0", "Engineering", "0", "Open"],
    @["Roof pump room", "18/10/2026", "870.609", "green", "green", "red", "0", "Engineering", "0.1", "Open"],
    @["Eggs for breakfast", "22/10/2026", "33.920", "green", "blue", "orange", "1", "Kitchen", "1", "Open"],
    @["Bread for canteen", "24/10/2026", "54.155", "green", "green", "orange", "0", "Cafeteria", "0.75", "Open"],
    @["All day dining food", "22/10/2026", "13.360", "green", "green", "orange", "0", "Banquet", "0", "Open"]]
  ordSel = 0
  ordPos = 0
  ordDirty = false
  phone = "968"
  fromDay = date(2026, 10, 1)
  toDay = date(2026, 10, 31)
  accounts = @["Cash", "Bank", "Sales", "Purchases", "Rent", "Salaries", "Utilities"]
  chosenAccounts: seq[string]
  props = @[textProp("Name", "Main store", "General", "What the store is called"),
            boolProp("Active", true, "General", "Inactive stores take no orders"),
            choiceProp("Region", ["North", "South", "East", "West"], 1, "General"),
            numberProp("Budget", 15000.5, 2, "Money", "The yearly budget in OMR"),
            intProp("Staff", 12, "Money"),
            colorProp("Label color", color(0, 128, 0), "Look", "Its color on the map"),
            dateProp("Opened", date(2019, 3, 1), "Look"),
            infoProp("Code", "ST-0042", "Look", "Given by the system")]
  propSel = 0
  accCols = @[column("Account", 200), numberColumn("Debit", 100), numberColumn("Credit", 100)]
  accRows = @[
    TreeRow(level: 0, cells: @["Assets", "25,400.00", ""], open: true, glyph: pxFolder),
    TreeRow(level: 1, cells: @["Cash", "5,400.00", ""], glyph: pxSheet),
    TreeRow(level: 1, cells: @["Bank", "20,000.00", ""], open: true, glyph: pxFolder),
    TreeRow(level: 2, cells: @["Current account", "14,000.00", ""], glyph: pxSheet),
    TreeRow(level: 2, cells: @["Savings", "6,000.00", ""], glyph: pxSheet),
    TreeRow(level: 0, cells: @["Liabilities", "", "8,200.00"], open: true, glyph: pxFolder),
    TreeRow(level: 1, cells: @["Suppliers", "", "3,200.00"], glyph: pxSheet),
    TreeRow(level: 1, cells: @["Loans", "", "5,000.00"], glyph: pxSheet)]
  accSel = 1
  recTab = 0
  wizardOpen = false
  wizardStep = 0
  company = ""

proc ordTotal(): string =
  var t = 0.0
  for o in ordRows:
    var v: float
    if parseNumber(o[2], v): t += v
  formatNumber(t, 3)

proc recordsTab() =
  tabs recTab, ["&Data grid", "&Forms", "&Properties", "&Accounts"]:
    case recTab
    of 0:
      let e = grid(ordCols, ordRows.len, proc (r, c: int): string = ordRows[r][c], ordSel,
                   height = 8, rowHeaders = true,
                   style = proc (r, c: int): CellStyle =
                     var v: float
                     if c == 2 and parseNumber(ordRows[r][2], v) and v > 500:
                       cellStyle(fg = color(200, 0, 0), bold = true)
                     else: CellStyle(),
                   footer = proc (c: int): string =
                     if c == 0: $ordRows.len & " orders" elif c == 2: ordTotal() else: "")
      if e.edited: ordRows[e.row][e.col] = e.text
      if e.clicked: toast("Opened " & ordRows[e.row][0], glyph = pxOpen)
      ordPos = ordSel
      case recordNav(ordPos, ordRows.len, ordDirty)
      of raNone: discard
      of raNew:
        ordRows.add @["New order", $today(), "0.000", "green", "green", "orange", "0",
                     "Kitchen", "0", "Open"]
        ordSel = ordRows.high
      of raDelete:
        if ordRows.len > 0:
          ordRows.delete(ordSel)
          ordSel = clamp(ordSel, 0, max(0, ordRows.high))
      else: ordSel = ordPos
      label("Cells hold check boxes, status colors, drop-downs, progress and buttons; " &
            "click the S boxes, F4 on Store, the Open buttons.", color = ui.theme.gray)
    of 1:
      form 0:
        field "&Phone:": maskedEdit(phone, "+### #### ####")
        field "&Period:": dateRange(fromDay, toDay)
        field "Accounts:": dualList(accounts, chosenAccounts, rows = 5)
      row:
        if button("&New company...", w = 140):
          wizardOpen = true
          wizardStep = 0
    of 2:
      let changed = propertyGrid(props, propSel, height = 300)
      if changed >= 0: status = props[changed].name & " is " & valueText(props[changed])
    else:
      discard treeGrid(accCols, accRows, accSel, height = 10)
  let act = wizard(wizardOpen, "New company", wizardStep, ["Name", "Address", "Bank", "Done"], 520):
    case wizardStep
    of 0:
      label "&Company name:"
      edit company
      stepDone(company.len > 0)
    of 1:
      label "&Street:"
      edit name
    of 2: label "The bank account comes later."
    else: label("Ready to make " & company & ".")
  if act == waFinish: toast("Made " & company, glyph = pxCheck)

# ---- the Windows page: windows in the window, find, shortcuts ----------------------------------

var
  # (a size grip on each; Notes kept on top -- its pin, its control menu, the
  # Window menu)
  win1 = MdiWindow(title: "Accounts", r: rect(10, 10, 260, 170), open: true, glyph: pxSheet, grip: true)
  win2 = MdiWindow(title: "Invoices", r: rect(150, 70, 260, 170), open: true, glyph: pxDocument, grip: true)
  win3 = MdiWindow(title: "Notes", r: rect(300, 30, 240, 150), open: true, glyph: pxText, grip: true,
                   gripSize: 18, pinned: true)
  winDock = block:
    # docked panels down the right: tabs, groups, a column of icons; the bar
    # at their left edge sizes them
    var dk = newDock()
    discard dk.addColumn()
    discard dk.addGroup(0, [dockPanel("props", "Properties", nfSliders), dockPanel("info", "Info", nfInfo)],
                        share = 45)
    discard dk.addGroup(0, [dockPanel("layers", "Layers", nfImageMultiple)], share = 55)
    discard dk.addColumn(iconic = true)
    discard dk.addGroup(1, [dockPanel("history", "History", nfHistory), dockPanel("swatches", "Swatches", nfPalette)])
    dk
  dockOpacity = 80
  dockVisible = [true, true, false]
  dockSel = 0
  findText = "The quick brown fox jumps over the lazy dog. The dog sleeps."
  finder = FindState(open: true)
  foundAt = -1
  saveKey = "Ctrl+Shift+S"
  aboutGallery = false

proc windowsTab() =
  row:
    if button("&Cascade", w = 90): mdiCascade("gallery")
    if button("&Tile", w = 90): mdiTile("gallery")
    if button("&Open all", w = 90):
      win1.open = true
      win2.open = true
      win3.open = true
    if not isCompact():
      spring()
      label "Save shortcut:"
      hotkeyEdit(saveKey)
  if isCompact():                       # (a phone: on a line of its own)
    row:
      label "Save shortcut:"
      hotkeyEdit(saveKey)
  if hotkeyPressed(saveKey): toast("Saved (" & saveKey & ")", glyph = pxSave)
  if not finder.open:
    if button("&Find...") or hotkeyPressed("Ctrl+F"): finder.open = true
  let fe = findBar(finder)
  if fe.next or fe.prev:
    let start = if foundAt < 0: 0 elif fe.next: foundAt + 1 else: foundAt
    foundAt = findIn(findText, finder.what, start, finder.matchCase, finder.wholeWord,
                     backwards = fe.prev)
    status = if foundAt < 0: "Not found" else: "Found at " & $foundAt
  mdiArea(-1, "gallery"):
    mdiWindow(win1):
      factList({"Cash": "5,400.00", "Bank": "20,000.00", "Total": "25,400.00"})
    mdiWindow(win2):
      for i in 1 .. 12: label "Invoice " & $(40 + i)
    mdiWindow(win3):
      paragraph(findText)
    if not isCompact():
      discard dockPanels(winDock, "gallery", proc (key: string) =
        case key
        of "props":
          label "Opacity:"
          slider(dockOpacity, 0, 100)
          label($dockOpacity & " %", color = ui.theme.gray)
        of "info":
          factList({"Windows": "3", "Kept on top": (if win3.pinned: "Notes" else: "none")})
        of "layers":
          for i, n in ["Text", "Shapes", "Background"]:
            checkbox(n, dockVisible[i])
        of "history":
          for s in ["Open", "Move", "Size", "Pin"]: label s
        of "swatches":
          label "Color:"
          colorWell(wellColor, "dockwell", dp(60))
        else: discard)


# ---- the Planning page --------------------------------------------------------------------------

let pToday = today()
var pLanes = @[
  KanbanLane(title: "To do", cards: @[
    KanbanCard(title: "Price list", detail: "For the new menu", tag: color(219, 68, 55),
               who: "Sultan Al-Said", due: pToday.addDays(3)),
    KanbanCard(title: "Staff rota", due: pToday.addDays(-2), who: "Amal Z")]),
  KanbanLane(title: "Doing", limit: 2, cards: @[
    KanbanCard(title: "Pool repair", detail: "Pump and filter", tag: color(66, 133, 244))]),
  KanbanLane(title: "Done", cards: @[KanbanCard(title: "Fire drill")])]
var pKsel: KanbanPos = (0, 0)
var pTasks = @[
  GanttTask(name: "Opening", start: pToday.addDays(-2), finish: pToday.addDays(20)),
  GanttTask(name: "Kitchen", start: pToday.addDays(-2), finish: pToday.addDays(6), progress: 0.7,
            level: 1, color: color(219, 68, 55)),
  GanttTask(name: "Rooms", start: pToday.addDays(3), finish: pToday.addDays(12), progress: 0.3,
            level: 1, deps: @[1]),
  GanttTask(name: "Soft opening", start: pToday.addDays(18), finish: pToday.addDays(18),
            level: 1, milestone: true, deps: @[2])]
var pGsel = 1
var pScale = gsDay
var pItems = @[
  Appointment(title: "Audit", day: pToday, start: 9 * 60, finish: 11 * 60),
  Appointment(title: "Holiday", day: pToday.addDays(2), allDay: true, color: color(15, 157, 88)),
  Appointment(title: "Review", day: pToday.addDays(1), start: 14 * 60, finish: 15 * 60 + 30)]
var pDay = pToday
var pMode = amMonth
var pOrg = @[
  OrgNode(name: "Amal Al-Harthy", title: "General manager", parent: -1),
  OrgNode(name: "Badr Al-Kindi", title: "Rooms", parent: 0, color: color(66, 133, 244)),
  OrgNode(name: "Dana Al-Said", title: "Food & beverage", parent: 0, color: color(219, 68, 55)),
  OrgNode(name: "Eid Saleh", title: "Front office", parent: 1),
  OrgNode(name: "Huda Nasser", title: "Restaurant", parent: 2)]
var pOsel = 0
var pTab = 0

proc planningTab() =
  kpiRow:
    discard kpiTile("Revenue", "OMR 84,120", 0.125, "vs last month",
                    trend = [3.0, 4, 3.5, 5, 6, 5.5, 7], target = 0.68)
    discard kpiTile("Complaints", "12", -0.2, "vs last month", lowerIsBetter = true,
                    color = color(219, 68, 55))
    discard statCard(pxUser, "Guests", "214", "38 arriving today", color(15, 157, 88))
  tabs pTab, ["&Board", "&Gantt", "A&genda", "&People"]:
    case pTab
    of 0:
      let e = kanbanBoard(pLanes, pKsel)
      if e.added: pLanes[e.lane].cards.add KanbanCard(title: "New card")
      if e.moved: toast("Moved to " & pLanes[e.toPos.lane].title)
    of 1: discard ganttView(pTasks, pGsel, pScale)
    of 2:
      let e = agendaView(pItems, pDay, pMode)
      if e.added: pItems.add Appointment(title: "New", day: e.addDay, allDay: e.addMinute < 0,
                                         start: max(0, e.addMinute), finish: max(0, e.addMinute) + 60)
    else: discard orgChart(pOrg, pOsel)

# ---- the Map and 3D page ------------------------------------------------------------------------

var mapState = MapState()
var mapPicked = "Click a country"
var sales3d = bars3d(@[@[12.0, 18, 9, 22], @[8.0, 14, 16, 11], @[5.0, 7, 12, 15]],
                     ["North", "South", "East"], ["Q1", "Q2", "Q3", "Q4"], showValues = true)
var sales3dCam = camera3(yaw = 30, pitch = 28)
fitView(sales3d, sales3dCam)
var model3d = Scene3()
block:
  var b = box(1.2, 0.6, 0.8, color(0, 0, 160), name = "Base")
  b.edges = true
  discard model3d.add b
  var sp = sphere(0.45, color(200, 0, 0), name = "Ball")
  sp.pos = vec3(0, 0.75, 0)
  discard model3d.add sp
  var c = cone(0.3, 0.6, color(0, 140, 0), name = "Cone")
  c.pos = vec3(0.9, 0, 0.3)
  discard model3d.add c
  model3d.addGrid(4, 8, -0.3)
  model3d.addAxes(1.5)
var model3dCam = camera3()
fitView(model3d, model3dCam)
var model3dPick = "nothing yet"
var show3d = 0

proc carModel(): Scene3 =
  ## A car made in code, its parts named as a model from Blender has them:
  ## the body, four wheels, a door; two clips (the door, the wheels).
  result.materials.add Material3(name: "CarPaint", baseColor: [0.7'f32, 0.05, 0.08, 1], metallic: 0.6,
                                 roughness: 0.3, alphaCutoff: 0.5)
  result.materials.add Material3(name: "Tire", baseColor: [0.08'f32, 0.08, 0.08, 1], metallic: 0,
                                 roughness: 0.9, alphaCutoff: 0.5)
  let car = result.addNode(newNode("Car"))
  proc part(s: var Scene3; m: Mesh3; parent: int; name: string; at = vec3(0, 0, 0);
            turn = Quat(w: 1)): int =
    var n = newNode(name, parent)
    n.t = at
    n.r = turn
    result = s.addNode(n)
    var mm = m
    mm.node = result
    s.nodes[result].meshes.add s.meshes.len
    s.meshes.add mm
  var body = box(4, 1, 2, name = "Body")
  body.material = 0
  discard result.part(body, car, "Body")
  for (name, x, z) in [("Wheel_FL", 1.3, 1.0), ("Wheel_FR", 1.3, -1.0), ("Wheel_RL", -1.3, 1.0),
                       ("Wheel_RR", -1.3, -1.0)]:
    var w = cylinder(0.45, 0.3, name = name)
    w.material = 1
    discard result.part(w, car, name, vec3(x, -0.5, z), quatAxis(vec3(1, 0, 0), 90))
  var door = box(1.2, 0.8, 0.05, name = "Door")
  for v in door.verts.mitems: v = Vec3(x: v.x - 0.6, y: v.y, z: v.z)   # (its hinge at the front)
  door.material = 0
  let di = result.part(door, car, "Door", vec3(0.6, 0, 1.02))
  result.animations.add Animation3(name: "DoorOpen", duration: 1, channels: @[
    AnimChannel3(node: di, path: apRotation, times: @[0'f32, 1],
                 values: @[0'f32, 0, 0, 1, 0, sin(PI / 4).float32, 0, cos(PI / 4).float32])])
  var spin = Animation3(name: "WheelsTurn", duration: 2)
  for name in ["Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR"]:
    var vals: seq[float32]
    for k in 0 .. 4:
      let q = quatAxis(vec3(0, 0, 1), -90.0 * k.float) * quatAxis(vec3(1, 0, 0), 90)
      vals.add [q.x, q.y, q.z, q.w]
    spin.channels.add AnimChannel3(node: result.findNode(name), path: apRotation,
                                   times: @[0'f32, 0.5, 1, 1.5, 2], values: vals)
  result.animations.add spin
  sceneChanged(result)

var car3d = carModel()
var car3dCam = camera3(yaw = 35, pitch = 18)
fitView(car3d, car3dCam)
var doorOpen = false
var carPick = "Click a part"

var streets = false         # the street map (OpenStreetMap's tiles: the network)
var streetMap = TileMapState(lat: 23.588, lon: 58.3829, zoom: 12)

proc mapTab() =
  # (big screens: down to the bottom)
  let tall = not isCompact()
  adaptive(360):
    col:
      if streets:
        discard tileMap(streetMap, osmTiles(), height = if tall: max(dp(300), remainingH() - CtrlH - Gap)
                                                         else: dp(300),
                        markers = [MapMarker(lat: 23.588, lon: 58.3829, label: "Muscat")], key = "gallery")
        row:
          label "OpenStreetMap's tiles, from the network"
          spring()
          if button("&World map"): streets = false
      else:
        let ev = mapView(mapState, height = if tall: max(dp(300), remainingH() - CtrlH - Gap)
                                            else: dp(300),
                         values = [("OM", 120.0), ("AE", 340.0), ("SA", 510.0), ("IN", 800.0),
                                   ("GB", 380.0), ("US", 950.0), ("QA", 150.0)],
                         markers = [cityMarker("Muscat", size = 6), cityMarker("Mumbai"),
                                    cityMarker("London"), cityMarker("New York")],
                         routes = [MapRoute(fromLat: 23.59, fromLon: 58.41, toLat: 51.51, toLon: -0.13)],
                         legendTitle = "Sales (OMR k)", key = "gallery")
        if ev.clicked and ev.country >= 0: mapPicked = ev.name & " (" & ev.code & ")"
        row:
          label mapPicked
          spring()
          if button("G&ulf"): mapState.fitTo(["OM", "AE", "SA", "QA", "BH", "KW"])
          if button("&World"): mapState.resetView()
          if button("Stree&ts"): streets = true
    col:
      segmented(["Bars", "Model", "Car"], show3d)
      let h3 = if tall: max(dp(270), remainingH() - 2 * (FontH + Gap)) else: dp(270)
      if show3d == 0:
        discard view3d(sales3d, sales3dCam, height = h3, key = "bars")
      elif show3d == 2:
        # (its clips move on with the frames: a model's parts by name)
        if car3d.animate(1 / 60): wakeIn(16)
        let ev = view3d(car3d, car3dCam, height = h3 - CtrlH - Gap, key = "car")
        if ev.clicked: carPick = if ev.nodeName.len > 0: ev.nodeName else: "nothing"
        row:
          if button(if doorOpen: "Close the &door" else: "Open the &door"):
            doorOpen = not doorOpen
            car3d.play("DoorOpen", loop = false, speed = if doorOpen: 1.0 else: -1.0)
          if button("&Wheels"):
            if car3d.isPlaying("WheelsTurn"): car3d.stop("WheelsTurn") else: car3d.play("WheelsTurn")
          if button("&Paint"):
            car3d.recolor("CarPaint", if car3d.materials[0].baseColor[2] > 0.5: color(180, 12, 20)
                                      else: color(20, 60, 170))
          label carPick
      else:
        let ev = view3d(model3d, model3dCam, height = h3, key = "model")
        if ev.clicked:
          model3dPick = if ev.picked >= 0: model3d.meshes[ev.picked].name else: "nothing"
        label "Clicked: " & model3dPick
      label("Drag to turn, Shift+drag to move, the wheel or + / - to zoom.",
            color = ui.theme.gray)

# ---- the HTML page ---------------------------------------------------------------------------------

var webUrl = "html:<h2>Web view</h2><p>With the system's engine this is the system's own " &
             "<b>browser</b> (the phone's on Android); with the kit's, local pages are read by " &
             "the kit.</p><p><button onclick=\"retro.post('Hello from the page')\">Say hello" &
             "</button></p><p><a href=\"https://nim-lang.org\">nim-lang.org</a></p>"
var webSystem = false       # the system's engine on the desktop too
var webSaid = ""            # what the page's script posted last
const reportHtml = "<h3>Sales <u>report</u></h3><p>Up <b>12%</b>, costs " &
  "<span style=\"color:#c00\">down</span>, <mark>new store</mark> open.</p>" &
  "<table><tr><th>Month</th><th align=right>Sales</th></tr>" &
  "<tr><td>August</td><td align=right>1,020</td></tr>" &
  "<tr><td>September</td><td align=right>980</td></tr></table>" &
  "<ul><li>North<li>South</ul><script>alert(1)</script>"

proc htmlTab() =
  adaptive(420):
    col:
      label "An HTML page read by the kit (no scripts run):", bold = true
      # (down to the bottom on a big screen)
      let h = htmlView(reportHtml, key = "gallery",
                       height = if isCompact(): 260 else: max(260, remainingH()))
      if h.link.len > 0: discard openUrl(h.link)
    col:
      label "A web view:", bold = true
      let w = webView(webUrl, key = "gallery", height = if isCompact(): 220
                      else: max(220, remainingH() - 2 * (CtrlH + Gap)),
                      engine = if webSystem: weSystem else: weAuto)
      for m in w.messages: webSaid = "The page said: " & m
      row:
        if button("&Back", enabled = w.canGoBack): discard webGoBack("gallery")
        if button("nim-lang.org"): webUrl = "https://nim-lang.org"
        checkbox("System engine", webSystem)
      label(if webSaid.len > 0: webSaid else: w.title)


# ---- the Canvas page: the HTML5 Canvas 2D API ------------------------------------------------------

var
  starAngle = 0.0
  inkSel = 0
  padReady = false
  padClear = false

proc starPath(ctx: Canvas2D; outer, inner: float) =
  ctx.beginPath()
  for i in 0 .. 9:
    let r = if i mod 2 == 0: outer else: inner
    let a = float(i) * PI / 5 - PI / 2
    if i == 0: ctx.moveTo(r * cos(a), r * sin(a))
    else: ctx.lineTo(r * cos(a), r * sin(a))
  ctx.closePath()

proc canvasTab() =
  adaptive(420):
    col:
      label "The HTML5 Canvas API: gradients, curves, shadows, text. Drag the star to turn it.",
            bold = true
      let tall = not isCompact()               # (big screens: down to the bottom)
      canvas2d(ctx, 0, if tall: max(300, remainingH()) else: 300):
        let w = ctx.width
        let h = ctx.height
        let sky = ctx.createLinearGradient(0, 0, 0, h)
        sky.addColorStop(0, "#000080")
        sky.addColorStop(1, "#1084d0")
        ctx.fillStyle = sky
        ctx.fillRect(0, 0, w, h)
        let sun = ctx.createRadialGradient(w * 0.8, h * 0.25, 4, w * 0.8, h * 0.25, 70)
        sun.addColorStop(0, "#fff7a0")
        sun.addColorStop(1, "rgba(255, 200, 0, 0)")
        ctx.fillStyle = sun
        ctx.fillRect(0, 0, w, h)
        ctx.fillStyle = "#2e7d32"
        ctx.beginPath()
        ctx.moveTo(0, h)
        ctx.bezierCurveTo(w * 0.3, h * 0.45, w * 0.6, h * 0.95, w, h * 0.6)
        ctx.lineTo(w, h)
        ctx.closePath()
        ctx.fill()
        ctx.save()
        ctx.translate(w * 0.3, h * 0.4)
        ctx.rotate(starAngle)
        ctx.shadowColor = "rgba(0, 0, 0, 0.5)"
        ctx.shadowBlur = 8
        ctx.shadowOffsetX = 4
        ctx.shadowOffsetY = 4
        starPath(ctx, 60, 26)
        let hot = ctx.isPointInPath(ctx.input.x, ctx.input.y)   # under the pointer
        ctx.fillStyle = if hot: "gold" else: "#f5d76e"
        ctx.fill()
        ctx.lineWidth = 2
        ctx.strokeStyle = "#8a6d00"
        ctx.stroke()
        ctx.restore()
        ctx.font = "bold 20px sans-serif"
        ctx.fillStyle = "white"
        ctx.fillText("Retro canvas", 16, 32)
        ctx.setLineDash([6, 4])
        ctx.strokeStyle = "rgba(255, 255, 255, 0.7)"
        ctx.strokeRect(8, 8, w - 16, h - 16)
        if ctx.input.dragging: starAngle += ctx.input.dx / 80
    col:
      label "A sketch pad (a retained canvas): draw with the mouse or a finger.", bold = true
      let padH = if isCompact(): 300 else: max(300, remainingH() - CtrlH - Gap)
      canvas2dWith(pad, 0, padH, CanvasOptions(retained: true, key: "pad")):
        if not padReady or padClear:
          pad.reset()
          pad.fillStyle = "white"
          pad.fillRect(0, 0, pad.width, pad.height)
          pad.strokeStyle = "#808080"          # the edge of the paper
          pad.lineWidth = 1
          pad.strokeRect(0.5, 0.5, pad.width - 1, pad.height - 1)
          padReady = true
          padClear = false
        let i = pad.input
        if i.down and (i.dx != 0 or i.dy != 0):
          pad.strokeStyle = ["#000080", "#c00000", "#008000"][inkSel]
          pad.lineWidth = 3
          pad.lineCap = "round"
          pad.beginPath()
          pad.moveTo(i.x - i.dx, i.y - i.dy)
          pad.lineTo(i.x, i.y)
          pad.stroke()
      row:
        segmented(["Blue", "Red", "Green"], inkSel)
        if button("C&lear"): padClear = true

# ---- the Reports page: an HTML template, a preview, PDF and printing ---------------------------------

const quoteTemplate = """
<header><span>Gulf Print House</span><span>Quote {{number}}</span></header>
<footer><span>{{date}}</span><span>Page {page} of {pages}</span></footer>
<table class="plain"><tr>
  <td width="60%"><h1>Gulf Print House</h1>Way 3021, Muscat<br>Tel. +968 2400 0000</td>
  <td align="right"><h2>QUOTE</h2>No. <b>{{number}}</b><br>Date: {{date}}</td>
</tr></table>
<p>For <b>{{customer}}</b>:</p>
<table>
<thead><tr><th width="55%">Item</th><th align="right">Qty</th><th align="right">Price</th>
<th align="right">Amount</th></tr></thead>
<tbody>{{#lines}}<tr><td>{{name}}</td><td>{{qty|n0}}</td><td>{{price|n3}}</td>
<td>{{amount|n3}}</td></tr>{{/lines}}</tbody>
<tfoot><tr><td colspan="3" align="right">Total (OMR)</td><td>{{total|n3}}</td></tr></tfoot>
</table>
<p style="text-align: right"><small>Valid for 30 days.</small></p>
<p dir="rtl">شكراً لتعاملكم معنا.</p>
"""

const quoteItems = ["Business cards, 500", "Letterheads, 1,000", "Envelopes DL, 500",
                    "Roll-up banner", "Brochures A4, 250", "Stickers, 1,000",
                    "Calendars 2027, 100", "Menu cards, 50"]
var
  quoteCustomer = "Al Noor Trading"
  quoteLines = 6
  quoteDoc: Report
  quoteMadeFor = ""
  quoteStatus = "Change the customer or the lines: the document follows."

proc quoteData(): JsonNode =
  var items = newJArray()
  var total = 0.0
  for i in 0 ..< quoteLines:
    let qty = float(1 + (i * 7) mod 5)
    let price = 12.5 + float((i * 13) mod 40)
    total += qty * price
    items.add %*{"name": quoteItems[i mod quoteItems.len], "qty": qty, "price": price,
                 "amount": qty * price}
  %*{"number": "Q-2026-118", "date": $today(), "customer": quoteCustomer,
     "lines": items, "total": total}

proc reportsTab() =
  let data = quoteData()
  if $data != quoteMadeFor:                 # made again only when the data changed
    quoteMadeFor = $data
    quoteDoc = reportFromHtml(renderTemplate(quoteTemplate, data))
  proc quoteForm() =
    group "&Quote":
      form 70:
        field "Customer:": edit quoteCustomer
        field "&Lines:": intEdit(quoteLines, lo = 0, hi = 400)
      label "From an HTML template filled with data (Mustache style), laid out on A4 " &
            "pages: headers and footers, the table's header again on each page, totals.",
            color = ui.theme.gray
    row:
      if button(pxPdf & " Save &PDF"):
        let path = dataDir("retro-gallery") / "quote.pdf"
        try:
          quoteDoc.savePdf(path)
          quoteStatus = "Saved " & path
        except IOError, OSError:
          quoteStatus = "Could not save " & path
      if button(pxPrint & " P&rint"): quoteStatus = quoteDoc.printReport().message
    label quoteStatus
  if isCompact():                           # a phone: the form, then the pages
    quoteForm()
    let ev = reportView(quoteDoc, height = max(dp(320), remainingH()), key = "gallery")
    if ev.link.len > 0: discard openUrl(ev.link)
  else:
    row([230, -1]):
      col: quoteForm()
      col:
        let ev = reportView(quoteDoc, key = "gallery")
        if ev.link.len > 0: discard openUrl(ev.link)

# ---- the System page: the OS's own APIs ------------------------------------------------------------

var nativeAnswer = ""
var nativeScreenOn = false
let tune = joinSounds([makeTone(523, 140), makeTone(659, 140), makeTone(784, 260)])
const patternGif = staticRead("assets/pattern.gif")
let gifFrames = loadGif(patternGif)

proc systemTab() =
  card("Native APIs"):
    factList({"Device": deviceName(), "System": osVersion(),
              "Battery": (let b = batteryLevel(); if b < 0: "unknown" else: $b & "%"),
              "Dark mode": (if systemDarkMode(): "on" else: "off")})
    row:
      if button("&Beep"): beepSystem()
      if button("&Vibrate"): nativeAnswer = if vibrate(80): "Buzzed." else: "Nothing buzzes here."
      if toggle("Keep the screen &on", nativeScreenOn): discard keepScreenOn(nativeScreenOn)
    when defined(android):
      if button("Build.MODEL (Java)"): nativeAnswer = javaStatic("android.os.Build", "MODEL")
    elif defined(macosx) or defined(ios):
      if button("Host name (Objective-C)"):
        nativeAnswer = toNim(objcSend(ObjcId, objcSend(ObjcId, objcClass("NSProcessInfo"), "processInfo"), "hostName"))
    elif defined(windows):
      if button("Documents (Win32)"): nativeAnswer = windowsDocumentsFolder()
    else:
      if button("getpid (libc)"):
        let libc = nativeLib("libc.so.6", "libc.so", "libc.so.7")
        let getpid = nativeProc[proc (): cint {.cdecl.}](libc, "getpid")
        nativeAnswer = if getpid != nil: "Process " & $getpid() else: "no libc"
    label nativeAnswer
  card("Sound and video"):
    row:
      if button("&Tone"): discard tone(660, 180)
      if button("T&une"): discard playSound(tune)
      if button("&Error sound"): uiSound(usError)
      if button("&Notify"): uiSound(usNotify)
    row:
      animation(gifFrames, height = dp(40))
      label "An animated GIF, decoded by the kit."
    label("Sounds are made and mixed by the kit and played by the system's own audio; " &
          "videoView(\"clip.mp4\") plays a video in the window.", color = ui.theme.gray)

var settings: array[40, tuple[on: bool, name: string]]
for i in 0 ..< settings.len:
  settings[i] = (i mod 3 == 0, "Setting number " & $(i + 1))

proc setScheme(i: int) =
  scheme = i
  ui.theme = [Classic, Gray, Dark][i]

# (`look`: the colors, sizes and font chosen in View, Appearance kept for
# the next start; the frame the user picks is kept by the toolkit itself)
app "Control Gallery", 760, 540, look = "retro-gallery":
  if closeRequested():
    cancelClose()
    showConfirm = true

  menubar:
    menu "&File":
      if menuItem("&New", "Ctrl+N"): status = "New file"
      if menuItem("&Open...", "Ctrl+O"): status = "Open..."
      if menuItem("&Save", "Ctrl+S"): status = "Saved " & name
      menuSeparator()
      if menuItem("E&xit", "Alt+F4"): showConfirm = true
    menu "&Edit":
      discard menuItem("&Undo", "Ctrl+Z", enabled = false)
      menuSeparator()
      if menuItem("Cu&t", "Ctrl+X"): status = "Cut"
      if menuItem("&Copy", "Ctrl+C"): status = "Copy"
      if menuItem("&Paste", "Ctrl+V"): status = "Paste"
    menu "&View":
      if menuItem("&Classic colors", checked = scheme == 0): setScheme(0)
      if menuItem("&Gray dialogs", checked = scheme == 1): setScheme(1)
      if menuItem("&Dark", checked = scheme == 2): setScheme(2)
      menuSeparator()
      if menuItem("Show &grid", checked = showGrid): showGrid = not showGrid
      submenu "&Toolbar Labels":
        for lk in [blIconOnly, blTextBelow, blTextBeside, blTextOnly]:
          if menuItem($lk, checked = toolbarLook == lk): setToolbarLook(lk)
      menuSeparator()
      if menuItem("&Appearance..."): showLook = true
    menu "&Insert":
      if menuItem("&Date and Time"): status = "Inserted " & $today()
      if menuItem("&Page Break", "Ctrl+Enter"): status = "Page break"
      menuSeparator()
      # (a long submenu: on a short screen it moves up to fit, or goes on in
      # columns; the pointer on its way to it leaves it open)
      submenu "&Field":
        for f in ["Author", "Title", "Subject", "Company", "Address", "City", "Country", "Phone",
                  "Email", "Website", "Date", "Time", "Page Number", "Page Count", "File Name",
                  "File Size", "Created", "Modified", "Printed", "Version", "Invoice Number",
                  "Customer", "Amount", "Tax", "Total", "Due Date", "Signature", "Barcode"]:
          if menuItem(f): status = "Inserted the field " & f
    menu "&Window":
      # (Cascade, Tile, Always on Top for the active window, the windows)
      mdiWindowMenu("gallery")
    menu "&Help":
      if menuItem("&About Gallery..."): showAbout = true

  toolbar:
    if barButton(pxNew, "New"): status = "New file"
    if barButton(pxOpen, "Open"): status = "Open..."
    if barButton(pxSave, "Save"): status = "Saved " & name
    toolSeparator()
    if barButton(pxCut, "Cut"): status = "Cut"
    if barButton(pxCopy, "Copy"): status = "Copy"
    if barButton(pxPaste, "Paste"): status = "Paste"
    toolSeparator()
    if toolButton("B", "Bold", down = boldOn, bold = true): boldOn = not boldOn
    if toolButton("I", "Italic", down = italicOn): italicOn = not italicOn
    toolSeparator()
    if toolButton(pxPrint, "Print"): status = "Printing..."
    if toolButton(pxHelp, "About"): showAbout = true

  statusbar(status, languages[lang], if boldOn: "BOLD" else: "    ")
  if phoneBars:
    # a phone app's bottom navigation and floating button
    if bottomNav([(pxHome, "Home"), (pxSearch, "Search"), (pxBell, "Alerts"),
                  (pxUser, "Profile")], navSel):
      status = "Went to " & ["Home", "Search", "Alerts", "Profile"][navSel]
    if fab(nfPlus, "New item"): toast("New item", glyph = nfPlus)

  # (Alt + a letter: a letter of its own for each tab; the menus' letters --
  # F, E, V, I, W, H -- and the buttons' of the pages are left to them)
  tabs(tab, ["&Controls", "&Lists", "&Business", "Char&ts", "Drawin&g", "&Scrolling",
             "&More", "Mar&kdown", "&Apps", "Files", "&Records", "Windows", "&Planning",
             "Map && &3D", "Ca&nvas", "HTML", "Reports", "S&ystem"]):
    case tab
    of 14: canvasTab()
    of 15: htmlTab()
    of 16: reportsTab()
    of 17: systemTab()
    of 10: recordsTab()
    of 11: windowsTab()
    of 12: planningTab()
    of 13: mapTab()
    of 0:
      adaptive(280):
        group "Buttons":
          row:
            if button("OK", isDefault = true): status = "OK clicked"
            if button("Cancel"): status = "Cancel clicked"
          tooltip "Cancel does nothing here"
          row:
            discard button("Disabled", enabled = false)
            if button("&Delete..."): showDelete = true
          row:
            if button("R&un", w = 72): running = not running
            if button("Reset", w = 72):
              progress = 0.0
              running = false
          # (a picture and a label: four looks)
          row:
            if button("Save", pxSave, blIconOnly): status = "Save (icon only)"
            if button("Print", pxPrint, blTextOnly): status = "Print (text only)"
          row:
            if button("Open", pxOpen, blTextBelow): status = "Open (text below)"
            if button("&Find", pxSearch, blTextBeside): status = "Find (text beside)"
        group "Choices":
          checkbox "&Auto save", autoSave
          checkbox "Keep &backups", backups
          checkbox "Show grid", showGrid
          checkbox "Disabled", backups, enabled = false
          separator()
          radio "&Small", size, 0
          radio "&Medium", size, 1
          radio "&Large", size, 2
        group "Text":
          label "&Name:"
          edit name
          label "Pass&word:"
          edit secret, password = true
          row([60, 70]):
            label "Copies:"
            spin copies, 1, 99, w = 70
      adaptive(420):
        group "Values":
          row([60, -1]):
            label "Volume:"
            slider volume, 0, 100
            label "Zoom:"
            slider zoomLevel, 1, 5, ticks = 4
            label "Scroll:"
            hscroll scrollPos, 0, 100, page = 10
          row([60, -1]):
            label "Saving:"
            progress(progress)
        group "Pickers":
          row([70, -1]):
            label "Lan&guage:"
            combo languages, lang
            label "Colors:"
            if combo(["Classic", "Gray dialogs", "Dark"], scheme):
              setScheme(scheme)
          label "Volume " & $volume & "%, zoom " & $zoomLevel & "x, " &
                $copies & " copies"
    of 1:
      adaptive(420):
        group "&Files":
          listbox files, fileSel, rows = 13, tabs = [110, 160]
          contextMenu:
            if menuItem("&Open"): status = "Open " & files[fileSel]
            if menuItem("&Rename..."): status = "Rename"
            menuSeparator()
            if menuItem("&Delete"): showDelete = true
          if doubleClicked(): status = "Opened " & files[fileSel]
          label "Right-click a file for its menu."
        group "&Notes":
          editArea notes, lines = 13
    of 2:
      adaptive(380):
        group "&Orders: sort by a header, F2 edits a total":
          let ev = grid(orderCols, orders, orderSel, height = 8,
                        sortColumn = orderSort.col, sortDescending = orderSort.desc)
          if ev.sorted:
            orderSort = (ev.sortColumn, ev.sortDescending)
            sortRows(orders, ev.sortColumn, ev.sortDescending)
          if ev.edited:
            var v: float
            if parseNumber(ev.text, v): orders[ev.row][3] = formatNumber(v)
          if ev.activated: status = "Order " & orders[orderSel][0]
        group "&Tree":
          tree(treeSel, 8):
            branch "Company", open1:
              branch "Sales", open2:
                leaf "Invoices"
                leaf "Quotes"
              branch "Stock", open3:
                leaf "Items"
                leaf "Suppliers"
              leaf "Reports"
          if doubleClicked(): status = "Opened " & treeSel
      adaptive(420):
        group "&Form":
          form 70:
            field "Due date:": datePicker due
            field "Amount:": numberEdit amount
            field "Quantity:": intEdit qty, lo = 0
            field "City:": comboEdit city, cities
            field "Help:":
              if link("Open nim-lang.org"): openUrl("https://nim-lang.org")
        group "C&ontact by":
          checkList channels, channelOn, rows = 6
    of 3:
      row:
        label "&Kind:"
        combo(chartKindNames, chKind)
        label chEvent, color = ui.theme.gray
      let e = chart(chartKindNames[ChartKind(chKind)], ChartKind(chKind), chMonths,
                    [series("2025", [12.0, 15, 14, 18, 21, 25]),
                     series("2026", [14.0, 17, 19, 22, 20, 28])],
                    height = 240, opts = ChartOpts(palette: @businessColors, target: 25,
                    format: NumFormat(prefix: "$", suffix: "K")))
      if e.clicked: chEvent = "Clicked " & chMonths[e.index mod chMonths.len]
      adaptive(220):
        card("Cash flow"):
          chart("", chWaterfall, ["Start", "Sales", "Rent", "Salaries", "Tax"],
                [series("", [120.0, 80, -30, -90, -25])], height = 190,
                opts = ChartOpts(totalAt: @[0], dataLabels: true))
        card("Pipeline"):
          chart("", chFunnel, ["Leads", "Qualified", "Proposals", "Won"],
                [series("", [1200.0, 640, 310, 75])], height = 190)
        card("Target"):
          gauge("Sales vs target", 78, hi = 100, target = 90,
                format = NumFormat(suffix: "%"), height = 190)
        card("Share"):
          chart("", chDonut, ["North", "South", "East", "West"],
                [series("Sales", [42.0, 28, 18, 12])], height = 190,
                opts = ChartOpts(palette: @businessColors))
    of 4:
      adaptive(420):
        group "Canvas":
          # (sizes through `dp`: the drawing grows with the UI's scale)
          let r = canvas(0, dp(200))
          # (what a screen reader says of the drawing: canvas() draws no text of its own)
          accessNode(arImage, "A drawing of bars and text", id = 0, r = r)
          fill(r, ui.theme.field)
          box(r, ui.theme.frame)
          if showGrid:
            for x in countup(r.x + dp(10), r.x + r.w - 2, max(2, dp(10))):
              vline(x, r.y + 1, r.h - 2, ui.theme.face)
            for y in countup(r.y + dp(10), r.y + r.h - 2, max(2, dp(10))):
              hline(r.x + 1, y, r.w - 2, ui.theme.face)
          for i in 0 ..< 8:
            let w = dp(20 + i * 12)
            fill(r.x + dp(16 + i * 4), r.y + dp(16 + i * 20), w, dp(14), palette[i + 8])
          let tx = max(r.x + dp(150), r.x + r.w - textWidth("fill, box, lines,") - dp(24))
          var ty = r.y + dp(20)
          for (t, bold) in [("Draw anything:", false), ("fill, box, lines,", false),
                            ("text and icons.", true)]:
            text(tx, ty, t, ui.theme.fieldText, bold)
            ty += lineHeight()
          text(tx, ty + dp(4), "Big", palette[colorSel], true, 3)
        group "Palette":
          for i, c in palette:
            if i mod 4 == 0: beginRow()
            let r = canvas(dp(32), dp(24))
            accessNode(arButton, "Color " & $(i + 1), id = 0, r = r,
                       states = if i == colorSel: {asSelected} else: {})
            fill(r, c)
            box(r, ui.theme.frame)
            if i == colorSel: box(inset(r, 2), if i == 0: palette[15] else: palette[0])
            if mouseIn(r) and ui.pressed: colorSel = i
            if i mod 4 == 3: endRow()
          row:
            for g in [pxNew, pxOpen, pxSave, pxCut, pxCopy, pxPaste]:
              icon(g, ui.theme.text, 1.0)

    of 6:
      adaptive(260):
        card("More controls"):
          label "Price range:"
          rangeSlider(priceLo, priceHi, 0, 500)
          label("$" & $priceLo & " to $" & $priceHi, color = ui.theme.gray)
          row:
            let pick = menuButton("&Export", ["PNG", "JPEG", "-", "PDF"])
            if pick >= 0: status = "Export as " & ["PNG", "JPEG", "", "PDF"][pick]
            let sb = splitButton("&Save", ["Save As...", "Save a Copy..."])
            if sb.clicked: status = "Saved"
            if sb.chose >= 0: status = ["Save As", "Save a Copy"][sb.chose]
          row:
            label "Color:"
            if colorWell(wellColor, "gallery", title = "Pick a color"): status = "Color " & hexOf(wellColor)
          tagInput(tagList, tagText)
          autocomplete(acCity, ["Muscat", "Muttrah", "Sohar", "Salalah", "Nizwa", "Sur", "Ibri", "Barka"])
          row:
            knob(volumeKnob, 0, 100, label = "Vol")
            col:
              led(true, "Online")
              led(false, "Syncing", color(255, 160, 0))
              pill("Paid", color(0, 140, 0))
          for i, t in ["General", "Advanced"]:
            if accordionHeader(t, i, openSection):
              label(if i == 0: "Shown when General is open" else: "Advanced settings here")
          timeline([("09:00", "Order placed", "Al Noor Trading"), ("11:30", "Packed", ""),
                    ("14:10", "Shipped", "by courier")], current = 1)
        card("Switches"):
          toggle("&Wi-Fi", wifi)
          toggle("&Bluetooth", bluetooth)
          segmented(["Day", "Week", "Month"], period)
          rating(stars)
        card("Search and tags"):
          searchBox(query, "Search files")
          let ev = chips(tags, tagOn, closable = true)
          if ev.clicked >= 0: tagOn[ev.clicked] = not tagOn[ev.clicked]
          if ev.closed >= 0:
            tags.delete(ev.closed)
            tagOn.delete(ev.closed)
          row:
            badge($tags.len)
            badge("NEW", color(0, 128, 0))
            spinner()
        card("Icons (Nerd Fonts)"):
          row:
            for g in [nfFolder, nfFileImage, nfMusic, nfCog, nfStar, nfHeart,
                      nfGithub, nfAndroid, nfTerminal]:
              icon(g, ui.theme.select, 1.5)
          iconLabel(nfFolderOpen, "Documents", iconColor = color(222, 170, 40))
        card("Pixel icons (1990s)"):
          var k = 0
          while k < pixelIconNames.len:
            row:
              for j in 0 ..< 8:
                if k + j < pixelIconNames.len:
                  label pixelIconChar(k + j)
                  tooltip "px" & pixelIconNames[k + j]
            k += 8
          row:
            for g in [pxFolder, pxComputer, pxTrashFull, pxWarning]:
              icon(g, ui.theme.text, 2.0)
          iconLabel(pxDocuments, "Documents")
          if button(pxBell & " Show a balloon"):
            toast("Saved \"Untitled project\" to Documents.", glyph = pxCheck,
                  title = "Control Gallery")
        card("Text"):
          heading("Heading", 2)
          styledText("Italic, underlined", style(italic = true, underline = true))
          styledText("Mono 0O1lI", style(mono = true))
          label "العربية: مرحبا بالعالم"
          label "Size: " & $uiScale() & "% (Ctrl + / - / 0)"
          row:
            if button("Smaller"): setUiScale(scaleStep(-1))
            if button("Larger"): setUiScale(scaleStep(1))
        card("Color and time"):
          colorPicker(pickColor)
          timePicker(hour, minute)
        card("More"):
          expander("Advanced", advancedOpen):
            checkbox("Expert mode", expert)
            paragraph "Expanders fold away what most people do not need."
    of 8:
      adaptive(300):
        card("Settings rows"):
          settingToggle("&Notifications", notify, "Alerts for new messages")
          settingChoice("Sync", ["Hourly", "Daily", "Never"], syncEvery)
          settingSlider("Brightness", brightness, 0, 100, suffix = "%")
          settingToggle("Phone &bars", phoneBars, "A bottom navigation bar and a floating button")
          if settingLink("Look", "Colors, sizes and the font"): lookOpen = not lookOpen
          if lookOpen: appearanceSettings()
        card("People, steps, pages"):
          row:
            for n in ["Sultan Al-Said", "Maryam Al Balushi", "Omar", "Layla Haddad"]:
              if avatar(n): status = n
          let back = stepper(["Cart", "Address", "Payment", "Done"], step)
          if back >= 0: step = back
          row:
            if button("Back", enabled = step > 0): dec step
            if button("Next", enabled = step < 3): inc step
          if pager(page, 20): status = "Page " & $(page + 1)
        card("Banners"):
          if bannerShown:
            case banner("A new version is ready.", bkInfo, ["Update"])
            of 0: bannerShown = false
            of 1: status = "Updating..."
            else: discard
          discard banner("Low on storage: 300 MB left.", bkWarning, closable = false)
          row:
            if not bannerShown and button("Show the banner again"): bannerShown = true
            if button(pxBell & " Notify"):
              toast("You have 3 new messages from Maryam and Omar.", glyph = pxBell,
                    title = "Retro Mail")
        card("Numbers"):
          rowPx([-1, FontH * 3]):
            col:
              label "Sales", color = ui.theme.gray
              heading(formatNumber(sales[^1] * 1000, 0), 2)
              sparkline(sales, w = dp(120))
            progressRing(progress)
          factList([("Orders", $orders.len), ("Best month", "May"),
                    ("Customers", "Al Noor Trading, Gulf Print House, Sohar Steel")])
        card("Files"):
          row:
            if sandbox.len == 0: makeSandbox()
            pictureBox(sandbox.parentDir / "sample.png", w = dp(72), h = dp(72))
            col:
              if button("&Open a file..."): pickOpen = true
              label(if picked.len > 0: picked.extractFilename else: "Nothing picked yet",
                    color = ui.theme.gray)
          emptyState(pxInbox, "No messages", h = dp(110), detail = "New ones show up here.")
    of 9:
      filesTab()
    of 7:
      let ev = markdownView(mdText)
      if ev.task >= 0: toggleTask(mdText, ev.task)
      if ev.link.len > 0: discard openUrl(ev.link)
    else:
      label "A scroll panel: use the wheel, the scroll bar or Tab through it."
      scrollPanel -1:
        for i in 0 ..< settings.len:
          row([30, 130, -1]):
            label $(i + 1)
            checkbox "Enabled", settings[i].on
            edit settings[i].name

  filesJob()
  if filePicker(pickOpen, picked, patterns = ["*.png", "*.jpg", "*.md", "*.nim"]):
    status = "Picked " & picked

  if running:
    progress += 0.01
    if progress >= 1.0:
      progress = 1.0
      running = false
      status = "Done"
    wakeIn(40)

  # (colors, sizes -- touch or desktop controls --, text and font: kept by `look`)
  dialog(showLook, "Appearance", 420):
    appearanceSettings()
    row:
      spring()
      if button("Close", isDefault = true): showLook = false

  aboutBox(showAbout, "Control Gallery", RetroVersion,
           ["Every control of Retro Nim UI, page by page: Windows 3.1 widgets " &
            "for Nim on Windows, macOS, Linux, Android and iOS."],
           tagline = "Every control of Retro Nim UI",
           iconPng = GalleryIconPng, glyph = pxApp,
           whatsNew = ["Menus by the keyboard: F10, or Alt pressed and let go; the arrows along and " &
                       "through them. Long menus in even columns; a submenu moves up to fit, opens beside " &
                       "the whole menu and stays open while the pointer goes to it (Insert > Field)",
                       "Windows kept on top: the pin in a title bar, the control menu, Window > Always on " &
                       "Top; a size grip on any window (Windows page)",
                       "Docked panels (retroui/dock): tabs, groups, a column of icons, floating -- the side " &
                       "panel sized from its edge (Windows page)",
                       "The folder tree: room inside its frame, and a menu on a right click (Files page)",
                       "Rows of fixed and own-width widgets share the room (nothing pushed out of the row)"],
           credits = [RetroFontCredit,
                      "Map: Natural Earth (public domain)."])

  case msgBox(showConfirm, "Gallery", "Quit the control gallery?",
              ["&Yes", "&No"], miQuestion)
  of 1: quitApp()
  else: discard

  case msgBox(showDelete, "Delete", "Delete " & files[fileSel].split('\t')[0] &
              "?\nThis cannot be undone.", ["&Delete", "Cancel"], miStop)
  of 1: status = "Deleted"
  of 2: status = "Kept"
  else: discard

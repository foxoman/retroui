## HR Book -- every employee of your hotels in one private book: records,
## salaries and allowances, documents and their expiry, groups, smart
## Excel import, letters and certificates from templates, charts, alerts,
## and encrypted backups that move to another tablet and merge.
##
## Made with Retro Nim UI. The data never leaves the device: the app has
## no internet permission, and its file is sealed with the PIN
## (retroui/vault). Its engine is in examples/hrbook: model, store, importer
## and letters, tested headless by tests/test_hrbook.nim.
##
##   nim c -r -d:release examples/hrbook.nim
##   retroapk examples/hrbook.nim --storage                    (Android)
##
## A demo book of invented people to try it with (PIN 246810), made with
## HOME pointed at a folder of its own: `nim c -r tests/hrbook_demo.nim`.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, tables, os, times, math, algorithm, sets, base64]
import retroui
import retroui/[report, vault, imaging]
import hrbook/[model, store, importer, letters]

const
  AppTitle = "HR Book"
  AppVersion = "0.2.5"
  AppId = "HRBook"
  AppIconPng = staticRead("assets/hrbook-icon.png")

let black = color(0, 0, 0)

# ---- the app's state -----------------------------------------------------------------------------

var
  book: Book
  st: Store
  dir = ""
  locked = true
  setupMode = false
  lastInput = 0.0
  pausedAt = 0.0
  section = "Dashboard"
  status = ""
  # the lock screen
  pin = ""
  pin2 = ""
  pinMsg = ""
  pinTries = 0
  pinWaitUntil = 0.0
  lockOpen = true
  setupNames = @["Hotel 1", "Hotel 2", "Hotel 3"]
  setupStep = 0
  # navigation
  navW = 205
  empOpen = true
  groupsOpen = false
  settingsOpen = true
  # employees
  query = ""
  hotelFilter = 0          ## 0 all, then 1 + hotel index
  deptFilter = 0
  groupFilter = 0
  statusFilter = 0         ## Active, Left, All
  visaOnly = false
  sel = 0
  current = -1             ## the employee shown (index), -1 the list
  profileTab = 0
  paneW = 270
  paneH = 260
  askDeleteEmp = false
  # dialogs
  aboutOpen = false

proc changed() =
  st.dirty = true

proc flushSave() =
  if st.opened and st.dirty and not locked:
    try: st.save(book)
    except IOError, OSError, VaultError:
      status = "Could not save: " & getCurrentExceptionMsg()

proc hotelNames(): seq[string] =
  for h in book.hotels: result.add h.name

proc listOf(name: string): seq[string] = book.lists.getOrDefault(name)

proc downloadsDir(): string =
  if platformName() == "android":
    if storageAccess(): "/storage/emulated/0/Download" else: dir
  else:
    let d = getHomeDir() / "Downloads"
    if dirExists(d): d else: getHomeDir()

proc colorOf(hex: string): Color =
  let c = namedColor(hex)
  if c.a == 0: color(128, 128, 128) else: c

var askFilesOpen = false

proc filesOk(): bool =
  ## The tablet's files (the Download folder: sheets, backups) can be used.
  ## On Android that takes "All files access", asked once (see `filesDialog`).
  if platformName() != "android" or storageAccess(): return true
  askFilesOpen = true
  false

proc filesDialog() =
  if not askFilesOpen: return
  dialog(askFilesOpen, "Access to your files", 460):
    paragraph("HR Book reads your Excel sheets and keeps its backups in the Download folder. " &
              "Android asks once: turn on \"Allow access to manage all files\" for HR Book, " &
              "then come back and try again.")
    paragraph("Nothing leaves the tablet: HR Book has no internet permission.", color = ui.theme.gray)
    row:
      spring()
      if button("&Allow...", isDefault = true):
        requestStorageAccess()
        askFilesOpen = false
      if button("Cancel"): askFilesOpen = false

include hrbook/ui_lock
include hrbook/ui_staff
include hrbook/ui_import
include hrbook/ui_letters
include hrbook/ui_views
include hrbook/ui_settings

# ---- the window ---------------------------------------------------------------------------------

proc lockNow() =
  flushSave()
  locked = true
  pin = ""
  pinMsg = ""
  lockOpen = true
  st.close()
  book = Book()
  current = -1

proc menus() =
  menubar:
    menu "&File":
      if menuItem("&New employee...", "Ctrl+N"): startEdit(-1)
      if menuItem("&Import Excel sheets...", "Ctrl+I"): section = "Import sheets"
      if menuItem("&Letters and certificates..."): section = "Letters"
      menuSeparator()
      if menuItem("&Back up now..."): backupNow()
      if menuItem("&Restore or merge a backup..."): startRestore()
      menuSeparator()
      if menuItem("&Lock", "Ctrl+L"): lockNow()
      if menuItem("E&xit"):
        flushSave()
        quitApp()
    menu "&View":
      if menuItem("&Dashboard"): section = "Dashboard"
      if menuItem("&Employees"): section = "Employees/All hotels"
      if menuItem("&Charts"): section = "Charts"
      if menuItem("&Alerts"): section = "Alerts"
      menuSeparator()
      if menuItem("&Hide salaries", checked = book.hideSalaries):
        book.hideSalaries = not book.hideSalaries
        changed()
    menu "&Help":
      if menuItem("&Tags for letters..."): section = "Letters"; showTagHelp = true
      if menuItem("&About HR Book..."): aboutOpen = true

proc tools() =
  toolbar:
    if toolButton(pxUser, "New employee", size = 1.3): startEdit(-1)
    if toolButton(pxOpen, "Import Excel sheets", size = 1.3): section = "Import sheets"
    if toolButton(pxDocument, "Letters and certificates", size = 1.3): section = "Letters"
    toolSeparator()
    if toolButton(pxChart, "Charts", size = 1.3): section = "Charts"
    if toolButton(pxBell, "Alerts", size = 1.3): section = "Alerts"
    toolSeparator()
    if toolButton(pxSave, "Back up now", size = 1.3): backupNow()
    if toolButton(pxLock, "Lock now", size = 1.3): lockNow()

proc navTree() =
  tree(section, -1):
    leaf("Dashboard", pic = glyphIcon(pxHome, black))
    branch("Employees", empOpen, glyphIcon(pxUser, black), "Employees", true):
      leaf("All hotels", pic = glyphIcon(pxFolderStar, black), id = "Employees/All hotels")
      for i, h in book.hotels:
        leaf(h.name, pic = glyphIcon(pxFolder, black), id = "Employees/hotel:" & h.id)
      leaf("Other hotels' visas", pic = glyphIcon(pxWarning, black), id = "Employees/visa")
      branch("Groups", groupsOpen, glyphIcon(pxStar, black), "Employees/Groups", book.groups.len > 0):
        for g in book.groups:
          leaf(g.name, pic = glyphIcon(pxStar, black), id = "Employees/group:" & g.id)
    leaf("Import sheets", pic = glyphIcon(pxSheet, black))
    leaf("Letters", pic = glyphIcon(pxDocument, black))
    leaf("Charts", pic = glyphIcon(pxPieChart, black))
    leaf("Alerts", pic = glyphIcon(pxBell, black))
    branch("Settings", settingsOpen, glyphIcon(pxSettings, black), "Settings", true):
      for s in ["Hotels", "Fields", "Allowances", "Lists", "Groups", "Security and backup", "Look"]:
        leaf(s, pic = glyphIcon(pxSettings, black), id = "Settings/" & s)

proc page() =
  if section.startsWith("Employees"):
    if current >= 0 and current < book.employees.len: profilePage()
    else: staffPage()
  elif section == "Import sheets": importPage()
  elif section == "Letters": lettersPage()
  elif section == "Charts": chartsPage()
  elif section == "Alerts": alertsPage()
  elif section.startsWith("Settings"): settingsPage()
  else: dashboard()

proc shell() =
  menus()
  tools()
  let portrait = ui.h > ui.w
  const places = ["Dashboard", "Employees/All hotels", "Import sheets", "Letters",
                  "Alerts", "Settings/Hotels"]
  if portrait:
    var nav = 0
    for i, p in places:
      if section.startsWith(p.split('/')[0]): nav = i
    if bottomNav([(pxHome, "Home"), (pxUser, "Staff"), (pxSheet, "Import"),
                  (pxDocument, "Letters"), (pxBell, "Alerts"), (pxSettings, "Settings")], nav):
      section = places[nav]
      current = -1
  else:
    var active = 0
    for e in book.employees:
      if e.active: inc active
    statusbar(if status.len > 0: status else: $active & " employees in " & $book.hotels.len & " hotels",
              "Locks after " & $book.lockMinutes & " min")
  if portrait:
    panel: page()
  else:
    split(navW, -1):
      let before = section
      navTree()
      if section != before: current = -1        # (a place picked in the tree)
    do:
      panel: page()
  # the dialogs
  editDialog()
  letterDialogs()
  importDialogs()
  settingsDialogs()
  filesDialog()
  case msgBox(askDeleteEmp, AppTitle, "Delete " & (if current >= 0 and current < book.employees.len:
                book.employees[current].name else: "this employee") &
              " for good?\n\nTo keep the record, set the status to Left instead.",
              ["&Delete", "Cancel"], miWarning)
  of 1:
    if current >= 0 and current < book.employees.len:
      book.employees[current].deleted = true
      book.employees[current].modified = nowT()
      current = -1
      changed()
  else: discard
  aboutBox(aboutOpen, AppTitle, AppVersion,
           ["Every employee of your hotels in one private book.",
            "The data stays on this device, sealed with your PIN (Monocypher: XChaCha20-Poly1305, Argon2id).",
            "Made with Retro Nim UI.",
            "Copyright (c) 2026 Sultan Al Isaiee. MIT licence."],
           tagline = "Your staff records, private", iconPng = AppIconPng, glyph = pxDocuments,
           credits = [RetroCredit & " -- " & RetroWebsite & " -- " & RetroEmail,
                      RetroFontCredit,
                      "Encryption: Monocypher (XChaCha20-Poly1305, Argon2id)."])

proc main() =
  dir = dataDir(AppId)
  createDir(dir)
  setupMode = not hasData(dir)
  # (the look chosen in Settings > Look is kept in the settings "HRBook")
  reportedVersion = AppVersion
  openApp(AppTitle, 1280, 800, id = AppId, icon = AppIconPng, look = AppId)
  lastInput = nowT()
  while beginFrame():
    if stoppedFrame(): (endFrame(); continue)
    captionBar()
    if ui.pressed or ui.key != KeyNone or ui.wheel != 0 or ui.typed.len > 0:
      lastInput = nowT()
    # in the background: saved; locked when away too long
    if ui.paused:
      if pausedAt == 0: pausedAt = nowT()
      flushSave()
    elif pausedAt > 0:
      if not locked and nowT() - pausedAt > float(max(1, book.lockMinutes) * 60): lockNow()
      pausedAt = 0
    if locked:
      lockScreen()
      filesDialog()
    else:
      shell()
      if nowT() - lastInput > float(max(1, book.lockMinutes) * 60): lockNow()
      if st.dirty and nowT() - st.lastSave > 1.5: flushSave()
      if st.dirty: wakeIn(1600)
      wakeIn(30_000)                 # (to lock when left alone)
    if closeRequested():
      flushSave()
    endFrame()
    appFrameDone()
  flushSave()
  closeApp()

main()

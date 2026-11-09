## Tests of what apps are made of: settings rows, avatars, steps, banners,
## pages, the bottom navigation bar, the floating button, the tool bar's
## "more" menu, side panes, and the file widgets (folder model, file list,
## preview, picture cache, dialogs) -- headless, on the fake driver.

import std/[os, strutils, times, unicode]
import retroui
import retroui/appicon
import retroui/uirelays/input
import harness

fakeDriver()
startApp("apps", W, H)

proc waitFor(cond: proc (): bool; what: string; seconds = 10.0) =
  ## Frames until `cond` (work on the worker threads takes real time).
  let until = epochTime() + seconds
  while not cond():
    doAssert epochTime() < until, "timed out: " & what
    run()
    os.sleep(2)

# ---- settings rows ----------------------------------------------------------------------------

block settingsRows:
  var on = false
  var choice = 0
  var level = 40
  var clicked = 0
  var linked = false
  var rows: array[5, Rect]
  view = proc () =
    settingToggle("Wi-Fi", on, "Wireless networks")
    rows[0] = ui.lastRect
    settingChoice("Sync", ["Hourly", "Daily", "Never"], choice)
    rows[1] = ui.lastRect
    settingSlider("Level", level, 0, 100, suffix = "%")
    rows[2] = ui.lastRect
    let b = settingButtons("Size", ["Smaller", "Normal", "Larger"])
    if b > 0: clicked = b
    rows[3] = ui.lastRect
    if settingLink("More", "Other things"): linked = true
    rows[4] = ui.lastRect
  run(2)
  doAssert rows[0].w > W div 2 and rows[0].h >= ItemH, "a row is as wide as the window"
  click(rows[0], dx = 20)
  doAssert on, "a click anywhere on the row flips the switch"
  click(rows[0], dx = rows[0].w - 20)
  doAssert not on
  # the last segment of the choice is at the right of its row
  click(rows[1], dx = rows[1].w - 20)
  doAssert choice == 2, $choice
  click(rows[3], dx = rows[3].w - 20)
  doAssert clicked == 3, $clicked
  click(rows[4], dx = 30)
  doAssert linked
  # Space on the focused switch row flips it too
  key(KeyTab)
  run()

block appearance:
  # ($RETRO_SCALE and $RETRO_THEME win over what was kept: the systems
  # workflow sets the first)
  delEnv("RETRO_SCALE")
  delEnv("RETRO_THEME")
  var s: Settings
  ui.theme = Dark
  setUiScale(125)
  storeAppearance(s)
  ui.theme = Classic
  setUiScale(100)
  restoreAppearance(s)
  doAssert themeIndex() == 2 and uiScale() == 125
  ui.theme = Classic
  setUiScale(100)
  view = proc () = appearanceSettings()
  run(2)

# ---- small widgets ---------------------------------------------------------------------------

block avatarsStepsPages:
  doAssert initialsOf("Sultan Al-Said") == "SA"
  doAssert initialsOf("omar") == "O"
  doAssert initialsOf("مريم البلوشي").runeLen == 2
  doAssert initialsOf("") == ""
  var step = 2
  var picked = -1
  var page = 0
  var stepR, pageR: Rect
  view = proc () =
    let s = stepper(["Cart", "Address", "Payment", "Done"], step)
    if s >= 0: picked = s
    stepR = ui.lastRect
    row:
      discard pager(page, 12)
    pageR = ui.lastRect
  run(2)
  let slot = stepR.w div 4
  # a step already done can be clicked; one not reached yet cannot
  click(rect(stepR.x + slot div 2 - 5, stepR.y, 10, FontH + 8), dx = 5)
  doAssert picked == 0, $picked
  picked = -1
  click(rect(stepR.x + slot * 3 + slot div 2 - 5, stepR.y, 10, FontH + 8), dx = 5)
  doAssert picked == -1
  # the pager's last button is "next"
  click(pageR, dx = pageR.w - 8)
  doAssert page == 1, $page
  doAssert pager(page, 1) == false

block bannerButtons:
  var got = -2
  var r: Rect
  view = proc () =
    let b = banner("Saved.", bkSuccess, ["Undo"])
    if b >= 0: got = b
    r = ui.lastRect
  run(2)
  click(r, dx = r.w - CtrlH div 2)            # the x at the right
  doAssert got == 0, $got
  got = -2
  click(r, dx = r.w - CtrlH - dp(30))          # "Undo" left of it
  doAssert got == 1, $got

block barsAndFloatingButton:
  var nav = 0
  var fabbed = false
  var under = 0
  var listR: Rect
  view = proc () =
    statusbar("ready")
    bottomNav([(nfHome, "Home"), (nfSearch, "Search"), (nfUser, "Me")], nav)
    if fab(nfPlus, "Add"): fabbed = true
    # a button under the floating one
    let h = remainingH()
    if button("Under", w = W - 2 * Pad): inc under
    listR = ui.lastRect
    discard h
  run(2)
  doAssert listR.y + listR.h <= H - FontH - 8, "content stays above the bars"
  # the middle item of the navigation bar
  let navY = H - FontH - 8 - dp(20)
  down(W div 2, navY)
  up(W div 2, navY)
  run(2)
  doAssert nav == 1, $nav

# ---- the tool bar's "more" menu --------------------------------------------------------------

block toolbarOverflow:
  var hits: array[30, int]
  var moreR: Rect
  view = proc () =
    toolbar:
      for i in 0 ..< 30:
        if toolButton("B" & $i, "Button " & $i): inc hits[i]
      moreR = ui.lastRect
  run(2)
  doAssert moreR.x + moreR.w <= W, "the more button is on the screen"
  # the last button did not fit: it is in the menu
  click(moreR, dx = moreR.w div 2)
  run()
  # the menu lists the buttons that did not fit; pick the last one
  var picked = false
  for y in countdown(H - 4, moreR.y + moreR.h, 2):
    discard
  key(KeyEnd)                                  # (keys move through the menu)
  run()
  key(KeyUp)
  run()
  key(KeyDown)
  run()
  key(KeyEnter)
  run(3)
  for i in 0 ..< 30:
    if hits[i] > 0: picked = true
  doAssert picked, "an item of the more menu clicks its button"

# ---- side panes ----------------------------------------------------------------------------

block sidePanes:
  var mainR, paneR: Rect
  var pw = 200
  var ph = 120
  view = proc () =
    sidePane(true, pw, ph):
      mainR = canvas(0, remainingH())
    do:
      paneR = canvas(0, remainingH())
  run(2)
  doAssert paneR.x > mainR.x + mainR.w, "wide: the pane is beside"
  doAssert abs(paneR.w - dp(200)) <= 2, $paneR.w
  doAssert paneBeside(200) and not paneBeside(2000)

# ---- the file widgets -------------------------------------------------------------------------

let root = getTempDir() / "retro-apps-test"
removeDir(root)
createDir(root / "sub" / "deep")
for n in ["photo 10.png", "photo 2.png", "notes.txt", "readme.md"]:
  writeFile(root / n, "x")
writeFile(root / "notes.txt", "first line\nsecond line\n")
writeFile(root / "sub" / "deep" / "needle.txt", "found me")
# a real picture
var px = newSeq[uint32](64 * 48)
for i, p in px.mpairs: p = 0xFF2080C0'u32
let bytes = png(64, 48, px)
var data = newString(bytes.len)
for i, b in bytes: data[i] = char(b)
writeFile(root / "photo 2.png", data)
writeFile(root / "photo 10.png", data)

block folderModel:
  let m = newFolderModel(root)
  view = proc () = discard fileList(m)
  waitFor(proc (): bool = m.dir == root and not m.loading, "the listing")
  var names: seq[string]
  for it in m.items: names.add it.name
  doAssert names == @["sub", "notes.txt", "photo 2.png", "photo 10.png", "readme.md"], $names
  doAssert m.folderStats.files == 4 and m.folderStats.folders == 1
  m.setFilter("photo")
  doAssert m.items.len == 2
  m.setFilter("")
  # into a folder and back up: the folder we were in is selected
  m.open(root / "sub")
  waitFor(proc (): bool = m.dir == root / "sub" and not m.loading, "sub")
  doAssert m.canGoBack and m.canGoUp
  m.goUp()
  waitFor(proc (): bool = m.dir == root and not m.loading, "up")
  doAssert m.current.name == "sub", m.current.name
  # files made and renamed show up selected
  doAssert m.makeFolder("new one") == ""
  waitFor(proc (): bool = m.current.name == "new one", "the new folder")
  doAssert m.makeFolder("new one").len > 0, "a name already there"
  doAssert m.makeFolder("a/b").len > 0, "a name with a slash"
  doAssert m.rename(root / "new one", "renamed") == ""
  waitFor(proc (): bool = m.current.name == "renamed", "the renamed folder")
  # another program changes the folder: it is listed again
  writeFile(root / "late.txt", "hello")
  ticks += 2000
  waitFor(proc (): bool =
    for it in m.items:
      if it.name == "late.txt": return true
    ticks += 100
    false, "the change")
  # a search through the subfolders
  m.search("needle")
  waitFor(proc (): bool = not m.searchBusy, "the search")
  doAssert m.items.len == 1 and m.items[0].name == "needle.txt"
  m.stopSearch()                     # back to this folder, still filtered
  doAssert m.items.len == 0 and m.filter == "needle"
  m.setFilter("")
  doAssert m.items.len > 1
  # selection
  m.selectAll()
  doAssert m.markedCount == m.items.len
  m.clearSelection()
  doAssert m.selectedItems.len == 0, "none marked: nothing selected"
  # a folder that is not there
  m.open(root / "nothing here")
  waitFor(proc (): bool = not m.loading, "the error")
  doAssert m.error.len > 0 and m.dir == root, "the old listing stays"

block fileListEvents:
  let m = newFolderModel(root)
  var ev: FileListEvent
  var r: Rect
  view = proc () =
    ev = fileList(m, fvDetails)
    r = ui.lastRect
  waitFor(proc (): bool = m.dir == root and not m.loading and m.items.len > 3, "listing")
  run(2)
  # double click on the first row (the header is above it)
  let rowY = r.y + ItemH + 4 + ItemH div 2
  var activated = false
  view = proc () =
    ev = fileList(m, fvDetails)
    r = ui.lastRect
    if ev.activated: activated = true
  down(r.x + 40, rowY, clicks = 1)
  up(r.x + 40, rowY)
  run()
  down(r.x + 40, rowY, clicks = 2)
  up(r.x + 40, rowY)
  run(2)
  doAssert activated, "a double click activates the row"

block thumbnailsAndCache:
  let m = newFolderModel(root)
  view = proc () = discard fileList(m, fvIcons)
  waitFor(proc (): bool = m.dir == root and not m.loading, "listing")
  waitFor(proc (): bool = pictures().get(root / "photo 2.png", 64, 64,
                           getLastModificationTime(root / "photo 2.png").toUnix) != nil,
          "a thumbnail")
  # a small cache drops what was not used lately
  let c = newPictureCache(budget = 64 * 48 + 10)
  view = proc () =
    discard c.get(root / "photo 2.png", 300, 300)
    discard c.get(root / "photo 10.png", 300, 300)
  waitFor(proc (): bool = not c.loading(root / "photo 2.png") and
                          not c.loading(root / "photo 10.png"), "decoding")
  run(3)
  doAssert c.pixelsKept <= 2 * 64 * 48
  # a file that is not a picture
  view = proc () = discard c.get(root / "notes.txt", 64, 64)
  waitFor(proc (): bool = c.failed(root / "notes.txt"), "the failure")
  view = proc () = pictureBox(root / "notes.txt", 80, 80)
  run(2)

block previewPane:
  let m = newFolderModel(root)
  view = proc () = discard filePreview(m)
  waitFor(proc (): bool = m.dir == root and not m.loading, "listing")
  run(2)
  # one item: the text file
  for i, it in m.items:
    m.marked[i] = it.name == "notes.txt"
    if it.name == "notes.txt": m.sel = i
  var ev: PreviewEvent
  view = proc () = ev = filePreview(m)
  run(2)
  # a folder: measured as it is shown
  for i, it in m.items:
    m.marked[i] = it.name == "sub"
  run(5)
  # several
  for i in 0 ..< m.marked.len: m.marked[i] = true
  run(2)

block textAndHexViews:
  var t = openTextFile(root / "notes.txt")
  let h = openHexFile(root / "notes.txt")
  var sel = 0
  view = proc () =
    textFileView(t, sel)
  run(3)
  doAssert t.done and textFileStatus(t).startsWith("2 lines")
  view = proc () = hexFileView(h, sel)
  run(2)
  t.close()
  h.close()

block dialogs:
  # properties of a folder: measured while open
  var open = true
  let items = @[infoOf(root / "sub")]
  view = proc () = propertiesDialog(open, items)
  run(5)
  key(KeyEsc)
  run(2)
  doAssert not open
  # a copy job with its progress box
  createDir(root / "copies")
  var job = newJob(jkCopy, [root / "notes.txt", root / "sub"], root / "copies")
  var over = false
  view = proc () =
    if runJobDialog(job, "Copying"): over = true
  waitFor(proc (): bool = over, "the job")
  doAssert fileExists(root / "copies" / "notes.txt")
  doAssert fileExists(root / "copies" / "sub" / "deep" / "needle.txt")
  doAssert jobSummary(job).startsWith("Copied")
  # again: the names are taken, it asks
  job = newJob(jkCopy, [root / "notes.txt"], root / "copies")
  over = false
  run(3)
  doAssert job.state == jsAsking
  key(KeyEnter)                                    # Replace (the default)
  run(3)
  waitFor(proc (): bool = over, "the second job")
  # the file picker: type a name and open it
  var pickOpen = true
  var path = root
  var picked = false
  view = proc () =
    if filePicker(pickOpen, path): picked = true
  waitFor(proc (): bool = not pictures().isNil and ui.frameNo > 0, "frames")
  run(10)
  os.sleep(50)
  run(5)

removeDir(root)
echo "apps tests passed"

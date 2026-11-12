## Desktop parts of retroui/desktop: windows inside the window (MDI), find
## and replace, shortcuts, the About box -- headless.

import std/[strutils, os]
import retroui
import retroui/[desktop, inspect]
import retroui/uirelays/[input, services]
import harness

fakeDriver()
startApp("desktop", W, H)

proc tap(x, y: int) =
  down(x, y)
  run()
  up(x, y)
  run()

# ---- windows in the window -------------------------------------------------------------------------

var w1 = MdiWindow(title: "Accounts", r: rect(10, 10, 300, 200), open: true)
var w2 = MdiWindow(title: "Invoices", r: rect(150, 100, 300, 200), open: true)
var clicks1, clicks2 = 0
var area: Rect

block mdi:
  view = proc () =
    mdiArea(-1):
      area = ui.lastRect
      mdiWindow(w1):
        if button("One"): inc clicks1
        for i in 0 ..< 30: label "line " & $i
      mdiWindow(w2):
        if button("Two"): inc clicks2
  run(3)
  let barH = FontH + dp(4)
  # w2 is on top: its title bar is the active (navy) one
  let t2 = (area.x + w2.r.x + w2.r.w div 2, area.y + w2.r.y + 4 + barH div 2)
  let t1 = (area.x + w1.r.x + w1.r.w div 2, area.y + w1.r.y + 4 + barH div 2)
  doAssert px(t2[0] + 60, t2[1]) == 0x000080, "the window on top is active"
  doAssert px(t1[0] + 60, t1[1]) != 0x000080
  # a click on the lower window brings it to the front
  tap(t1[0] + 40, t1[1])
  run(2)
  doAssert px(t1[0] + 60, t1[1]) == 0x000080, "brought to the front"
  # where the windows overlap, the one on top takes the click
  let over = (area.x + 200, area.y + 140)       # inside both
  tap(over[0], over[1])
  run(2)
  doAssert px(t1[0] + 60, t1[1]) == 0x000080, "a click on the top window keeps it on top"
  # dragging the title bar moves it
  let x0 = w1.r.x
  down(t1[0] + 40, t1[1])
  run()
  for i in 1 .. 4:
    move(t1[0] + 40 + i * 10, t1[1] + i * 5)
    run()
  up(t1[0] + 80, t1[1] + 20)
  run()
  doAssert w1.r.x == x0 + 40 and w1.r.y == 30, $w1.r
  # the right edge sizes it
  let ex = area.x + w1.r.x + w1.r.w - 2
  let ey = area.y + w1.r.y + w1.r.h div 2
  let wBefore = w1.r.w
  down(ex, ey)
  run()
  move(ex + 50, ey)
  run()
  up(ex + 50, ey)
  run()
  doAssert w1.r.w == wBefore + 50, $w1.r
  # Ctrl+F6: the next window comes to the front
  key(KeyF6, {CtrlPressed})
  run(2)
  doAssert px(area.x + w2.r.x + w2.r.w div 2 + 60, area.y + w2.r.y + 4 + barH div 2) == 0x000080
  # maximize fills the area, restore brings it back (Windows 95's buttons:
  # the close button at the right, two pixels apart)
  let xw = barH + dp(2)
  let mx = area.x + w2.r.x + w2.r.w - 4 - xw - barH div 2
  tap(mx, area.y + w2.r.y + 4 + barH div 2)
  run(2)
  doAssert w2.maximized
  tap(area.x + area.w - 1 - xw - barH div 2, area.y + 1 + barH div 2)
  run(2)
  doAssert not w2.maximized, "the restore button"
  # minimize: an icon at the bottom; a double click restores it
  let mn = area.x + w2.r.x + w2.r.w - 4 - xw - barH - barH div 2
  tap(mn, area.y + w2.r.y + 4 + barH div 2)
  run(2)
  doAssert w2.minimized
  let iy = area.y + area.h - dp(4) - (dp(32) + FontH + dp(6)) + dp(10)
  down(area.x + dp(4) + dp(38), iy, clicks = 1)
  run()
  up(area.x + dp(4) + dp(38), iy)
  run()
  down(area.x + dp(4) + dp(38), iy, clicks = 2)
  run()
  up(area.x + dp(4) + dp(38), iy)
  run(2)
  doAssert not w2.minimized, "a double click on the icon restores it"
  # the close button closes that window only (as Ctrl+F4)
  tap(area.x + w2.r.x + w2.r.w - 4 - barH div 2, area.y + w2.r.y + 4 + barH div 2)
  run(2)
  doAssert not w2.open and w1.open, "the close button"
  w2.open = true
  run(2)
  # Windows 3.1's buttons: maximize at the right, no close button
  captionButtons = cbWin31
  run(2)
  tap(area.x + w2.r.x + w2.r.w - 4 - barH div 2, area.y + w2.r.y + 4 + barH div 2)
  run(2)
  doAssert w2.open and w2.maximized, "3.1: the maximize button at the right"
  w2.maximized = false
  captionButtons = cbWin95
  run(2)
  # Tile lays them side by side; Ctrl+F4 closes the active one
  mdiTile()
  run(3)
  doAssert w1.r.y == w2.r.y and w1.r.x != w2.r.x and not w1.maximized, $w1.r & " " & $w2.r
  key(KeyF4, {CtrlPressed})
  run(3)
  doAssert not (w1.open and w2.open), "Ctrl+F4 closed one"
  w1.open = true
  w2.open = true
  mdiCascade()
  run(3)
  doAssert w2.r.x != w1.r.x
  # the button inside a window works
  let c0 = clicks1 + clicks2
  mdiActivate(w1)
  run(3)
  tap(area.x + w1.r.x + 4 + Pad + 10, area.y + w1.r.y + 4 + barH + 1 + Pad + 8)
  doAssert clicks1 + clicks2 == c0 + 1, "a click on the button in the window"
  # Always on Top: the pinned window stays over the other one, even when
  # the other is clicked or activated
  w1.r = rect(10, 10, 300, 200)
  w2.r = rect(150, 100, 300, 200)
  w1.pinned = true
  run(3)
  mdiActivate(w2)
  run(3)
  # (w2 is the active one, under w1)
  doAssert px(area.x + w2.r.x + w2.r.w - 100, area.y + w2.r.y + 5) == 0x000080,
    "activated under the pinned window"
  let mid = (area.x + 200, area.y + 140)             # inside both
  let c1 = clicks1
  let c2 = clicks2
  tap(mid[0], mid[1])
  run(2)
  # (the click lands on w1, over w2: w2's content is not reached)
  doAssert px(area.x + w1.r.x + w1.r.w div 2 + 60, area.y + w1.r.y + 4 + barH div 2) == 0x000080,
    "the pinned window takes the click and is the active one"
  doAssert clicks2 == c2
  discard c1
  # maximized: the pin waits (the other one comes over it), restored: on top again
  w1.maximized = true
  mdiActivate(w2)
  run(3)
  doAssert w1.pinned, "kept, waiting"
  doAssert px(area.x + w2.r.x + w2.r.w div 2 + 60, area.y + w2.r.y + 4 + barH div 2) == 0x000080,
    "a maximized window is not kept on top"
  w1.maximized = false
  mdiActivate(w2)
  run(3)
  doAssert px(area.x + w2.r.x + w2.r.w - 100, area.y + w2.r.y + 5) == 0x000080
  # unpinned from the Window menu's command: w2 comes over it again
  w1.pinned = false
  mdiActivate(w2)
  run(3)
  doAssert px(area.x + w2.r.x + w2.r.w div 2 + 60, area.y + w2.r.y + 4 + barH div 2) == 0x000080
  # the pin in the title bar, clicked: on; again: off (the title bar's drag
  # does not take its press)
  let bh = FontH + dp(5)
  let pinX = area.x + w2.r.x + w2.r.w - dp(5) - (bh + dp(2)) - 2 * bh - dp(2) - bh div 2
  let pinY = area.y + w2.r.y + dp(5) + bh div 2
  doAssert not w2.pinned
  tap(pinX, pinY)
  run(2)
  doAssert w2.pinned, "the pin clicked"
  tap(pinX, pinY)
  run(2)
  doAssert not w2.pinned, "clicked again: off"
  # a window with no pin (noPin, Program Manager's groups): the place of the
  # pin is the title bar's, and it is never kept on top
  w2.noPin = true
  w2.pinned = true
  run(2)
  doAssert not w2.pinned, "a window with no pin is not kept on top"
  tap(pinX, pinY)
  run(2)
  doAssert not w2.pinned, "no pin to click"
  w2.noPin = false

# ---- a dialog's close button --------------------------------------------------------------------

block dialogClose:
  # Windows 95's close button at the right of a dialog's title bar does what
  # Esc does; a press that leaves it does nothing; 3.1's buttons: none there
  let tb = FontH + dp(5)                   # (a dialog's title bar)
  var open = true
  var first: Rect
  view = proc () =
    dialog(open, "Page setup", 300):
      label "Copies"
      first = ui.lastRect
  run(3)
  let w = dp(300)
  let xc = (ui.w - w) div 2 + w - 5 - tb div 2
  let yc = first.y - Pad - 1 - tb div 2
  doAssert px(xc, yc) == 0, "the X's middle: " & $px(xc, yc)
  down(xc, yc)
  run()
  up(xc - 100, yc + 100)
  run(2)
  doAssert open, "a press that leaves it"
  tap(xc, yc)
  run(2)
  doAssert not open, "the close button"
  open = true
  captionButtons = cbWin31
  run(3)
  doAssert px(xc, yc) == 0x000080, "3.1: the title bar there"
  tap(xc, yc)
  run(2)
  doAssert open, "3.1: no close button"
  open = false
  captionButtons = cbWin95
  run(2)
  # a message box: X counts as its last button; a question with no way out
  # but its answers (Yes and No) has it grayed, and Esc still answers
  accessKeep = true
  var asking = true
  var answer = 0
  var choices = @["OK", "Cancel"]
  view = proc () =
    let a = msgBox(asking, "Ledger", "Post them now?", choices, miQuestion)
    if a != 0: answer = a
  run(3)
  var x = findNode(accessLast, "Close", {arButton})
  doAssert x > 0 and asDisabled notin accessLast[x].states
  var xr = nodeRect(accessLast[x])
  doAssert px(xr.x + xr.w div 2, xr.y + xr.h div 2) == 0, "the X black"
  tap(xr.x + xr.w div 2, xr.y + xr.h div 2)
  run(2)
  doAssert not asking and answer == 2, "X: Cancel"
  choices = @["&Yes", "&No"]
  asking = true
  answer = 0
  run(3)
  x = findNode(accessLast, "Close", {arButton})
  doAssert x > 0 and asDisabled in accessLast[x].states, "grayed"
  xr = nodeRect(accessLast[x])
  doAssert px(xr.x + xr.w div 2, xr.y + xr.h div 2) == 0x808080, "the X gray"
  tap(xr.x + xr.w div 2, xr.y + xr.h div 2)
  run(2)
  doAssert asking and answer == 0, "a grayed X does nothing"
  key(KeyEsc)
  run(2)
  doAssert not asking and answer == 2, "Esc: the last button"
  accessKeep = false
  view = proc () = discard
  run(2)

# ---- find and replace ---------------------------------------------------------------------------

block finding:
  let t = "The cat sat. Concatenate cats! cat"
  doAssert findIn(t, "cat", 0) == 4
  doAssert findIn(t, "cat", 5) == 16, "inside a word when not whole words"
  doAssert findIn(t, "cat", 5, wholeWord = true) == 31
  doAssert findIn(t, "CAT", 0, matchCase = true) == -1
  doAssert findIn(t, "cat", 32, wrap = true) == 4, "goes round the end"
  doAssert findIn(t, "cat", 32, wrap = false) == -1
  doAssert findIn(t, "cat", 31, backwards = true) == 25
  doAssert findIn(t, "", 0) == -1 and findIn("", "x", 0) == -1
  var s = "a cat, a CAT, a category"
  doAssert replaceAllIn(s, "cat", "dog", wholeWord = true) == 2
  doAssert s == "a dog, a dog, a category", s
  var u = "aaa"
  doAssert replaceAllIn(u, "a", "aa") == 3 and u == "aaaaaa", "no loop on its own result"

block findBarKeys:
  var f = FindState(open: true, replacing: true)
  var ev: FindEvent
  view = proc () =
    let e = findBar(f)
    if e.next or e.prev or e.closed or e.replace or e.replaceAll: ev = e
  run(3)
  typeText("cat")
  run()
  doAssert f.what == "cat", "the bar takes the keyboard when it opens: " & f.what
  key(KeyEnter)
  run()
  doAssert ev.next
  ev = FindEvent()
  key(KeyEnter, {ShiftPressed})
  run()
  doAssert ev.prev
  ev = FindEvent()
  key(KeyF3)
  run()
  doAssert ev.next
  ev = FindEvent()
  key(KeyA, {AltPressed})
  run(2)
  doAssert ev.replaceAll, "Alt+A: Replace all"
  key(KeyEsc)
  run(2)
  doAssert ev.closed and not f.open

# ---- shortcuts ----------------------------------------------------------------------------------

block shortcuts:
  doAssert hotkeyText(KeyS, {CtrlPressed, ShiftPressed}) == "Ctrl+Shift+S"
  doAssert parseHotkey("ctrl+shift+s") == (KeyS, {CtrlPressed, ShiftPressed})
  doAssert parseHotkey("Alt+F4") == (KeyF4, {AltPressed})
  doAssert parseHotkey("Ctrl+Nothing").key == KeyNone
  doAssert parseHotkey("").key == KeyNone and parseHotkey("+").key == KeyNone
  # (Cmd is the shortcut key on every system: a Mac's Cmd+S is Ctrl+S here)
  doAssert parseHotkey("Cmd+S") == (KeyS, {CtrlPressed})
  doAssert parseHotkey("Win+E") == (KeyE, {GuiPressed})
  when defined(macosx):
    doAssert hotkeyText(KeyS, {CtrlPressed, ShiftPressed}) == "Cmd+Shift+S"
  else:
    doAssert hotkeyText(KeyE, {GuiPressed}) == "Win+E"
    doAssert parseHotkey("Control+S") == (KeyS, {CtrlPressed})
  var hits = 0
  var keys = "Ctrl+S"
  var r: Rect
  view = proc () =
    if hotkeyPressed(keys): inc hits
    hotkeyEdit(keys)
    r = ui.lastRect
  run(2)
  ui.focus = 0
  run()
  key(KeyS, {CtrlPressed})
  run()
  doAssert hits == 1
  key(KeyS)
  run()
  doAssert hits == 1, "S alone is not Ctrl+S"
  # the box takes the next key as the shortcut
  tap(r.x + 5, r.y + 5)
  key(KeyP, {CtrlPressed, AltPressed})
  run()
  doAssert keys == "Ctrl+Alt+P", keys
  key(KeyBackspace)
  run()
  doAssert keys == ""

# ---- the About box -----------------------------------------------------------------------------

block about:
  var open = true
  view = proc () =
    aboutBox(open, "Ledger", "2.0", ["(c) 2026 Foxoman. A very long line that has " &
             "to wrap inside the dialog instead of running out of its frame."])
  run(3)
  # nothing is drawn right of the dialog: the long line wrapped
  var outside = 0
  for y in 0 ..< H:
    if px(W - 3, y) != 0xFFFFFF: inc outside
  doAssert outside == 0, "the text stays in the dialog"
  key(KeyEnter)
  run(2)
  doAssert not open
  # the new one: a banner, pages of What's New and Credits, Copy Info
  open = true
  view = proc () =
    aboutBox(open, "Ledger", "2.0", ["What it is."], tagline = "Books, as in 1994",
             whatsNew = ["One", "Two"], credits = ["Fonts: ..."])
  run(3)
  let info = aboutInfo("Ledger", "2.0")
  doAssert info.startsWith("Ledger") and "Version: 2.0" in info and "Retro Nim UI " & RetroVersion in info
  doAssert ("System: " & systemName()) in info
  # (the banner: the blue of a 1994 Setup screen, darker down)
  var blue = 0
  for y in 0 ..< H:
    let c = px(W div 2, y)
    if (c and 0xFF) > 60 and ((c shr 16) and 0xFF) < 40: inc blue
  doAssert blue > 20, "a blue banner: " & $blue
  key(KeyEsc)
  run(2)
  doAssert not open

# ---- settings: a file of its own for each name, also on a phone --------------------------------------

block settingsEachName:
  # A phone's driver gives every name the app's one folder: the app's
  # settings and its look's are each a file of their own there, the one
  # they shared before read until written
  let root = getTempDir() / "retro-settings-test"
  removeDir(root)
  createDir(root)
  let desktopDataDir = systemRelays.dataDir
  systemRelays.dataDir = proc (app: string): string = getTempDir() / "retro-settings-test"
  writeFile(root / "settings.ini", "colors=3\nlook.size=125\n")
  var app = loadSettings("Retro Test")
  var look = loadSettings("retro-look")
  doAssert app.get("colors") == "3" and look.get("look.size") == "125", "read from before"
  app.put("colors", 5)
  look.put("look.size", 150)
  doAssert saveSettings("Retro Test", app) and saveSettings("retro-look", look)
  doAssert loadSettings("Retro Test").get("colors") == "5"
  doAssert loadSettings("retro-look").get("look.size") == "150"
  doAssert loadSettings("retro-look").get("colors") == "3", "(the old keys came along)"
  doAssert fileExists(root / "settings" / "Retro Test.ini") and
           fileExists(root / "settings" / "retro-look.ini")
  systemRelays.dataDir = desktopDataDir
  removeDir(root)
  # (a name as a folder's: what Windows cannot take is left out)
  doAssert folderName("Gallery: 2") == (when defined(windows): "Gallery_ 2" else: "Gallery: 2")

echo "desktop tests passed"

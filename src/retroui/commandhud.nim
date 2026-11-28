## The command search: a key (Ctrl+Shift+P, `commandHudKeys`) opens a box over the app, and what
## is typed finds the commands of its menu bar -- every menu and submenu walked, the ones chosen
## lately first, a few letters of each word enough ("sv as" finds File > Save As...) --; Enter or a
## double click does the one picked, exactly as choosing it from its menu would. Every app with a
## menu bar has it, with nothing to write: it reads the menus the app already draws (each frame
## while it is open they are walked, not drawn: `menuWalk` in retroui/widgets).
##
## ```nim
## commandHudKeys = "Ctrl+Shift+Space"   # another key ("" none: the app has its own search)
## if menuItem("Command &Search...", commandHudKeys): openCommandHud()
## ```
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, algorithm]
import uirelays/input
import core, widgets, desktop

template th: untyped = ui.theme
const black = color(0, 0, 0)
const white = color(255, 255, 255)

var
  commandHudKeys* = "Ctrl+Shift+P"
    ## The keys that open the command search ("" none: an app with a search of its own, or
    ## those keys another command's).
  hudOpen: bool
  hudQuery: string
  hudSel: int
  hudShown: seq[int]                   # (the items listed: indexes into `menuWalked`)
  hudFor = "\0"                        # (what they were found for)
  hudRecent: seq[string]               # (the commands chosen lately, newest first: their paths)
  hudPending: seq[string]              # (the one picked: chosen when the menus are walked next)

proc openCommandHud*() =
  ## Opens the command search (what its keys do).
  hudOpen = true
  hudQuery = ""
  hudSel = 0
  hudFor = "\0"
  focusFirstText(inDialog = true)
  ui.redraw = true

proc commandHudOpen*(): bool = hudOpen
  ## The command search is open.

proc commandHudText*(): string = hudQuery
  ## What is typed in the command search.

proc pathText(p: seq[string]): string = p.join(" > ")

proc wordScore(word, label, full: string): int =
  ## (how well one typed word is found: at the start of the command's name, of one of its words,
  ## inside it, in its menus, or its letters in order)
  if label.startsWith(word): return 100
  var start = true
  for i, c in label:
    if start and label.continuesWith(word, i): return 80
    start = c in {' ', '-', '/', '(', '&', '.'}
  if word in label: return 60
  if word in full: return 40
  var k = 0
  for c in label:
    if k < word.len and c == word[k]: inc k
  if k == word.len: return 20
  0

proc hudScore(c: MenuCommand; q: string): int =
  let label = c.path[^1].toLowerAscii
  let full = c.path.pathText.toLowerAscii
  if q.len > 0:
    for w in q.splitWhitespace:
      let s = wordScore(w, label, full)
      if s == 0: return 0
      result += s
  else: result = 1
  let r = hudRecent.find(c.path.pathText)
  if r >= 0: result += 1000 - 10 * r
  if c.enabled: result += 500

proc findCommands() =
  let q = hudQuery.strip.toLowerAscii
  var scored: seq[(int, int)]
  var seen: seq[string]
  for i, c in menuWalked:
    if c.path.len == 0 or c.path[^1] in ["\x01", "-"]: continue   # (the system menu's marks)
    let s = hudScore(c, q)
    if s <= 0: continue
    let key = c.path.pathText
    if key in seen: continue
    seen.add key
    scored.add (-s, i)
  scored.sort()
  hudShown.setLen(0)
  for (_, i) in scored:
    if hudShown.len >= 200: break
    hudShown.add i
  hudSel = clamp(hudSel, 0, max(0, hudShown.high))

proc drawHud() =
  dialog(hudOpen, "Commands", 560):
    label "&Find a command (a few letters of its words):"
    if edit(hudQuery) or hudFor != hudQuery:
      hudFor = hudQuery
      hudSel = 0
    findCommands()
    if canInput():
      let page = 10
      for (k, step) in [(KeyDown, 1), (KeyUp, -1), (KeyPageDown, page), (KeyPageUp, -page)]:
        if keyHit(k):
          hudSel = clamp(hudSel + step, 0, max(0, hudShown.high))
          ui.keyUsed = true
    var rows: seq[string]
    for i in hudShown:
      let c = menuWalked[i]
      var where = c.path[0 ..< c.path.high].pathText
      if c.keys.len > 0: where.add "   " & shortcutText(c.keys)
      if not c.enabled: where.add "   " & tr("(not now)")
      rows.add c.path[^1] & "\t" & where
    if rows.len == 0:
      rows.add(if menuWalked.len == 0: tr("This window has no menus") else: tr("No command has those letters"))
    var go = false
    listbox(rows, hudSel, rows = 12, tabs = [230])
    if doubleClicked() and hudShown.len > 0: go = true
    ui.takesEnter = true              # (Enter is the search's: the command picked, not a default button)
    if canInput() and keyHit(KeyEnter) and hudShown.len > 0:
      ui.keyUsed = true
      go = true
    row:
      spring()
      let can = hudSel in 0 .. hudShown.high and menuWalked[hudShown[hudSel]].enabled
      if button("&Do It", w = dp(90), enabled = can): go = true
      if button("Close", w = dp(90)): hudOpen = false
    if go and hudSel in 0 .. hudShown.high:
      let c = menuWalked[hudShown[hudSel]]
      if c.enabled:
        hudPending = c.path
        let key = c.path.pathText
        let at = hudRecent.find(key)
        if at >= 0: hudRecent.delete(at)
        hudRecent.insert(key, 0)
        if hudRecent.len > 12: hudRecent.setLen(12)
        hudOpen = false
        ui.redraw = true

var
  shortcutSheet* = true
    ## Hold Ctrl (Command on a Mac) alone for a moment and a sheet of every key shortcut of the
    ## menu bar's menus comes up over the app, menu by menu; let go of it and it goes -- the
    ## keys found without opening a menu. Not on touch screens. False: never.
  ctrlHeld: tuple[since: int; on: bool]   # (Ctrl down alone since then; the sheet up)

proc shortcutSheetShown*(): bool = ctrlHeld.on
  ## The sheet of key shortcuts is up now (Ctrl held).

proc watchCtrl() =
  ## (Ctrl held alone, nothing else pressed, the mouse still: after 0.9 s the sheet)
  let alone = CtrlPressed in ui.mods and ui.mods - {CtrlPressed} == {} and not ui.mouseDown and
              ui.wheel == 0 and not ui.touch and shortcutSheet and ui.popup == 0 and ui.dialogTop == 0
  if not alone or ui.key != KeyNone:
    ctrlHeld = (0, false)
    return
  if ctrlHeld.since == 0: ctrlHeld.since = ui.now
  if not ctrlHeld.on:
    if ui.now - ctrlHeld.since >= 900: ctrlHeld.on = true
    else: wakeIn(900 - (ui.now - ctrlHeld.since))

proc drawShortcutSheet() =
  ## (every shortcut of the menus, in columns by menu, on a sheet over the app)
  var groups: seq[tuple[menu: string; rows: seq[(string, string)]]]
  for c in menuWalked:
    if c.keys.len == 0 or c.path.len == 0 or c.path[^1] in ["\x01", "-"]: continue
    let m = c.path[0]
    if groups.len == 0 or groups[^1].menu != m: groups.add (m, @[])
    groups[^1].rows.add (c.path[1 .. ^1].join(" > "), shortcutText(c.keys))
  pushLayer(LayerPopup)
  defer: popLayer()
  let pad = dp(16)
  let colW = dp(230)
  let rowH = FontH + dp(5)
  let cols = max(1, min(groups.len, (ui.w - 2 * pad - dp(40)) div colW))
  var heights = newSeq[int](cols)
  var place: seq[tuple[col, y: int]]
  for g in groups:
    var c = 0
    for k in 1 ..< cols:
      if heights[k] < heights[c]: c = k
    place.add (c, heights[c])
    heights[c] += (g.rows.len + 1) * rowH + dp(10)
  var h = 0
  for x in heights: h = max(h, x)
  if groups.len == 0: h = rowH
  let w = cols * colW + 2 * pad
  let r = rect(ui.winX + (ui.w - w) div 2, ui.winY + max(dp(20), (ui.h - h - 2 * pad - rowH) div 3), w,
               h + 2 * pad + rowH)
  if not frostedFace(r, th.window, float(dp(14))):
    fill(rect(r.x + 3, r.y + 3, r.w, r.h), withAlpha(black, 70))
    fill(r, th.window)
    box(r, th.frame)
  let tst = style(bold = true, size = 1.15)
  text(r.x + pad, r.y + pad - dp(4), tr("Keys"), th.text, tst)
  if groups.len == 0:
    text(r.x + pad, r.y + pad + rowH, tr("This window's menus have no key shortcuts"), th.gray)
  for gi, g in groups:
    let x = r.x + pad + place[gi].col * colW
    var y = r.y + pad + rowH + place[gi].y
    text(x, y, splitMnemonic(g.menu).text, th.text, true)
    y += rowH
    for (label, keys) in g.rows:
      let kw = textWidth(keys)
      text(x, y, ellipsize(splitMnemonic(label).text, colW - kw - dp(24)), th.text)
      text(x + colW - dp(12) - kw, y, keys, th.gray)
      y += rowH
  if accessOn: accessNode(arDialog, tr("Keys"), r = r)

proc hudBefore() =
  if not hudOpen and commandHudKeys.len > 0 and hotkeyPressed(commandHudKeys): openCommandHud()
  watchCtrl()
  # (walked this frame: to list them, or to choose the one picked, or for the keys' sheet, or
  # for the system's menu bar)
  let mirrored = menuBarElsewhere != nil and menuBarElsewhere()
  menuWalk = hudOpen or hudPending.len > 0 or ctrlHeld.on or mirrored
  if menuWalk:
    menuWalked.setLen(0)
    if hudPending.len > 0:
      menuWalkRun = hudPending
      hudPending.setLen(0)

var menuMirror*: proc () {.nimcall.}
  ## (called after the menus were walked for the system's menu bar: retroui/macmenu builds it
  ## from `menuWalked`)

proc pickMenuCommand*(path: seq[string]) =
  ## Chooses the menu item at `path` (its menus and label, as `menuWalked` has it) when the menus
  ## are walked next -- as a click on it would (the system's menu bar's items do it).
  hudPending = path
  ui.redraw = true

proc hudAfter() =
  if menuMirror != nil and menuBarElsewhere != nil and menuBarElsewhere(): menuMirror()
  menuWalk = false
  menuWalkRun.setLen(0)          # (not found: its menu changed meanwhile)
  if hudOpen: drawHud()
  elif ctrlHeld.on: drawShortcutSheet()

menubarHooks = (hudBefore, hudAfter)

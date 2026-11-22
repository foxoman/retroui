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
    if c.path.len == 0: continue
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

proc hudBefore() =
  if not hudOpen and commandHudKeys.len > 0 and hotkeyPressed(commandHudKeys): openCommandHud()
  # (walked this frame: to list them, or to choose the one picked)
  menuWalk = hudOpen or hudPending.len > 0
  if menuWalk:
    menuWalked.setLen(0)
    if hudPending.len > 0:
      menuWalkRun = hudPending
      hudPending.setLen(0)

proc hudAfter() =
  menuWalk = false
  menuWalkRun.setLen(0)          # (not found: its menu changed meanwhile)
  if hudOpen: drawHud()

menubarHooks = (hudBefore, hudAfter)

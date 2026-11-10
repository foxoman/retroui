## The inspector: F12 over any app (in a debug build, or with
## RETRO_INSPECT=1 in any build: then it is shown from the start). A panel
## at the side shows
##
## - the frame: how long it took to build, how many ran in the last second;
## - why it ran -- the input it took, or the line of the program that asked
##   for it (`ui.redraw = true`, `wakeIn`) -- and what the next one waits
##   for: an app at rest waits for input;
## - the control under the mouse, outlined (its kind, name, value, id,
##   place, states) and the one with the focus;
## - the tree of the frame's controls, as a screen reader gets it.
##
## Shift+F12 moves the panel to the other side. It takes no click and no
## key but those: what is under it still gets them.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, monotimes, times]
import core, gfx
import uirelays/[input, access]

var
  inspectorOn = false                  # shown now
  inspectorKey = false                 # F12 shows and hides it
  inspectorLeft = false                # at the left (Shift+F12)
  frameStart: MonoTime
  frameMs: float                       # the last frame's build time
  recent: seq[MonoTime]                # the frames of the last second

proc inspectorShown*(): bool = inspectorOn
  ## The inspector is shown.

proc showInspector*(on = true) =
  ## Show (or hide) the inspector, as F12 does; it also lets F12 work.
  inspectorOn = on
  inspectorKey = true
  whyFrames = on
  accessKeep = on or accessKeep
  ui.redraw = true

proc kindText(r: AccessRole): string =
  ## (a control's kind as people say it: "Button", "Text field", "List item")
  let raw = ($r)[2 .. ^1]
  for i, c in raw:
    if c.isUpperAscii and i > 0: result.add ' ' & c.toLowerAscii else: result.add c

proc stateNames*(s: set[AccessState]): string =
  ## A node's states: "focusable, focused, default".
  var parts: seq[string]
  for st in s:
    var n = ($st)[2 .. ^1]
    n[0] = n[0].toLowerAscii
    parts.add n
  parts.join(", ")

proc nodeLine*(n: AccessNode): string =
  ## One line for a node: its kind, its name, its value.
  result = kindText(n.role)
  if n.name.len > 0: result.add " \"" & n.name & "\""
  if n.value.len > 0: result.add " = " & n.value

proc logical(n: AccessNode): Rect =
  ## (a node's place in the window's logical pixels, as it is drawn)
  let z = max(1, zoom)
  var x = n.x div z
  let w = n.w div z
  if ui.rtl: x = ui.w - x - w
  rect(x, n.y div z, w, n.h div z)

proc nodeAt*(tree: openArray[AccessNode]; x, y: int): int =
  ## The control at `x`, `y` (logical pixels): the smallest one there, the
  ## window itself when none; -1 for an empty tree.
  result = if tree.len > 0: 0 else: -1
  var best = high(int)
  for i in 1 ..< tree.len:
    let r = logical(tree[i])
    if r.w > 0 and r.h > 0 and x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h:
      let area = r.w * r.h
      if area <= best:
        best = area
        result = i

proc depth(tree: openArray[AccessNode]; i: int): int =
  var p = tree[i].parent
  while p >= 0 and p < tree.len and result < 40:
    inc result
    p = tree[p].parent

proc inspectBegin() =
  if inspectorKey and ui.key == KeyF12 and not ui.keyUsed:
    ui.keyUsed = true
    if ShiftPressed in ui.mods: inspectorLeft = not inspectorLeft
    else:
      inspectorOn = not inspectorOn
      whyFrames = inspectorOn
      accessKeep = inspectorOn or accessKeep
    ui.redraw = true
  if inspectorOn: frameStart = getMonoTime()

proc inspectDraw() =
  if not inspectorOn: return
  let now = getMonoTime()
  frameMs = float((now - frameStart).inMicroseconds) / 1000
  recent.add now
  while recent.len > 0 and (now - recent[0]).inMilliseconds > 1000: recent.delete 0
  let th = ui.theme
  let tree = accessTree
  pushLayer(LayerTip)
  pushClip(rect(0, 0, ui.w, ui.h))
  # what is under the mouse, and the focus, outlined in the app
  let hot = nodeAt(tree, ui.mx, ui.my)
  var focusAt = -1
  for i, n in tree:
    if asFocused in n.states: focusAt = i
  if focusAt > 0: box(inset(logical(tree[focusAt]), -1), Color(r: 0, g: 96, b: 224, a: 255), 2)
  if hot > 0: box(logical(tree[hot]), Color(r: 224, g: 32, b: 32, a: 255), 2)
  # the panel
  let pw = min(380, max(200, ui.w div 2))
  let px = if inspectorLeft: 4 else: ui.w - pw - 4
  let panel = rect(px, 4, pw, ui.h - 8)
  fill(rect(panel.x + 3, panel.y + 3, panel.w, panel.h), th.shadow)
  fill(panel, th.window)
  box(panel, th.frame)
  fill(rect(panel.x + 1, panel.y + 1, panel.w - 2, FontH + 6), th.select)
  pushClip(inset(panel, 1))
  text(panel.x + 6, panel.y + 4, "Inspector (F12)", th.selectText, bold = true)
  var y = panel.y + FontH + 12
  let x = panel.x + 8
  template line(s: string; c = th.text; bold = false) =
    text(x, y, s, c, bold)
    y += FontH + 2
  line("Frame: " & formatFloat(frameMs, ffDecimal, 1) & " ms, " & $recent.len &
       " in the last second")
  line("Why: " & (if frameCause.len > 0: frameCause else: "the first"), th.gray)
  let next =
    if ui.redraw: "Next: right away -- ui.redraw = true at " & redrawSite.file & ":" &
                  $redrawSite.line
    elif ui.wakeAt > 0: "Next: in " & $max(0, ui.wakeAt - ui.now) & " ms -- wakeIn at " &
                        wakeSite.file & ":" & $wakeSite.line
    else: "Next: when something happens (at rest)"
  line(next, if ui.redraw or ui.wakeAt > 0: th.text else: th.gray)
  y += 4
  hline(x, y, pw - 16, th.shadow)
  y += 6
  if hot >= 0:
    let n = tree[hot]
    let r = logical(n)
    line("Under the mouse:", bold = true)
    line(nodeLine(n))
    line("id " & toHex(n.id, 8) & ", at " & $r.x & "," & $r.y & ", " & $r.w & " x " & $r.h,
         th.gray)
    if n.states.len > 0: line(stateNames(n.states), th.gray)
    if n.help.len > 0: line(n.help, th.gray)
  if focusAt >= 0:
    line("Focused: " & nodeLine(tree[focusAt]))
  y += 4
  hline(x, y, pw - 16, th.shadow)
  y += 6
  line("The frame's controls (" & $tree.len & "):", bold = true)
  # the tree, from a little before the one under the mouse
  let rows = max(1, (panel.y + panel.h - y - 4) div (FontH + 1))
  var first = max(0, (if hot >= 0: hot else: 0) - rows div 3)
  first = max(0, min(first, tree.len - rows))
  for i in first ..< min(tree.len, first + rows):
    let ind = depth(tree, i) * 10
    if i == hot: fill(rect(x - 2, y - 1, pw - 12, FontH + 1), th.select)
    text(x + ind, y, nodeLine(tree[i]), if i == hot: th.selectText else: th.text)
    y += FontH + 1
  popClip()
  popClip()
  popLayer()

beginFrameHooks.add inspectBegin
endFrameHooks.add inspectDraw

block:
  let v = getEnv("RETRO_INSPECT")
  inspectorKey = not defined(release) or v.len > 0
  if v == "1": showInspector(true)

proc findNode*(tree: openArray[AccessNode]; name: string; roles: set[AccessRole] = {};
               nth = 0): int =
  ## The control called `name` (its name as a screen reader reads it, any
  ## case; failing that, one whose name has it in it), of one of `roles`
  ## (empty: any), the `nth` of them; -1 when there is none. An empty
  ## `name`: any name (the third text box: `findNode(t, "", {arTextField},
  ## 2)`). For tests and the driver: `findNode(accessLast, "OK", {arButton})`.
  let want = name.toLowerAscii
  for pass in 0 .. 1:
    var k = 0
    for i, n in tree:
      if roles.len > 0 and n.role notin roles: continue
      let have = n.name.toLowerAscii
      if (pass == 0 and (want.len == 0 or have == want)) or
         (pass == 1 and want.len > 0 and want in have):
        if k == nth: return i
        inc k
  -1

proc nodeRect*(n: AccessNode): Rect = logical(n)
  ## A node's place in the window's logical pixels (where a click goes).

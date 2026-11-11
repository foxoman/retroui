## Tests of `retroui/dock`: docked panels as Photoshop's -- groups of tabs,
## a column collapsed to icons and its fly-out, a panel dragged to another
## group, to a group of its own, out into a floating palette and back,
## closed and brought back where it was, the bars that share the height,
## kept as JSON -- headless, on the fake driver.

import std/[json, strutils]
import retroui, retroui/dock
import retroui/uirelays/input
import harness

fakeDriver()
startApp("dock", W, H)

var dk = newDock()
discard dk.addColumn()
discard dk.addGroup(0, [dockPanel("color", "Color"), dockPanel("swatches", "Swatches")], share = 30)
discard dk.addGroup(0, [dockPanel("layers", "Layers"), dockPanel("channels", "Channels")], share = 70)
discard dk.addColumn(iconic = true)
discard dk.addGroup(1, [dockPanel("history", "History", nfHistory), dockPanel("actions", "Actions", nfPlay)])
discard dk.addGroup(1, [dockPanel("info", "Info", nfInfo)])

var drawn: seq[string]
var ev = DockEvent()
view = proc () =
  drawn.setLen(0)
  if beginMdi(-1, "ws"):
    ev = dockPanels(dk, "ws", proc (key: string) =
      drawn.add key
      label("the " & key & " panel"))
    endMdi()
run(3)

let a = mdiAreaRect("ws")
let colW = if fingers(): dp(290) else: dp(236)
let iconW = if fingers(): dp(46) else: dp(32)
let gripW = if fingers(): dp(10) else: dp(5)
let mainX = a.x + a.w - colW
let iconX = mainX - iconW

block layout:
  doAssert dk.width == colW + iconW + gripW
  doAssert dk.left == a.w - dk.width, $dk.left
  # the panels shown: the first tab of each open group (the icons show none)
  doAssert drawn == @["color", "layers"], $drawn
  doAssert dk.panelShown("color") and dk.panelShown("layers")
  doAssert not dk.panelShown("swatches") and not dk.panelShown("history")

block tabsAndFolding:
  # a click on a tab shows it
  let tabY = a.y + panelHeaderH() + 4
  let x0 = mainX + dp(6) + textWidth("Color", style(size = 0.9)) + dp(12)
  click(rect(x0, tabY - 4, 20, 8), dx = 4)
  run(2)
  doAssert dk.panelShown("swatches") and not dk.panelShown("color"), $drawn
  doAssert ev.picked == "swatches" or "swatches" in drawn
  # a double-click on the tab shown folds the group to its tabs; a click opens it again
  click(rect(x0, tabY - 4, 20, 8), dx = 4, clicks = 2)
  run(2)
  doAssert dk.columns[0].groups[0].folded
  doAssert "swatches" notin drawn
  click(rect(x0, tabY - 4, 20, 8), dx = 4)
  run(2)
  doAssert not dk.columns[0].groups[0].folded and "swatches" in drawn

block icons:
  # a click on an icon shows its group beside the strip; Esc puts it away
  let iy = a.y + panelHeaderH() + dp(3) + 4
  click(rect(iconX + 4, iy, 10, 10), dx = 4)
  run(2)
  doAssert dk.panelShown("history"), "the fly-out"
  doAssert "history" in drawn
  key(KeyEsc)
  run(2)
  doAssert not dk.panelShown("history")
  # showPanel on a panel of a collapsed column: the fly-out too
  dk.showPanel("info")
  run(2)
  doAssert dk.panelShown("info") and "info" in drawn

block closeAndBack:
  dk.closePanel("channels")
  run(2)
  doAssert not dk.hasPanel("channels")
  dk.showPanel("channels")
  run(2)
  doAssert dk.hasPanel("channels") and dk.panelShown("channels")
  # back in the group it was in
  doAssert dk.columns[0].groups[1].panels.len == 2
  # Window's toggle: shown, closed
  dk.togglePanel("channels")
  doAssert not dk.hasPanel("channels")
  dk.togglePanel("channels")
  doAssert dk.panelShown("channels")

block collapseColumn:
  # the arrows at the top of the main column: icons; again: open
  let hh = panelHeaderH()
  click(rect(mainX + colW - hh - dp(4), a.y, hh, hh), dx = 4)
  run(2)
  doAssert dk.columns[0].iconic
  doAssert dk.width == 2 * iconW + gripW
  click(rect(a.x + a.w - iconW + 2, a.y, iconW - 4, hh), dx = (iconW - 4) div 2)
  run(2)
  doAssert not dk.columns[0].iconic

block gripSizesTheSidePanel:
  # the bar between the documents and the dock: dragged left, the side
  # panel (its open column) widens; right, it narrows
  let gx = iconX - gripW div 2 - 1
  let gy = a.y + a.h div 2
  down(gx, gy)
  run()
  move(gx - 30, gy)
  run()
  move(gx - 60, gy)
  run()
  up(gx - 60, gy)
  run(2)
  doAssert dk.columns[0].width == colW + 60, $dk.columns[0].width
  doAssert dk.width == colW + 60 + iconW + gripW
  doAssert dk.left == a.w - dk.width
  let gx2 = a.x + dk.left + gripW div 2
  down(gx2, gy)
  run()
  move(gx2 + 40, gy)
  run()
  up(gx2 + 40, gy)
  run(2)
  doAssert dk.columns[0].width == colW + 20, $dk.columns[0].width
  # all collapsed to icons: dragged out, the main column opens again
  dk.columns[0].iconic = true
  run(2)
  let gx3 = a.x + dk.left + gripW div 2
  down(gx3, gy)
  run()
  move(gx3 - 30, gy)
  run()
  doAssert dk.columns[0].iconic, "not yet: a little drag"
  move(gx3 - 200, gy)
  run()
  up(gx3 - 200, gy)
  run(2)
  doAssert not dk.columns[0].iconic
  doAssert dk.columns[0].width == iconW + 200, $dk.columns[0].width
  dk.columns[0].width = 0
  run(2)

block dragToAnotherGroup:
  # "Layers" dragged by its tab onto the top group's tabs: it goes there
  run(2)
  let g1 = dk.columns[0].groups[1]
  doAssert g1.panels[g1.sel].key in ["layers", "channels"]
  dk.showPanel("layers")
  run(2)
  # (where the second group's tabs are: under the first group and the bar)
  let hh = panelHeaderH()
  let tabsH = FontH + dp(5) + (if fingers(): dp(8) else: 0)
  let barH = if fingers(): dp(10) else: dp(5)
  let room = a.h - hh - 2 * tabsH - barH
  let top0 = a.y + hh
  # (the second group's tabs: under the first group (30 of 100) and the bar)
  let ty = top0 + tabsH + room * 30 div 100 + barH + tabsH div 2
  let lx = mainX + dp(10)
  down(lx, ty)
  run()
  move(lx + 20, ty - 20)
  run()
  move(lx + 30, top0 + tabsH div 2)
  run()
  move(lx + 140, top0 + tabsH div 2)
  run()
  up(lx + 140, top0 + tabsH div 2)
  run(2)
  doAssert dk.columns[0].groups[0].panels.len == 3, $dk.columns[0].groups[0].panels.len
  var keys: seq[string]
  for p in dk.columns[0].groups[0].panels: keys.add p.key
  doAssert "layers" in keys and dk.panelShown("layers")

block dragOutAndBack:
  # "Layers" dragged out over the documents: a floating palette of its own
  let hh = panelHeaderH()
  let tabsH = FontH + dp(5) + (if fingers(): dp(8) else: 0)
  let top0 = a.y + hh
  # (its tab: the one shown, after Color and Swatches)
  let st = style(size = 0.9)
  let lx = mainX + textWidth("Color", st) + dp(12) + textWidth("Swatches", st) + dp(12) + dp(6)
  down(lx, top0 + tabsH div 2)
  run()
  move(lx - 20, top0 + 40)
  run()
  move(a.x + 120, a.y + 150)
  run()
  up(a.x + 120, a.y + 150)
  run(3)
  doAssert dk.floating.len == 1, $dk.floating.len
  doAssert dk.floating[0].panels[0].key == "layers"
  doAssert dk.panelShown("layers") and "layers" in drawn
  # closed by its box: it goes; shown again: where it was (floating)
  dk.floating[0].win.open = false
  run(2)
  doAssert not dk.hasPanel("layers")
  dk.showPanel("layers")
  run(2)
  doAssert dk.hasPanel("layers")

block keptAsJson:
  let j = dk.toJson
  var dk2 = newDock()
  doAssert dk2.loadDock(j)
  doAssert $dk2.toJson == $j
  doAssert dk2.keys == dk.keys
  doAssert not newDock().loadDock(%*{"x": 1})
  doAssert not newDock().loadDock(nil)

block aPanelThatFails:
  # a panel whose drawing fails (an index out of range): it says so where
  # it is, the program goes on, the fault is in the log for a report
  discard takeFaults()
  dk.showPanel("color")
  var boom = true
  view = proc () =
    if beginMdi(-1, "ws"):
      ev = dockPanels(dk, "ws", proc (key: string) =
        label("the " & key & " panel")
        if key == "color" and boom:
          var s = @[1, 2, 3]
          let i = s.len + int(boom)
          echo s[i])
      endMdi()
  run(3)
  doAssert ui.lastFault.len > 0 and "color" in ui.lastFault, ui.lastFault
  let log = takeFaults()
  doAssert "the color panel" in log and "index" in log, log
  boom = false
  run(3)
  doAssert takeFaults() == ""

echo "test_dock: ok"

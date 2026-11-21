## Retro Atelier on a phone (included by photo.nim): the picture fills the
## screen between a bar at the top -- the menus behind one button, Undo,
## Redo, the pictures open -- and the tools in a strip at the bottom; a
## panel (Layers, Tool Options, Color, Adjustments, Brushes, History) slides
## up under the picture. Two fingers zoom and move the picture; one draws
## with the tool. A tablet, or a phone turned, keeps the desktop's
## workspace when it is wide enough.

const phonePanels = [("layers", "Layers", pxLayers), ("options", "Options", pxSettings),
                     ("color", "Color", pxColorPanel), ("adjustments", "Adjust", pxAdjustLayer),
                     ("brushes", "Brushes", pxBrush), ("history", "History", pxHistory)]

var
  phonePanel = ""                 # the panel under the picture ("": none)
  phoneMenu = false               # the menu bar shown (the button at the top)
  phoneFly = -1                   # (the group whose tools are shown, held)
  phoneBtnH = 0                   # (the panels' buttons: their row's height, last frame)

proc phoneTop() =
  ## The bar at the top: the menus, Undo, Redo, the picture shown.
  let d = cur()
  toolbar:
    if toolButton("\u2261", "Menus", down = phoneMenu): phoneMenu = not phoneMenu
    toolSeparator()
    if toolButton(pxUndo, "Undo", size = 1.3, enabled = d != nil and d.canUndo): runCommand("Undo")
    if toolButton(pxRedo, "Redo", size = 1.3, enabled = d != nil and d.canRedo): runCommand("Redo")
    toolSeparator()
    if toolButton(pxOpen, "Open...", size = 1.3): doCommand("Open...")
    if toolButton(pxSave, "Save", size = 1.3, enabled = d != nil): doCommand("Save")
  # the pictures open: one shown at a time
  var shown: seq[DocWin]
  for dw in docs:
    if dw.win.open: shown.add dw
  if shown.len > 1:
    var names: seq[string]
    for dw in shown: names.add dw.title()
    var at = max(0, shown.find(active))
    let ev = tabStrip(names, at, addButton = false, look = tlPalette)
    if ev.selected and at in 0 .. shown.high: active = shown[at]
    if ev.closed >= 0: shown[ev.closed].win.open = false

proc phoneTools() =
  ## The tools, rows at the bottom: a group's button picks the tool it
  ## shows; held (or a right click), the group's other tools.
  let side = max(toolCell()[0], dp(44))
  var shown: seq[int]
  for g in 0 ..< toolGroups.len:
    if not groupHidden(g): shown.add g
  let perRow = max(1, available() div side)
  let rows = (shown.len + perRow - 1) div perRow
  let strip = canvas(0, rows * side)
  fill(strip, ui.theme.face)
  hline(strip.x, strip.y, strip.w, ui.theme.shadow)
  let cur = groupOf(tool)
  for idx, g in shown:
    let cr = rect(strip.x + (idx mod perRow) * side, strip.y + 1 + (idx div perRow) * side, side, side - 1)
    let grp = toolGroups[g]
    let k = shownItem(g)
    let it = grp.items[k]
    let th = interact(idOf("phone-tool:" & grp.name), cr, focusable = false)
    toolFace(cr, it.glyph, th.down, cur == g, grp.items.len > 1)
    tooltip(it.name)
    if grp.items.len > 1 and ((th.hover and ui.rpressed) or (th.down and longPressed())):
      phoneFly = g
      openPopupMenu("phonefly", cr.x, cr.y)
    elif th.clicked: pickTool(g, k)
  popupMenu("phonefly"):
    if phoneFly in 0 .. toolGroups.high:
      let grp = toolGroups[phoneFly]
      for k, it in grp.items:
        if menuItem(it.glyph & "  " & it.name, checked = itemOn(it)): pickTool(phoneFly, k)

proc phonePanelArea(h: int) =
  ## The panel shown under the picture, `h` high: its tabs, then it.
  var names: seq[string]
  var at = 0
  for i, (key, name, _) in phonePanels:
    names.add name
    if key == phonePanel: at = i
  let ev = tabStrip(names, at, closable = false, addButton = false, look = tlPalette)
  if ev.selected: phonePanel = phonePanels[at][0]
  panel(max(dp(60), h - ui.lastRect.h - Gap)):
    panelBody(phonePanel)

proc phoneFrame() =
  ## One frame of the phone's layout (photoFrame calls it in place of the
  ## workspace's on a narrow screen).
  springTool()
  springKeys()
  modeKeys()
  typeWatch()
  captionBar()
  if phoneMenu: menus()
  phoneTop()
  # the room: the picture, then what is under it (the panels' buttons, the
  # panel, the tools: as tall as it was last frame)
  let panelH = if phonePanel.len > 0: remainingH() * 2 div 5 else: 0
  let side = max(toolCell()[0], dp(44))
  var groups = 0
  for g in 0 ..< toolGroups.len:
    if not groupHidden(g): inc groups
  let toolsH = (groups + max(1, available() div side) - 1) div max(1, available() div side) * side
  let btnH = if phoneBtnH > 0: phoneBtnH else: CtrlH + dp(8)
  let picH = max(dp(120), remainingH() - btnH - toolsH - panelH - 3 * Gap -
                          (if panelH > 0: 2 * Gap else: 0))
  let dw = active
  if dw != nil and dw in docs and dw.win.open:
    docHeight = picH
    dw.docBody()
    docHeight = -1
  else:
    emptyState(pxImage, tr("Open a picture, or start a new one."), h = picH - CtrlH - dp(8))
    row:
      spring()
      if button(tr("&Open...")): doCommand("Open...")
      if button(tr("&New...")): doCommand("New...")
      spring()
  # the panels' buttons: one shows its panel under the picture, again hides it
  row:
    for (key, name, glyph) in phonePanels:
      if toolButton(glyph, name, down = phonePanel == key):
        phonePanel = if phonePanel == key: "" else: key
    spring()
  if ui.lastRect.h > 0 and ui.lastRect.h != phoneBtnH:
    phoneBtnH = ui.lastRect.h
    ui.redraw = true
  if phonePanel.len > 0: phonePanelArea(panelH)
  phoneTools()
  dialogs()
  keys()
  spaceKeyHeld()

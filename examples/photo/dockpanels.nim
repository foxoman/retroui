# Retro Atelier -- included by photo.nim
#
# The panels in the dock (retroui/dock): what each draws, its menu, and what
# a panel brought up does. The dock itself (where each is, collapsed to
# icons, floating) is the toolkit's; `panelList` and `defaultDock` in
# photo.nim say which there are and where they start.

proc panelBody(key: string) =
  ## A panel's content, in the dock's column (as a palette's).
  let d = cur()
  if d == nil and key in ["layers", "channels", "paths"]:
    label("No image open", color = ui.theme.gray)
    return
  case key
  of "color": pickerBody()
  of "swatches": swatchesBody()
  of "scratch": scratchBody()
  of "gradients": gradientsBody()
  of "patterns": patternsBody()
  of "properties": propertiesBody(d)
  of "adjustments": adjustmentsBody()
  of "libraries": librariesBody()
  of "assistant": assistantBody()
  of "layers": layersBody(d)
  of "channels": channelsBody(d)
  of "paths": pathsBody(d)
  of "history": historyBody(d)
  of "navigator": navigatorBody(active)
  of "actions": actionsBody(d)
  of "histogram": histogramBody()
  of "brushes": brushesBody()
  of "brushsettings": brushSettingsBody()
  of "options": optionsBody()
  of "character":
    characterBody()
    typeTargetNote()
  of "paragraph":
    paragraphBody()
    typeTargetNote()
  of "glyphs": glyphsBody()
  of "charstyles": charStylesBody()
  of "parastyles": paraStylesBody()
  of "opentype": openTypeBody()
  of "info": infoPalBody()
  of "commands": cmdPalBody()
  of "styles": stylesBody()
  of "shapes": shapesBody()
  of "toolpresets": toolPresetsBody()
  of "layercomps": layerCompsBody()
  of "clonesource": cloneSourceBody()
  of "quickactions": quickActionsBody()
  of "colorthemes": colorThemesBody()
  of "pages": pagesBody()
  of "vbrushes": vectorBrushesBody()
  of "appearance": appearanceBody()
  of "objectstyles": objectStylesBody()
  of "graphicstyles": graphicStylesBody()
  of "bookmarks": bookmarksBody()
  of "links": linksBody()
  of "separations": separationsBody(d)
  of "attributes": attributesBody(d)
  of "textwrap": textWrapBody(d)
  of "tabs": tabsBody()
  of "tablestyles": tableStylesBody(false)
  of "cellstyles": tableStylesBody(true)
  of "buttons": buttonsBody(d)
  of "conditions": conditionsBody(d)
  of "review": reviewBody(d)
  of "designstyles": designStylesBody(d)
  of "patternoptions": patternOptionsBody(d)
  else: label("(" & key & ")", color = ui.theme.gray)

proc panelMenu(key: string) =
  ## A panel's menu (the dock adds Close and Close Tab Group after it).
  case key
  of "color": colorMenuItems(0)
  of "swatches": colorMenuItems(1)
  of "scratch": colorMenuItems(2)
  of "gradients": colorMenuItems(3)
  of "patterns": colorMenuItems(4)
  of "layers": layerMenuItems(0)
  of "channels": layerMenuItems(1)
  of "paths": layerMenuItems(2)
  of "navigator": histMenuItems(0)
  of "history": histMenuItems(1)
  of "actions": histMenuItems(2)
  of "histogram": histMenuItems(3)
  of "brushes", "options": brushMenuItems()
  of "character", "paragraph", "glyphs": typeMenuItems()
  of "charstyles": stylesMenuItems(false)
  of "parastyles": stylesMenuItems(true)
  of "brushsettings":
    if menuItem("Brush Tip Options..."):
      let t = brushOwner()
      brushOpts = opts[t].tip
      brushOptsNew = false
      brushOptsOpen = true
  of "adjustments": adjustmentsMenu()
  of "properties":
    if menuItem("Adjustment Presets..."): showPanel("adjustments")
  else:
    if menuItem("Panel Options...", enabled = false): discard

proc panelPicked(key: string) =
  ## A panel brought up by its tab or its icon.
  discard key

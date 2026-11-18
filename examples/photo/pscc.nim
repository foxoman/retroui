# Retro Atelier -- included by photo.nim
#
# today's editors as it is today, so that its tutorials can be followed step by
# step: the menus as today's editors has them (Image > Adjustments, Edit >
# Transform, Layer > New, the panels A to Z in Window...), Edit > Search
# (Ctrl+F) over every command and tool, the commands editors added since
# 1994, and the Contextual Task Bar under the image. Drawn as 1994 drew
# things. (With the Retro Atelier 1994 key set, Preferences > Tools, the
# menus are 1994's: `classicMenus`.)

# ---- the menus as data and as menus --------------------------------------------------------------------

var mIndex: tuple[on: bool; path: seq[string]; found: seq[tuple[path, label, cmd: string]]]
  ## while `on`, the menus are walked, not drawn: every item is put in
  ## `found` (Edit > Search looks there)

proc bare(label: string): string =
  ## A label without its mnemonic marks ("&&" is a "&").
  label.replace("&&", "\0").replace("&", "").replace("\0", "&")

template psMenu(title: string; body: untyped) =
  ## A menu of the menu bar (or, walking them, a level of the path).
  if mIndex.on:
    mIndex.path.add bare(title)
    body
    discard mIndex.path.pop()
  else:
    menu title:
      body

template psSub(title: string; body: untyped) =
  ## A submenu (or, walking them, a level of the path).
  if mIndex.on:
    mIndex.path.add bare(title)
    body
    discard mIndex.path.pop()
  else:
    submenu title:
      body

template live(body: untyped) =
  ## Items the menus make as they are drawn (recent files, plug-ins...):
  ## not walked.
  if not mIndex.on:
    body

proc ci(label: string; cmd = ""; enabled = true; checked = false; shortcut = "") =
  ## A menu item that runs command `cmd` (the label's, without "&", when
  ## empty), its keys from the key map.
  let c = if cmd.len > 0: cmd else: bare(label)
  if mIndex.on:
    mIndex.found.add (mIndex.path.join(" > "), bare(label), c)
    return
  let k = keymap.keyFor(c)
  if menuItem(label, (if k.len > 0: k elif c in mappedCmds: "" else: shortcut), checked, enabled):
    runCommand(c)

proc sep() =
  if not mIndex.on: menuSeparator()

proc psFilters(names: openArray[string]) =
  ## Filters, each enabled when the image's mode takes it.
  let d = cur()
  for n in names:
    let b = bare(n).strip(chars = {'.'})
    ci(n, enabled = d != nil and filters.hasKey(b) and d.mode in editModes)

proc psMenus() =
  ## The menu bar as today's editors have it.
  let d = cur()
  let dw = active
  let some = d != nil
  let sel = some and d.hasSelection
  let rgb = some and d.mode in colorModes
  let edits = some and d.mode in editModes
  let grp = some and d.current.group
  let bgl = some and d.current.background
  template bar(body: untyped) =
    if mIndex.on:
      body
    else:
      menubar:
        body
  bar:
    psMenu "&File":
      ci("&New...")
      ci("New &Drawing (SVG)...")
      ci("New &Book...", "New Book...")
      ci("&Open...")
      ci("Open &As...")
      live:
        let recent = recentFiles(loadSettingsCached())
        submenu "Open &Recent":
          for i, f in recent:
            if i >= max(1, prefs.recent): break
            if menuItem("&" & $((i + 1) mod 10) & " " & f.extractFilename.replace("&", "&&")):
              openFile(f)
          if recent.len == 0: discard menuItem("(none)", enabled = false)
          menuSeparator()
          if menuItem("Clear Recent File List", enabled = recent.len > 0):
            var st = loadSettings(AppData)
            st.addRecentFile("", 0)
            discard saveSettings(AppData, st)
            settingsCache.at = -1
      sep()
      ci("&Close", enabled = some)
      ci("Close A&ll", "Close All", enabled = docs.len > 0)
      ci("Close O&thers", enabled = docs.len > 1)
      ci("&Save", enabled = some)
      ci("Save &As...", enabled = some)
      ci("Save a Cop&y...", enabled = some)
      ci("Save as P&DF...", enabled = some)
      ci("Pac&kage...", "Package...", enabled = some)
      ci("Re&vert", enabled = some and d.path.len > 0 and d.modified)
      sep()
      ci("Browse &Assets...", "Browse Assets...")
      ci("S&hare...", "Share...", enabled = some)
      ci("&Mockups...", "Mockups...", enabled = some)
      psSub "&Export":
        ci("&Quick Export as PNG", enabled = some)
        ci("Quick Export as &JPEG", enabled = some)
        ci("&Export As...", enabled = some)
        ci("Art&boards to Files...", "Artboards to Files", enabled = some and d.artboards.len > 0)
        ci("Artboard &Options...", enabled = some and d.artboards.len > 0)
        ci("&Layers to Files...", "Layers to Files...", enabled = some)
        ci("&Slices to Files...", "Slices to Files", enabled = some and slicesOf(d).len > 0)
        sep()
        ci("S&VG...", "SVG...", enabled = some)
        ci("SVG, Type as &Outlines...", "SVG, Type as Outlines...", enabled = some)
        sep()
        ci("E&PUB...", "Export EPUB...", enabled = some)
        ci("Publish as &Web Page...", "Publish as Web Page...", enabled = some)
      sep()
      ci("Place &Embedded...", "Place...", enabled = some)
      ci("Place Lin&ked...", "Place Linked...", enabled = some)
      ci("Place as &Layer...", "Layer from File...", enabled = some)
      sep()
      psSub "Au&tomate":
        ci("&Batch...")
        ci("&Image Processor...", "Image Processor...")
        ci("&Contact Sheet...", "Contact Sheet...")
        ci("Crop and S&traighten Photos", "Crop and Straighten Photos", enabled = some)
        ci("&Fit Image...", enabled = some)
        ci("Merge to &HDR Pro...")
        ci("&Photomerge...")
        ci("PDF Prese&ntation...", "PDF Presentation...", enabled = docs.len > 0)
      psSub "S&cripts":
        ci("Script &Editor...", "Script Editor...")
        ci("&Run Script...", "Run Script...")
        let sf = scriptFiles()
        if sf.len > 0:
          sep()
          for f in sf: ci(f.splitFile.name, "Run Script File:" & f)
        sep()
        ci("&Load Files into Stack...")
      sep()
      ci("File &Info...", enabled = some)
      sep()
      ci("&Print...", enabled = some)
      ci("Page Set&up...")
      sep()
      ci("E&xit")
    psMenu "&Edit":
      live:
        let un = some and d.canUndo
        let re = some and d.canRedo
        if menuItem("&Undo" & (if un: " " & d.undoName else: ""), keymap.keyFor("Undo"), enabled = un):
          runCommand("Undo")
        if menuItem("&Redo" & (if re: " " & d.redoName else: ""), keymap.keyFor("Redo"), enabled = re):
          runCommand("Redo")
      if mIndex.on:
        ci("&Undo")
        ci("&Redo")
      ci("T&oggle Last State", enabled = some and (d.canUndo or d.canRedo))
      sep()
      ci("Cu&t", "Cut", enabled = sel)
      ci("&Copy", enabled = some)
      ci("Copy &Merged", enabled = some and d.layers.len > 1)
      ci("&Paste", enabled = some or hasClip)
      psSub "Paste &Special":
        ci("Paste in &Place", "Paste", enabled = hasClip)
        ci("Paste &Into", enabled = sel and hasClip)
        ci("Paste as &Layer...", "Paste Layer...", enabled = some and hasClip)
      ci("Cl&ear", "Clear", enabled = some)
      sep()
      ci("Searc&h...", "Search...")
      ci("&Find/Change...", "Find/Change...")
      ci("As&k AI...", "Ask AI...")
      psSub "Spe&lling":
        ci("&Check Spelling...", "Check Spelling...", enabled = some)
        ci("&Dynamic Spelling", "Dynamic Spelling", checked = dynamicSpelling)
      sep()
      ci("&Fill...", enabled = some)
      ci("&Stroke...", enabled = sel)
      ci("Content-A&ware Fill...", "Content-Aware Fill", enabled = sel and d.mode in editModes)
      ci("Remove with Its Shado&w", "Remove with Its Shadow", enabled = sel and d.mode in editModes)
      sep()
      ci("Content-Aware Sc&ale", "Content-Aware Scale...", enabled = some and d.mode in editModes)
      ci("Pu&ppet Warp", "Puppet Warp", enabled = some)
      ci("Pe&rspective Warp", "Perspective Warp...", enabled = some)
      ci("Free T&ransform", "Free Transform", enabled = some)
      psSub "Transfor&m":
        ci("&Again", "Transform Again", enabled = some and lastXf.set)
        sep()
        ci("&Scale", enabled = some)
        ci("&Rotate", "Free", enabled = some)
        ci("Sk&ew", "Skew", enabled = some)
        ci("&Distort", enabled = some)
        ci("&Perspective", enabled = some)
        ci("&Warp", enabled = some)
        sep()
        ci("Rotate &180°", "Rotate Layer 180°", enabled = some)
        ci("Rotate 90° &Clockwise", "Rotate Layer 90° CW", enabled = some)
        ci("Rotate 90° C&ounter Clockwise", "Rotate Layer 90° CCW", enabled = some)
        sep()
        ci("Flip &Horizontal", "Flip Layer Horizontal", enabled = some)
        ci("Flip &Vertical", "Flip Layer Vertical", enabled = some)
      ci("Auto-Align Layers...", enabled = some and d.layers.len > 1)
      ci("Auto-Blend Layers...", enabled = some and d.layers.len > 1)
      ci("Sk&y Replacement...", enabled = rgb)
      sep()
      ci("Define &Brush Preset...", enabled = sel)
      ci("Define Patter&n...", "Define Pattern", enabled = sel)
      sep()
      psSub "P&urge":
        ci("&Undo History", enabled = some)
        ci("&Clipboard", enabled = hasClip)
        ci("&Snapshot", enabled = some and d.snapshots.len > 0)
        ci("&Pattern", enabled = pattern.len > 0)
        sep()
        ci("&All", "Everything", enabled = some or hasClip)
      live: presetItems()
      sep()
      ci("Color Se&ttings...")
      ci("Assign Profile...", enabled = some and d.mode in {cmRGB, cmIndexed})
      ci("Convert to Profile...", enabled = some and d.mode in {cmRGB, cmIndexed})
      ci("&Ink Manager...", "Ink Manager...", enabled = some)
      ci("New Spot In&k...", "New Spot Ink...", enabled = some)
      sep()
      ci("&Keyboard Shortcuts...")
      ci("Tool&bar...")
      ci("AI Co&nnector...", "AI Connector...")
      psSub "Pre&ferences":
        ci("&General...")
        ci("&Interface...")
        ci("&Workspace...")
        ci("&Tools...")
        ci("&History && Saving...")
        ci("&Performance...")
        ci("&Scratch Disks...")
        ci("&Cursors...")
        ci("T&ransparency && Gamut...")
        ci("&Units && Rulers...")
        ci("Guides, Gri&d && Slices...")
        ci("T&ype...")
        ci("Color &Profiles...")
    psMenu "&Image":
      psSub "&Mode":
        ci("&Bitmap...", enabled = some and d.layers.len == 1 and d.mode == cmGray, checked = some and d.mode == cmBitmap)
        ci("&Grayscale", enabled = some and d.mode != cmGray, checked = some and d.mode == cmGray)
        ci("&Duotone...", enabled = some and d.mode in {cmGray, cmDuotone, cmRGB, cmCMYK, cmLab},
           checked = some and d.mode == cmDuotone)
        ci("&Indexed Color...", enabled = some and d.mode in {cmRGB, cmGray}, checked = some and d.mode == cmIndexed)
        ci("&RGB Color", enabled = some and d.mode != cmRGB, checked = some and d.mode == cmRGB)
        ci("&CMYK Color", enabled = some and d.mode != cmCMYK, checked = some and d.mode == cmCMYK)
        ci("&Lab Color", enabled = some and d.mode != cmLab, checked = some and d.mode == cmLab)
        ci("&Multichannel", enabled = some and d.mode in {cmRGB, cmCMYK, cmLab, cmGray, cmDuotone, cmIndexed},
           checked = some and d.mode == cmMultichannel)
        sep()
        ci("&8 Bits/Channel", enabled = some, checked = some and d.depth notin [16, 32])
        ci("1&6 Bits/Channel", enabled = some and d.mode in {cmRGB, cmGray}, checked = some and d.depth == 16)
        ci("&32 Bits/Channel", enabled = some and d.mode in {cmRGB, cmGray}, checked = some and d.depth == 32)
        sep()
        ci("Color &Table...", enabled = some and d.mode == cmIndexed)
      sep()
      psSub "&Adjustments":
        ci("&Brightness/Contrast...", enabled = edits)
        ci("&Levels...", enabled = edits)
        ci("&Curves...", enabled = edits)
        ci("&Exposure...", enabled = edits)
        ci("Li&ght...", enabled = edits)
        sep()
        ci("&Vibrance...", enabled = rgb)
        ci("&Hue/Saturation...", enabled = rgb)
        ci("Color B&alance...", enabled = rgb)
        ci("Black && &White...", enabled = rgb)
        ci("&Photo Filter...", enabled = rgb)
        ci("Channel &Mixer...", enabled = rgb)
        ci("Color Loo&kup...", enabled = rgb)
        ci("Match Colo&r...", "Match Color...", enabled = rgb)
        sep()
        ci("&Invert", enabled = edits)
        ci("P&osterize...", enabled = edits)
        ci("&Threshold...", enabled = edits)
        ci("&Gradient Map...", enabled = rgb)
        ci("&Selective Color...", enabled = rgb)
        sep()
        ci("Shadows/Hi&ghlights...", enabled = edits)
        ci("HD&R Toning...", enabled = some and d.depth == 32)
        sep()
        ci("&Desaturate", enabled = rgb)
        ci("&Replace Color...", enabled = rgb)
        ci("E&qualize", enabled = edits)
        ci("Va&riations...", enabled = rgb)
      sep()
      ci("Auto &Tone", enabled = edits)
      ci("Auto C&ontrast", enabled = edits)
      ci("Auto Co&lor", enabled = rgb)
      sep()
      ci("Image &Size...", enabled = some)
      ci("&Canvas Size...", enabled = some)
      ci("&Upscale...", "Upscale...", enabled = edits)
      ci("Image Tra&ce...", enabled = some)
      psSub "Image &Rotation":
        ci("&180°", enabled = some)
        ci("90° &Clockwise", "90° CW", enabled = some)
        ci("90° C&ounter Clockwise", "90° CCW", enabled = some)
        ci("&Arbitrary...", enabled = some)
        sep()
        ci("Flip Canvas &Horizontal", "Horizontal", enabled = some)
        ci("Flip Canvas &Vertical", "Vertical", enabled = some)
      ci("C&rop", "Crop", enabled = sel)
      ci("Tri&m...", "Trim", enabled = some)
      sep()
      ci("&Duplicate...", enabled = some)
      ci("Appl&y Image...", enabled = edits)
      ci("Calc&ulations...", enabled = edits)
    psMenu "&Layer":
      psSub "&New":
        ci("&Layer...", "New Layer...", enabled = some)
        ci("Layer from &Background...", "Layer from Background", enabled = some and d.layers[0].background)
        sep()
        ci("&Group...", "New Group...", enabled = some)
        ci("Group from L&ayers...", "Group Layers", enabled = some and not bgl)
        sep()
        ci("Layer via &Copy", enabled = some)
        ci("Layer via Cu&t", enabled = sel)
        ci("Layer by Lifting the &Subject", "Lift Subject", enabled = edits)
      let many = some and d.severalPicked
      ci(if many: "&Duplicate Layers..." elif grp: "&Duplicate Group..." else: "&Duplicate Layer...",
         if many: "Duplicate Layers" elif grp: "Duplicate Group" else: "Duplicate Layer", enabled = some)
      psSub "De&lete":
        ci(if many: "&Layers" elif grp: "&Group" else: "&Layer",
           if many: "Delete Layers" elif grp: "Delete Group" else: "Delete Layer",
           enabled = some and d.layers.len > 1)
      ci("Rena&me Layer...", if grp: "Group Properties..." else: "Layer Options...", enabled = some)
      ci("Object E&xport Options...", "Object Export Options...", enabled = some)
      psSub "Layer St&yle":
        live: layerStyleMenu(d)
        if mIndex.on: ci("Blending Options...")
      sep()
      psSub "New Fi&ll Layer":
        ci("&Solid Color...", enabled = some)
        ci("&Gradient...", enabled = some)
        ci("&Pattern...", enabled = some and pattern.len > 0)
      psSub "New &Adjustment Layer":
        live:
          if some: adjustLayerMenu(d)
      sep()
      let mk = some and not bgl and d.current.adjust.kind.len == 0
      let hasMask = some and d.current.mask != nil
      psSub "Layer &Mask":
        ci("&Reveal All", enabled = mk and not hasMask)
        ci("&Hide All", enabled = mk and not hasMask)
        ci("Reveal &Selection", enabled = mk and not hasMask and sel)
        ci("Hide S&election", enabled = mk and not hasMask and sel)
        sep()
        ci("&Delete", "Delete Layer Mask", enabled = hasMask)
        ci("&Apply", "Apply Layer Mask", enabled = hasMask)
        ci(if hasMask and d.current.maskOff: "E&nable" else: "Disa&ble", "Toggle Layer Mask", enabled = hasMask)
        sep()
        ci("&Gradient Mask", enabled = mk)
      if some and d.current.clipped:
        ci("Release &Clipping Mask", enabled = true)
      else:
        ci("Create &Clipping Mask", enabled = some and d.cur > 0 and not bgl)
      sep()
      psSub "Smart O&bjects":
        live: smartObjectItems(d)
        if mIndex.on:
          ci("Convert to Smart Object")
          ci("Edit Contents")
      psSub "Rasteri&ze":
        ci("&Type", "Rasterize Type", enabled = some and d.current.isText)
        ci("Type to Sha&pes", "Convert to Shape", enabled = some and d.current.isText)
        ci("&Shape", "Rasterize Shape", enabled = some and d.current.isShape)
        ci("&Smart Object", "Rasterize Smart Object", enabled = some and d.current.isSmart)
        ci("Layer St&yle", "Rasterize Layer Style", enabled = some and d.current.hasStyle)
      ci("More S&hapes...", "More Shapes...", enabled = some)
      ci("Shape Op&tions...", "Shape Options...", enabled = some and liveOf(d.current).ok)
      psSub "Pat&h Operations":
        let pathOk = some and (d.current.isShape or (d.curPath >= 0 and d.curPath < d.paths.len))
        ci("&Merge Shape Components (Pathfinder)", "Merge Shape Components", enabled = pathOk)
        ci("&Offset Path...", enabled = pathOk)
        ci("Outline &Stroke", enabled = some and d.current.isShape and d.current.shape.strokeWidth > 0 and
                                       d.current.shape.stroke.kind != spNone)
        ci("Si&mplify Path...", enabled = pathOk)
        ci("&Reverse Path Direction", enabled = pathOk)
        ci("&Join Paths", enabled = pathOk)
        sep()
        ci("Make &Blend...", enabled = some and (d.current.isShape or d.pickedLayers.len == 2))
        ci("Replace S&pine", "Replace Spine", enabled = some and d.pickedLayers.len >= 2)
        ci("Replace Spine (Align to Path)", enabled = some and d.pickedLayers.len >= 2)
        ci("Shape B&uilder...", "Shape Builder...", enabled = some and d.pickedLayers.len >= 2)
        ci("&Freeform Gradient...", "Freeform Gradient...", enabled = some and d.current.isShape)
        ci("Gradient &Mesh...", "Gradient Mesh...", enabled = some and d.current.isShape)
        ci("Apply &Brush to Path...", "Apply Brush to Path...", enabled = pathOk)
        ci("&Transform Each...", "Transform Each...", enabled = some)
      psSub "En&velope Distort":
        let shp1 = some and d.current.isShape
        ci("Make with &Warp...", "Envelope: Make with Warp...", enabled = shp1)
        ci("Make with &Mesh...", "Envelope: Make with Mesh...", enabled = shp1)
        ci("Make with &Top Object", "Envelope: Make with Top Object", enabled = shp1)
        sep()
        ci("&Release", "Envelope: Release", enabled = shp1)
      psSub "Live Pa&int":
        ci("&Make", "Live Paint: Make", enabled = some and (d.current.isShape or d.pickedLayers.len > 0))
        ci("Live Paint &Bucket", "Live Paint Bucket", enabled = some, checked = lpBucket)
        ci("&Expand", "Live Paint: Expand", enabled = some and d.current.livePaintOf.on)
      ci("Inter&twine", "Intertwine: Make", enabled = some and d.pickedLayers.len >= 2, checked = intertwineOn)
      sep()
      ci("Group Layers", enabled = some and not bgl)
      ci("&Ungroup Layers", enabled = grp)
      ci("&Hide Layers", "Hide Layers", enabled = some)
      ci(if some and d.current.link != 0: "Unlin&k Layers" else: "Lin&k Layers",
         if some and d.current.link != 0: "Unlink Layers" else: "Link Layers",
         enabled = some and (d.current.link != 0 or d.pickedLayers.len > 1))
      psSub "&Arrange":
        ci("Bring to &Front", enabled = some and not bgl)
        ci("Bring For&ward", enabled = some and not bgl)
        ci("Send Back&ward", enabled = some and not bgl)
        ci("Send to &Back", enabled = some and not bgl)
      psSub "Al&ign":
        live: alignItems(d)
      psSub "Dis&tribute":
        live: distributeItems(d)
      sep()
      ci(if some and d.current.locked: "Unloc&k Layers" else: "Loc&k Layers...",
         if some and d.current.locked: "Unlock Layer" else: "Lock Layer", enabled = some and not bgl)
      sep()
      ci("&Place Into...", enabled = some and not bgl)
      psSub "Fitti&ng":
        let fc = frameAndContent(d).content != nil
        ci("&Fill Frame Proportionally", enabled = fc)
        ci("Fit &Content Proportionally", enabled = fc)
        ci("Fit Content to &Frame", enabled = fc)
        ci("C&enter Content", enabled = fc)
        ci("&Original Size", enabled = fc)
        sep()
        ci("Frame &Options...", enabled = fc)
        ci("&Remove Content", enabled = fc)
      psSub "Pe&rspective":
        ci("&Attach to Active Plane", "Attach to Active Plane", enabled = some and not bgl and d.pgOf.shown)
        ci("&Release with Perspective", "Release with Perspective", enabled = some and d.current.isText and
                                                                   d.current.text.perspOn)
      ci("Anc&hor to Text", "Anchor to Text", enabled = some and not bgl and d.current.anchorTo == 0)
      ci("Release Anc&hor", "Release Anchor", enabled = some and d.current.anchorTo != 0)
      ci("New &Frame", enabled = some)
      ci("Make Photo Place&holder", "Make Photo Placeholder", enabled = some)
      ci("New &QR Code...", "New QR Code...", enabled = some)
      ci("Har&monize...", "Harmonize...", enabled = some and d.cur > 0 and not bgl and not grp and
                                                  d.current.adjust.kind.len == 0)
      ci("Layer &Cleanup...", "Layer Cleanup...", enabled = some)
      ci("Show Layer Si&zes", "Show Layer Sizes", checked = prefs.layerSizes)
      ci("Rename Layers by Co&ntent", "Rename Layers by Content", enabled = some and not bgl)
      sep()
      ci(if grp: "Merge Grou&p" else: "Merge Do&wn", if grp: "Merge Group" else: "Merge Down",
         enabled = some and canMergeDown(d))
      ci("Merge &Visible", enabled = some and d.layers.len > 1)
      ci("&Flatten Image", enabled = some and d.layers.len > 1)
      sep()
      ci("Gradient &Feather...", "Gradient Feather...", enabled = some and not bgl and not grp)
      psSub "Ma&tting":
        psFilters(["&Defringe...", "Remove &Black Matte", "Remove &White Matte"])
      psSub "Live &Effects":
        let shp = some and d.current.isShape
        psSub "&Distort && Transform":
          ci("&Free Distort...", enabled = shp)
          ci("&Pucker && Bloat...", enabled = shp)
          ci("&Roughen...", enabled = shp)
          ci("&Transform Effect...", enabled = shp)
          ci("T&weak...", enabled = shp)
          ci("T&wist...", enabled = shp)
          ci("&Zig Zag...", enabled = shp)
        psSub "&Warp":
          live:
            for n in WarpStyles:
              if menuItem(tr(n) & "...", enabled = shp): runCommand("Warp: " & n & "...")
        ci("&Offset Path Effect...", enabled = shp)
        psSub "Re&peat":
          ci("&Radial Repeat...", enabled = shp)
          ci("&Grid Repeat...", enabled = shp)
          ci("&Mirror Repeat...", enabled = shp)
        psSub "&Stylize":
          ci("Round &Corners...", enabled = shp)
          ci("&Scribble...", enabled = shp)
        sep()
        ci("E&xpand Appearance", enabled = shp)
      if mIndex.on:
        # (no item in the usual menus, but keys: found by Search too)
        ci("Stamp Visible")
        ci("Select Layer Above")
        ci("Select Layer Below")
        ci("Fill with Foreground Color")
        ci("Fill with Background Color")
        ci("Step Backward")
        ci("Step Forward")
    psMenu "&Type":
      psSub "&Panels":
        ci("&Character Panel", "Character", checked = panelShown("character"))
        ci("&Paragraph Panel", "Paragraph", checked = panelShown("paragraph"))
        ci("&Glyphs Panel", "Glyphs", checked = panelShown("glyphs"))
        ci("Character &Styles Panel", "Character Styles", checked = panelShown("charstyles"))
        ci("Paragraph S&tyles Panel", "Paragraph Styles", checked = panelShown("parastyles"))
        ci("&OpenType Panel", "OpenType", checked = panelShown("opentype"))
      sep()
      ci("Get Google &Fonts...", "Get Google Fonts...")
      sep()
      ci("Text Frame &Options...", "Text Frame Options...", enabled = some and (te.on or (d.current.isText and
                                                                                    d.current.text.boxW > 0)))
      ci("Flow Into a &New Box", enabled = some and d.current.isText and d.current.text.boxW > 0)
      ci("Unlink Text Bo&x", "Unlink Text Box", enabled = some and d.current.flowFrom != 0)
      ci("Paste &Lorem Ipsum", "Paste Lorem Ipsum", enabled = some)
      ci("Word &Shapes...", "Word Shapes...", enabled = some)
      ci("Insert Page N&umber", "Insert Page Number", enabled = some)
      psSub "Text &Variables":
        ci("Insert &Page Number", "Insert Page Number", enabled = some)
        ci("Insert &Number of Pages", "Insert Number of Pages", enabled = some)
        ci("Insert &File Name", "Insert File Name", enabled = some)
        ci("Insert &Output Date", "Insert Output Date", enabled = some)
        ci("Insert &Modification Date", "Insert Modification Date", enabled = some)
        psSub "Insert Date &As":
          ci("&Hijri Date (١٧ جمادى الآخرة)", "Insert Hijri Date", enabled = some)
          ci("Hijri Date in &English", "Insert Hijri Date in English", enabled = some)
          ci("Hijri Date in &Numbers", "Insert Hijri Date in Numbers", enabled = some)
          ci("&Arabic Date (١٧ نوفمبر)", "Insert Arabic Date", enabled = some)
          ci("Arabic Date, the &Levant's Months", "Insert Arabic Date (Levant)", enabled = some)
          ci("Arabic Date with the &Day", "Insert Arabic Date with the Day", enabled = some)
          ci("&Day/Month/Year", "Insert Date dd/MM/yyyy", enabled = some)
        psSub "Insert &Running Header":
          if some and d.paraStyles.len > 0:
            for st in d.paraStyles: ci(st.name, "Insert Running Header: " & st.name)
          else: ci("(no paragraph styles)", enabled = false)
      psSub "&Hyperlinks && Cross-References":
        ci("New &Hyperlink...", "New Hyperlink...", enabled = some)
        ci("New Hyperlink &Destination...", "New Hyperlink Destination...", enabled = some)
        ci("Insert &Cross-Reference...", "Insert Cross-Reference...", enabled = some and te.on)
        ci("&Remove Hyperlink", "Remove Hyperlink", enabled = some)
        sep()
        ci("New &Bookmark", "New Bookmark", enabled = some)
      ci("Insert &Footnote", "Insert Footnote", enabled = some)
      ci("Insert &Endnote", "Insert Endnote", enabled = some)
      ci("Footnotes and Endnot&es...", "Footnotes...", enabled = some and (te.on or d.current.isText))
      ci("Story Edi&tor...", "Story Editor...", enabled = some and (te.on or d.current.isText))
      ci("Paragraph Shading and &Borders...", "Paragraph Shading and Borders...",
         enabled = some and (te.on or d.current.isText))
      ci("Insert E&quation...", "Insert Equation...", enabled = some)
      psSub "Trac&k Changes":
        let tl = if some: d.storyLayer else: nil
        ci("&Track Changes in This Story", "Track Changes", enabled = tl != nil, checked = tl != nil and tl.text.track)
        ci("&Accept All Changes", "Accept All Changes", enabled = tl != nil)
        ci("&Reject All Changes", "Reject All Changes", enabled = tl != nil)
        sep()
        ci("New &Note", "New Note", enabled = tl != nil)
        ci("Track Changes and Notes &Panel", "Track Changes and Notes", checked = panelShown("review"))
      ci("Con&ditional Text", "Conditional Text", checked = panelShown("conditions"))
      sep()
      let ts = shownStyle()
      ci("Li&gatures", "Ligatures", checked = ts.ligaturesOn)
      psSub "Open&Type":
        for (nm, tag) in OpenTypeMenu:
          ci(otLabel(nm, tag, ts), "OpenType: " & nm, checked = featureOn(ts.features, tag))
      sep()
      live: typeMenu(d)
      if mIndex.on: ci("Rasterize Type Layer", "Rasterize Type")
    psMenu "La&yout":
      layoutMenu()
    psMenu "&Select":
      ci("&All", enabled = some)
      ci("&Deselect", "None", enabled = sel)
      ci("&Reselect", enabled = d != nil and reselect.d == d and reselect.sel.len == d.w * d.h)
      ci("&Inverse", enabled = sel)
      sep()
      ci("A&ll Layers", "All Layers", enabled = some)
      ci("D&eselect Layers", "Deselect Layers", enabled = some)
      sep()
      ci("&Color Range...", enabled = rgb)
      ci("Su&bject", enabled = edits)
      ci("S&ky", enabled = edits)
      ci("&Focus Area...", "Focus Area...", enabled = edits)
      ci("Remove Bac&kground", enabled = edits)
      sep()
      ci("Select and &Mask...", enabled = sel)
      psSub "M&odify":
        ci("&Border...", enabled = sel)
        ci("&Smooth...", enabled = sel)
        ci("&Expand...", enabled = sel)
        ci("&Contract...", enabled = sel)
        ci("&Feather...", enabled = sel)
      sep()
      ci("&Grow", enabled = sel)
      ci("Si&milar", enabled = sel)
      sep()
      ci("Edit in &Quick Mask Mode", "Quick Mask", enabled = some, checked = some and d.quickMask)
      sep()
      ci("&Load Selection...", "Load Selection", enabled = some and d.alphas.len > 0)
      ci("&Save Selection...", "Save Selection", enabled = sel)
      ci("Make &Work Path", enabled = sel)
      sep()
      ci("Start &Global Edit", "Start Global Edit", enabled = some and d.current.isShape and not gEdit.on)
      ci("Stop Global Edi&t", "Stop Global Edit", enabled = gEdit.on)
    psMenu "Filte&r":
      ci("&Last Filter" & (if lastFilter.set: " (" & lastFilter.name & ")" else: ""), "Last Filter",
         enabled = edits and lastFilter.set)
      sep()
      ci("Con&vert for Smart Filters", "Convert to Smart Object",
         enabled = some and not d.current.isSmart and not grp)
      sep()
      psSub "Filter &Gallery":
        psSub "&Artistic": psFilters(galleryArtistic.mapIt(it & "..."))
        psSub "&Brush Strokes": psFilters(galleryBrush.mapIt(it & "..."))
        psSub "&Distort": psFilters(galleryDistort.mapIt(it & "..."))
        psSub "&Sketch": psFilters(gallerySketch.mapIt(it.replace("&", "&&") & "..."))
        psSub "St&ylize": psFilters(galleryStylize.mapIt(it & "..."))
        psSub "&Texture": psFilters(galleryTexture.mapIt(it & "..."))
      ci("&Neural Filters...", "Neural Filters...", enabled = edits and d.mode in {cmRGB, cmGray, cmCMYK})
      ci("&Camera Raw Filter...", "Develop...", enabled = edits and rgb)
      ci("Lens C&orrection...", enabled = edits)
      ci("Li&quify...", enabled = edits)
      ci("&Vanishing Point...", "Vanishing Point...", enabled = edits)
      sep()
      psSub "&Blur":
        psFilters(["&Average", "&Blur", "Blur &More", "Bo&x Blur...", "&Gaussian Blur...", "&Lens Blur...",
                   "M&otion Blur...", "&Radial Blur...", "S&hape Blur...", "Smar&t Blur...", "&Surface Blur..."])
      psSub "Blur &Gallery":
        ci("&Field Blur...", enabled = edits)
        ci("&Iris Blur...", enabled = edits)
        ci("&Tilt-Shift...", enabled = edits)
      psSub "&Distort":
        psFilters(["&Pinch...", "Polar &Coordinates...", "&Ripple..."])
        ci("S&hear...", "Shear...", enabled = edits)
        psFilters(["S&pherize...", "&Twirl...", "&Wave...", "&ZigZag...", "&Displace..."])
      psSub "&Noise":
        psFilters(["&Add Noise...", "&Despeckle", "D&ust && Scratches...", "&Median...", "&Reduce Noise..."])
      psSub "&Pixelate":
        psFilters(["Color &Halftone...", "&Crystallize...", "&Facet", "F&ragment", "M&ezzotint...",
                   "&Mosaic...", "&Pointillize..."])
      psSub "&Render":
        psFilters(["&Clouds", "&Difference Clouds", "F&ibers...", "&Lens Flare...", "Lighting &Effects..."])
        ci("&Texture Fill...", enabled = edits)
        ci("&Relight...", "Relight...", enabled = edits)
      psSub "&Sharpen":
        psFilters(["&Sharpen", "Sharpen &Edges", "Sharpen &More", "S&mart Sharpen...", "&Unsharp Mask..."])
      psSub "St&ylize":
        psFilters(["&Oil Paint..."])
        psFilters(["&Diffuse...", "&Emboss...", "E&xtrude...", "&Find Edges", "&Solarize", "&Tiles...",
                   "Trace &Contour...", "&Wind..."])
      psSub "&Video":
        psFilters(["&De-Interlace...", "&NTSC Colors"])
      psSub "&Other":
        ci("&Custom...", enabled = edits)
        psFilters(["&High Pass...", "HSB/H&SL...", "Ma&ximum...", "M&inimum...", "&Offset..."])
        ci("&Frequency Separation", "Frequency Separation", enabled = edits)
    psMenu "Pl&ugins":
      ci("Filter &Factory...", enabled = edits)
      ci("&Edit Plug-in...", enabled = plugins.len > 0)
      live:
        if plugins.len > 0: menuSeparator()
        for cat in pluginCategories():
          submenu cat:
            for f in plugins:
              if f.category != cat: continue
              let nm = f.name.replace("&", "&&") & (if f.sliders != default(array[8, string]): "..." else: "")
              if menuItem(nm, enabled = edits): runCommand(f.name & (if nm.endsWith("..."): "..." else: ""))
    psMenu "&View":
      ci("&Before && After", "Before & After", enabled = some, checked = active != nil and
         cast[pointer](active) in baSplit)
      sep()
      ci("Proof &Colors", "CMYK Preview", enabled = some and d.mode in {cmRGB, cmLab}, checked = some and d.proof)
      ci("Gamut Wa&rning", "Gamut Warning", enabled = some and d.mode in colorModes,
         checked = some and d.gamutWarning)
      ci("32-bit &Preview Options...", enabled = some and d.depth == 32)
      ci("O&verprint Preview", "Overprint Preview", enabled = some, checked = some and d.overprintView)
      ci("Separations Pre&view", "Separations Preview", enabled = some, checked = some and d.sepView.on)
      sep()
      ci("Zoom &In", enabled = some)
      ci("Zoom &Out", enabled = some)
      ci("&Fit on Screen", enabled = some)
      ci("&100%", "Actual Pixels", enabled = some)
      ci("&200%", "200%", enabled = some)
      sep()
      psSub "Screen Mo&de":
        ci("&Standard Screen Mode", checked = screenMode == 0)
        ci("Full Screen Mode With &Menu Bar", checked = screenMode == 1)
        ci("&Full Screen Mode", checked = screenMode == 2)
      sep()
      ci("E&xtras", "Hide Edges", enabled = some, checked = dw != nil and not dw.view.hideEdges)
      # (a drawing: the objects' outlines, as the drawing program names them; a layout: the
      # frames' edges, as the layout program does -- the same switch, Ctrl+H)
      case active.pickLook
      of plDrawing:
        ci(if dw != nil and dw.view.hideEdges: "Show &Edges" else: "Hide &Edges", "Hide Edges", enabled = some)
      of plLayout:
        ci(if dw != nil and dw.view.hideEdges: "Show &Frame Edges" else: "Hide &Frame Edges", "Hide Frame Edges",
           enabled = some)
      of plPhoto: discard
      psSub "Sho&w":
        ci("&Selection Edges", "Hide Edges", enabled = some, checked = dw != nil and not dw.view.hideEdges)
        ci("&Layer Edges", "Layer Edges", enabled = some, checked = showLayerEdges)
        ci("&Guides", "Show Guides", enabled = some, checked = dw != nil and dw.view.showGuides)
        ci("G&rid", "Show Grid", enabled = some, checked = dw != nil and dw.view.showGrid)
        ci("S&mart Guides", "Smart Guides", checked = smartGuidesOn)
        ci("&Pixel Grid", "Pixel Grid", checked = pixelGridOn)
        ci("&Text Threads", "Show Text Threads", checked = showThreads)
      ci("&Rulers", "Show Rulers", enabled = some, checked = dw != nil and dw.view.rulers)
      ci("Pattern Pre&view", "Pattern Preview", enabled = some, checked = some and d.patternPreview)
      sep()
      ci("Sn&ap", "Snap", checked = snapOn)
      psSub "Snap &To":
        ci("&Guides", checked = snapGuides)
        ci("G&rid", checked = snapGrid)
        ci("&Document Bounds", checked = snapBounds)
      sep()
      psSub "&Perspective Grid":
        let pg = if some: d.pgOf else: PerspectiveGrid()
        ci(if pg.shown: "&Hide Grid" else: "&Show Grid", if pg.shown: "Hide Perspective Grid" else: "Show Perspective Grid",
           enabled = some, checked = pg.shown)
        ci("&Lock Grid", "Lock Perspective Grid", enabled = some, checked = pg.locked)
        sep()
        ci("&One Point Perspective", "One Point Perspective", enabled = some,
           checked = pg.shown and pg.kind == pkOnePoint)
        ci("&Two Point Perspective", "Two Point Perspective", enabled = some,
           checked = pg.shown and pg.kind == pkTwoPoint)
        ci("T&hree Point Perspective", "Three Point Perspective", enabled = some,
           checked = pg.shown and pg.kind == pkThreePoint)
        ci("&Define Grid...", "Define Perspective Grid...", enabled = some)
        sep()
        ci("&Left Wall", "Perspective Plane: Left Wall", enabled = some and pg.shown,
           checked = pg.shown and not pg.noActive and pg.active == ppLeft)
        ci("&Right Wall", "Perspective Plane: Right Wall", enabled = some and pg.shown,
           checked = pg.shown and not pg.noActive and pg.active == ppRight)
        ci("&Floor", "Perspective Plane: Floor", enabled = some and pg.shown,
           checked = pg.shown and not pg.noActive and pg.active == ppFloor)
        ci("Fa&cing Wall", "Perspective Plane: Facing Wall", enabled = some and pg.shown and pg.kind == pkOnePoint,
           checked = pg.shown and not pg.noActive and pg.active == ppFacing)
        ci("&No Active Plane", "Perspective Plane: None", enabled = some and pg.shown, checked = pg.shown and pg.noActive)
      sep()
      ci("Loc&k Guides", "Lock Guides", enabled = some, checked = dw != nil and dw.view.lockGuides)
      ci("C&lear Guides", "Clear Guides", enabled = some and d.guides.len > 0)
      ci("&New Guide...", enabled = some)
      ci("Grid Settings...")
    psMenu "&Window":
      psSub "&Arrange":
        ci("T&abbed Documents", checked = prefs.docTabs)
        ci("&Floating Windows (MDI)", checked = not prefs.docTabs)
        sep()
        ci("&Cascade", enabled = not prefs.docTabs and docs.len > 0)
        ci("&Tile", enabled = not prefs.docTabs and docs.len > 0)
        # (not for a maximized window: it fills the workspace)
        ci("Always on T&op", enabled = not prefs.docTabs and dw != nil and dw.floating and not dw.win.maximized,
           checked = dw != nil and dw.win.pinned and not dw.win.maximized)
        sep()
        ci("&Match Zoom", enabled = some and docs.len > 1)
        ci("Match &Location", enabled = some and docs.len > 1)
        sep()
        ci("&New Window", enabled = some)
        ci("Next &Document", enabled = docs.len > 1)
        ci("Pre&vious Document", enabled = docs.len > 1)
        ci("Close &All", enabled = docs.len > 0)
      psSub "&Workspace":
        ci("&Photo (Essentials)", "Workspace: Photo")
        ci("&Drawing", "Workspace: Drawing")
        ci("&Layout", "Workspace: Layout")
        sep()
        ci("&Reset Essentials", "Reset Workspace")
        sep()
        ci("&New Workspace...", "Save Workspace")
        ci("&Load Saved Workspace")
      sep()
      # (the panels, A to Z, as editors list them)
      ci("Actions", checked = panelShown("actions"))
      ci("Adjustments", checked = panelShown("adjustments"))
      ci("Appearance", checked = panelShown("appearance"))
      ci("Attributes", checked = panelShown("attributes"))
      ci("Brush Settings", checked = panelShown("brushsettings"), shortcut = "F5")
      ci("Brushes", checked = panelShown("brushes"))
      ci("Brushes (Vector)", checked = panelShown("vbrushes"))
      ci("Buttons and Forms", checked = panelShown("buttons"))
      ci("Bookmarks", checked = panelShown("bookmarks"))
      ci("Channels", checked = panelShown("channels"))
      ci("Character", checked = panelShown("character"))
      ci("Character Styles", checked = panelShown("charstyles"))
      ci("Clone Source", checked = panelShown("clonesource"))
      ci("Color", "Picker", checked = panelShown("color"))
      ci("Commands", checked = panelShown("commands"))
      ci("Conditional Text", checked = panelShown("conditions"))
      ci("Glyphs", checked = panelShown("glyphs"))
      ci("Gradients", checked = panelShown("gradients"))
      ci("Histogram", checked = panelShown("histogram"))
      ci("History", checked = panelShown("history"))
      ci("Info", checked = panelShown("info"))
      ci("Layer Comps", checked = panelShown("layercomps"))
      ci("Layers", checked = panelShown("layers"))
      ci("Libraries", checked = panelShown("libraries"))
      ci("Links", checked = panelShown("links"))
      ci("Navigator", checked = panelShown("navigator"))
      ci("Object Styles", checked = panelShown("objectstyles"))
      ci("Graphic Styles", checked = panelShown("graphicstyles"))
      ci("Paragraph", checked = panelShown("paragraph"))
      ci("Paragraph Styles", checked = panelShown("parastyles"))
      ci("OpenType", checked = panelShown("opentype"))
      ci("Pages", checked = panelShown("pages"))
      ci("Paths", checked = panelShown("paths"))
      ci("Pattern Options", checked = panelShown("patternoptions"))
      ci("Patterns", checked = panelShown("patterns"))
      ci("Properties", checked = panelShown("properties"))
      ci("Scratch", checked = panelShown("scratch"))
      ci("Separations Preview", "Separations Preview Panel", checked = panelShown("separations"))
      ci("Shapes", checked = panelShown("shapes"))
      ci("Styles", checked = panelShown("styles"))
      ci("Styles and Fonts", checked = panelShown("designstyles"))
      ci("Swatches", checked = panelShown("swatches"))
      ci("Tool Presets", checked = panelShown("toolpresets"))
      ci("Track Changes and Notes", checked = panelShown("review"))
      ci("Assets", "Browse Assets...")
      ci("Quick Actions", checked = panelShown("quickactions"))
      ci("Color Themes", checked = panelShown("colorthemes"))
      sep()
      ci("&Options", "Options Bar", checked = optionsBarOn)
      ci("&Tools", "Tools", checked = toolbox.open)
      ci("Contextual Task &Bar", checked = prefs.taskBar)
      ci(if palettesHidden: "&Show Panels" else: "&Hide Panels", if palettesHidden: "Show Palettes" else: "Hide Palettes")
      live:
        if docs.len > 0: menuSeparator()
        for i, w in docs:
          if i >= 9: break
          if menuItem("&" & $(i + 1) & " " & w.doc.name.replace("&", "&&"), checked = w == active):
            w.showDoc()
    psMenu "&Help":
      ci("Retro Atelier &Help...", "Contents")
      ci("&Keyboard Shortcuts...")
      ci("&Report a Problem...", "Report a Problem")
      sep()
      ci("&About Retro Atelier...")
      live:
        submenu "About Plug-&in":
          for n in ["Gaussian Blur", "Unsharp Mask", "Lens Flare", "Mezzotint", "Twirl"]:
            if menuItem(n & "..."): aboutOpen = true

# ---- the commands editors have that 1994 did not -------------------------------------------------------------

proc straightenByRuler() =
  ## The Ruler's Straighten Layer: the image turned so that the line is
  ## level (or upright, when it is nearer upright).
  let d = cur()
  if d == nil or not ruler.on or ruler.d != d: return
  var a = rulerAngle()
  # (to the nearest level or upright)
  while a > 45: a -= 90
  while a < -45: a += 90
  if abs(a) < 0.01: return
  d.change("Straighten"): d.rotateArbitrary(a, bg)
  ruler.on = false
  if active != nil: active.fitWindow()

var lastUndoRedo = ""            ## (Toggle Last State: the last of Undo and Redo)

proc rotateLayerBy(quarter: int) =
  ## Edit > Transform > Rotate 180° / 90°: the layer (or the selection's
  ## pixels) turned around its middle, as a transform put down at once.
  startTransform(xkScale)
  if not xf.on: return
  var cx, cy = 0.0
  for c in 0 .. 3:
    cx += xf.quad[c][0] / 4
    cy += xf.quad[c][1] / 4
  let a = quarter.float * PI / 2
  var q = xf.quad
  for c in 0 .. 3:
    let (x, y) = (xf.quad[c][0] - cx, xf.quad[c][1] - cy)
    q[c] = (cx + x * cos(a) - y * sin(a), cy + x * sin(a) + y * cos(a))
  xf.quad = q
  xfApply()
  finishTransform(true)

proc transformAgain() =
  ## Edit > Transform > Again: the last transform done once more, to what
  ## is current now (moved as much, turned as much, sized as much).
  if not lastXf.set: return
  startTransform(xkScale)
  if not xf.on: return
  let f = quadMap(lastXf.r, lastXf.quad)
  var q: Quad
  for c in 0 .. 3: q[c] = f(xf.quad[c][0], xf.quad[c][1])
  xf.quad = q
  xfApply()
  finishTransform(true)

var searchDlg: tuple[open: bool; q: string; sel: int; shown: seq[int]]

# ---- Illustrator's path operations, on a shape layer (else the work path) ---------------------------------

var pathVal: tuple[open: bool; what: string; v, lo, hi: int; unit: string]

proc pathOperation(d: Doc; what: string; v: int) =
  ## (Merge Shape Components, Offset Path, Outline Stroke, Simplify,
  ## Reverse, Join: the current shape layer's outline changed -- or the
  ## work path's)
  let L = d.current
  let onShape = L.isShape and L.shape.path.subs.len > 0
  if not onShape and (d.curPath < 0 or d.curPath >= d.paths.len): return
  let src = if onShape: L.shape.path else: d.paths[d.curPath]
  var np: Path
  beginBusy(what)
  try:
    case what
    of "Merge Shape Components": np = mergeComponents(src, d.w, d.h)
    of "Offset Path": np = offsetPath(src, d.w, d.h, v.float)
    of "Simplify Path": np = simplifyPath(src, v.float)
    of "Reverse Path Direction": np = reversePath(src)
    of "Join Paths": np = joinPaths(src)
    of "Outline Stroke":
      if onShape: np = outlineStroke(L.shape, d.w, d.h)
    else: discard
  finally: endBusy()
  if np.subs.len == 0:
    status = what & ": nothing came of it"
    return
  np.name = src.name
  if onShape:
    var sh = L.shape
    sh.path = np
    sh.kind = ""
    if what == "Outline Stroke":
      # (the stroke is the shape now: filled with the stroke's color)
      sh.fill = sh.stroke
      sh.stroke = ShapePaint(kind: spNone, color: sh.stroke.color)
      sh.strokeWidth = 0
    d.beginStep(what)
    d.touchLayers()
    d.setShape(L, sh)
    d.endStep()
  else:
    d.beginStep(what)
    d.touchPaths()
    d.paths[d.curPath] = np
    d.endStep()
  inc d.ver
  status = what & ": " & $np.subs.len & (if np.subs.len == 1: " outline" else: " outlines")

proc startPathValue(what: string; v, lo, hi: int; unit: string) =
  pathVal = (true, what, v, lo, hi, unit)

proc pathValueDialog() =
  if not pathVal.open: return
  var ok = false
  dialog(pathVal.open, pathVal.what, 320):
    row:
      label(if pathVal.what == "Offset Path": "Offset:" else: "Tolerance:")
      discard spin(pathVal.v, pathVal.lo, pathVal.hi, w = dp(70))
    label(pathVal.unit, color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): ok = true
      if button("Cancel", w = dp(80)): pathVal.open = false
  if ok:
    pathVal.open = false
    let d = cur()
    if d != nil: d.pathOperation(pathVal.what, pathVal.v)

proc psCommand(name: string): bool =
  ## The commands above (true: done here).
  let d = cur()
  let dw = active
  result = true
  if name.startsWith("Run Script File:"):
    runScriptFile(name["Run Script File:".len .. ^1])
    return
  case name
  of "Undo", "Redo":
    lastUndoRedo = name
    return false                 # (done by the 1994 commands)
  of "Toggle Last State":
    if d != nil:
      if lastUndoRedo == "Undo" and d.canRedo: runCommand("Redo")
      elif d.canUndo: runCommand("Undo")
  of "Search...":
    searchDlg.open = true
    searchDlg.q = ""
    searchDlg.sel = 0
    focusFirstText(inDialog = true)
  of "Close Others":
    for o in docs:
      if o != dw: o.win.open = false
  of "Free Transform": startTransform(xkScale)
  of "Transform Again": transformAgain()
  of "Rotate Layer 180°": rotateLayerBy(2)
  of "Rotate Layer 90° CW": rotateLayerBy(1)
  of "Rotate Layer 90° CCW": rotateLayerBy(-1)
  of "Hide Layers":
    if d != nil:
      d.layersChange("Hide Layers"):
        for L in d.layers:
          if L.picked or L == d.current: L.visible = not L.visible
        d.markAll()
  of "All Layers":
    if d != nil:
      for L in d.layers:
        if not L.background: L.picked = true
      inc d.ver
  of "Deselect Layers":
    if d != nil:
      d.clearPicks()
      inc d.ver
  of "200%":
    if dw != nil: dw.view.setZoom(d, 2)
  of "Standard Screen Mode", "Full Screen Mode With Menu Bar", "Full Screen Mode":
    screenMode = (case name
                  of "Standard Screen Mode": 0
                  of "Full Screen Mode With Menu Bar": 1
                  else: 2)
    if active != nil: active.win.maximized = screenMode > 0
  of "Quick Mask":
    if d != nil:
      if d.quickMask: d.leaveQuickMask() else: d.enterQuickMask()
  of "Layer from Background":
    if d != nil and d.layers[0].background:
      d.layersChange("Layer from Background"): d.layerFromBackground()
  of "Delete Layer Mask", "Apply Layer Mask":
    if d != nil and d.current.mask != nil:
      d.layersChange(name): d.removeLayerMask(apply = name == "Apply Layer Mask")
  of "Toggle Layer Mask":
    if d != nil and d.current.mask != nil:
      let L = d.current
      d.layersChange(if L.maskOff: "Enable Layer Mask" else: "Disable Layer Mask"):
        L.maskOff = not L.maskOff
        d.markAll()
  of "Rasterize Type":
    if d != nil and d.current.isText:
      if te.on: commitType()
      let L = d.current
      d.stepOnce("Rasterize Type", proc () = d.rasterizeText(L))
  of "Merge Shape Components", "Reverse Path Direction", "Join Paths", "Outline Stroke":
    if d != nil: d.pathOperation(name, 0)
  of "Offset Path...": startPathValue("Offset Path", 10, -500, 500, "pixels (negative: inward)")
  of "Simplify Path...": startPathValue("Simplify Path", 2, 1, 50, "pixels of curve fit")
  of "Rasterize Shape":
    if d != nil and d.current.isShape:
      let L = d.current
      d.stepOnce("Rasterize Shape", proc () = d.rasterizeShape(L))
  of "Define Brush Preset...":
    if d != nil and d.hasSelection:
      let t = if tool in {tBrush, tPencil, tAirbrush, tEraser, tSmudge, tBlur, tDodge, tStamp}: tool else: tBrush
      var tip = d.tipFromSelection()
      tip.name = "Sampled Brush"
      opts[t].tip = tip
      opts[t].preset = ""
      presetDlg = (true, 0, "Sampled Brush " & $tip.diameter, -1)
  of "Define Pattern":
    if d != nil and d.hasSelection:
      d.definePattern()
      userPatterns.add PatternPreset(name: "Pattern " & $(userPatterns.len + 1), w: patternW, h: patternH,
                                     px: pattern)
  of "Picker", "Color": togglePanel("color")
  of "Gradients": togglePanel("gradients")
  of "Patterns": togglePanel("patterns")
  of "Histogram": togglePanel("histogram")
  of "Properties": togglePanel("properties")
  of "Adjustments": togglePanel("adjustments")
  of "Glyphs": showTypePal(2)
  of "Character Styles": togglePanel("charstyles")
  of "Paragraph Styles": togglePanel("parastyles")
  of "Object Styles": togglePanel("objectstyles")
  of "Graphic Styles": togglePanel("graphicstyles")
  of "Links": togglePanel("links")
  of "Bookmarks": togglePanel("bookmarks")
  of "OpenType": togglePanel("opentype")
  of "Vanishing Point...": startVanishingPoint()
  of "Script Editor...": scriptOpen = true
  of "Run Script...":
    scriptPath = scriptsDir() & "/"
    scriptPick = true
  of "SVG...": startSvgExport()
  of "SVG, Type as Outlines...": startSvgExport(outlines = true)
  of "New SVG Drawing", "New Drawing...", "New Drawing (SVG)...": startNewDrawing()
  of "Styles": togglePanel("styles")
  of "Shapes": togglePanel("shapes")
  of "Tool Presets": togglePanel("toolpresets")
  of "Libraries": togglePanel("libraries")
  of "Neural Filters...": startNeural()
  of "PDF Presentation...": startPdfPresentation()
  of "Get Google Fonts...": startGetFonts()
  of "Layer Comps": togglePanel("layercomps")
  of "Layer Cleanup...": ccDlg.cleanup = true
  of "Rename Layers by Content":
    # (the picked layers named after what they hold, whatever their names: a group after
    # what is in it)
    if d != nil:
      d.beginStep("Rename Layers")
      let n = d.autoRename(d.pickedLayers())
      d.endStep()
      status = $n & (if n == 1: " layer" else: " layers") & " named after what they hold"
  of "Harmonize...":
    if d != nil and d.cur > 0:
      ccDlg.harmonize = true
  of "Link Layers":
    if d != nil and d.pickedLayers.len > 1:
      d.layersChange("Link Layers"): d.linkLayers(d.pickedLayers)
  of "Unlink Layers":
    if d != nil:
      d.layersChange("Unlink Layers"):
        d.unlinkLayers(if d.pickedLayers.len > 1: d.pickedLayers else: @[d.cur])
  of "Flow Into a New Box":
    # (threaded text frames: a box beside this one shows what does not fit it)
    if d != nil and d.current.isText and d.current.text.boxW > 0:
      let S = d.current
      var t = S.text
      t.spans = @[]
      t.x = t.x + t.boxW + 24
      if t.x + t.boxW > d.w.float32: (t.x = S.text.x; t.y = S.text.y + S.text.boxH + 24)
      t.fit = false
      d.beginStep("Flow Into a New Box")
      d.touchLayers()
      let M = d.addTextLayer(t)
      M.name = S.name & " (continued)"
      M.flowFrom = uidOf(S)
      d.drawText(S)
      d.drawText(M)
      d.endStep()
      status = "The text that does not fit \"" & S.name & "\" flows on into the new box"
    else: status = "Flow Into a New Box: pick a type layer whose text is in a box (drag a box with the Type tool)"
  of "Unlink Text Box":
    if d != nil and d.current.flowFrom != 0:
      let M = d.current
      d.beginStep("Unlink Text Box")
      d.touchLayers()
      var t = d.effectiveText(M)
      t.clipOverflow = false
      let S = d.layerOfUid(M.flowFrom)
      M.flowFrom = 0
      M.text = t                                   # (what it showed: its own text now)
      d.drawText(M)
      if S != nil: d.drawText(S)
      d.endStep()
  of "Report a Problem":
    reportProblem()
  of "Artboard Options...": startArtboardOptions()
  of "Gradient Feather...": startGradientFeather()
  of "Artboards to Files":
    if d != nil: exportArtboards(d)
  of "Slices to Files":
    if d != nil: exportSlices(d)
  of "Slices From Guides":
    if d != nil: slicesFromGuides(d)
  of "Clone Source": togglePanel("clonesource")
  of "Contextual Task Bar":
    prefs.taskBar = not prefs.taskBar
    savePrefs()
  else: result = false

# ---- Edit > Search ----------------------------------------------------------------------------------------

proc searchIndex(): seq[tuple[path, label, cmd: string]] =
  ## Every menu command (where it is) and every tool, walked once.
  if mIndex.found.len == 0:
    mIndex.on = true
    mIndex.path.setLen(0)
    try: psMenus()
    finally: mIndex.on = false
    for g in toolGroups:
      for it in g.items:
        mIndex.found.add ("Tools (" & $g.key & ")", it.name, "tool:" & it.name)
  mIndex.found

proc searchScore(label, path, q: string): int =
  ## How well an entry matches what was typed (0: not at all).
  let l = label.toLowerAscii
  let p = path.toLowerAscii
  if q.len == 0: return 0
  if l.startsWith(q): return 4
  for w in l.split({' ', '/', '-'}):
    if w.startsWith(q): return 3
  if q in l: return 2
  if q in p: return 1
  0

proc runFound(e: tuple[path, label, cmd: string]) =
  if e.cmd.startsWith("tool:"):
    let want = e.cmd[5 .. ^1]
    for g, grp in toolGroups:
      for k, it in grp.items:
        if it.name == want: pickTool(g, k)
  else:
    runCommand(e.cmd)

proc searchDialog() =
  ## Edit > Search (Ctrl+F): type a few letters of a command, a panel or a
  ## tool; Enter (or a double click) does the one picked.
  if not searchDlg.open: return
  let all = searchIndex()
  dialog(searchDlg.open, "Search", 480):
    label "&Search for commands, panels and tools:"
    let changed = edit(searchDlg.q)
    let q = searchDlg.q.strip.toLowerAscii
    if changed or searchDlg.shown.len == 0:
      var scored: seq[(int, int)]
      var seen: HashSet[string]
      for i, e in all:
        let s = searchScore(e.label, e.path, q)
        if s > 0 and (e.path & e.label) notin seen:
          seen.incl e.path & e.label
          scored.add (-s, i)
      scored.sort()
      searchDlg.shown.setLen(0)
      for (_, i) in scored:
        if searchDlg.shown.len >= 60: break
        searchDlg.shown.add i
      searchDlg.sel = 0
    if keyHit(KeyDown):
      searchDlg.sel = min(searchDlg.shown.high, searchDlg.sel + 1)
      ui.keyUsed = true
    if keyHit(KeyUp):
      searchDlg.sel = max(0, searchDlg.sel - 1)
      ui.keyUsed = true
    var rows: seq[string]
    for i in searchDlg.shown:
      let e = all[i]
      let k = if e.cmd.startsWith("tool:"): "" else: keymap.keyFor(e.cmd)
      rows.add e.label & "\t" & e.path & (if k.len > 0: "  (" & k & ")" else: "")
    var go = false
    if rows.len == 0:
      rows.add(if q.len == 0: "Type to search" else: "Nothing found")
    listbox(rows, searchDlg.sel, rows = 10, tabs = [dp(190)])
    if doubleClicked() and searchDlg.shown.len > 0: go = true
    if keyHit(KeyEnter) and searchDlg.shown.len > 0:
      ui.keyUsed = true
      go = true
    row:
      spring()
      if button("&Go", isDefault = false, enabled = searchDlg.shown.len > 0): go = true
      if button("Close"): searchDlg.open = false
    if go and searchDlg.sel in 0 .. searchDlg.shown.high:
      let e = all[searchDlg.shown[searchDlg.sel]]
      searchDlg.open = false
      runFound(e)

# ---- the Contextual Task Bar ----------------------------------------------------------------------------

var tbar: tuple[dw: DocWin; r: Rect; items: seq[(string, string)]; rects: seq[Rect]; hits: seq[Hit]]
  ## the Contextual Task Bar of this frame (its buttons take the mouse
  ## before the image does; drawn after it)

proc taskBarItems(dw: DocWin): seq[(string, string)] =
  ## (label, command) for what is there now
  let d = dw.doc
  if xf.on and xf.dw == dw:
    @[("Commit", "\1ok"), ("Cancel", "\1no"), ("Warp", "Warp"), ("Flip H", "Flip Layer Horizontal")]
  elif pendingCrop.on and pendingCrop.dw == dw:
    @[("Crop", "\1crop"), ("Cancel", "\1nocrop")]
  elif te.on:
    @[("Done", "\1type"), ("Character", "Character"), ("Glyphs", "Glyphs"), ("Warp Text", "\1warp")]
  elif touchPick:
    # (picking by touch: what to do with those picked, and Done)
    @[("Done", "\1pickdone"), ("Group", "Group Layers"), ("Delete", "Delete Layer"), ("Transform", "Free Transform")]
  elif d.pickedLayers.len > 1:
    # (several layers picked: into a group -- a folder -- of their own)
    @[("Group", "Group Layers"), ("Merge", "Merge Layers"), ("Transform", "Free Transform")]
  elif d.current.group:
    @[("Ungroup", "Ungroup Layers"), ("Merge Group", "Merge Group"), ("Transform", "Free Transform")]
  elif d.hasSelection:
    @[("Select and Mask", "Select and Mask..."), ("Feather", "Feather..."), ("Invert", "Inverse"),
      ("Mask", "Reveal Selection"), ("Fill", "Fill..."), ("Transform", "Free Transform"), ("Deselect", "None")]
  elif d.current.isText:
    @[("Character", "Character"), ("Warp Text", "\1warp"), ("Rasterize", "Rasterize Type"),
      ("Transform", "Free Transform")]
  elif d.current.isShape:
    @[("Transform", "Free Transform"), ("Rasterize", "Rasterize Shape"), ("Properties", "Properties")]
  else:
    @[("Select Subject", "Subject"), ("Remove Background", "Remove Background"),
      ("Transform", "Free Transform"), ("Adjustments", "Adjustments")]

proc taskBarPress(dw: DocWin) =
  ## (before the image: where the bar is, its buttons' clicks)
  tbar.dw = nil
  if not prefs.taskBar or dw != active or dw.view.view.w < dp(260) or ui.menuOpen: return
  let items = taskBarItems(dw)
  let st = style(size = 0.92)
  var widths: seq[int]
  var total = dp(14) + dp(6)
  for (l, _) in items:
    widths.add textWidth(l, st) + dp(14)
    total += widths[^1] + dp(2)
  let v = dw.view.view
  let h = CtrlH - dp(2)
  if total > v.w - dp(8) or v.h < dp(120): return
  tbar.dw = dw
  tbar.items = items
  tbar.r = rect(v.x + (v.w - total) div 2, v.y + v.h - h - dp(20), total, h + dp(6))
  tbar.rects.setLen(0)
  tbar.hits.setLen(0)
  var x = tbar.r.x + dp(14)
  for i, (l, _) in items:
    let br = rect(x, tbar.r.y + dp(3), widths[i], h)
    tbar.rects.add br
    tbar.hits.add interact(idOf("taskbar:" & l), br, focusable = false)
    x += widths[i] + dp(2)

proc taskBarDraw(dw: DocWin) =
  ## (after the image) the bar drawn; what its buttons do.
  if tbar.dw != dw: return
  let st = style(size = 0.92)
  let r = tbar.r
  fill(r, ui.theme.face)
  raised(r)
  for k in 0 .. 2:
    vline(r.x + dp(4) + k * dp(3), r.y + dp(5), r.h - dp(10), ui.theme.shadow)
  var chosen = ""
  for i, (l, c) in tbar.items:
    let br = tbar.rects[i]
    let hit = tbar.hits[i]
    buttonFace(br, hit.down, 1, hot = hit.hover)
    let dd = if hit.down: 1 else: 0
    text(br.x + (br.w - textWidth(l, st)) div 2 + dd, br.y + (br.h - lineHeight(st)) div 2 + dd, l,
         ui.theme.text, st)
    if hit.clicked: chosen = c
  if mouseIn(r): ui.cursor = curArrow
  tbar.dw = nil
  case chosen
  of "": discard
  of "\1ok": finishTransform(true)
  of "\1pickdone": endTouchPick()
  of "\1no": finishTransform(false)
  of "\1crop":
    commitCropNow()
  of "\1nocrop":
    pendingCrop.on = false
    status = ""
  of "\1type": commitType()
  of "\1warp": startWarp()
  else: runCommand(chosen)

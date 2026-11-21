# Retro Atelier -- included by photo.nim
#
# File > New as today's editors has it, kept simple: tabs of what the
# document is for (Recent, Saved, Photo, Print, Social, Web, Mobile, Art &
# Illustration, Film & Video), blank document presets as cards, ready-made
# templates with their pictures (layers that stay editable: type, shapes,
# frames to place photos into), and the preset's details at the right --
# its name, size in any unit, orientation, artboards, resolution, color
# mode and contents. Preferences > General > Use Legacy "New Document"
# Interface brings back the 1994 dialog.

var
  ndTab = -1                     ## the tab shown (-1: not chosen yet this run)
  ndKey = ""                     ## the card picked ("p:<tab>:<i>", "t:<i>", "r:<i>", "s:<i>", "clip")
  ndTemplate = -1                ## the template picked (in `docTemplates()`; -1 a blank document)
  ndUnits = 0                    ## Pixels, Inches, Centimeters, Millimeters, Points, Picas
  ndResUnits = 0                 ## Pixels/Inch, Pixels/Centimeter
  ndArtboards = false
  ndWv, ndHv, ndRv: float        ## the size and resolution as the fields show them
  ndSeen: tuple[w, h, dpi, units, resUnits: int]
  ndThumbs: Table[string, Bitmap]
  ndThumbFrame = -1
  ndRecentFiles: seq[string]
  ndRecent, ndSaved: seq[DocPreset]
  ndSaveAsk = false
  ndSaveName = ""

const
  ndUnitNames = ["Pixels", "Inches", "Centimeters", "Millimeters", "Points", "Picas"]
  ndContents = ["White", "Black", "Background Color", "Transparent", "Custom"]
  ndContentsCodes = [0, 3, 1, 2, 4]   ## (`newContents` of each, in that order)

proc ndTabs(): seq[string] =
  result = @["Recent", "Saved"]
  for c in PresetCategory: result.add $c

proc ndPresetLine(p: DocPreset): string = p.name & "|" & $p.w & "|" & $p.h & "|" & $p.dpi & "|" & p.units

proc ndPresetsFrom(s: string): seq[DocPreset] =
  for line in s.split('\n'):
    let f = line.split('|')
    if f.len >= 4:
      try:
        result.add DocPreset(name: f[0], w: parseInt(f[1]), h: parseInt(f[2]), dpi: parseInt(f[3]),
                             units: if f.len > 4: f[4] else: "px")
      except ValueError: discard

proc ndLoad() =
  let st = loadSettings(AppData)
  ndRecent = ndPresetsFrom(st.getOrDefault("new.recent"))
  ndSaved = ndPresetsFrom(st.getOrDefault("new.saved"))
  ndRecentFiles = @[]
  for f in st.recentFiles():
    if fileExists(f) and ndRecentFiles.len < 8: ndRecentFiles.add f
  if ndTab < 0:
    ndTab = 2
    try: ndTab = clamp(parseInt(st.getOrDefault("new.tab", "2")), 0, ndTabs().high)
    except ValueError: discard

proc ndStore() =
  var st = loadSettings(AppData)
  st["new.recent"] = ndRecent.mapIt(ndPresetLine(it)).join("\n")
  st["new.saved"] = ndSaved.mapIt(ndPresetLine(it)).join("\n")
  st["new.tab"] = $ndTab
  discard saveSettings(AppData, st)

proc ndPick(key: string; p: DocPreset; tmpl = -1) =
  ## A card picked: its size in the details.
  ndKey = key
  ndTemplate = tmpl
  newW = max(1, p.w)
  newH = max(1, p.h)
  newDpi = max(1, p.dpi)
  newName = if tmpl >= 0: tr(p.name) else: "Untitled-" & $(untitled + 1)
  ndUnits = case p.units
            of "in": 1
            of "mm": 3
            else: 0

proc ndFactor(): float =
  ## Pixels a unit of `ndUnits`.
  let dpi = max(1, newDpi).float
  case ndUnits
  of 1: dpi
  of 2: dpi / 2.54
  of 3: dpi / 25.4
  of 4: dpi / 72
  of 5: dpi / 6
  else: 1.0

proc ndSync() =
  ## The fields follow the size when it changed (a card picked, the unit).
  let now = (newW, newH, newDpi, ndUnits, ndResUnits)
  if now == ndSeen: return
  ndSeen = now
  let k = ndFactor()
  ndWv = newW.float / k
  ndHv = newH.float / k
  ndRv = if ndResUnits == 1: newDpi.float / 2.54 else: newDpi.float

proc ndThumb(key: string; make: proc (): Bitmap): Bitmap =
  ## A card's picture, made once (one a frame, so the dialog opens at once).
  if key in ndThumbs: return ndThumbs[key]
  if ndThumbFrame != ui.frameNo:
    ndThumbFrame = ui.frameNo
    result = make()
    ndThumbs[key] = result

proc ndCard(key, title, sub: string; pw, ph: int; thumb: Bitmap; cw, ch: int): tuple[picked, open: bool] =
  ## A card: a page of the preset's shape (or the template's picture), its
  ## name and size under it.
  let r = place(dp(cw), dp(ch))
  let id = idOf("ndcard:" & key)
  let hit = interact(id, r, focusable = false)
  let th = ui.theme
  let on = ndKey == key
  if on: fill(r, mixColor(th.field, th.select, 0.22))
  elif hit.hover: fill(r, hoverColor())
  if on: box(r, th.select, 2)
  let pad = dp(8)
  let lh = lineHeight(style(size = 0.9))
  let area = rect(r.x + pad, r.y + pad, r.w - 2 * pad, r.h - 2 * pad - 2 * lh - dp(4))
  if thumb != nil and thumb.w > 0:
    let k = min(area.w / thumb.w, area.h / thumb.h)
    let tw = max(1, int(thumb.w.float * k))
    let tht = max(1, int(thumb.h.float * k))
    let tr0 = rect(area.x + (area.w - tw) div 2, area.y + (area.h - tht) div 2, tw, tht)
    drawBitmap(tr0, thumb)
    box(tr0, th.edge)
  else:
    # (a page of the preset's shape, as editors draw one)
    let side = min(area.w, area.h)
    let k = side.float * 0.82 / max(pw, ph).float
    let w = max(dp(6), int(pw.float * k))
    let h = max(dp(6), int(ph.float * k))
    let pg = rect(area.x + (area.w - w) div 2, area.y + (area.h - h) div 2, w, h)
    fill(rect(pg.x + dp(2), pg.y + dp(2), pg.w, pg.h), mixColor(th.face, th.shadow, 0.5))
    fill(pg, color(255, 255, 255))
    box(pg, th.text)
  let tst = style(bold = true, size = 0.9)
  let sst = style(size = 0.85)
  let ty = r.y + r.h - pad - 2 * lh
  let t1 = ellipsize(title, r.w - 2 * pad, tst)
  text(r.x + (r.w - textWidth(t1, tst)) div 2, ty, t1, th.text, tst)
  let t2 = ellipsize(sub, r.w - 2 * pad, sst)
  text(r.x + (r.w - textWidth(t2, sst)) div 2, ty + lh, t2, th.gray, sst)
  if title.len > 0: tooltip(title & "\n" & sub)
  result.picked = hit.clicked or (hit.down and ui.pressed)
  result.open = ui.doubleClick and ui.doubleClickId == id
  ui.lastId = id

proc ndRemember() =
  ## The size just made first in Recent.
  let p = DocPreset(name: (if ndTemplate >= 0: "" else: newName.strip), w: newW, h: newH, dpi: newDpi,
                    units: ["px", "in", "px", "mm", "px", "px"][clamp(ndUnits, 0, 5)])
  var k = 0
  while k < ndRecent.len:
    if ndRecent[k].w == p.w and ndRecent[k].h == p.h and ndRecent[k].dpi == p.dpi: ndRecent.delete(k)
    else: inc k
  ndRecent.insert(p, 0)
  if ndRecent.len > 10: ndRecent.setLen(10)
  ndStore()

proc ndCreate() =
  ## Create: the template, or a blank document as the details say.
  let tmpls = docTemplates()
  if ndTemplate in 0 .. tmpls.high:
    let t = tmpls[ndTemplate]
    inc untitled
    let nm = if newName.strip.len > 0: newName.strip else: tr(t.name)
    let d = buildTemplate(t, scale = newW / t.w, say = proc (s: string): string = tr(s), name = nm)
    d.clearHistory()
    d.modified = false
    addDoc(d)
    status = tr("A template: double-click a type layer to change its words; Layer > Place Into puts a photo " &
                "in a frame")
  else:
    let c = case newContents
            of 0: white
            of 1: bg
            of 3: black
            of 4: newColor or 0xFF000000'u32
            else: 0'u32
    let mode = newModeOf(newMode)
    let bits = if newBits == 1 and mode != cmBitmap: 16 else: 8
    let d = newUntitled(max(1, newW), max(1, newH), (if ndArtboards: 0'u32 else: c), newDpi.float, mode,
                        newName.strip, bits)
    if mode == cmRGB and prefs.workingSpace > 1 and prefs.workingSpace <= builtInProfileNames.len:
      d.icc = iccBytes(builtInProfile(builtInProfileNames[prefs.workingSpace - 1]))
    if ndArtboards:
      d.layers[0].background = false
      discard d.addArtboard(rect(0, 0, d.w, d.h), "Artboard 1", c)
      d.clearHistory()
      d.modified = false
    addDoc(d)
  ndRemember()
  newOpen = false

proc newDocDialog() =
  if not newOpen: return
  let avail = int(ui.w.float / ui.k)
  let availH = int(ui.h.float / ui.k)
  let W = clamp(avail - 24, 520, 980)
  let detailsW = if W < 700: 220 else: 268
  let cardsH = clamp(availH - 200, 240, 600)
  let cw = if W < 700: 116 else: 134
  ndSync()
  var open = false
  var create = false
  dialog(newOpen, "New Document", W):
    row([-1, detailsW]):
      col:
        var tab = ndTab
        let labels = ndTabs().mapIt(tr(it).replace("&", "&&"))
        beginTabs(tab, labels)
        if tab != ndTab:
          ndTab = tab
          ndStore()
        beginScroll(dp(cardsH), "ndcards")
        if ndTab == 0:
          # Recent: the clipboard's size, the files opened last, the sizes made last
          if hasClip or ndRecentFiles.len > 0:
            label(tr("RECENT FILES"), bold = true, color = ui.theme.gray)
            row:
              if hasClip:
                let (picked, op) = ndCard("clip", tr("Clipboard"), $clip.w & " x " & $clip.h & " px",
                                          clip.w, clip.h, nil, cw, 112)
                if picked: ndPick("clip", DocPreset(name: "Clipboard", w: clip.w, h: clip.h, dpi: 72))
                if op: create = true
              for i, f in ndRecentFiles:
                let r = place(dp(cw), dp(112))
                let id = idOf("ndfile:" & f)
                let hit = interact(id, r, focusable = false)
                if hit.hover: fill(r, hoverColor())
                let pad = dp(8)
                let lh = lineHeight(style(size = 0.9))
                let pr = rect(r.x + pad, r.y + pad, r.w - 2 * pad, r.h - 2 * pad - lh - dp(4))
                if not drawPicture(pr, f):
                  fill(pr, ui.theme.face)
                  box(pr, ui.theme.edge)
                let st = style(size = 0.9)
                let nm = ellipsize(f.extractFilename, r.w - 2 * pad, st)
                text(r.x + (r.w - textWidth(nm, st)) div 2, r.y + r.h - pad - lh, nm, ui.theme.text, st)
                ui.lastId = id
                tooltip(f)
                if hit.clicked:
                  newOpen = false
                  openFile(f)
            space(dp(6))
          label(tr("RECENT SIZES"), bold = true, color = ui.theme.gray)
          let recents = if ndRecent.len > 0: ndRecent else: @[docPresets(pcPhoto)[0]]
          row:
            for i, p in recents:
              let nm = if p.name.len > 0 and not p.name.startsWith("Untitled"): p.name else: tr("Custom")
              let (picked, op) = ndCard("r:" & $i, nm, p.sizeLabel, p.w, p.h, nil, cw, 112)
              if picked: ndPick("r:" & $i, p)
              if op: create = true
        elif ndTab == 1:
          label(tr("SAVED PRESETS"), bold = true, color = ui.theme.gray)
          if ndSaved.len == 0:
            label(tr("None yet: set a size at the right and click Save Preset."), color = ui.theme.gray)
          row:
            for i, p in ndSaved:
              let (picked, op) = ndCard("s:" & $i, p.name, p.sizeLabel, p.w, p.h, nil, cw, 112)
              if picked: ndPick("s:" & $i, p)
              if op: create = true
          if ndKey.startsWith("s:") and button(tr("Delete Preset"), w = dp(120)):
            try:
              let k = parseInt(ndKey[2 .. ^1])
              if k in 0 .. ndSaved.high:
                ndSaved.delete(k)
                ndStore()
            except ValueError: discard
            ndKey = ""
        else:
          let cat = PresetCategory(ndTab - 2)
          label(tr("BLANK DOCUMENT PRESETS"), bold = true, color = ui.theme.gray)
          row:
            for i, p in docPresets(cat):
              let key = "p:" & $ndTab & ":" & $i
              let (picked, op) = ndCard(key, tr(p.name), p.sizeLabel, p.w, p.h, nil, cw, 112)
              if picked: ndPick(key, p)
              if op: create = true
          let all = docTemplates()
          var any = false
          for t in all:
            if t.category == cat: any = true
          if any:
            space(dp(6))
            label(tr("TEMPLATES"), bold = true, color = ui.theme.gray)
            row:
              for i, t in all:
                if t.category != cat: continue
                let key = "t:" & $i
                let tt = t
                let thumb = ndThumb(key & ":" & uiLanguageCode(), proc (): Bitmap =
                  templateThumb(tt, dp(cw) - dp(16), proc (s: string): string = tr(s)))
                let p = DocPreset(name: t.name, w: t.w, h: t.h, dpi: t.dpi,
                                  units: if t.category == pcPrint: "mm" elif t.dpi >= 150: "in" else: "px")
                let (picked, op) = ndCard(key, tr(t.name), p.sizeLabel, t.w, t.h, thumb, cw, 150)
                if picked: ndPick(key, p, i)
                if op: create = true
        endScroll()
        endTabs()
      col:
        label(tr("PRESET DETAILS"), bold = true, color = ui.theme.gray)
        if ndTemplate >= 0: label(tr("Template:") & " " & tr(docTemplates()[ndTemplate].name), bold = true)
        row([-1, 64]):
          edit(newName)
          if button(tr("Save"), w = dp(60), enabled = ndTemplate < 0):
            ndSaveName = if newName.strip.startsWith("Untitled"): "" else: newName.strip
            ndSaveAsk = true
        tooltip(tr("Save Preset"))
        label tr("Width")
        row([-1, 98]):
          let decW = if ndUnits == 0 or abs(ndWv - round(ndWv)) < 0.02: 0 else: 2
          if numberEdit(ndWv, decW, w = dp(80), lo = 0.01, hi = 300000):
            newW = clamp(int(round(ndWv * ndFactor())), 1, 300000)
            ndSeen.w = newW
            ndTemplate = -1
          if combo(ndUnitNames, ndUnits, w = dp(98)): ndSync()
        label tr("Height")
        row([-1, 98]):
          let decH = if ndUnits == 0 or abs(ndHv - round(ndHv)) < 0.02: 0 else: 2
          if numberEdit(ndHv, decH, w = dp(80), lo = 0.01, hi = 300000):
            newH = clamp(int(round(ndHv * ndFactor())), 1, 300000)
            ndSeen.h = newH
            ndTemplate = -1
          label ""
        row:
          label tr("Orientation")
          if toolButton("▯", tr("Portrait"), down = newH >= newW) and newW > newH:
            swap(newW, newH)
          if toolButton("▭", tr("Landscape"), down = newW > newH) and newH > newW:
            swap(newW, newH)
          if ndTemplate < 0: checkbox(tr("Artboards"), ndArtboards)
        label tr("Resolution")
        row([-1, 98]):
          if numberEdit(ndRv, (if ndResUnits == 1: 2 else: 0), w = dp(80), lo = 1, hi = 9999):
            newDpi = clamp(int(round(if ndResUnits == 1: ndRv * 2.54 else: ndRv)), 1, 9999)
            ndSeen.dpi = newDpi
          combo(["Pixels/Inch", "Pixels/Centimeter"], ndResUnits, w = dp(98))
        let enabledBlank = ndTemplate < 0
        label tr("Color Mode")
        row([-1, 70]):
          combo(newModeNames, newMode, w = dp(detailsW - 80), enabled = enabledBlank)
          combo(["8 bit", "16 bit"], newBits, w = dp(70), enabled = enabledBlank and newModeOf(newMode) != cmBitmap)
        label tr("Background Contents")
        row([-1, 0]):
          # (the list's order is not the codes' -- 0 white, 1 background color,
          # 2 transparent, 3 black, 4 custom: Transparent made it black)
          var ci = max(0, ndContentsCodes.find(newContents))
          combo(ndContents, ci, w = dp(detailsW - (if newContents == 4: 50 else: 10)), enabled = enabledBlank)
          newContents = ndContentsCodes[ci]
          if newContents == 4 and colorWell(newColor, "ndcontents", dp(36)): discard
        let chans = case newModeOf(newMode)
                    of cmBitmap, cmGray: 1
                    of cmCMYK: 4
                    else: 3
        label(tr("Image Size:") & " " & sizeText(newW * newH * chans * (if newBits == 1: 2 else: 1)) &
              "  (" & $newW & " x " & $newH & " px)", color = ui.theme.gray)
        let fits = sizeOk(newW, newH)
        if not fits:
          label(tr("Too big: at most") & " " & $(maxPixels div 1_000_000) & " " & tr("million pixels"),
                color = color(160, 0, 0))
        space(dp(8))
        row:
          spring()
          if button(tr("Create"), isDefault = true, w = dp(86), enabled = fits): create = true
          if button(tr("Close"), w = dp(76)): newOpen = false
  if ndSaveAsk:
    dialog(ndSaveAsk, "Save Document Preset", 340):
      label tr("Preset Name:")
      edit(ndSaveName)
      label($newW & " x " & $newH & tr(" px, ") & $newDpi & tr(" ppi"), color = ui.theme.gray)
      row:
        spring()
        if button(tr("Save Preset"), isDefault = true, w = dp(100), enabled = ndSaveName.strip.len > 0):
          ndSaved.add DocPreset(name: ndSaveName.strip, w: newW, h: newH, dpi: newDpi,
                                units: ["px", "in", "px", "mm", "px", "px"][clamp(ndUnits, 0, 5)])
          ndStore()
          ndSaveAsk = false
          ndTab = 1
          ndKey = "s:" & $ndSaved.high
        if button(tr("Cancel"), w = dp(80)): ndSaveAsk = false
  if create and newOpen and sizeOk(newW, newH): ndCreate()
  discard open

proc startNewDocument() =
  ## File > New: the dialog of today's editors (or the legacy one).
  ndLoad()
  if not prefs.legacyNew:
    if hasClip:
      ndPick("clip", DocPreset(name: "Clipboard", w: clip.w, h: clip.h, dpi: 72))
      if ndTab < 0: ndTab = 0
    elif ndKey.len == 0:
      let p = if ndRecent.len > 0: ndRecent[0] else: docPresets(pcPhoto)[0]
      ndPick(if ndRecent.len > 0: "r:0" else: "p:2:0", p)
    newName = "Untitled-" & $(untitled + 1)
    ndTemplate = if ndKey.startsWith("t:"): ndTemplate else: -1
    if ndTemplate >= 0: newName = tr(docTemplates()[ndTemplate].name)
    ndSeen = (-1, -1, -1, -1, -1)

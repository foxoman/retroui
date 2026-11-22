# Retro Atelier -- included by photo.nim
#
# File > Browse Assets (Window > Assets): free photos, illustrations,
# vectors, icons, textures and backgrounds from the open sources on the
# web (Openverse, Wikimedia Commons, Pixabay, Pexels and Unsplash with a key, Iconify, Poly
# Haven, ambientCG) and the Retro Atelier Library (brushes, patterns,
# gradients, swatches, styles, designs -- carried in the app, more online),
# by kind and category, with a search. A click shows one; Insert puts it in
# the image (a photo as a Smart Object, an icon as shapes, a pattern as a
# fill layer, a style on the layer, a brush in the Brushes...), Open makes
# it a document, Download keeps the file (and its credit) in Pictures.

include librarydata

var
  asOpen = false
  asKind = akPhoto
  asSrc: array[AssetKind, int]          ## the source picked for each kind (in `sourcesFor`)
  asCat: array[AssetKind, int]          ## ... its category (0: all / none)
  asText = ""
  asAsked = ""                          ## (the query shown: kind, source, category, words)
  asItems: seq[AssetItem]
  asPage = 1
  asMore = false
  asTotal = -1
  asError = ""
  asTicket = -1                         ## (the answer awaited)
  asSel = -1
  asThumbs: Table[string, Bitmap]       ## (url: its picture; nil while it comes)
  asThumbOf: Table[int, string]         ## (fetch ticket: the url)
  asLib: seq[AssetItem]                 ## the library: carried + online
  asLibTicket = -1
  asLibOnline = false
  asSettings = false
  asKey = ""                            ## (the Pixabay key being typed)
  asPexelsKey = ""                      ## (... Pexels')
  asUnsplashKey = ""                    ## (... Unsplash's)
  asLibUrl = ""

const defaultLibraryUrl = "https://raw.githubusercontent.com/foxoman/retro-photo-library/main/catalog.json"

proc bundledFile(name: string): string =
  for (n, data) in bundledLibrary:
    if n == name: return data

proc bundledFor(url: string): string =
  ## (a library file carried in the app -- a path with no address: its
  ## bytes; "" when it is not one)
  if "://" in url or url.startsWith("template:"): return ""
  bundledFile(if url.startsWith("bundled:"): url["bundled:".len .. ^1] else: url)

proc assetsSetup() =
  ## (where things are kept; the keys; the carried library)
  assetCacheDir = dataDir(AppData) / "Asset Cache"
  assetUserAgent = AppName & "/" & AppVersion & " (https://github.com/foxoman)"
  let st = loadSettings(AppData)
  pixabayKey = st.getOrDefault("assets.pixabay")
  pexelsKey = st.getOrDefault("assets.pexels")
  unsplashKey = st.getOrDefault("assets.unsplash")
  libraryCatalogUrl = st.getOrDefault("assets.library", defaultLibraryUrl)
  if asLib.len == 0:
    asLib = parseLibrary(bundledFile("catalog.json"), "bundled:")
    setLibrary(asLib)

proc assetsSave() =
  var st = loadSettings(AppData)
  st["assets.pixabay"] = pixabayKey
  st["assets.pexels"] = pexelsKey
  st["assets.unsplash"] = unsplashKey
  st["assets.library"] = libraryCatalogUrl
  discard saveSettings(AppData, st)

proc kindIcon(k: AssetKind): string =
  case k
  of akPhoto: pxImage
  of akIllustration: pxPaint
  of akVector: pxPen
  of akIcon: pxStar
  of akTexture: pxPatterns
  of akBackground: pxSky
  of akBrush: pxBrush
  of akPattern: pxPatternStamp
  of akGradient: pxGradient
  of akSwatches: pxSwatches
  of akStyle: pxLayerStyle
  of akDesign: pxSlides

proc usableSources(k: AssetKind): seq[AssetSource] =
  # (under the kit's random input -- tools/soak.sh -- the library carried in the app only: an hour of
  # clicks downloading 4K textures and opening them measures the network's files, not a leak)
  if smokeOn(): return @[asLibrary]
  for s in sourcesFor(k):
    if hasKey(s): result.add s

proc curSource(): AssetSource =
  let ss = usableSources(asKind)
  if ss.len == 0: asLibrary else: ss[clamp(asSrc[asKind], 0, ss.high)]

proc curCategories(): seq[AssetCategory] =
  let s = curSource()
  if s == asLibrary: libraryCategories(asLib, asKind) else: categoriesOf(s, asKind)

proc askPage(page: int) =
  ## The query as the window says it, asked (the page `page` of it).
  let cats = curCategories()
  let ci = asCat[asKind]
  var q = AssetQuery(source: curSource(), kind: asKind, text: asText.strip, page: page,
                     category: if ci > 0 and ci <= cats.len: cats[ci - 1].key else: "")
  if page == 1:
    asItems.setLen(0)
    asSel = -1
    asTotal = -1
    cancelFetches(2)
    asThumbOf.clear()
    if asThumbs.len > 200: asThumbs.clear()   # (a new search: those of the old ones let go)
  asError = ""
  asPage = page
  if q.source == asLibrary:
    let pg = libraryPage(q)
    asItems.add pg.items
    asMore = pg.hasMore
    asTotal = pg.total
    asError = pg.error
    asTicket = -1
    return
  let url = queryUrl(q)
  if url.len == 0:
    asError = tr("This source has nothing of this kind")
    asTicket = -1
    return
  asTicket = fetchAsync(url, group = 1, maxAgeSec = (if q.source == asPixabay: 24 * 3600 else: 6 * 3600))

proc queryKey(): string =
  $asKind & "/" & $curSource() & "/" & $asCat[asKind] & "/" & asText.strip

proc thumbOf(it: AssetItem; side: int): Bitmap =
  ## The item's small picture: made at once from the library carried in the
  ## app, else fetched (nil until it is there).
  let url = it.thumbUrl
  if url.len == 0: return nil
  if url in asThumbs: return asThumbs[url]
  asThumbs[url] = nil
  let data = bundledFor(url)
  if data.len > 0:
    asThumbs[url] = try: decodePng(data) except CatchableError: nil
    return asThumbs[url]
  let t = fetchAsync(url, group = 2, priority = 1)
  asThumbOf[t] = url
  nil

proc assetsPoll() =
  ## (every frame: what came)
  for r in fetchDone():
    if r.ticket == asTicket:
      asTicket = -1
      if r.error.len > 0:
        asError = r.error
      else:
        let q = AssetQuery(source: curSource(), kind: asKind, page: asPage)
        let pg = try: parsePage(q, readFile(r.path)) except CatchableError: AssetPage(error: getCurrentExceptionMsg())
        asItems.add pg.items
        asMore = pg.hasMore
        asTotal = pg.total
        asError = pg.error
    elif r.ticket == asLibTicket:
      asLibTicket = -1
      if r.error.len == 0:
        let base = libraryCatalogUrl[0 .. max(0, libraryCatalogUrl.rfind('/'))]
        let online = try: parseLibrary(readFile(r.path), base) except CatchableError: @[]
        var ids: seq[string]
        for it in online: ids.add $it.kind & "/" & it.id
        var merged = online
        for it in asLib:
          if ($it.kind & "/" & it.id) notin ids: merged.add it
        asLib = merged
        setLibrary(asLib)
        asLibOnline = online.len > 0
        if curSource() == asLibrary: asAsked = ""        # (shown again, with them)
    elif r.ticket in asThumbOf:
      let url = asThumbOf[r.ticket]
      asThumbOf.del r.ticket
      if r.error.len == 0 and r.path.len > 0:
        if url.toLowerAscii.endsWith(".svg") or url.contains(".svg?"):
          asThumbs[url] = try: rasterizeSvg(readFile(r.path), dp(96), dp(96), argb(255, int(ui.theme.text.r), int(ui.theme.text.g), int(ui.theme.text.b)))
                          except CatchableError: nil
        else:
          discard pictureAsync(r.path, dp(180), dp(180), group = 77, onDone = proc (res: var TaskResult) =
            if res.w > 0: asThumbs[url] = res.toBitmap)

proc startAssets(kind = akPhoto) =
  assetsSetup()
  asKind = kind
  asOpen = true
  asAsked = ""
  asKey = pixabayKey
  asPexelsKey = pexelsKey
  asUnsplashKey = unsplashKey
  asLibUrl = libraryCatalogUrl
  if not asLibOnline and asLibTicket < 0 and libraryCatalogUrl.len > 0:
    asLibTicket = fetchAsync(libraryCatalogUrl, group = 3, maxAgeSec = 6 * 3600)

# ---- what a picked item does ------------------------------------------------------------------------

proc assetFile(it: var AssetItem): string =
  ## The item's file, fetched (a busy box meanwhile): its path ("" failed,
  ## the status says why).
  if it.needsResolve:
    let u = resolveUrl(it)
    let p = cachedPath(u)
    let path = if p.len > 0: p else: assetCacheDir / "resolve-" & $hash(u) & ".json"
    if p.len == 0:
      let err = fetchNow(u, path)
      if err.len > 0:
        status = tr("Could not get it:") & " " & err
        return ""
    try: it.applyResolve(readFile(path))
    except CatchableError:
      status = tr("Could not get it:") & " " & getCurrentExceptionMsg()
      return ""
  if it.fullUrl.len == 0:
    status = tr("Could not get it:") & " " & tr("no file")
    return ""
  let data = bundledFor(it.fullUrl)
  let ext = if it.ext.len > 0: it.ext else: "bin"
  let dest = assetCacheDir / "full-" & $hash(it.fullUrl) & "." & ext
  if data.len > 0:
    try:
      createDir(assetCacheDir)
      writeFile(dest, data)
    except CatchableError: return ""
    return dest
  if fileExists(dest) and getFileSize(dest) > 0: return dest
  let err = fetchNow(it.fullUrl, dest)
  if err.len > 0:
    status = tr("Could not get it:") & " " & err
    return ""
  if ext == "zip":
    # (a texture's maps: its color one)
    try:
      let (name, img) = textureFromZip(readFile(dest))
      if img.len == 0:
        status = tr("Could not get it:") & " " & tr("no picture in the download")
        return ""
      let p = assetCacheDir / "full-" & $hash(it.fullUrl) & "-" & name.extractFilename
      writeFile(p, img)
      return p
    except CatchableError:
      status = tr("Could not get it:") & " " & getCurrentExceptionMsg()
      return ""
  dest

proc credit(d: Doc; it: AssetItem) =
  ## (the credit kept with the image: File > File Info)
  let note = it.licenseNote
  if note.len == 0 or d == nil: return
  if note notin d.info.copyright:
    d.info.copyright = (if d.info.copyright.len > 0: d.info.copyright & "\n" else: "") & note

proc gradientFromJson(s: string): GradientPreset =
  let j = parseJson(s)
  result.name = j{"name"}.getStr("Gradient")
  for st in j{"stops"}.getElems:
    let hex = st{"color"}.getStr("#000000").strip(chars = {'#'})
    let rgb = try: uint32(parseHexInt(hex)) and 0xFFFFFF'u32 except ValueError: 0'u32
    let a = uint32(clamp(st{"alpha"}.getInt(255), 0, 255))
    result.stops.add GradientStop(at: st{"at"}.getFloat(0), color: (a shl 24) or rgb, mid: st{"mid"}.getFloat(0.5))

proc insertAsset(it: var AssetItem; asDocument = false) =
  ## Insert (or Open as Document): the item in the current image -- or a
  ## new one.
  var d = cur()
  if asDocument: d = nil
  if it.fullUrl.startsWith("template:"):
    let name = it.fullUrl["template:".len .. ^1]
    for t in docTemplates():
      if t.name == name:
        inc untitled
        let nd = buildTemplate(t, say = proc (s: string): string = tr(s), name = tr(t.name))
        nd.clearHistory()
        nd.modified = false
        addDoc(nd)
        status = tr("A template: double-click a type layer to change its words; Layer > Place Into puts a photo " &
                    "in a frame")
        return
    return
  beginBusy(tr("Getting") & " " & it.title)
  var path = ""
  try: path = assetFile(it)
  finally: endBusy()
  if path.len == 0: return
  let ext = path.splitFile.ext.toLowerAscii
  try:
    case it.kind
    of akBrush:
      let got = presetsFromJson(readFile(path))
      for p in got:
        var q = p
        q.folder = "Library"
        presets.add q
      savePresets()
      if got.len > 0:
        tool = tBrush
        opts[tBrush].tip = got[0].tip
        opts[tBrush].dyn = got[0].dyn
      status = tr("Brush added to the Brushes (folder Library):") & " " & it.title
    of akPattern:
      let b = decodePng(readFile(path))
      let pp = PatternPreset(name: it.title, w: b.w, h: b.h, px: b.px)
      userPatterns.add pp
      usePattern(pp)
      if d != nil:
        d.layersChange("Pattern Fill"):
          discard d.addFillLayer(ShapePaint(kind: spPattern, pattern: pp.px, pw: pp.w, ph: pp.h, scale: 100,
                                            opacity: 100), it.title)
      status = tr("Pattern added to the Patterns:") & " " & it.title
    of akGradient:
      let g = gradientFromJson(readFile(path))
      userGradients.add g
      if d != nil:
        d.layersChange("Gradient Fill"):
          var gp = gradientPaint(g.stops[0].color, g.stops[^1].color, 90)
          gp.stops = g.stops
          discard d.addFillLayer(gp, it.title)
      status = tr("Gradient added to the gradients:") & " " & it.title
    of akSwatches:
      let got = readAse(readFile(path))
      for (_, c) in got: swatches.add c
      status = $got.len & " " & tr("swatches added:") & " " & it.title
    of akStyle:
      let j = parseJson(readFile(path))
      let fx = layerFxFrom(j{"fx"})
      userStyles.add (it.title, fx)
      if d != nil and not d.current.background and not d.current.group:
        let L = d.current
        d.stepOnce("Apply Style", proc () =
          L.fx = fx
          d.markAll())
        status = tr("Style on the layer and in the Styles:") & " " & it.title
      else:
        status = tr("Style added to the Styles:") & " " & it.title
    of akDesign:
      openFile(path)
    of akVector, akIcon:
      let data = readFile(path)
      if d == nil:
        inc untitled
        d = newDoc(1200, 1200, 0'u32, 300, it.title)
        d.clearHistory()
        addDoc(d)
      let side = min(d.w, d.h).float * (if it.kind == akIcon: 0.3 else: 0.6)
      let box = if d.hasSelection: d.clip(d.selBounds)
                else: rect(int((d.w.float - side) / 2), int((d.h.float - side) / 2), int(side), int(side))
      d.beginStep(if it.kind == akIcon: "Place Icon" else: "Place Vector")
      d.touchLayers()
      discard d.placeSvg(data, box, fg or 0xFF000000'u32)
      d.endStep()
      d.credit(it)
      status = it.title & " -- " & tr("shape layers (sharp at any size; change their color in Properties)")
    else:
      if ext == ".svg":
        # (an illustration drawn as vectors)
        var it2 = it
        it2.kind = akVector
        insertAsset(it2, asDocument)
        return
      if d == nil:
        openFile(path)
        let nd = cur()
        if nd != nil:
          nd.name = it.title
          nd.credit(it)
      else:
        d.placeSmart(path)
        d.credit(it)
        status = it.title & " -- " & tr("placed as a Smart Object; credit kept in File Info")
  except CatchableError:
    status = tr("Could not use it:") & " " & getCurrentExceptionMsg()

proc downloadAsset(it: var AssetItem) =
  ## Download: the file kept in Pictures/Retro Atelier Assets, its credit in
  ## CREDITS.txt there.
  if it.fullUrl.startsWith("template:"):
    status = tr("Designs open as documents: use Open as Document, then save")
    return
  beginBusy(tr("Getting") & " " & it.title)
  var path = ""
  try: path = assetFile(it)
  finally: endBusy()
  if path.len == 0: return
  let dir = picturesDir() / "Retro Atelier Assets" / $it.kind
  try:
    createDir(dir)
    var name = it.title.multiReplace(("/", "-"), ("\\", "-"), (":", " "), ("\"", ""), ("*", ""), ("?", ""))
    if name.len == 0: name = it.id
    let dest = dir / name & path.splitFile.ext
    copyFile(path, dest)
    let credits = picturesDir() / "Retro Atelier Assets" / "CREDITS.txt"
    let f = open(credits, fmAppend)
    f.writeLine(dest.extractFilename & " -- " & it.licenseNote & (if it.pageUrl.len > 0: " <" & it.pageUrl & ">" else: ""))
    f.close()
    status = tr("Saved:") & " " & dest
  except CatchableError:
    status = tr("Could not save it:") & " " & getCurrentExceptionMsg()

# ---- the window ----------------------------------------------------------------------------------------------

proc assetsDialog() =
  if not asOpen:
    # (closed: its pictures let go -- each one ever shown was kept, an hour's browsing online
    # a hundred MB)
    if asThumbs.len > 0 or asThumbOf.len > 0:
      asThumbs.clear()
      asThumbOf.clear()
    return
  assetsPoll()
  if fetchPending() > 0 or asTicket >= 0: wakeIn(50)
  let avail = int(ui.w.float / ui.k)
  let availH = int(ui.h.float / ui.k)
  let W = clamp(avail - 24, 560, 1080)
  let gridH = clamp(availH - 230, 220, 640)
  let leftW = if W < 760: 150 else: 186
  let rightW = if W < 760: 190 else: 230
  if queryKey() != asAsked:
    asAsked = queryKey()
    askPage(1)
  var doInsert, doOpen, doDownload = false
  dialog(asOpen, "Assets", W):
    row([leftW, -1, rightW]):
      # the kinds, and the categories of the one picked
      col:
        label(tr("KIND"), bold = true, color = ui.theme.gray)
        for k in AssetKind:
          let on = asKind == k
          let r = place(available(), dp(22))
          let id = idOf("askind" & $k)
          let hit = interact(id, r, focusable = false)
          if on: fill(r, ui.theme.select)
          elif hit.hover: fill(r, hoverColor())
          image(r.x + dp(3), r.y + (r.h - dp(16)) div 2, glyphIcon(kindIcon(k), ui.theme.text, dp(16)))
          text(r.x + dp(24), r.y + (r.h - FontH) div 2, tr($k), if on: ui.theme.selectText else: ui.theme.text)
          if hit.clicked and not on:
            asKind = k
        space(dp(6))
        let cats = curCategories()
        if cats.len > 0:
          label(tr("CATEGORY"), bold = true, color = ui.theme.gray)
          beginScroll(max(dp(80), dp(gridH) - dp(12 * 22 + 40)), "ascats")
          var names = @[tr("All")]
          for c in cats: names.add tr(c.name)
          for i, n in names:
            let on = asCat[asKind] == i
            let r = place(available(), dp(20))
            let hit = interact(idOf("ascat" & $asKind & ":" & $i), r, focusable = false)
            if on: fill(r, ui.theme.select)
            elif hit.hover: fill(r, hoverColor())
            text(r.x + dp(6), r.y + (r.h - FontH) div 2, ellipsize(n, r.w - dp(8)),
                 if on: ui.theme.selectText else: ui.theme.text)
            if hit.clicked: asCat[asKind] = i
          endScroll()
      # the search, the source, the pictures
      col:
        row([-1, 76, 156]):
          if edit(asText) and asText.len == 0: discard
          if button(tr("Search"), w = dp(70)): asAsked = ""
          let ss = usableSources(asKind)
          var names: seq[string]
          for s in ss: names.add $s
          if names.len == 0: names.add $asLibrary
          var si = clamp(asSrc[asKind], 0, max(0, names.high))
          if combo(names, si, w = dp(150)):
            asSrc[asKind] = si
            asCat[asKind] = 0
        beginScroll(dp(gridH), "asgrid")
        let cw = dp(if asKind in {akIcon, akSwatches, akGradient}: 92 else: 128)
        let ch = dp(if asKind in {akIcon}: 92 elif asKind in {akSwatches, akGradient, akBrush}: 76 else: 112)
        if asItems.len == 0:
          label((if asTicket >= 0: tr("Getting the list...")
                 elif asError.len > 0: tr("Could not get the list:") & " " & asError
                 else: tr("Nothing found")), color = if asError.len > 0: color(160, 0, 0) else: ui.theme.gray)
        row:
          for i in 0 ..< asItems.len:
            let r = place(cw, ch)
            let id = idOf("asitem" & $i)
            let hit = interact(id, r, focusable = false)
            let on = asSel == i
            if on: fill(r, mixColor(ui.theme.field, ui.theme.select, 0.25))
            elif hit.hover: fill(r, hoverColor())
            let pic = inset(r, dp(4))
            let th = thumbOf(asItems[i], max(pic.w, pic.h))
            if th != nil and th.w > 0:
              let k = min(pic.w / th.w, pic.h / th.h)
              let tw = max(1, int(th.w.float * k))
              let tht = max(1, int(th.h.float * k))
              drawBitmap(rect(pic.x + (pic.w - tw) div 2, pic.y + (pic.h - tht) div 2, tw, tht), th)
            else:
              drawSpinner(pic.x + pic.w div 2, pic.y + pic.h div 2, min(dp(10), pic.h div 4))
            if on: box(r, ui.theme.select, 2)
            ui.lastId = id
            tooltip(asItems[i].title & (if asItems[i].author.len > 0: "  --  " & asItems[i].author else: ""))
            if hit.clicked: asSel = i
            if ui.doubleClick and ui.doubleClickId == id:
              asSel = i
              doInsert = true
        if asMore and asTicket < 0:
          if button(tr("More"), w = dp(100)): askPage(asPage + 1)
        elif asTicket >= 0 and asItems.len > 0:
          label(tr("Getting more..."), color = ui.theme.gray)
        endScroll()
        let src = curSource()
        label((if asTotal >= 0: $asTotal & " " & tr("found") & "  ·  " else: "") & tr("from") & " " & $src &
              (if src == asPolyHaven: "  ·  Powered by Poly Haven" else: ""), color = ui.theme.gray)
      # the one picked
      col:
        label(tr("DETAILS"), bold = true, color = ui.theme.gray)
        if asSel in 0 .. asItems.high:
          let it = asItems[asSel]
          let th = thumbOf(it, dp(rightW))
          let r = place(available(), dp(150))
          fill(r, ui.theme.face)
          if th != nil and th.w > 0:
            let k = min(r.w / th.w, r.h / th.h)
            let tw = max(1, int(th.w.float * k))
            let tht = max(1, int(th.h.float * k))
            drawBitmap(rect(r.x + (r.w - tw) div 2, r.y + (r.h - tht) div 2, tw, tht), th)
          box(r, ui.theme.edge)
          paragraph(it.title)
          if it.author.len > 0: label(tr("By") & " " & it.author, color = ui.theme.gray)
          if it.license.len > 0: label(tr("License:") & " " & it.license, color = ui.theme.gray)
          if it.width > 0: label($it.width & " x " & $it.height & " px", color = ui.theme.gray)
          label(tr("Source:") & " " & $it.source, color = ui.theme.gray)
          space(dp(6))
          let insertLabel = case it.kind
                            of akBrush: tr("Add to Brushes")
                            of akStyle: tr("Apply Style")
                            of akSwatches: tr("Add to Swatches")
                            of akDesign: tr("Open Design")
                            else: tr("Insert")
          if button(insertLabel, w = available(), isDefault = true): doInsert = true
          if it.kind notin {akBrush, akStyle, akSwatches, akDesign}:
            if button(tr("Open as Document"), w = available()): doOpen = true
          if button(tr("Download"), w = available()): doDownload = true
          if it.pageUrl.len > 0 and button(tr("View on the Web"), w = available()):
            discard openUrl(it.pageUrl)
        else:
          label(tr("Click a picture to see it; double-click to insert it."), color = ui.theme.gray)
        space(dp(10))
        if button(tr("Settings..."), w = available()): asSettings = true
  if asSel in 0 .. asItems.high and (doInsert or doOpen or doDownload):
    var it = asItems[asSel]
    # (Unsplash counts what is used: told once, when it is)
    if it.pingUrl.len > 0:
      discard fetchAsync(it.pingUrl, group = 4, maxAgeSec = 0)
      asItems[asSel].pingUrl = ""
      it.pingUrl = ""
    if doDownload: downloadAsset(it)
    else: insertAsset(it, asDocument = doOpen)
    asItems[asSel] = it
  if asSettings:
    dialog(asSettings, "Assets Settings", 440):
      group("Pixabay"):
        label(tr("Pixabay asks each app for a free key: make one at pixabay.com (API), then paste it here."),
              color = ui.theme.gray)
        row:
          label "API Key:"
          edit(asKey, w = dp(260))
        if button(tr("Get a Free Key..."), w = dp(150)): discard openUrl("https://pixabay.com/api/docs/")
      group("Pexels"):
        label(tr("Pexels: free photos. Make a free key at pexels.com/api, then paste it here."),
              color = ui.theme.gray)
        row:
          label "API Key:"
          edit(asPexelsKey, w = dp(260))
        if button(tr("Get a Free Key..."), w = dp(150)): discard openUrl("https://www.pexels.com/api/new/")
      group("Unsplash"):
        label(tr("Unsplash: free photos. Make a free app at unsplash.com/developers and paste its Access Key here."),
              color = ui.theme.gray)
        row:
          label "Access Key:"
          edit(asUnsplashKey, w = dp(260))
        if button(tr("Get a Free Key..."), w = dp(150)): discard openUrl("https://unsplash.com/oauth/applications")
      group("Retro Atelier Library"):
        label(tr("The online catalog (catalog.json) added to the library the app carries:"), color = ui.theme.gray)
        edit(asLibUrl)
        if button(tr("Default"), w = dp(80)): asLibUrl = defaultLibraryUrl
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)):
          pixabayKey = asKey.strip
          pexelsKey = asPexelsKey.strip
          unsplashKey = asUnsplashKey.strip
          if asLibUrl.strip != libraryCatalogUrl:
            libraryCatalogUrl = asLibUrl.strip
            asLibOnline = false
            if libraryCatalogUrl.len > 0: asLibTicket = fetchAsync(libraryCatalogUrl, group = 3, maxAgeSec = 0)
          assetsSave()
          asAsked = ""
          asSettings = false
        if button("Cancel", w = dp(80)): asSettings = false

proc assetsCommand(name: string): bool =
  ## The commands of the Assets window (true: done here).
  result = true
  case name
  of "Browse Assets...", "Assets": startAssets(asKind)
  of "Browse Icons...": startAssets(akIcon)
  of "Browse Photos...": startAssets(akPhoto)
  of "Browse Designs...": startAssets(akDesign)
  else: result = false

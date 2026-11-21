## Retro Atelier: Window > Links and File > Package, as the layout program has them -- the
## pictures placed linked (Place Linked), each shown OK, Modified or Missing, updated, relinked,
## embedded; and a document or a book gathered with its pictures and fonts into one folder, with
## its IDML and PDF and a report, to hand to a printer (included by photo.nim).

var
  linkPick = false             ## (Relink: the picker up)
  linkPath = ""
  linkLayer: Layer
  placeLinkedPick = false
  pkgDlg: tuple[open: bool; fonts, links, relink, idml, pdf: bool; pick: bool; path: string; report: string]
  pkgOk*: string               ## (the folder to package into, from outside: the tests)

type LinkState = enum lsOk = "OK", lsModified = "Modified", lsMissing = "Missing", lsEmbedded = "Embedded"

proc linkState(L: Layer): LinkState =
  if not L.isSmart or L.smart.link.len == 0: return lsEmbedded
  if not fileExists(L.smart.link): return lsMissing
  if fileStamp(L.smart.link) != L.smart.linkStamp: lsModified else: lsOk

proc relinked(d: Doc; L: Layer; path: string): bool =
  ## (a linked picture read again from `path`, in the same corners, its link that file)
  try:
    let src = openPicture(path)
    var s = L.smart.withSource(src.flattened(), src.w, src.h)
    s.link = path.absolutePath
    s.linkStamp = fileStamp(path)
    s.name = path.extractFilename
    d.layersChange("Update Link"):
      L.smart = s
      d.renderSmartLayer(L)
    true
  except CatchableError:
    status = "Could not read " & path.extractFilename & ": " & getCurrentExceptionMsg()
    false

proc embedLink(d: Doc; L: Layer) =
  if not L.isSmart or L.smart.link.len == 0: return
  var s = L.smart.withQuad(L.smart.quad)
  s.link = ""
  s.linkStamp = 0
  d.layersChange("Embed Link"):
    L.smart = s

proc linksBody() =
  ## Window > Links: the pictures placed, linked or embedded
  let d = cur()
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  var pick {.global.}: Layer
  var rows: seq[Layer]
  for i in countdown(d.layers.high, 0):
    if d.layers[i].isSmart: rows.add d.layers[i]
  let lh = max(ItemH * 4, min(ItemH * 12, remainingH() - ItemH * 3))
  beginScroll(lh, "linklist")
  if rows.len == 0: label("(no pictures placed: File > Place Linked)", color = ui.theme.gray)
  for L in rows:
    let r = place(available(), ItemH)
    let sel = L == pick
    if sel: fill(r, ui.theme.select)
    let st = linkState(L)
    let col = if sel: ui.theme.selectText else: ui.theme.text
    let nm = if L.smart.name.len > 0: L.smart.name else: L.name
    text(r.x + dp(4), itemTextY(r.y), nm, col)
    let mark = case st
               of lsOk: ""
               of lsModified: "!"
               of lsMissing: "?"
               of lsEmbedded: "E"
    let markCol = case st
                  of lsModified: color(220, 160, 0)
                  of lsMissing: color(220, 0, 0)
                  else: col
    text(r.x + r.w - dp(20), itemTextY(r.y), mark, markCol)
    let hit = interact(idOf("link:" & $uidOf(L)), r, focusable = false)
    if hit.clicked: pick = L
    if hit.hover: ui.tip = tr($st) & (if L.smart.link.len > 0: ": " & L.smart.link else: "")
  endScroll()
  let some = pick != nil and pick in d.layers and pick.isSmart
  if some:
    let st = linkState(pick)
    label(tr($st) & (if pick.smart.link.len > 0: " -- " & pick.smart.link.extractFilename else: ""),
          color = ui.theme.gray)
  row:
    if panelIcon(pxOpen, "Relink...", enabled = some):
      linkLayer = pick
      linkPath = if pick.smart.link.len > 0: pick.smart.link.parentDir else: picturesDir()
      linkPick = true
    if panelIcon(pxRefresh, "Update Link", enabled = some and linkState(pick) == lsModified):
      discard d.relinked(pick, pick.smart.link)
    if panelIcon(pxEye, "Go To Link", enabled = some):
      d.cur = d.layers.find(pick)
      d.clearPicks()
      inc d.ver
    if panelIcon(pxLayers, "Embed Link", enabled = some and pick.smart.link.len > 0): d.embedLink(pick)
  var stale = 0
  for L in rows:
    if linkState(L) == lsModified: inc stale
  if stale > 0 and button("Update All Links (" & $stale & ")", w = dp(170)):
    for L in rows:
      if linkState(L) == lsModified: discard d.relinked(L, L.smart.link)

# ---- File > Package -----------------------------------------------------------------------------------------

proc docsToPackage(): tuple[docs: seq[Doc]; book: Book; name: string] =
  ## (what is packaged: the book the window is a page of -- all its pages --, else the image)
  let bw = curBook()
  if bw != nil:
    let b = bw.book
    for i in 0 ..< b.pages.len: result.docs.add b.doc(i)
    result.book = b
    result.name = b.name
  elif cur() != nil:
    result.docs = @[cur()]
    result.name = cur().name.changeFileExt("")

proc fontsOf(docs: seq[Doc]): seq[tuple[family, style, file: string]] =
  ## (the fonts the documents' type is set in, each once: its file, "" built in or not found)
  var seen: seq[string]
  proc add(r: var seq[tuple[family, style, file: string]]; fam, sty: string) =
    if fam.len == 0 or (fam & "\t" & sty) in seen: return
    seen.add fam & "\t" & sty
    r.add (fam, sty, fontFileOf(fam, sty))
  for d in docs:
    for L in d.layers:
      if not L.isText: continue
      for sp in L.text.spans:
        result.add(sp.style.family, sp.style.style)
        if sp.style.arabicFont.family.len > 0: result.add(sp.style.arabicFont.family, sp.style.arabicFont.style)
        if sp.style.latinFont.family.len > 0: result.add(sp.style.latinFont.family, sp.style.latinFont.style)
      for f in @[L.text.para] & L.text.paraFmts:
        for n in f.nested: result.add(n.look.family, n.look.style)
        for g in f.grepStyles: result.add(g.look.family, g.look.style)
        for n in f.lineStyles: result.add(n.look.family, n.look.style)

proc startPackage() =
  let what = docsToPackage()
  if what.docs.len == 0:
    status = tr("Package: open a document or a book first")
    return
  pkgDlg = (true, true, true, true, true, true, false, "", "")

proc writePackage(dir: string): string =
  ## The document or the book, its linked pictures, its fonts, its IDML and PDF and a report, in a
  ## folder of its own in `dir`; that folder (an error's message: "" and `status`).
  let what = docsToPackage()
  if what.docs.len == 0: return ""
  let name = (if what.name.len > 0: what.name else: "Untitled").multiReplace(("/", "-"), (":", "-"))
  let root = dir / name & " Folder"
  var report = AppName & " " & AppVersion & " -- Package\n" & "Date: " & now().format("d MMMM yyyy HH:mm") &
               "\n" & "Document: " & name & (if what.book != nil: " (a book of " & $what.docs.len & " pages)" else: "") &
               "\n\n"
  try:
    createDir(root)
    # the pictures placed linked: copied, the package's copy of the document linked to them there
    var linksTo: seq[tuple[L: Layer; was: SmartData]]
    if pkgDlg.links:
      createDir(root / "Links")
      report.add "LINKS\n"
      var names: seq[string]
      for d in what.docs:
        for L in d.layers:
          if not L.isSmart or L.smart.link.len == 0: continue
          let st = linkState(L)
          report.add "  " & L.smart.link & "  -- " & $st & "\n"
          if st == lsMissing: continue
          var nm = L.smart.link.extractFilename
          var k = 1
          while nm in names and L.smart.link notin names:
            inc k
            nm = L.smart.link.splitFile.name & " " & $k & L.smart.link.splitFile.ext
          if nm notin names:
            copyFile(L.smart.link, root / "Links" / nm)
            names.add nm
          if pkgDlg.relink:
            var s = L.smart.withQuad(L.smart.quad)
            s.link = root / "Links" / nm
            s.linkStamp = fileStamp(s.link)
            linksTo.add (L, L.smart)
            L.smart = s
      if names.len == 0: report.add "  (none: the pictures are embedded)\n"
      report.add "\n"
    # its fonts
    let fonts = fontsOf(what.docs)
    report.add "FONTS\n"
    if pkgDlg.fonts: createDir(root / "Document fonts")
    for (fam, sty, file) in fonts:
      var how = if file.len == 0: "built in" else: file.extractFilename
      if pkgDlg.fonts and file.len > 0 and fileExists(file):
        try:
          copyFile(file, root / "Document fonts" / file.extractFilename)
        except CatchableError: how.add " (could not be copied)"
      report.add "  " & fam & " " & sty & " -- " & how & "\n"
    report.add "\n"
    # the document itself, its IDML, its PDF
    try:
      if what.book != nil:
        let b = what.book
        let (wasPath, wasMod) = (b.path, b.modified)
        b.saveBook(root / name & ".rpb", curBook().keepOf)
        b.path = wasPath
        b.modified = wasMod
        if pkgDlg.idml: b.saveBookIdml(root / name & ".idml", curBook().keepOf)
        if pkgDlg.pdf: b.saveBookPdf(root / name & ".pdf", pdfPreset(ppPrint), curBook().keepOf)
      else:
        let d = what.docs[0]
        let wasMod = d.modified
        d.saveRpd(root / name & ".rpd")
        d.modified = wasMod
        if pkgDlg.idml: saveDocIdml(d, root / name & ".idml")
        if pkgDlg.pdf: d.savePdf(root / name & ".pdf", pdfPreset(ppPrint))
    finally:
      for (L, was) in linksTo: L.smart = was
    report.add "FILES\n  " & name & (if what.book != nil: ".rpb" else: ".rpd") &
               (if pkgDlg.idml: ", " & name & ".idml" else: "") & (if pkgDlg.pdf: ", " & name & ".pdf" else: "") & "\n"
    writeFile(root / "Instructions.txt", report)
    pkgDlg.report = report
    status = tr("Packaged into") & " \"" & root.extractFilename & "\""
    root
  except CatchableError:
    status = tr("Package: could not write") & ": " & getCurrentExceptionMsg()
    ""

proc packageDialog() =
  if filePicker(linkPick, linkPath, fmOpen, openPatterns, "Relink"):
    let d = cur()
    if d != nil and linkLayer != nil and linkLayer in d.layers and linkLayer.isSmart:
      discard d.relinked(linkLayer, linkPath)
  if filePicker(placeLinkedPick, openPath, fmOpen, openPatterns, "Place Linked"):
    let d = cur()
    if d != nil:
      placeLinking = true
      d.placeSmart(openPath)
      placeLinking = false
  if pkgOk.len > 0:
    let dir = pkgOk
    pkgOk = ""
    pkgDlg.path = writePackage(dir)
    pkgDlg.open = false
  if filePicker(pkgDlg.pick, pkgDlg.path, fmFolder, [], "Package"):
    pkgDlg.open = false
    discard writePackage(pkgDlg.path)
  if not pkgDlg.open: return
  let what = docsToPackage()
  if what.docs.len == 0:
    pkgDlg.open = false
    return
  var missing, modified, linked = 0
  for d in what.docs:
    for L in d.layers:
      if L.isSmart and L.smart.link.len > 0:
        inc linked
        case linkState(L)
        of lsMissing: inc missing
        of lsModified: inc modified
        else: discard
  let fonts = fontsOf(what.docs)
  var notFound = 0
  for f in fonts:
    if f.file.len > 0 and not fileExists(f.file): inc notFound
  dialog(pkgDlg.open, "Package", 420):
    label(what.name & (if what.book != nil: " -- " & $what.docs.len & tr(" pages") else: ""))
    row([150, -1]):
      label "Fonts:"
      label($fonts.len & tr(" used") & (if notFound > 0: tr(", ") & $notFound & tr(" missing") else: ""))
    row([150, -1]):
      label "Links and Images:"
      label($linked & tr(" linked") & (if missing > 0: tr(", ") & $missing & tr(" missing") else: "") &
            (if modified > 0: tr(", ") & $modified & tr(" modified") else: ""))
    if missing > 0 or modified > 0:
      label("Window > Links updates or relinks them first.", color = color(200, 0, 0))
    checkbox("Copy Fonts", pkgDlg.fonts)
    checkbox("Copy Linked Graphics", pkgDlg.links)
    checkbox("Update Graphic Links In Package", pkgDlg.relink)
    checkbox("Include IDML", pkgDlg.idml)
    checkbox("Include PDF (High Quality Print)", pkgDlg.pdf)
    row:
      spring()
      if button("Package...", isDefault = true, w = dp(100)):
        proc go() =
          if pkgDlg.path.len == 0: pkgDlg.path = picturesDir().parentDir
          pkgDlg.pick = true
        if storageFor(go): go()
      if button("Cancel", w = dp(80)): pkgDlg.open = false

proc packageCommand(name: string): bool =
  result = true
  case name
  of "Package...": startPackage()
  of "Links": togglePanel("links")
  of "Place Linked...":
    if cur() != nil:
      proc go() =
        if openPath.len == 0: openPath = picturesDir()
        placeLinkedPick = true
      if storageFor(go): go()
  else: result = false

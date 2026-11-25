# Retro Atelier -- included by photo.nim
#
# Save As > layered PDF and File > Automate > PDF Presentation: the
# "Save PDF" dialog -- a preset (the web, quality print, a press),
# the pictures' resolution (up to 3500 ppi), compression, colors (RGB or
# CMYK), crop marks and bleed, type and shapes as vectors.

var
  pdfDlg: tuple[open: bool; docs: seq[Doc]; path: string; preset: int; o: PdfOptions]
  presDlg: tuple[open: bool; picks: seq[bool]; order: seq[int]; sel: int]
  presPick = false
  presPath = ""

proc startPdfOptions(docs: seq[Doc]; path: string; drawing = false) =
  ## The Save PDF dialog for `docs` (one: Save As; more: a presentation).
  ## `drawing`: for a drawing program (.ai) -- type and shapes as vectors,
  ## the type as text.
  pdfDlg.open = true
  pdfDlg.docs = docs
  pdfDlg.path = path
  bookPdfFor(nil)              # (for a book, its caller says so after this)
  artboardPdfFor(docs)         # (one with artboards: them, each a page, in spreads, or the whole canvas)
  if pdfDlg.o.quality == 0:
    pdfDlg.preset = 1
    pdfDlg.o = pdfPreset(ppPrint)
  pdfDlg.o.title = if docs.len == 1: docs[0].name else: "Presentation"
  if drawing:
    pdfDlg.o.vectors = true
    pdfDlg.o.liveText = true
  pdfDlg.o.author = if docs.len > 0: docs[0].info.author else: ""

proc writePdfNow() =
  let path = pdfDlg.path
  var o = pdfDlg.o
  if o.ppi <= 0: o.ppi = 0
  var book = false
  try:
    beginBusy("Saving " & path.extractFilename, cancel = true)
    try:
      if bookPdfWrite(path, o): book = true      # (a book: all its pages, each read as it is written)
      elif artboardPdfWrite(path, o): book = true # (artboards: each a page, or in spreads)
      elif pdfDlg.docs.len == 1: pdfDlg.docs[0].savePdf(path, o)
      else: savePdfPresentation(pdfDlg.docs, path, o, o.title)
    finally: endBusy(cancel = true)
    rememberFile(path)
    if not book:
      status = "Saved " & path.extractFilename & " (" & $pdfDlg.docs.len &
               (if pdfDlg.docs.len == 1: " page)" else: " pages)")
  except BusyCancelled:
    status = "Cancelled"
  except CatchableError:
    status = "Could not save " & path.extractFilename & ": " & getCurrentExceptionMsg()

proc pdfDialogs() =
  if pdfDlg.open:
    var ok = false
    dialog(pdfDlg.open, "Save PDF", 470):
      var o = pdfDlg.o
      row:
        label "PDF Preset:"
        if combo([$ppWeb, $ppPrint, $ppPress, $ppCustom], pdfDlg.preset, w = dp(230)):
          let keep = (o.title, o.author)
          o = pdfPreset(PdfPresetKind(pdfDlg.preset))
          (o.title, o.author) = keep
      bookPdfPagesGroup()
      artboardPdfGroup()
      group("Compression and Resolution"):
        row:
          label "Pictures at:"
          var ppi = if o.ppi > 0: o.ppi else: 300
          if spin(ppi, 72, 3500, w = dp(80)):
            o.ppi = ppi
            pdfDlg.preset = ord(ppCustom)
          label "pixels/inch"
        var comp = if o.jpeg: 1 else: 0
        row:
          label "Compression:"
          if combo(["ZIP (lossless)", "JPEG"], comp, w = dp(130), enabled = not o.cmyk):
            o.jpeg = comp == 1
            pdfDlg.preset = ord(ppCustom)
        if o.jpeg and not o.cmyk:
          row([110, -1, 40]):
            label "Image Quality:"
            if slider(o.quality, 10, 100, ticks = 0): pdfDlg.preset = ord(ppCustom)
            label $o.quality
        # (what it makes: the pixels of the biggest page)
        var big = 0.0
        for d in pdfDlg.docs:
          let f = (if o.ppi > 0: o.ppi.float else: d.dpi) / max(1.0, d.dpi)
          big = max(big, d.w.float * d.h.float * f * f)
        let mp = big / 1e6
        label((if mp >= 1: $int(round(mp)) & " million pixels" else: $int(big) & " pixels") &
              " a page" & (if big > 160e6: " (made smaller: 160 million at most)" else: ""), color = ui.theme.gray)
      group("Color"):
        var c = if o.cmyk: 1 else: 0
        if radio("RGB (screens, home and photo printers)", c, 0) or
           radio("CMYK (a press: Color Settings' inks)", c, 1):
          o.cmyk = c == 1
          if o.cmyk: o.jpeg = false
          pdfDlg.preset = ord(ppCustom)
      group("Marks and Bleeds"):
        row:
          if checkbox("Crop Marks", o.marks): pdfDlg.preset = ord(ppCustom)
          if checkbox("Registration Marks", o.regMarks): pdfDlg.preset = ord(ppCustom)
        row:
          if checkbox("Color Bars", o.colorBars): pdfDlg.preset = ord(ppCustom)
          if checkbox("Page Information", o.pageInfo): pdfDlg.preset = ord(ppCustom)
        if o.marks:
          row:
            label "Bleed:"
            var b = int(round(o.bleedMm))
            if spin(b, 0, 20, w = dp(64)): o.bleedMm = b.float
            label "mm (the picture's edges drawn out past the cut)"
      group("Standard"):
        var stdI = ["", "PDF/X-4", "PDF/X-1a:2003"].find(o.standard)
        row:
          label "Standard:"
          if combo(["None", "PDF/X-4 (a press, live color)", "PDF/X-1a:2003 (a press, all CMYK)"], stdI,
                   w = dp(230), enabled = o.cmyk):
            o.standard = ["", "PDF/X-4", "PDF/X-1a:2003"][max(0, stdI)]
            pdfDlg.preset = ord(ppCustom)
        if o.cmyk and o.standard.len > 0:
          var ci = max(0, ["FOGRA39", "FOGRA51", "GRACoL2006", "SWOP2006", "JC200103"].find(o.condition))
          row:
            label "Printing condition:"
            if combo(["FOGRA39 (coated, Europe)", "FOGRA51 (PSO coated v3)", "GRACoL2006 (coated, US)",
                      "SWOP2006 (web offset, US)", "Japan Color 2001"], ci, w = dp(210)):
              o.condition = ["FOGRA39", "FOGRA51", "GRACoL2006", "SWOP2006", "JC200103"][ci]
              pdfDlg.preset = ord(ppCustom)
        elif not o.cmyk:
          label("For a press: Color: CMYK.", color = ui.theme.gray)
      group("Type and Shapes"):
        if checkbox("Type and shapes as vectors (sharp at any size)", o.vectors): pdfDlg.preset = ord(ppCustom)
        if o.vectors:
          if checkbox("Type as text, its fonts in the file (editable later in a PDF editor)", o.liveText):
            pdfDlg.preset = ord(ppCustom)
          if not o.liveText:
            label("Type as outlines: looks the same anywhere, but is not text any more.", color = ui.theme.gray)
      group("Accessibility and Interactivity"):
        if checkbox("Create Tagged PDF (reading order, alt text: for screen readers)", o.tagged):
          pdfDlg.preset = ord(ppCustom)
        if checkbox("Interactive (form fields, buttons, page transitions)", o.interactive):
          pdfDlg.preset = ord(ppCustom)
        var spots = not o.noSpots
        if checkbox("Spot Inks on Plates of Their Own (else in process inks)", spots):
          o.noSpots = not spots
          pdfDlg.preset = ord(ppCustom)
      pdfDlg.o = o
      row:
        let note = if bookPdfNote().len > 0: bookPdfNote() else: artboardPdfNote()
        label(if note.len > 0: note elif pdfDlg.docs.len == 1: "1 page" else: $pdfDlg.docs.len & " pages",
              color = ui.theme.gray)
        spring()
        if button("Save PDF", isDefault = true, w = dp(90)): ok = true
        if button("Cancel", w = dp(80)): pdfDlg.open = false
    if ok:
      pdfDlg.open = false
      writePdfNow()
  if presDlg.open:
    var go = false
    dialog(presDlg.open, "PDF Presentation", 420):
      label("Pages, in this order:", bold = true)
      var names: seq[string]
      for k in presDlg.order:
        names.add (if presDlg.picks[k]: "[x] " else: "[ ] ") & docs[k].doc.name & "  (" & $docs[k].doc.w & " x " &
                  $docs[k].doc.h & ")"
      listbox(names, presDlg.sel, rows = min(10, max(4, names.len)))
      row:
        let s = presDlg.sel
        if button("Include", w = dp(70), enabled = s in 0 .. presDlg.order.high):
          presDlg.picks[presDlg.order[s]] = not presDlg.picks[presDlg.order[s]]
        if button("Up", w = dp(50), enabled = s > 0 and s <= presDlg.order.high):
          swap(presDlg.order[s], presDlg.order[s - 1])
          dec presDlg.sel
        if button("Down", w = dp(56), enabled = s >= 0 and s < presDlg.order.high):
          swap(presDlg.order[s], presDlg.order[s + 1])
          inc presDlg.sel
      row:
        spring()
        if button("Save...", isDefault = true, w = dp(80)): go = true
        if button("Cancel", w = dp(80)): presDlg.open = false
    if go:
      presDlg.open = false
      presPick = true
      if presPath.len == 0: presPath = picturesDir() / "Presentation.pdf"
  if filePicker(presPick, presPath, fmSave, ["*.pdf"], "Save PDF Presentation"):
    var p = presPath
    if p.splitFile.ext.toLowerAscii != ".pdf": p.add ".pdf"
    var list: seq[Doc]
    for k in presDlg.order:
      if k < docs.len and presDlg.picks[k]: list.add docs[k].doc
    if list.len > 0: startPdfOptions(list, p)

proc startPdfPresentation() =
  ## File > Automate > PDF Presentation: the open documents, in order.
  if docs.len == 0: return
  presDlg.open = true
  presDlg.picks = newSeq[bool](docs.len)
  presDlg.order.setLen(0)
  for i in 0 ..< docs.len:
    presDlg.picks[i] = true
    presDlg.order.add i
  presDlg.sel = 0

# ---- opening a PDF or an Illustrator drawing: Import PDF ---------------------------------------------------

var
  impDlg: tuple[open: bool; path: string; data: string; pages: seq[tuple[w, h: float]]; page: int;
                ppi: int; shapes: bool; thumbs: seq[Bitmap]]
  epsDlg: tuple[open: bool; dw: DocWin; path: string; cmyk, vectors: bool]

proc startPdfImport(path: string) =
  ## The Import PDF dialog for a PDF or an .ai: which page, at what
  ## resolution, the outlines as shapes or pixels.
  let data = try: readFile(path) except IOError, OSError: ""
  let pages = pdfPages(data)
  if pages.len == 0:
    status = "Could not open " & path.extractFilename & ": not a PDF (an .ai saved without PDF compatibility?)"
    return
  impDlg = (true, path, data, pages, 0, (if impDlg.ppi > 0: impDlg.ppi else: 300),
            path.toLowerAscii.endsWith(".ai"), newSeq[Bitmap](pages.len))

proc startEpsOptions(dw: DocWin; path: string) =
  epsDlg = (true, dw, path, dw.doc.mode == cmCMYK, true)

proc importDialogs() =
  if impDlg.open:
    var ok = false
    dialog(impDlg.open, "Import PDF", 460):
      label(impDlg.path.extractFilename & " -- " & $impDlg.pages.len &
            (if impDlg.pages.len == 1: " page" else: " pages"), bold = true)
      row([170, -1]):
        col:
          # the page, small
          let r = place(dp(160), dp(200))
          fill(r, ui.theme.shadow)
          let k = impDlg.page
          if impDlg.thumbs[k] == nil:
            try:
              let f = openPdf(impDlg.data)
              let (w, h) = f.pageSize(k)
              impDlg.thumbs[k] = f.renderPage(k, 72 * min(dp(156).float * pxScale.float / w,
                                                          dp(196).float * pxScale.float / h))
            except CatchableError: impDlg.thumbs[k] = newBitmap(1, 1)
          drawFit(inset(r, dp(2)), impDlg.thumbs[k])
          box(r, ui.theme.frame)
          row:
            if toolButton("<", "The page before", enabled = k > 0): dec impDlg.page
            label("Page " & $(k + 1) & " of " & $impDlg.pages.len)
            if toolButton(">", "The page after", enabled = k < impDlg.pages.high): inc impDlg.page
        col:
          let (pw, ph) = impDlg.pages[impDlg.page]
          label("Size: " & formatFloat(pw / 72 * 25.4, ffDecimal, 0) & " x " &
                formatFloat(ph / 72 * 25.4, ffDecimal, 0) & " mm", color = ui.theme.gray)
          row:
            label "Resolution:"
            discard spin(impDlg.ppi, 36, 3500, w = dp(80))
            label "pixels/inch"
          let w = int(ceil(pw * impDlg.ppi.float / 72))
          let h = int(ceil(ph * impDlg.ppi.float / 72))
          label($w & " x " & $h & " pixels" & (if not sizeOk(w, h): " (too big)" else: ""), color = ui.theme.gray)
          checkbox("Outlines as shape layers (an Illustrator drawing: sharp, editable)", impDlg.shapes)
          paragraph("Else the page becomes pixels on one layer, as an imported PDF usually does.",
                    color = ui.theme.gray)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): ok = true
        if button("Cancel", w = dp(80)): impDlg.open = false
    if ok:
      impDlg.open = false
      try:
        beginBusy("Opening " & impDlg.path.extractFilename, cancel = true)
        try:
          let d = importPdf(impDlg.data, impDlg.path.splitFile.name & (if impDlg.pages.len > 1: " (page " &
                            $(impDlg.page + 1) & ")" else: ""),
                            ImportOptions(page: impDlg.page, ppi: impDlg.ppi.float, shapes: impDlg.shapes))
          d.path = ""                      # (Save asks where: a PDF is not written back as it was)
          addDoc(d)
          rememberFile(impDlg.path)
        finally: endBusy(cancel = true)
      except BusyCancelled: status = "Cancelled"
      except CatchableError: status = "Could not open " & impDlg.path.extractFilename & ": " & getCurrentExceptionMsg()
      impDlg.data = ""
      impDlg.thumbs.setLen(0)
  if epsDlg.open:
    var ok = false
    dialog(epsDlg.open, "EPS Options", 360):
      group("Color"):
        var c = if epsDlg.cmyk: 1 else: 0
        if radio("RGB", c, 0) or radio("CMYK (printing inks)", c, 1): epsDlg.cmyk = c == 1
      checkbox("Type and shapes as vectors", epsDlg.vectors)
      paragraph("Level 2 PostScript, its picture run-length coded; image editors and Retro Atelier read the " &
                "picture back.", color = ui.theme.gray)
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): ok = true
        if button("Cancel", w = dp(80)): epsDlg.open = false
    if ok:
      epsDlg.open = false
      let dw = epsDlg.dw
      if dw != nil and dw in docs:
        try:
          beginBusy("Saving " & epsDlg.path.extractFilename)
          try: dw.doc.savePs(epsDlg.path, eps = epsDlg.path.toLowerAscii.endsWith(".eps"), cmyk = epsDlg.cmyk,
                             vectors = epsDlg.vectors)
          finally: endBusy()
          rememberFile(epsDlg.path)
          status = "Saved " & epsDlg.path.extractFilename
        except CatchableError:
          status = "Could not save " & epsDlg.path.extractFilename & ": " & getCurrentExceptionMsg()

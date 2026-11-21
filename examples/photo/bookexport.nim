# (included by photo.nim) File > Export of a book, as the usual layout app
# has it: a PDF, or a JPEG or PNG of each page; all the pages or a range;
# as pages or as spreads (facing pages together, one sheet); the PDF's
# options in sections (General, Compression, Marks and Bleeds, Output,
# Summary) under a preset. The work is retroui/photobook's `exportBook`.

var
  exDlg: tuple[open: bool; bw: BookWin; e: BookExport; preset: int; section: int; all: bool]
  exPick = false
  exPath = ""

const exSections = ["General", "Compression", "Marks and Bleeds", "Output", "Summary"]

proc startBookExport(kind: ExportKind; asBefore = false) =
  ## File > Export (a book): its dialog, as it was last set (`asBefore`: in
  ## the format chosen last, else in `kind`).
  let bw = curBook()
  if bw == nil:
    status = "Export: open a book first (File > New Book)."
    return
  endModes()
  exDlg.bw = bw
  if not asBefore or exDlg.e.pdf.quality == 0: exDlg.e.kind = kind
  if exDlg.e.pdf.quality == 0:
    exDlg.preset = ord(ppPrint)
    exDlg.e.pdf = pdfPreset(ppPrint)
    exDlg.e.spreads = false
    exDlg.e.quality = 90
    exDlg.all = true
  exDlg.e.pdf.title = bw.book.name
  if exDlg.section >= exSections.len or (kind != exPdf and exDlg.section != 0): exDlg.section = 0
  exDlg.open = true

proc exSheets(): seq[seq[int]] =
  let b = exDlg.bw.book
  b.exportSheets(b.pageList(if exDlg.all: "" else: exDlg.e.pages), exDlg.e.spreads)

proc exSummary(): seq[string] =
  ## (what will be written, line by line)
  let e = exDlg.e
  let b = exDlg.bw.book
  let sheets = exSheets()
  var pages = 0
  for s in sheets: pages += s.len
  result.add $pages & (if pages == 1: tr(" page") else: tr(" pages")) & tr(", ") & $sheets.len &
             (if e.spreads: (if sheets.len == 1: tr(" sheet (spreads)") else: tr(" sheets (spreads)"))
              else: (if sheets.len == 1: tr(" sheet") else: tr(" sheets")))
  case e.kind
  of exPdf:
    let o = e.pdf
    result.add "PDF, " & (if o.cmyk: "CMYK" else: "RGB") & (if o.standard.len > 0: ", " & o.standard else: "")
    result.add "Pictures at " & $(if o.ppi > 0: o.ppi else: int(b.setup.dpi)) & " ppi, " &
               (if o.jpeg and not o.cmyk: "JPEG quality " & $o.quality else: "ZIP (lossless)")
    result.add "Type " & (if not o.vectors: "as pixels" elif o.liveText: "as text, its fonts in the file"
                          else: "as outlines")
    var marks: seq[string]
    if o.marks: marks.add "crop marks, bleed " & $int(round(o.bleedMm)) & " mm"
    if o.regMarks: marks.add "registration marks"
    if o.colorBars: marks.add "color bars"
    if o.pageInfo: marks.add "page information"
    result.add(if marks.len > 0: "Marks: " & marks.join(", ") else: "No printer's marks")
  of exJpeg, exPng:
    let ppi = if e.ppi > 0: e.ppi else: int(b.setup.dpi)
    let k = ppi.float / max(1.0, b.setup.dpi)
    let w = int(b.setup.w.float * k * (if e.spreads: 2.0 else: 1.0) + 0.5)
    result.add $e.kind & ", " & $ppi & " ppi" & (if e.kind == exJpeg: ", quality " & $e.quality else: "") &
               ", up to " & $w & " x " & $int(b.setup.h.float * k + 0.5) & " pixels a sheet"
    result.add(if sheets.len > 1: "A file a sheet: its name with the page numbers (name-2-3)" else: "One file")

proc exGeneral() =
  let b = exDlg.bw.book
  group("Pages"):
    var a = if exDlg.all: 0 else: 1
    if radio("All (" & $b.pages.len & ")", a, 0): exDlg.all = true
    row:
      if radio("Range:", a, 1): exDlg.all = false
      if edit(exDlg.e.pages, w = dp(160)): exDlg.all = false
    label("By their place in the book, from 1: 1-3, 5, 8- (to the end)", color = ui.theme.gray)
    var sp = if exDlg.e.spreads: 1 else: 0
    row:
      label "Export as:"
      if radio("Pages", sp, 0) or radio("Spreads", sp, 1): exDlg.e.spreads = sp == 1
    if exDlg.e.spreads and not b.setup.facing:
      label("The pages do not face (Document Setup): each is a sheet of its own.", color = ui.theme.gray)
  if exDlg.e.kind == exPdf:
    group("Document"):
      row([70, -1]):
        label "Title:"
        discard edit(exDlg.e.pdf.title)
      row([70, -1]):
        label "Author:"
        discard edit(exDlg.e.pdf.author)
  else:
    group("Image"):
      var ppis = [72, 96, 150, 200, 300, 600]
      var pi = max(0, ppis.find(if exDlg.e.ppi > 0: exDlg.e.ppi else: int(b.setup.dpi)))
      row:
        label "Resolution:"
        if combo(["72 ppi", "96 ppi", "150 ppi", "200 ppi", "300 ppi", "600 ppi"], pi, w = dp(100)):
          exDlg.e.ppi = ppis[pi]
        label("(the book's: " & $int(b.setup.dpi) & ")", color = ui.theme.gray)
      if exDlg.e.ppi > int(b.setup.dpi):
        label("Above the book's resolution the pages are enlarged, not drawn sharper.", color = ui.theme.gray)
      if exDlg.e.kind == exJpeg:
        row([90, -1, 40]):
          label "Quality:"
          discard slider(exDlg.e.quality, 10, 100, ticks = 0)
          label $exDlg.e.quality

proc exCompression() =
  var o = exDlg.e.pdf
  group("Pictures"):
    row:
      label "Resolution:"
      var ppi = if o.ppi > 0: o.ppi else: int(exDlg.bw.book.setup.dpi)
      if spin(ppi, 72, 3500, w = dp(80)):
        o.ppi = ppi
        exDlg.preset = ord(ppCustom)
      label "pixels/inch"
    var comp = if o.jpeg: 1 else: 0
    row:
      label "Compression:"
      if combo(["ZIP (lossless)", "JPEG"], comp, w = dp(130), enabled = not o.cmyk):
        o.jpeg = comp == 1
        exDlg.preset = ord(ppCustom)
    if o.jpeg and not o.cmyk:
      row([110, -1, 40]):
        label "Image Quality:"
        if slider(o.quality, 10, 100, ticks = 0): exDlg.preset = ord(ppCustom)
        label $o.quality
    if o.cmyk: label("CMYK pictures go in lossless.", color = ui.theme.gray)
  exDlg.e.pdf = o

proc exMarks() =
  var o = exDlg.e.pdf
  group("Marks"):
    row:
      if checkbox("Crop Marks", o.marks): exDlg.preset = ord(ppCustom)
      if checkbox("Registration Marks", o.regMarks): exDlg.preset = ord(ppCustom)
    row:
      if checkbox("Color Bars", o.colorBars): exDlg.preset = ord(ppCustom)
      if checkbox("Page Information", o.pageInfo): exDlg.preset = ord(ppCustom)
  group("Bleed"):
    row:
      label "Bleed:"
      var b = int(round(o.bleedMm))
      if spin(b, 0, 20, w = dp(64), enabled = o.marks):
        o.bleedMm = b.float
        exDlg.preset = ord(ppCustom)
      label "mm past the cut"
    if not o.marks: label("With crop marks: the pictures' edges drawn out past the cut.", color = ui.theme.gray)
  exDlg.e.pdf = o

proc exOutput() =
  var o = exDlg.e.pdf
  group("Color"):
    var c = if o.cmyk: 1 else: 0
    if radio("RGB (screens, home and photo printers)", c, 0) or radio("CMYK (a press: Color Settings' inks)", c, 1):
      o.cmyk = c == 1
      if o.cmyk: o.jpeg = false
      exDlg.preset = ord(ppCustom)
  group("Standard"):
    var stdI = max(0, ["", "PDF/X-4", "PDF/X-1a:2003"].find(o.standard))
    row:
      label "Standard:"
      if combo(["None", "PDF/X-4 (a press, live color)", "PDF/X-1a:2003 (a press, all CMYK)"], stdI,
               w = dp(230), enabled = o.cmyk):
        o.standard = ["", "PDF/X-4", "PDF/X-1a:2003"][stdI]
        exDlg.preset = ord(ppCustom)
    if o.cmyk and o.standard.len > 0:
      var ci = max(0, ["FOGRA39", "FOGRA51", "GRACoL2006", "SWOP2006", "JC200103"].find(o.condition))
      row:
        label "Printing condition:"
        if combo(["FOGRA39 (coated, Europe)", "FOGRA51 (PSO coated v3)", "GRACoL2006 (coated, US)",
                  "SWOP2006 (web offset, US)", "Japan Color 2001"], ci, w = dp(210)):
          o.condition = ["FOGRA39", "FOGRA51", "GRACoL2006", "SWOP2006", "JC200103"][ci]
          exDlg.preset = ord(ppCustom)
  group("Type and Shapes"):
    if checkbox("Type and shapes as vectors (sharp at any size)", o.vectors): exDlg.preset = ord(ppCustom)
    if o.vectors and checkbox("Type as text, its fonts in the file (editable later)", o.liveText):
      exDlg.preset = ord(ppCustom)
  exDlg.e.pdf = o

proc bookExportDialog() =
  if exDlg.open:
    if exDlg.bw == nil or exDlg.bw notin books:
      exDlg.open = false
      return
    var go = false
    dialog(exDlg.open, "Export", 620):
      var k = ord(exDlg.e.kind)
      row:
        label "Format:"
        if combo(["PDF (Print)", "JPEG", "PNG"], k, w = dp(140)):
          exDlg.e.kind = ExportKind(k)
          if exDlg.e.kind != exPdf: exDlg.section = 0
        if exDlg.e.kind == exPdf:
          label "Preset:"
          if combo(["Smallest File Size (web)", "High Quality Print", "Press Quality (PDF/X-4)", "Custom"],
                   exDlg.preset, w = dp(200)) and exDlg.preset != ord(ppCustom):
            let keep = (exDlg.e.pdf.title, exDlg.e.pdf.author)
            exDlg.e.pdf = pdfPreset(PdfPresetKind(exDlg.preset))
            (exDlg.e.pdf.title, exDlg.e.pdf.author) = keep
      row:
        if exDlg.e.kind == exPdf:
          col(130):
            for i, s in exSections:
              if button(s, w = dp(124), accent = exDlg.section == i): exDlg.section = i
        col(440):
          case (if exDlg.e.kind == exPdf: exDlg.section else: 0)
          of 1: exCompression()
          of 2: exMarks()
          of 3: exOutput()
          of 4:
            group("Summary"):
              for line in exSummary(): label line
          else: exGeneral()
      row:
        let lines = exSummary()
        label(lines[0], color = ui.theme.gray)
        spring()
        if button("Export...", isDefault = true, w = dp(90), enabled = exSheets().len > 0): go = true
        if button("Cancel", w = dp(80)): exDlg.open = false
    if go:
      exDlg.open = false
      let b = exDlg.bw.book
      let dir = if b.path.len > 0 and dirExists(b.path.parentDir): b.path.parentDir else: picturesDir()
      exPath = dir / b.name & [".pdf", ".jpg", ".png"][ord(exDlg.e.kind)]
      exPick = true
  if exPick:
    let ext = ["*.pdf", "*.jpg", "*.png"][ord(exDlg.e.kind)]
    if filePicker(exPick, exPath, fmSave, [ext], "Export"):
      let bw = exDlg.bw
      if bw != nil and bw in books:
        var p = exPath
        let want = [".pdf", ".jpg", ".png"][ord(exDlg.e.kind)]
        if p.splitFile.ext.toLowerAscii notin [want, (if want == ".jpg": ".jpeg" else: want)]: p.add want
        var e = exDlg.e
        if exDlg.all: e.pages = ""
        try:
          beginBusy("Exporting " & p.extractFilename, cancel = true)
          var files: seq[string]
          try: files = bw.book.exportBook(p, e, bw.keepOf)
          finally: endBusy(cancel = true)
          for f in files: rememberFile(f)
          status = "Exported " & (if files.len == 1: files[0].extractFilename
                                  else: $files.len & " files (" & files[0].extractFilename & "...)")
        except BusyCancelled:
          status = "Cancelled"
        except CatchableError:
          status = "Could not export: " & getCurrentExceptionMsg()

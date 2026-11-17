# (included by photo.nim) Layout > Data Merge (retroui/datamerge): a design whose text says
# «Name» -- and frames named @Photo -- and a table of rows (CSV); each row a page of a new
# book, the fields filled in, the frames' pictures placed to fill them. The box shows the
# fields the design asks for, the table's columns, and a row as it will be. Or a file a row
# instead (Photoshop's Export > Data Sets as Files): PNG or JPEG, each named by a column or
# numbered, in a folder picked.

var
  dmDlg: tuple[open, pick: bool; path: string; table: DataTable; row: int; preview: Bitmap; key: string;
               pickDir: bool; dir: string; fmt, nameCol: int]

proc startDataMerge() =
  let d = cur()
  if d == nil:
    status = "Data Merge: open the design first -- its text says «Name» where a column's value goes."
    return
  endModes()
  dmDlg.open = true
  dmDlg.row = 0
  dmDlg.key = ""

proc mergePicture(path: string): Bitmap =
  try: loadPicture(path, 4096, 4096) except CatchableError: nil

proc mergeNow() =
  ## Create Merged Document: a book of the design's size, a page a row.
  let d = cur()
  if d == nil or dmDlg.table.rows.len == 0: return
  let n = min(dmDlg.table.rows.len, MaxBookPages)
  let mmW = d.w.float / d.dpi * 25.4
  let mmH = d.h.float / d.dpi * 25.4
  var s = bookSetup(mmW, mmH, dpi = d.dpi, facing = false)
  s.top = 0
  s.bottom = 0
  s.inside = 0
  s.outside = 0
  let b = newBook(s, pages = n, name = d.name.splitFile.name & " (merged)")
  let folder = dmDlg.path.parentDir
  beginBusy("Data Merge", cancel = true)
  try:
    for i in 0 ..< n:
      let m = merged(d, dmDlg.table, i, mergePicture, folder)
      let pg = b.doc(i)
      if pg.w == m.w and pg.h == m.h:
        pg.layers = m.layers
        pg.cur = max(0, m.cur)
      else:
        # (a size a pixel apart, from the book's millimetres: scaled to it)
        m.imageSize(pg.w, pg.h)
        pg.layers = m.layers
      pg.markAll()
      b.park([])
      busyFraction = (i + 1) / n
      busyTickCheck()
  except BusyCancelled:
    b.close()
    status = "Data Merge stopped"
    return
  finally: endBusy()
  addBook(b)
  status = tr("Data Merge: ") & $n & tr(" pages, one a row of ") & dmDlg.path.extractFilename &
           (if dmDlg.table.rows.len > n: tr(" (a book has ") & $MaxBookPages & tr(" pages at most)") else: "")

proc mergeToFiles() =
  ## Export a File a Row: the design with each row's values in it, saved flat in the folder picked.
  let d = cur()
  if d == nil or dmDlg.table.rows.len == 0 or dmDlg.dir.len == 0: return
  let column = if dmDlg.nameCol > 0 and dmDlg.nameCol <= dmDlg.table.headers.len:
                 dmDlg.table.headers[dmDlg.nameCol - 1] else: ""
  beginBusy("Data Merge", cancel = true)
  var files: seq[string]
  try:
    files = d.exportRows(dmDlg.table, dmDlg.dir, (if dmDlg.fmt == 1: "jpg" else: "png"), mergePicture,
                         dmDlg.path.parentDir, column,
                         progress = proc (done, total: int) =
                           busyFraction = done / max(1, total)
                           busyTickCheck())
  except BusyCancelled:
    status = "Data Merge stopped"
    return
  except CatchableError as e:
    status = tr("Data Merge: ") & e.msg
    return
  finally: endBusy()
  status = tr("Data Merge: ") & $files.len & tr(" files, one a row, in ") & dmDlg.dir

proc mergeCommand(name: string): bool =
  result = true
  case name
  of "Data Merge...": startDataMerge()
  else: result = false

proc dataMergeDialog() =
  if filePicker(dmDlg.pick, dmDlg.path, fmOpen, ["*.csv", "*.txt", "*.tsv"], "Data Source"):
    dmDlg.table = readCsv(dmDlg.path)
    dmDlg.row = 0
    dmDlg.key = ""
    if dmDlg.table.error.len > 0: status = tr("Data Merge: ") & dmDlg.table.error
  if filePicker(dmDlg.pickDir, dmDlg.dir, fmFolder, [], "Data Merge: a File a Row Into"):
    mergeToFiles()
  if not dmDlg.open: return
  let d = cur()
  if d == nil:
    dmDlg.open = false
    return
  var create = false
  dialog(dmDlg.open, "Data Merge", 520):
    row([110, -1, 90]):
      label "Data source:"
      label(if dmDlg.path.len > 0: dmDlg.path.extractFilename else: "(a CSV file: a header row, a row a page)",
            color = (if dmDlg.path.len > 0: ui.theme.text else: ui.theme.gray))
      if button("Choose...", w = dp(86)): dmDlg.pick = true
    let fields = d.fieldsOf
    if fields.len == 0:
      paragraph(tr("The design asks for nothing yet: type «Name» (or <<Name>>) where a column's value goes, ") &
                tr("and name a frame @Photo for a picture whose file the row names."), color = ui.theme.gray)
    else:
      var missing: seq[string]
      for f in fields:
        var found = false
        for h in dmDlg.table.headers:
          if cmpIgnoreCase(h.strip.strip(chars = {'@'}), f.strip(chars = {'@'})) == 0: found = true
        if not found: missing.add f
      label(tr("The design asks for: ") & fields.join(", "))
      if dmDlg.table.headers.len > 0:
        label(tr("The table has: ") & dmDlg.table.headers.join(", ") & " -- " & $dmDlg.table.rows.len & tr(" rows"))
        if missing.len > 0:
          label(tr("Not in the table (left empty): ") & missing.join(", "), color = ui.theme.gray)
    if dmDlg.table.rows.len > 0:
      row([110, 80, -1]):
        label "Preview row:"
        var r = dmDlg.row + 1
        if spin(r, 1, dmDlg.table.rows.len, w = dp(70)): dmDlg.row = r - 1
        label(tr("of ") & $dmDlg.table.rows.len, color = ui.theme.gray)
      let key = dmDlg.path & "#" & $dmDlg.row & "#" & $d.ver
      if key != dmDlg.key:
        dmDlg.key = key
        let m = merged(d, dmDlg.table, dmDlg.row, mergePicture, dmDlg.path.parentDir)
        let k = min(1.0, min(480 / m.w, 260 / m.h))
        dmDlg.preview = thumbnailOf(m.flattened(white), m.w, m.h, max(1, int(m.w.float * k)),
                                    max(1, int(m.h.float * k)), checker = false)
      if dmDlg.preview != nil:
        let r = place(dp(dmDlg.preview.w), dp(dmDlg.preview.h))
        drawBitmap(r, dmDlg.preview)
      # (or a file a row: its format, what names it)
      row([110, 90, 70, -1]):
        label "A file a row:"
        discard combo(["PNG", "JPEG"], dmDlg.fmt, w = dp(86))
        label "Named by:"
        var names = @["Numbers"]
        for h in dmDlg.table.headers: names.add h
        dmDlg.nameCol = clamp(dmDlg.nameCol, 0, names.high)
        discard combo(names, dmDlg.nameCol, w = dp(150))
    row:
      spring()
      if button("Export a File a Row...", w = dp(170), enabled = dmDlg.table.rows.len > 0 and fields.len > 0):
        dmDlg.open = false
        dmDlg.pickDir = true
      if button("Create Merged Document", isDefault = true, w = dp(180),
                enabled = dmDlg.table.rows.len > 0 and fields.len > 0):
        create = true
      if button("Cancel", w = dp(80)): dmDlg.open = false
  if create:
    dmDlg.open = false
    mergeNow()

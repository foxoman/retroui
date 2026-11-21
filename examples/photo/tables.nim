# (included by photo.nim) Tables: Type > Insert Table (rows, columns, a
# theme: a text box whose paragraphs are rows and tabs cells), Type >
# Table Options (its theme from a gallery, its header and footer, fills,
# stripes, lines, padding, the columns' widths), Cell Options (inset, place
# up and down, turn, fill, sides, the row's height), rows and columns put in
# and taken out, cells merged and apart, Table and Cell Styles, Convert Text
# to Table and back. The table is the type engine's (`TextData.table`,
# `tableTheme`, `TableCell`, `mergeCells`...).

var
  tblIns: tuple[open: bool; rows, cols, header: int; theme: int] = (false, 5, 3, 1, 1)
  tblDlg = false
  tblPics: Table[string, Bitmap]
  tblWidths = ""
  cellDlg: tuple[open: bool; page: int; f: TableCell; row: TableRowFmt; sides: array[4, bool]; strokeW: float;
                 strokeC: uint32; applied: string]

proc tablePicture(theme: string): Bitmap =
  ## (a small table in a theme, for the gallery)
  if theme in tblPics: return tblPics[theme]
  let st = CharStyle(family: "", size: 9, color: 0xFF202020'u32, hScale: 1, vScale: 1)
  var t = newText("Item\tQty\tPrice\nPaper\t12\t4.50\nPens\t3\t1.20\nTotal\t\t5.70", st, 4, 4)
  t.boxW = 112
  t.boxH = 70
  t.table = tableTheme(theme)
  t.table.pad = 2
  var px = newSeq[uint32](120 * 76)
  for p in px.mitems: p = 0xFFFFFFFF'u32
  discard t.renderTextInto(px, 120, 76, layoutText(t))
  result = Bitmap(w: 120, h: 76, px: px)
  tblPics[theme] = result

proc tblCard(key, title: string; pic: Bitmap; on: bool): bool =
  ## (a theme's card: its picture, its name; true when clicked)
  let r = place(dp(124), dp(80) + lineHeight())
  let hit = interact(idOf("tblcard:" & key), r, focusable = false)
  let th = ui.theme
  if on: fill(r, th.select)
  elif hit.hover: fill(r, hoverColor())
  drawBitmap(rect(r.x + dp(2), r.y + dp(2), dp(120), dp(76)), pic)
  text(r.x + dp(4), r.y + dp(80), tr(title), (if on: th.selectText else: th.text))
  hit.clicked

proc startInsertTable() =
  if cur() == nil:
    status = "Insert Table: open or make a document first."
    return
  tblIns.open = true

proc insertTableNow() =
  ## (a new type layer: a table of the rows and columns asked, in the theme, in the page's
  ## margins on a book's page, else across most of the image)
  let d = cur()
  if d == nil: return
  var r = rect(d.w div 10, d.h div 10, d.w * 8 div 10, d.h * 8 div 10)
  let bw = curBook()
  if bw != nil: r = bw.book.marginBox(bw.page)
  var s = ""
  for row in 0 ..< tblIns.rows:
    for c in 0 ..< tblIns.cols:
      if c > 0: s.add '\t'
      if row < tblIns.header: s.add "Heading " & $(c + 1)
    if row < tblIns.rows - 1: s.add '\n'
  var t = newText(s, typingStyle(), r.x.float32, r.y.float32)
  t.boxW = r.w.float32
  t.boxH = r.h.float32
  t.table = tableTheme(tableThemes[clamp(tblIns.theme, 0, tableThemes.high)])
  t.table.headerRows = tblIns.header
  if te.on: commitType()
  d.beginStep("Insert Table")
  d.touchLayers()
  let L = d.addTextLayer(t)
  L.name = "Table"
  d.cur = d.layers.find(L)
  d.endStep()
  d.markAll()
  status = "A table: type in its cells (Tab goes to the next one); Type > Table Options sets its look"

proc tableTarget(): Layer =
  ## (the table worked on: the one typed in, else the current layer when it is one)
  let L = typeTarget()
  if L != nil and L.isText and L.text.table.on: L else: nil

proc pickedCells(L: Layer): tuple[r0, c0, r1, c1: int] =
  ## (the cells picked: those the selection reaches while typing in the table; else all of them)
  if te.on and te.layer == L:
    let a = L.text.cellOfChar(min(te.caret, te.anchor))
    let b = L.text.cellOfChar(max(te.caret, te.anchor))
    return (min(a.r, b.r), min(a.c, b.c), max(a.r, b.r), max(a.c, b.c))
  let rows = L.text.tableCells
  var nc = 1
  for r in rows: nc = max(nc, r.len)
  (0, 0, rows.high, nc - 1)

proc tableEdit(name: string; change: proc (t: var TextData)) =
  ## (the table changed: as typed, while typing in it; else one step)
  let L = tableTarget()
  if L == nil:
    status = tr(name) & tr(": pick a table, or type in one.")
    return
  if te.on and te.layer == L: editText(change)
  else: applyText(name, change)

proc startCellOptions() =
  let L = tableTarget()
  if L == nil:
    status = tr("Cell Options: pick a table, or type in one.")
    return
  let p = pickedCells(L)
  cellDlg.f = L.text.table.cellAt(p.r0, p.c0)
  cellDlg.row = L.text.table.rowFmtAt(p.r0)
  cellDlg.sides = [true, true, true, true]
  cellDlg.strokeW = 1
  cellDlg.strokeC = 0xFF000000'u32
  for k in 0 .. 3:
    if cellDlg.f.strokes[k].on:
      cellDlg.strokeW = cellDlg.f.strokes[k].width
      cellDlg.strokeC = cellDlg.f.strokes[k].color
  cellDlg.applied = $(cellDlg.f, cellDlg.row)
  cellDlg.open = true

proc tableCommand(name: string): bool =
  ## (the Type menu's table commands; true: done here)
  result = true
  case name
  of "Insert Row Above", "Insert Row Below", "Insert Column Before", "Insert Column After", "Delete Rows",
     "Delete Columns", "Merge Cells", "Unmerge Cells":
    let L = tableTarget()
    if L == nil:
      status = tr(name) & tr(": pick a table, or type in one.")
      return
    let p = pickedCells(L)
    let nm = name
    tableEdit(name, proc (t: var TextData) =
      case nm
      of "Insert Row Above": t.insertRow(p.r0)
      of "Insert Row Below": t.insertRow(p.r1 + 1)
      of "Insert Column Before": t.insertColumn(p.c0)
      of "Insert Column After": t.insertColumn(p.c1 + 1)
      of "Delete Rows":
        for r in countdown(p.r1, p.r0): t.deleteRow(r)
      of "Delete Columns":
        for c in countdown(p.c1, p.c0): t.deleteColumn(c)
      of "Merge Cells": t.mergeCells(p.r0, p.c0, p.r1, p.c1)
      else:
        for r in p.r0 .. p.r1:
          for c in p.c0 .. p.c1: t.unmergeCells(r, c))
  of "Cell Options...": startCellOptions()
  of "Table Styles": togglePanel("tablestyles")
  of "Cell Styles": togglePanel("cellstyles")
  of "Insert Table...": startInsertTable()
  of "Table Options...":
    let L = typeTarget()
    if L == nil or L.text.boxW <= 0:
      status = "Table Options: pick a text box (a table, or text with tabs to make one)."
    else:
      tblWidths = ""
      for k, w in L.text.table.widths: tblWidths.add (if k > 0: ", " else: "") & formatFloat(w, ffDecimal, 1)
      tblDlg = true
  of "Convert Text to Table":
    let L = typeTarget()
    if L == nil or L.text.boxW <= 0: status = "Convert Text to Table: pick a text box (tabs between the cells)."
    else: applyText("Convert Text to Table", proc (t: var TextData) = t.table = tableTheme("Plain Grid"))
  of "Convert Table to Text":
    let L = typeTarget()
    if L != nil: applyText("Convert Table to Text", proc (t: var TextData) = t.table = TableStyle())
  else: result = false

proc tableDialogs() =
  if tblIns.open:
    var ok = false
    dialog(tblIns.open, "Insert Table", 560):
      row:
        label "Rows:"
        spin(tblIns.rows, 1, 200, w = dp(60))
        label "Columns:"
        spin(tblIns.cols, 1, 30, w = dp(60))
        label "Header rows:"
        spin(tblIns.header, 0, 5, w = dp(50))
      label("Theme:", bold = true)
      adaptive(130):
        for i, th in tableThemes:
          if tblCard("i" & th, th, tablePicture(th), tblIns.theme == i): tblIns.theme = i
      row:
        spring()
        if button("OK", isDefault = true, w = dp(80)): ok = true
        if button("Cancel", w = dp(80)): tblIns.open = false
    if ok:
      tblIns.open = false
      insertTableNow()
  if tblDlg:
    let L = typeTarget()
    if L == nil or L.text.boxW <= 0:
      tblDlg = false
      return
    dialog(tblDlg, "Table Options", 600):
      var ts = L.text.table
      let was = ts
      if checkbox("The text is a table (each paragraph a row, tabs between the cells)", ts.on) and ts.on and
         ts.theme.len == 0 and ts.border == 0 and ts.fill == 0 and ts.headerFill == 0:
        ts = tableTheme("Plain Grid")
      if ts.on:
        label("Theme:", bold = true)
        adaptive(130):
          for th in tableThemes:
            if tblCard("o" & th, th, tablePicture(th), ts.theme == th):
              let keep = (ts.headerRows, ts.widths, ts.footerRows, ts.noRepeat, ts.cells, ts.rowFmts)
              ts = tableTheme(th)
              (ts.headerRows, ts.widths, ts.footerRows, ts.noRepeat, ts.cells, ts.rowFmts) = keep
        group("Header and rows"):
          row:
            label "Header rows:"
            spin(ts.headerRows, 0, 20, w = dp(56))
            label "Footer rows:"
            spin(ts.footerRows, 0, 20, w = dp(56))
            checkbox("Bold", ts.headerBold)
          row:
            var again = not ts.noRepeat
            if checkbox("Header and footer again in each box it goes on into", again): ts.noRepeat = not again
            checkbox("Numbers at the right", ts.numbersRight)
          template wellRow(lab: string; field: untyped; key: string) {.redefine.} =
            row([150, -1]):
              var on = ts.field != 0
              if checkbox(lab, on): ts.field = if on: (fg or 0xFF000000'u32) else: 0'u32
              if on:
                var c = ts.field
                if colorWell(c, key, dp(40)): ts.field = c or 0xFF000000'u32
          wellRow("Header fill", headerFill, "tblhf")
          wellRow("Header text", headerColor, "tblhc")
          wellRow("Text", bodyColor, "tblbc")
          wellRow("Rows' fill", fill, "tblf")
          wellRow("Stripes", altFill, "tbla")
        group("Lines"):
          var kind = if ts.border == 0: 0 elif ts.inner: 3 elif ts.rowLines: 2 else: 1
          row:
            label "Lines:"
            if combo(["None", "Round it and under the header", "Between the rows", "Round every cell"], kind,
                     w = dp(230)):
              if kind == 0: ts.border = 0
              else:
                if ts.border == 0: ts.border = 0xFF333333'u32
                ts.inner = kind == 3
                ts.rowLines = kind == 2
          if ts.border != 0:
            row:
              label "Weight:"
              var bw = if ts.borderW > 0: ts.borderW else: 1'f32
              if cur().lengthField(bw, dp(56), 0.5, 20): ts.borderW = bw
              label unitShort()
              var c = ts.border
              if colorWell(c, "tblline", dp(40)): ts.border = c or 0xFF000000'u32
        group("Cells"):
          row:
            label "Padding:"
            discard cur().lengthField(ts.pad, dp(56), 0, 400)
            label(tr(unitShort()) & tr(" (0: a third of the type's size)"))
          row([150, -1]):
            label "Column widths:"
            if edit(tblWidths):
              ts.widths = @[]
              for part in tblWidths.replace(" ", ",").split(','):
                try:
                  let v = parseFloat(part.strip)
                  if v > 0 and ts.widths.len < 200: ts.widths.add v.float32
                except ValueError: discard
          label("Parts of the box, one a column: 2, 1, 1 makes the first as wide as the others together.",
                color = ui.theme.gray)
      if ts != was:
        if ts.theme.len > 0 and ts != tableTheme(ts.theme): discard
        let v = ts
        applyText("Table Options", proc (t: var TextData) = t.table = v)
      row:
        spring()
        if button("Close", isDefault = true, w = dp(80)): tblDlg = false
  if cellDlg.open:
    let L = tableTarget()
    if L == nil:
      cellDlg.open = false
      return
    let p = pickedCells(L)
    let d = cur()
    dialog(cellDlg.open, "Cell Options", 520):
      label(tr("Cells: rows ") & $(p.r0 + 1) & "-" & $(p.r1 + 1) & tr(", columns ") & $(p.c0 + 1) & "-" & $(p.c1 + 1),
            color = ui.theme.gray)
      discard tabStrip([tr("Text"), tr("Strokes and Fills"), tr("Rows")], cellDlg.page)
      case cellDlg.page
      of 0:
        group("Cell Insets"):
          for (k, cap) in [(0, "Top:"), (2, "Bottom:"), (3, "Left:"), (1, "Right:")]:
            row([90, 80, -1]):
              label cap
              discard d.lengthField(cellDlg.f.inset[k], dp(70), 0, 4000)
              label unitShort()
          label("All 0: the table's padding.", color = ui.theme.gray)
        row([150, -1]):
          label "Vertical Justification:"
          var vj = ord(cellDlg.f.vAlign)
          var vn: seq[string]
          for v in VertJust: vn.add tr($v)
          if combo(vn, vj, w = dp(140)): cellDlg.f.vAlign = VertJust(clamp(vj, 0, ord(high(VertJust))))
        row([150, -1]):
          label "Text Rotation:"
          var rk = max(0, [0, 90, 180, 270].find(cellDlg.f.rotation))
          if combo(["0°", "90°", "180°", "270°"], rk, w = dp(90)): cellDlg.f.rotation = [0, 90, 180, 270][rk]
      of 1:
        row([150, -1]):
          var on = cellDlg.f.fill != 0
          if checkbox("Cell Fill", on): cellDlg.f.fill = if on: (fg or 0xFF000000'u32) else: 0'u32
          if on:
            var c = cellDlg.f.fill
            if colorWell(c, "cellfill", dp(40)): cellDlg.f.fill = c or 0xFF000000'u32
        group("Cell Stroke"):
          row:
            label "Sides:"
            for (k, cap) in [(0, "Top"), (1, "Right"), (2, "Bottom"), (3, "Left")]:
              discard checkbox(cap, cellDlg.sides[k])
          row:
            label "Weight:"
            var sw = float32(cellDlg.strokeW)
            if d.lengthField(sw, dp(64), 0, 100): cellDlg.strokeW = float(sw)
            label unitShort()
            var c = cellDlg.strokeC
            if colorWell(c, "cellstroke", dp(40)): cellDlg.strokeC = c or 0xFF000000'u32
          row:
            if button("Set the Sides", w = dp(110)):
              for k in 0 .. 3:
                if cellDlg.sides[k]:
                  cellDlg.f.strokes[k] = CellStroke(on: true, width: float32(cellDlg.strokeW), color: cellDlg.strokeC)
            if button("The Table's Lines", w = dp(130)):
              for k in 0 .. 3:
                if cellDlg.sides[k]: cellDlg.f.strokes[k] = CellStroke()
          label("Weight 0: no line on those sides.", color = ui.theme.gray)
      else:
        row([150, -1]):
          label "Row Height:"
          var k = ord(cellDlg.row.kind)
          var kn: seq[string]
          for v in RowHeight: kn.add tr($v)
          if combo(kn, k, w = dp(120)): cellDlg.row.kind = RowHeight(clamp(k, 0, ord(high(RowHeight))))
        if cellDlg.row.kind != rhAuto:
          row([150, 80, -1]):
            label ""
            discard d.lengthField(cellDlg.row.height, dp(70), 1, 20000)
            label unitShort()
        label("Exactly: what does not fit in the row is cut off.", color = ui.theme.gray)
      if $(cellDlg.f, cellDlg.row) != cellDlg.applied:
        # (applied at once to every cell picked: their merges kept)
        cellDlg.applied = $(cellDlg.f, cellDlg.row)
        let f = cellDlg.f
        let rf = cellDlg.row
        tableEdit("Cell Options", proc (t: var TextData) =
          for r in p.r0 .. p.r1:
            for c in p.c0 .. p.c1:
              var cref = t.table.cellRef(r, c)
              let (rs, cs, st) = (cref.rowSpan, cref.colSpan, cref.style)
              cref = f
              cref.rowSpan = rs
              cref.colSpan = cs
              cref.style = st
              t.table.cellRef(r, c) = cref
            while t.table.rowFmts.len <= r: t.table.rowFmts.add TableRowFmt()
            t.table.rowFmts[r] = rf)
      row:
        spring()
        if button("Close", isDefault = true, w = dp(80)): cellDlg.open = false

proc tableStylesBody(cells: bool) =
  ## The Table Styles and Cell Styles panels: the document's styles; a click gives one to the
  ## table (to the cells picked); New makes one of how it looks, Redefine makes it so again.
  let d = cur()
  if d == nil:
    label("No image open", color = ui.theme.gray)
    return
  let L = tableTarget()
  var names = @[tr(if cells: "[None]" else: "[Basic Table]")]
  if cells:
    for st in d.cellStyles: names.add st.name
  else:
    for st in d.tableStyles: names.add st.name
  var curName = ""
  if L != nil:
    let p = pickedCells(L)
    curName = if cells: L.text.table.cellAt(p.r0, p.c0).style else: L.text.table.styleName
  var sel = max(0, names.find(curName))
  let before = sel
  listbox(names, sel, rows = min(8, max(4, names.len)))
  if sel != before and L != nil:
    let nm = if sel <= 0: "" else: names[sel]
    let p = pickedCells(L)
    d.beginStep(if cells: "Apply Cell Style" else: "Apply Table Style")
    d.touchLayers()
    if cells: d.applyCellStyle(L, p.r0, p.c0, p.r1, p.c1, nm) else: d.applyTableStyle(L, nm)
    d.endStep()
  row:
    if button("New", w = dp(64), enabled = L != nil):
      let p = pickedCells(L)
      var n = (if cells: d.cellStyles.len else: d.tableStyles.len) + 1
      let base = if cells: tr("Cell Style ") else: tr("Table Style ")
      while (base & $n) in names: inc n
      let nm = base & $n
      d.beginStep(if cells: "New Cell Style" else: "New Table Style")
      d.touchLayers()
      if cells:
        d.setCellStyle(nm, L.text.table.cellAt(p.r0, p.c0))
        d.applyCellStyle(L, p.r0, p.c0, p.r1, p.c1, nm)
      else:
        d.setTableStyle(nm, L.text.table)
        d.applyTableStyle(L, nm)
      d.endStep()
    if button("Redefine", w = dp(80), enabled = L != nil and sel > 0):
      let p = pickedCells(L)
      d.beginStep(if cells: "Redefine Cell Style" else: "Redefine Table Style")
      d.touchLayers()
      if cells: d.setCellStyle(names[sel], L.text.table.cellAt(p.r0, p.c0))
      else: d.setTableStyle(names[sel], L.text.table)
      d.endStep()
    if button("Delete", w = dp(64), enabled = sel > 0):
      let nm = names[sel]
      d.beginStep(if cells: "Delete Cell Style" else: "Delete Table Style")
      d.touchLayers()
      if cells:
        for i in countdown(d.cellStyles.high, 0):
          if d.cellStyles[i].name == nm: d.cellStyles.delete(i)
      else:
        for i in countdown(d.tableStyles.high, 0):
          if d.tableStyles[i].name == nm: d.tableStyles.delete(i)
      d.endStep()
  paragraph(tr(if cells: "Type in a table, select across cells: a click gives them the style."
               else: "Pick a table or type in one: a click gives it the style; its cells keep their own looks."),
            color = ui.theme.gray)

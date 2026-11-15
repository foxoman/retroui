# (included by photo.nim) Tables: Type > Insert Table (rows, columns, a
# theme: a text box whose paragraphs are rows and tabs cells), Type >
# Table Options (its theme from a gallery, its header, fills, stripes,
# lines, padding, the columns' widths), Convert Text to Table and back.
# The table is the type engine's (`TextData.table`, `tableTheme`).

var
  tblIns: tuple[open: bool; rows, cols, header: int; theme: int] = (false, 5, 3, 1, 1)
  tblDlg = false
  tblPics: Table[string, Bitmap]
  tblWidths = ""

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

proc tableCommand(name: string): bool =
  ## (the Type menu's table commands; true: done here)
  result = true
  case name
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
              let keep = (ts.headerRows, ts.widths)
              ts = tableTheme(th)
              (ts.headerRows, ts.widths) = keep
        group("Header and rows"):
          row:
            label "Header rows:"
            spin(ts.headerRows, 0, 20, w = dp(56))
            checkbox("Bold", ts.headerBold)
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
              label "Width:"
              var bw = int(round((if ts.borderW > 0: ts.borderW else: 1'f32) * 2))
              if spin(bw, 1, 40, w = dp(56)): ts.borderW = bw.float32 / 2
              label "half pixels"
              var c = ts.border
              if colorWell(c, "tblline", dp(40)): ts.border = c or 0xFF000000'u32
        group("Cells"):
          row:
            label "Padding:"
            var p = int(round(ts.pad))
            if spin(p, 0, 200, w = dp(56)): ts.pad = p.float32
            label "px (0: a third of the type's size)"
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

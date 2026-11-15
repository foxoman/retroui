# (included by photo.nim) File > New Drawing and File > New Book as File >
# New is for photos: tabs of what it is for, blank presets as cards,
# templates with their pictures, the details at the right
# (retroui/layouttemplates).

var
  nlDraw: tuple[open: bool; tab: int; key: string; tmpl: int; w, h: int; name: string; clear: bool] =
    (false, 0, "", -1, 1000, 1000, "", true)
  nlBook: tuple[open: bool; tab: int; key: string; tmpl: int; name: string] = (false, 0, "", -1, "")
  nlThumbs: Table[string, Bitmap]

proc nlThumb(key: string; make: proc (): Bitmap): Bitmap =
  ## (a template's picture, made once; one a frame, so the dialog opens at once)
  if key in nlThumbs: return nlThumbs[key]
  if ndThumbFrame != ui.frameNo:
    ndThumbFrame = ui.frameNo
    result = (try: make() except CatchableError: nil)
    nlThumbs[key] = result

proc nlLayout(): tuple[W, detailsW, cardsH, cw: int] =
  let avail = int(ui.w.float / ui.k)
  let availH = int(ui.h.float / ui.k)
  let W = clamp(avail - 24, 520, 980)
  (W, (if W < 700: 220 else: 268), clamp(availH - 200, 240, 600), (if W < 700: 116 else: 134))

# ---- New Drawing ------------------------------------------------------------------------------------------

proc startNewDrawing() =
  ## File > New Drawing: a drawing of vectors, saved as SVG.
  nlDraw.open = true
  nlDraw.name = "Drawing-" & $(untitled + 1)
  if nlDraw.key.len == 0:
    let p = drawingPresets(DrawingCategory(nlDraw.tab))[0]
    nlDraw.key = "p:" & $nlDraw.tab & ":0"
    nlDraw.w = p.w
    nlDraw.h = p.h

proc nlDrawCreate() =
  let tmpls = drawingTemplates()
  inc untitled
  let name = if nlDraw.name.strip.len > 0: nlDraw.name.strip else: "Drawing-" & $untitled
  let w = clamp(nlDraw.w, 1, 30000)
  let h = clamp(nlDraw.h, 1, 30000)
  if not sizeOk(w, h):
    status = "Too big a drawing"
    return
  let d = newUntitled(w, h, (if nlDraw.clear: 0'u32 else: white), 72, cmRGB, name)
  d.format = "svg"
  if nlDraw.tmpl in 0 .. tmpls.high:
    discard d.placeSvg(tmpls[nlDraw.tmpl].svg, rect(0, 0, w, h), asGroup = false)
    if d.layers.len > 1 and d.layers[0].background and nlDraw.clear: d.layers[0].visible = false
    d.cur = d.layers.high
  d.clearHistory()
  d.modified = false
  addDoc(d)
  nlDraw.open = false
  status = if nlDraw.tmpl >= 0: "A template: each shape and text is a layer to change; File > Save writes an SVG"
           else: "A drawing: its shapes, pen paths and type stay vectors; File > Save writes an SVG"

proc newDrawingDialog() =
  if not nlDraw.open: return
  let (W, detailsW, cardsH, cw) = nlLayout()
  var create = false
  dialog(nlDraw.open, "New Drawing", W):
    row([-1, detailsW]):
      col:
        var tab = nlDraw.tab
        var labels: seq[string]
        for c in DrawingCategory: labels.add tr($c).replace("&", "&&")
        beginTabs(tab, labels)
        nlDraw.tab = tab
        beginScroll(dp(cardsH), "nldrawcards")
        let cat = DrawingCategory(nlDraw.tab)
        label(tr("BLANK DRAWINGS"), bold = true, color = ui.theme.gray)
        row:
          for i, p in drawingPresets(cat):
            let key = "p:" & $nlDraw.tab & ":" & $i
            let (picked, op) = ndCard(key, tr(p.name), p.sizeLabel, p.w, p.h, nil, cw, 112)
            if picked:
              nlDraw.key = key
              nlDraw.tmpl = -1
              nlDraw.w = p.w
              nlDraw.h = p.h
            if op: create = true
        let all = drawingTemplates()
        var any = false
        for t in all:
          if t.category == cat: any = true
        if any:
          space(dp(6))
          label(tr("TEMPLATES"), bold = true, color = ui.theme.gray)
          row:
            for i, t in all:
              if t.category != cat: continue
              let key = "dt:" & $i
              let tt = t
              let side = dp(cw) - dp(16)
              let thumb = nlThumb(key, proc (): Bitmap =
                let k = side / max(tt.w, tt.h)
                rasterizeSvg(tt.svg, max(1, int(tt.w.float * k)), max(1, int(tt.h.float * k))))
              let (picked, op) = ndCard(key, tr(t.name), $t.w & " x " & $t.h & " px", t.w, t.h, thumb, cw, 150)
              if picked:
                nlDraw.key = key
                nlDraw.tmpl = i
                nlDraw.w = t.w
                nlDraw.h = t.h
              if op: create = true
        endScroll()
        endTabs()
      col:
        label(tr("DETAILS"), bold = true, color = ui.theme.gray)
        if nlDraw.tmpl >= 0: label(tr("Template:") & " " & tr(drawingTemplates()[nlDraw.tmpl].name), bold = true)
        edit(nlDraw.name)
        label tr("Width (pixels)")
        if spin(nlDraw.w, 1, 30000, w = dp(100)): nlDraw.tmpl = -1
        label tr("Height (pixels)")
        if spin(nlDraw.h, 1, 30000, w = dp(100)): nlDraw.tmpl = -1
        row:
          label tr("Orientation")
          if toolButton("▯", tr("Portrait"), down = nlDraw.h >= nlDraw.w) and nlDraw.w > nlDraw.h:
            swap(nlDraw.w, nlDraw.h)
          if toolButton("▭", tr("Landscape"), down = nlDraw.w > nlDraw.h) and nlDraw.h > nlDraw.w:
            swap(nlDraw.w, nlDraw.h)
        checkbox(tr("Transparent background"), nlDraw.clear)
        paragraph(tr("A drawing keeps its shapes, paths and type as vectors: File > Save writes an SVG, " &
                     "File > Export > PDF keeps them sharp at any size."), color = ui.theme.gray)
        space(dp(8))
        row:
          spring()
          if button(tr("Create"), isDefault = true, w = dp(86)): create = true
          if button(tr("Close"), w = dp(76)): nlDraw.open = false
  if create and nlDraw.open: nlDrawCreate()

# ---- New Book ---------------------------------------------------------------------------------------------

proc nlBookPick(p: BookPreset) =
  ## (a preset's setup in the fields at the right)
  let s = p.setup
  let k = 25.4 / s.dpi
  proc mm(px: int): int = int(px.float * k + 0.5)
  bookDlg.w = int(p.wMm + 0.5)
  bookDlg.h = int(p.hMm + 0.5)
  bookDlg.paper = BookPapers.len
  bookDlg.dpi = max(0, bookDpis.find(int(s.dpi)))
  bookDlg.pages = p.pages
  bookDlg.facing = s.facing
  bookDlg.binding = ord(s.binding)
  bookDlg.top = mm(s.top)
  bookDlg.bottom = mm(s.bottom)
  bookDlg.inside = mm(s.inside)
  bookDlg.outside = mm(s.outside)
  bookDlg.columns = max(1, s.columns)
  bookDlg.gutter = mm(s.gutter)
  bookDlg.numbers = ord(s.numbers)
  bookDlg.first = max(1, s.firstNumber)
  bookDlg.grid = int(s.baseline * 72 / s.dpi + 0.5)

proc startNewBook() =
  ## File > New Book: a book, a magazine, a brochure, cards -- pages.
  nlBook.open = true
  nlBook.name = "Untitled Book " & $(untitled + 1)
  if nlBook.key.len == 0:
    nlBook.key = "bp:0:0"
    nlBook.tmpl = -1
    nlBookPick(bookPresets(bcBooks)[0])

proc nlBookCreate() =
  let tmpls = bookTemplates()
  inc untitled
  let name = if nlBook.name.strip.len > 0: nlBook.name.strip else: "Untitled Book " & $untitled
  try:
    beginBusy("Making the book")
    try:
      if nlBook.tmpl in 0 .. tmpls.high:
        let b = tmpls[nlBook.tmpl].build()
        b.name = name
        addBook(b)
      else:
        addBook(newBook(setupOf(), bookDlg.pages, name))
    finally: endBusy()
    nlBook.open = false
    status = if nlBook.tmpl >= 0: "A template: every part of it is a layer to change; File > Place puts a picture in"
             else: "A book: Layout > Add Page, master pages, page numbers; File > Save writes it as one file"
  except CatchableError:
    status = "Could not make the book: " & getCurrentExceptionMsg()

proc newBookDialog() =
  if not nlBook.open: return
  let (W, detailsW, cardsH, cw) = nlLayout()
  var create = false
  dialog(nlBook.open, "New Book", W):
    row([-1, detailsW + 40]):
      col:
        var tab = nlBook.tab
        var labels: seq[string]
        for c in BookCategory: labels.add tr($c).replace("&", "&&")
        beginTabs(tab, labels)
        nlBook.tab = tab
        beginScroll(dp(cardsH), "nlbookcards")
        let cat = BookCategory(nlBook.tab)
        label(tr("BLANK PRESETS"), bold = true, color = ui.theme.gray)
        row:
          for i, p in bookPresets(cat):
            let key = "bp:" & $nlBook.tab & ":" & $i
            # (facing pages: a spread's shape)
            let pw = int(p.wMm * (if p.setup.facing: 2 else: 1))
            let sub = $int(p.wMm + 0.5) & " x " & $int(p.hMm + 0.5) & " mm, " & $p.pages & " " & tr("pages") &
                      (if p.setup.binding == bindRight: ", RTL" else: "")
            let (picked, op) = ndCard(key, tr(p.name), sub, pw, int(p.hMm), nil, cw, 112)
            if picked:
              nlBook.key = key
              nlBook.tmpl = -1
              nlBookPick(p)
            if op: create = true
        let all = bookTemplates()
        var any = false
        for t in all:
          if t.category == cat: any = true
        if any:
          space(dp(6))
          label(tr("TEMPLATES"), bold = true, color = ui.theme.gray)
          row:
            for i, t in all:
              if t.category != cat: continue
              let key = "bt:" & $i
              let tt = t
              let side = dp(cw) - dp(16)
              let thumb = nlThumb(key, proc (): Bitmap =
                let b = tt.build()
                defer: b.close()
                b.thumb(0, side))
              let (picked, op) = ndCard(key, tr(t.name), $int(t.wMm + 0.5) & " x " & $int(t.hMm + 0.5) & " mm",
                                        int(t.wMm), int(t.hMm), thumb, cw, 150)
              if picked:
                nlBook.key = key
                nlBook.tmpl = i
                bookDlg.w = int(t.wMm + 0.5)
                bookDlg.h = int(t.hMm + 0.5)
                bookDlg.facing = t.facing
              if op: create = true
        endScroll()
        endTabs()
      col:
        label(tr("DETAILS"), bold = true, color = ui.theme.gray)
        edit(nlBook.name)
        if nlBook.tmpl >= 0:
          label(tr("Template:") & " " & tr(bookTemplates()[nlBook.tmpl].name), bold = true)
          paragraph(tr("Made as it is: its pages, masters, text and pictures. Document Setup changes it after."),
                    color = ui.theme.gray)
        else:
          bookFields(false, withPaper = false)
          let s = setupOf()
          label(tr("A page:") & " " & $s.w & " x " & $s.h & " px", color = ui.theme.gray)
        space(dp(8))
        row:
          spring()
          if button(tr("Create"), isDefault = true, w = dp(86)): create = true
          if button(tr("Close"), w = dp(76)): nlBook.open = false
  if create and nlBook.open: nlBookCreate()

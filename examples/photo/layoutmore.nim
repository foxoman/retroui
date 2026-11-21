# (included by photo.nim) More of the layout program's help: File > Print Booklet -- a book's
# pages on printer's spreads (2-up saddle stitch, or perfect bound in signatures), the space
# between a spread's pages and the paper's creep made up for, into a PDF that prints both sides
# and folds into the book in order (retroui/photobook's `saveBookletPdf`); Type > Find Font -- the
# fonts the type is set in, each changed for another everywhere (`fontsUsed`, `replaceFontAll`),
# in a book on every page.

var
  blDlg: tuple[open: bool; bw: BookWin; bl: Booklet; sig: int]
  blPick = false
  blPath = ""
  fontFind: tuple[open: bool; fonts: seq[tuple[family, style: string; chars, layers: int]]; pick: int;
               toFamily, toStyle: int; key: string]

const blSignatures = [4, 8, 12, 16, 32]

proc startPrintBooklet() =
  let bw = curBook()
  if bw == nil:
    status = tr("Print Booklet: open a book first (File > New Book)")
    return
  endModes()
  blDlg.bw = bw
  blDlg.open = true

proc printBookletDialog() =
  if blDlg.open:
    if blDlg.bw == nil or blDlg.bw notin books:
      blDlg.open = false
      return
    let b = blDlg.bw.book
    var go = false
    dialog(blDlg.open, "Print Booklet", 460):
      var k = ord(blDlg.bl.kind)
      var names: seq[string]
      for x in BookletKind: names.add tr($x)
      row([170, -1]):
        label "Booklet Type:"
        if combo(names, k, w = dp(200)): blDlg.bl.kind = BookletKind(k)
      if blDlg.bl.kind == bkPerfect:
        row([170, -1]):
          label "Pages a signature:"
          var sn: seq[string]
          for s in blSignatures: sn.add $s
          if combo(sn, blDlg.sig, w = dp(80)): discard
          blDlg.bl.signature = blSignatures[clamp(blDlg.sig, 0, blSignatures.high)]
      row([170, 90, -1]):
        label "Space between pages:"
        discard numberEdit(blDlg.bl.space, decimals = 1, w = dp(80), lo = 0, hi = 720, thousands = false)
        label "pt"
      row([170, 90, -1]):
        label "Creep:"
        discard numberEdit(blDlg.bl.creep, decimals = 1, w = dp(80), lo = -720, hi = 720, thousands = false)
        label "pt"
      paragraph(tr("Creep makes up for the paper's thickness: below 0 the inner sheets' pages move toward " &
                   "the fold (the cover stays), above 0 the outer sheets' away from it."),
                color = ui.theme.gray)
      let spreads = bookletSpreads(b.pages.len, blDlg.bl)
      var blanks = 0
      for (l, r, _) in spreads:
        if l < 0: inc blanks
        if r < 0: inc blanks
      label($b.pages.len & tr(" pages: ") & $spreads.len & tr(" printer's spreads on ") & $(spreads.len div 2) &
            tr(" sheets") & (if blanks > 0: ", " & $blanks & tr(" blank pages added") else: ""),
            color = ui.theme.gray)
      # (the first spreads, as they print)
      var shown = ""
      for n, (l, r, _) in spreads:
        if n >= 6: break
        let ln = if l < 0: "-" else: b.label(l)
        let rn = if r < 0: "-" else: b.label(r)
        shown.add (if shown.len > 0: "   " else: "") & ln & "|" & rn
      label(shown & (if spreads.len > 6: "  ..." else: ""), literal = true)
      row:
        spring()
        if button("Save PDF...", isDefault = true, w = dp(100), enabled = spreads.len > 0): go = true
        if button("Cancel", w = dp(80)): blDlg.open = false
    if go:
      blDlg.open = false
      let dir = if b.path.len > 0 and dirExists(b.path.parentDir): b.path.parentDir else: picturesDir()
      blPath = dir / (b.name & " booklet.pdf")
      blPick = true
  if blPick:
    if filePicker(blPick, blPath, fmSave, ["*.pdf"], "Print Booklet"):
      let bw = blDlg.bw
      if bw != nil and bw in books:
        var p = blPath
        if p.splitFile.ext.toLowerAscii != ".pdf": p.add ".pdf"
        try:
          beginBusy("Print Booklet")
          try: bw.book.saveBookletPdf(p, blDlg.bl, pdfPreset(ppPrint), bw.keepOf)
          finally: endBusy()
          rememberFile(p)
          status = tr("Booklet saved: ") & p.extractFilename
        except CatchableError:
          status = tr("Could not save the booklet: ") & getCurrentExceptionMsg()

# ---- Find Font ----------------------------------------------------------------------------------------------

proc fontFindDocs(): seq[Doc] =
  ## (the documents Find Font looks through: a book's pages, else the picture in front)
  let bw = curBook()
  if bw != nil:
    for i in 0 ..< bw.book.pages.len:
      try: result.add bw.book.doc(i)
      except CatchableError: discard
  elif cur() != nil: result.add cur()

proc fontFindScan() =
  fontFind.fonts.setLen(0)
  for d in fontFindDocs():
    for (f, s, n, ls) in d.fontsUsed:
      var found = false
      for x in fontFind.fonts.mitems:
        if x.family == f and x.style == s:
          x.chars += n
          x.layers += ls
          found = true
      if not found: fontFind.fonts.add (f, s, n, ls)
  fontFind.fonts.sort(proc (a, b: tuple[family, style: string; chars, layers: int]): int = cmp(b.chars, a.chars))

proc startFindFont() =
  if cur() == nil:
    status = tr("Find Font: open a picture or a book first")
    return
  if te.on: commitType()
  fontFindScan()
  fontFind.pick = 0
  fontFind.open = true

proc fontShown(f: string): string = (if f.len == 0: "FreeSans" else: f)

proc findFontDialog() =
  if not fontFind.open: return
  var change = false
  let fams = fontFamilies()
  dialog(fontFind.open, "Find Font", 520):
    label(tr("Fonts in the document:"), bold = true)
    var items: seq[string]
    for x in fontFind.fonts:
      let missing = x.family.len > 0 and x.family notin fams
      items.add fontShown(x.family) & " " & x.style & "  (" & $x.chars & tr(" characters, ") & $x.layers &
                tr(" layers") & ")" & (if missing: tr("  -- missing") else: "")
    if items.len == 0: label(tr("No type in it."), color = ui.theme.gray)
    else: discard listbox(items, fontFind.pick, rows = 7)
    group("Replace With"):
      var fn = @["FreeSans"]
      for f in fams:
        if f != "FreeSans": fn.add f
      row([110, -1]):
        label "Font Family:"
        if combo(fn, fontFind.toFamily, w = dp(260)): fontFind.toStyle = 0
      var sn: seq[string]
      let fam = fn[clamp(fontFind.toFamily, 0, fn.high)]
      for s in fontStyles(if fam == "FreeSans": "" else: fam): sn.add s
      if sn.len == 0: sn = @["Regular"]
      row([110, -1]):
        label "Font Style:"
        discard combo(sn, fontFind.toStyle, w = dp(160))
      fontFind.key = fam & "\t" & sn[clamp(fontFind.toStyle, 0, sn.high)]
    row:
      spring()
      if button("Change All", isDefault = true, w = dp(100), enabled = fontFind.fonts.len > 0): change = true
      if button("Done", w = dp(80)): fontFind.open = false
  if change and fontFind.pick in 0 .. fontFind.fonts.high:
    let src = fontFind.fonts[fontFind.pick]
    let parts = fontFind.key.split('\t')
    let toF = if parts[0] == "FreeSans": "" else: parts[0]
    let toS = if parts.len > 1: parts[1] else: ""
    var n = 0
    let bw = curBook()
    if bw != nil:
      for i in 0 ..< bw.book.pages.len:
        let d = (try: bw.book.doc(i) except CatchableError: nil)
        if d == nil: continue
        d.beginStep("Find Font")
        d.touchLayers()
        let k = d.replaceFontAll(src.family, src.style, toF, toS)
        if k > 0:
          d.endStep()
          bw.book.touch(i)
          n += k
        else: d.cancelStep()
    elif cur() != nil:
      let d = cur()
      d.beginStep("Find Font")
      d.touchLayers()
      n = d.replaceFontAll(src.family, src.style, toF, toS)
      if n > 0: d.endStep() else: d.cancelStep()
    status = $n & tr(" type layers now in ") & fontShown(toF) & " " & toS
    fontFindScan()
    fontFind.pick = clamp(fontFind.pick, 0, max(0, fontFind.fonts.high))

# ---- Islamic patterns --------------------------------------------------------------------------------------
# Layout > Islamic Pattern: eight-pointed stars and crosses, six-pointed stars, octagons with stars,
# or a border of stars along the edges (`retroui/geopatterns`) -- a shape layer over the selection
# (else the whole picture), filled with the foreground color and stroked with the background's.

var gpDlg: tuple[open: bool; kind: int; cell: int; stroke: int]

proc startGeoPattern() =
  if cur() == nil:
    status = tr("Islamic Pattern: open a picture or a book first")
    return
  if gpDlg.cell <= 0: gpDlg = (true, 0, 0, 2)
  if gpDlg.cell <= 0: gpDlg.cell = max(16, min(cur().w, cur().h) div 8)
  gpDlg.open = true

proc geoPatternDialog() =
  if not gpDlg.open: return
  var go = false
  dialog(gpDlg.open, "Islamic Pattern", 420):
    var names: seq[string]
    for k in GeoPattern: names.add tr($k)
    names.add tr("A Border of Stars")
    row([130, -1]):
      label "Pattern:"
      discard combo(names, gpDlg.kind, w = dp(250))
    row([130, 90, -1]):
      label(if gpDlg.kind == names.high: "Border width:" else: "Cell size:")
      discard spin(gpDlg.cell, 8, 4000, w = dp(80))
      label "px"
    row([130, 90, -1]):
      label "Stroke:"
      discard spin(gpDlg.stroke, 0, 200, w = dp(80))
      label "px"
    paragraph(tr("Over the selection, else the whole picture: filled with the foreground color, " &
                 "stroked with the background's. Put it inside a frame to cut it to the frame's edge."),
              color = ui.theme.gray)
    row:
      spring()
      if button("OK", isDefault = true, w = dp(80)): go = true
      if button("Cancel", w = dp(80)): gpDlg.open = false
  if go:
    gpDlg.open = false
    let d = cur()
    if d == nil: return
    let r = if d.hasSelection: d.selBounds else: rect(0, 0, d.w, d.h)
    let border = gpDlg.kind > ord(high(GeoPattern))
    let p = if border: geoBorder(r.x.float, r.y.float, (r.x + r.w).float, (r.y + r.h).float, gpDlg.cell.float)
            else: geoPattern(GeoPattern(gpDlg.kind), r.x.float, r.y.float, (r.x + r.w).float, (r.y + r.h).float,
                             gpDlg.cell.float)
    var sd = ShapeData(path: p, fill: solidPaint(fg or 0xFF000000'u32), strokeWidth: gpDlg.stroke.float)
    if gpDlg.stroke > 0: sd.stroke = solidPaint(bg or 0xFF000000'u32)
    let nm = if border: tr("A Border of Stars") else: tr($GeoPattern(gpDlg.kind))
    d.stepOnce("Islamic Pattern", proc () = discard d.addShapeLayer(sd, nm))
    status = nm & ": " & $p.subs.len & tr(" shapes")

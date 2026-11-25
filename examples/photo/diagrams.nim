# (included by photo.nim) Layout > Insert Diagram... and File > New Carousel...: a diagram
# (retroui/diagrams) -- a family tree, a dendrogram, a timeline, a numbered list, a note, a title
# -- typed as a few lines in a dialog with a preview, placed as a group of shape and type layers and
# made again from the same dialog later (Edit Diagram...): its settings are kept with its group
# (`Layer.meta`). And a carousel: slides (artboards) with a header and a footer in English and
# Arabic, their page numbers, a diagram on each to type over.

import retroui/diagrams as dg

var
  dgDlg: tuple[open: bool; spec: DiagramSpec; datas: array[DiagramKind, string]; editing: Layer; box: Rect;
               key: string; preview: Bitmap]
  carDlg: tuple[open: bool; spec: CarouselSpec; size: int]

const carouselSizes = [("Portrait", 1080, 1350), ("Square", 1080, 1080), ("Story", 1080, 1920),
                       ("Wide", 1920, 1080)]

proc dgOf(d: Doc): Layer =
  ## (the diagram the current layer is, or is in: its group, with its settings)
  if d == nil or d.cur < 0: return
  var i = d.cur
  while i < d.layers.len:
    let L = d.layers[i]
    if L.isDiagram: return L
    var j = i + 1
    while j < d.layers.len and d.layers[j].depth >= L.depth: inc j
    if j >= d.layers.len or d.layers[j].depth >= L.depth or not d.layers[j].group: return
    i = j

proc dgDefaultBox(d: Doc): Rect =
  ## (where a new one goes: the current artboard's room between a slide's header and footer, a
  ## book's page's margins, else the middle of the image)
  if d.boards.len > 0: return slideContent(d.boards[clamp(d.boardCur, 0, d.boards.high)].r)
  igDefaultBox(d, 1.1)

proc startDiagram(edit = false) =
  let d = cur()
  if d == nil:
    status = "Open or make a document first."
    return
  dgDlg.editing = nil
  dgDlg.key = ""
  for k in DiagramKind: dgDlg.datas[k] = defaultDiagram(k).data
  if edit:
    let L = dgOf(d)
    let r = L.diagramOf
    if not r.ok:
      status = "Pick a diagram (or a layer in it) to change it."
      return
    dgDlg.spec = r.spec
    dgDlg.box = r.box
    dgDlg.editing = L
    dgDlg.datas[r.spec.kind] = r.spec.data
  else:
    dgDlg.spec = defaultDiagram(dkTree)
    dgDlg.box = dgDefaultBox(d)
  dgDlg.open = true

proc dgSpec(): DiagramSpec =
  result = dgDlg.spec
  result.data = dgDlg.datas[result.kind]

proc dgPreview(): Bitmap =
  ## (the diagram drawn small, as it will be: its box scaled down to 400 pixels wide)
  let s = dgSpec()
  let bw = max(1, dgDlg.box.w)
  let k = min(1.0, 400 / bw.float)
  var ss = s
  if ss.size > 0: ss.size *= k
  if ss.radius > 0: ss.radius *= k
  if ss.lineWidth > 0: ss.lineWidth *= k
  let w = max(1, int(bw.float * k))
  let h = max(0, int(dgDlg.box.h.float * k))
  let (parts, ph) = diagramParts(ss, rect(0, 0, w, h))
  let pd = newDoc(w, max(1, (if h > 0: h else: int(ceil(ph)) + 1)), s.theme.paper, 72, "Preview")
  discard pd.addParts(parts)
  pd.toBitmap(0xFFFFFFFF'u32)

proc dgMake() =
  ## (the diagram placed -- in place of the one edited -- as a group of shape and type layers, its
  ## settings with it; one step)
  let d = cur()
  if d == nil: return
  let s = dgSpec()
  d.beginStep(if dgDlg.editing != nil: "Edit Diagram" else: "Insert Diagram")
  d.touchLayers()
  var name = ""
  if dgDlg.editing != nil:
    let i = d.layers.find(dgDlg.editing)
    if i >= 0:
      name = dgDlg.editing.name
      d.cur = i
      d.deleteLayer(i)
  let g = d.placeDiagram(s, dgDlg.box, name)
  d.endStep()
  d.markAll()
  if g == nil: status = "The diagram has nothing to draw: type its lines."
  else: status = tr($s.kind) & ": " & tr("a group of shape and type layers (Layout > Edit Diagram... changes it)")

proc diagramCommand(name: string): bool =
  result = true
  case name
  of "Diagram...", "Insert Diagram...": startDiagram()
  of "Edit Diagram...": startDiagram(edit = true)
  of "New Carousel...":
    carDlg.spec = defaultCarousel()
    carDlg.size = 0
    carDlg.open = true
  else: result = false

proc kindHelp(k: DiagramKind): string =
  case k
  of dkTree: "An item a line, | between its two names; two spaces in: a level down. * highlighted, " &
             "~ dashed, > its children one under another."
  of dkDendrogram: "An item a line, | between its two names; two spaces in: a level down; * highlighted. " &
                   "The leaves are named under them."
  of dkTimeline: "A date a line: date | left text | right text (| left note | right note). " &
                 "\"328 CE / ٣٢٨ م\": a date for each side. * highlighted."
  of dkList: "An item a line: its text | its second line. * highlighted."
  of dkNote: "The first line its labels (Note | ملاحظة), then a paragraph a line."
  of dkTitle: "The title, then its second line; --- the rule; then the lines under it. " &
              "A line that starts with \". \": small (a source)."

proc dgColor(name: string; c: var uint32; key: string) =
  label name
  discard colorWell(c, key, dp(34))

proc diagramFields() =
  var s = dgDlg.spec
  row([90, -1]):
    label "Kind:"
    var k = ord(s.kind)
    var kinds: seq[string]
    for x in DiagramKind: kinds.add tr($x)
    if combo(kinds, k, w = dp(190)):
      s.kind = DiagramKind(k)
      s.links = if s.kind == dkDendrogram: lsCurve else: lsElbow
      if s.kind == dkDendrogram: s.labels = true
  paragraph(kindHelp(s.kind), color = ui.theme.gray)
  discard editArea(dgDlg.datas[s.kind], lines = 9)
  row([90, -1]):
    label "Theme:"
    var names: seq[string]
    for n in diagramThemes(): names.add tr(n)
    var t = max(0, diagramThemes().find(s.theme.name))
    if combo(names, t, w = dp(150)):
      let (af, lf) = (s.theme.arabicFont, s.theme.latinFont)
      s.theme = diagramTheme(diagramThemes()[t])
      s.theme.arabicFont = af
      s.theme.latinFont = lf
  row:
    dgColor("Accent:", s.theme.accent, "dgacc")
    dgColor("Text:", s.theme.ink, "dgink")
    dgColor("Second:", s.theme.muted, "dgmut")
    dgColor("Paper:", s.theme.paper, "dgpap")
  row:
    dgColor("Boxes:", s.theme.fill, "dgfil")
    dgColor("Outlines:", s.theme.edge, "dgedg")
    dgColor("Lines:", s.theme.line, "dglin")
  row([90, -1]):
    label "Arabic font:"
    var fa = if s.theme.arabicFont.len > 0: s.theme.arabicFont else: DastkhatFamily
    if fontCombo(fa, w = dp(190)): s.theme.arabicFont = fa
  row([90, -1]):
    label "Latin font:"
    var fl = if s.theme.latinFont.len > 0: s.theme.latinFont else: DastkhatFamily
    if fontCombo(fl, w = dp(190)): s.theme.latinFont = fl
  row:
    label "Text size:"
    let (sized, sz) = cur().typeField(float32(s.size), dp(60), "dgsize", 0, 2000)
    if sized: s.size = sz.float
    label(if s.size > 0: typeShort() else: "(0: by its width)", color = ui.theme.gray)
  row:
    checkbox("Arabic first (right to left)", s.rtl)
    checkbox("Arabic digits", s.arabicDigits)
  if s.kind in {dkTree, dkDendrogram}:
    row:
      label "Lines:"
      var l = ord(s.links)
      var styles: seq[string]
      for x in LinkStyle: styles.add tr($x)
      if combo(styles, l, w = dp(110)): s.links = LinkStyle(l)
      label "Corners:"
      var r = int(round(s.radius))
      if spin(r, -1, 200, w = dp(56)): s.radius = r.float
  if s.kind == dkDendrogram:
    row:
      checkbox("From the side", s.horizontal)
      checkbox("Names", s.labels)
  dgDlg.spec = s

proc carouselDialog() =
  if not carDlg.open: return
  var ok = false
  var c = carDlg.spec
  dialog(carDlg.open, "New Carousel", 560):
    row:
      label "Slides:"
      spin(c.slides, 1, 40, w = dp(60))
    row([120, -1]):
      label "Size:"
      var names: seq[string]
      for (n, w, h) in carouselSizes: names.add tr(n) & " " & $w & " x " & $h
      if combo(names, carDlg.size, w = dp(200)): discard
    row([120, -1]):
      label "Theme:"
      var themes: seq[string]
      for n in diagramThemes(): themes.add tr(n)
      var t = max(0, diagramThemes().find(c.theme.name))
      if combo(themes, t, w = dp(150)): c.theme = diagramTheme(diagramThemes()[t])
    label("Header", bold = true)
    row([120, -1]):
      label "English title:"
      edit(c.frame.enTitle)
    row([120, -1]):
      label "English subtitle:"
      edit(c.frame.enSubtitle)
    row([120, -1]):
      label "Arabic title:"
      edit(c.frame.arTitle)
    row([120, -1]):
      label "Arabic subtitle:"
      edit(c.frame.arSubtitle)
    label("Footer", bold = true)
    row([120, -1]):
      label "English source:"
      edit(c.frame.enSource)
    row([120, -1]):
      label "Arabic source:"
      edit(c.frame.arSource)
    row:
      checkbox("Page numbers (1 / 8)", c.frame.pageNumbers)
      checkbox("Arabic digits", c.frame.arabicDigits)
    row:
      checkbox("A title page first", c.titleSlide)
      checkbox("A diagram on the next ones", c.samples)
    paragraph("Each slide is an artboard. Layout > Edit Diagram... changes a diagram; Save As > PDF " &
              "and Export > Artboards to Files... give the slides.", color = ui.theme.gray)
    row:
      spring()
      if button("Create", isDefault = true, w = dp(90)): ok = true
      if button("Cancel", w = dp(80)): carDlg.open = false
  carDlg.spec = c
  if ok:
    carDlg.open = false
    let (_, w, h) = carouselSizes[clamp(carDlg.size, 0, carouselSizes.high)]
    var spec = carDlg.spec
    spec.w = w
    spec.h = h
    inc untitled
    addDoc(newCarousel(spec, tr("Carousel") & " " & $untitled))
    status = $spec.slides & tr(" slides: Window > Artboards lists them; Layout > Edit Diagram... changes a diagram")

proc diagramDialogs() =
  carouselDialog()
  if not dgDlg.open: return
  let d = cur()
  if d == nil:
    dgDlg.open = false
    return
  var ok = false
  dialog(dgDlg.open, "Diagram", 820):
    row:
      col(370):
        diagramFields()
      col(410):
        row:
          label "Size:"
          spin(dgDlg.box.w, 40, 20000, w = dp(70))
          label "x"
          spin(dgDlg.box.h, 0, 20000, w = dp(70))
          label "px"
        label("(height 0: as tall as it needs; it shrinks to fit)", color = ui.theme.gray)
        # (the preview: drawn again when the settings change)
        let key = $toJson(dgSpec()) & $dgDlg.box
        if key != dgDlg.key:
          dgDlg.key = key
          dgDlg.preview = try: dgPreview() except CatchableError: nil
        let pr = place(dp(400), dp(380))
        fill(pr, color(255, 255, 255))
        if dgDlg.preview != nil and dgDlg.preview.w > 0:
          let k = min(pr.w / dgDlg.preview.w, pr.h / dgDlg.preview.h)
          let w = max(1, int(dgDlg.preview.w.float * k))
          let h = max(1, int(dgDlg.preview.h.float * k))
          drawBitmap(rect(pr.x + (pr.w - w) div 2, pr.y + (pr.h - h) div 2, w, h), dgDlg.preview)
        box(pr, ui.theme.edge)
        paragraph("Its parts are shape and type layers in a group: each box, line and word still to change, " &
                  "sharp in a PDF.", color = ui.theme.gray)
    row:
      spring()
      if button((if dgDlg.editing != nil: "Change" else: "Insert"), isDefault = true, w = dp(90)): ok = true
      if button("Cancel", w = dp(80)): dgDlg.open = false
  if ok:
    dgDlg.open = false
    dgMake()

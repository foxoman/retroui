# (included by photo.nim) Insert > Chart and Insert > Map: a chart or a map
# made of shape and type layers (retroui/infographics), set in a dialog
# with a preview -- its numbers typed or pasted, its kind, theme and every
# part of its look -- and made again from the same dialog later (Edit
# Chart or Map...): the settings are kept with its group (`Layer.meta`).

import retroui/infographics as ig

var
  igDlg: tuple[open, isMap: bool; chart: ChartSpec; map: MapSpec; data, cities, countries: string;
               region: int; editing: Layer; box: Rect; key: string; preview: Bitmap]

proc igSpecJson(): string =
  if igDlg.isMap: $(%*{"map": ig.toJson(igDlg.map), "box": [igDlg.box.x, igDlg.box.y, igDlg.box.w, igDlg.box.h]})
  else: $(%*{"chart": ig.toJson(igDlg.chart), "box": [igDlg.box.x, igDlg.box.y, igDlg.box.w, igDlg.box.h]})

proc igDefaultBox(d: Doc; aspect: float): Rect =
  ## (where a new one goes: the page's margins on a book's page, else the middle of the image)
  var r = rect(d.w div 8, d.h div 8, d.w * 3 div 4, d.h * 3 div 4)
  let bw = curBook()
  if bw != nil: r = bw.book.marginBox(bw.page)
  let h = min(r.h, int(r.w.float / aspect))
  rect(r.x, r.y, r.w, max(1, h))

proc igOf(d: Doc): Layer =
  ## (the chart or map the current layer is, or is in: its group, with its settings)
  if d == nil or d.cur < 0: return
  var i = d.cur
  while i < d.layers.len:
    let L = d.layers[i]
    if L.meta.startsWith("{\"chart\"") or L.meta.startsWith("{\"map\""): return L
    # (up to the group this layer is in)
    var j = i + 1
    while j < d.layers.len and d.layers[j].depth >= L.depth: inc j
    if j >= d.layers.len or d.layers[j].depth >= L.depth or not d.layers[j].group: return
    i = j

proc startInfographic(isMap: bool; edit = false) =
  let d = cur()
  if d == nil:
    status = "Open or make a document first."
    return
  igDlg.open = true
  igDlg.isMap = isMap
  igDlg.editing = nil
  igDlg.key = ""
  if edit:
    let L = igOf(d)
    if L == nil:
      status = "Pick a chart or a map (or a layer in it) to change it."
      igDlg.open = false
      return
    try:
      let j = parseJson(L.meta)
      igDlg.isMap = j.hasKey("map")
      if igDlg.isMap: igDlg.map = ig.mapFrom(j["map"]) else: igDlg.chart = ig.chartFrom(j["chart"])
      let b = j{"box"}.getElems
      if b.len == 4: igDlg.box = rect(b[0].getInt, b[1].getInt, max(1, b[2].getInt), max(1, b[3].getInt))
      igDlg.editing = L
    except CatchableError:
      status = "Its settings could not be read."
      igDlg.open = false
      return
  elif isMap:
    igDlg.map = MapSpec(region: "Middle East", theme: "Sand", values: @[("OM", 5.0), ("SA", 9.0), ("AE", 7.0),
                        ("QA", 3.0), ("KW", 2.0), ("BH", 1.0)], labels: true, legend: true, title: "Map")
    igDlg.box = igDefaultBox(d, 9 / 5)
  else:
    igDlg.chart = ChartSpec(kind: ckColumn, title: "Chart", labels: @["Q1", "Q2", "Q3", "Q4"],
                            series: @[("2025", @[12.0, 15, 9, 20]), ("2026", @[14.0, 18, 12, 24])],
                            theme: "Office", legend: lpTop, grid: true, valueLabels: true, radius: 6)
    igDlg.box = igDefaultBox(d, 8 / 5)
  if igDlg.isMap:
    igDlg.data = ""
    for (c, v) in igDlg.map.values: igDlg.data.add c & ", " & $v & "\n"
    igDlg.cities = igDlg.map.cities.join(", ")
    igDlg.region = max(0, mapRegions().find(igDlg.map.region))
    igDlg.countries = if igDlg.region == 0 and mapRegions().find(igDlg.map.region) < 0: igDlg.map.region else: ""
  else:
    igDlg.data = chartCsv(igDlg.chart.labels, igDlg.chart.series)

proc igSvg(): string =
  if igDlg.isMap:
    var m = igDlg.map
    m.w = igDlg.box.w
    m.h = igDlg.box.h
    mapSvg(m)
  else:
    var c = igDlg.chart
    c.w = igDlg.box.w
    c.h = igDlg.box.h
    chartSvg(c)

proc igMake() =
  ## (the chart or map placed -- in place of the one edited -- as a group of shape and type
  ## layers, its settings with it; one step)
  let d = cur()
  if d == nil: return
  let svg = igSvg()
  let what = if igDlg.isMap: "Map" else: "Chart"
  d.beginStep(if igDlg.editing != nil: "Edit " & what else: "Insert " & what)
  d.touchLayers()
  var name = what
  if igDlg.editing != nil:
    let i = d.layers.find(igDlg.editing)
    if i >= 0:
      name = igDlg.editing.name
      d.cur = i
      d.deleteLayer(i)
  let made = d.placeSvg(svg, igDlg.box, asGroup = true)
  var top: Layer = nil
  for L in made:
    if L.group and (top == nil or L.depth < top.depth): top = L
  if top == nil and made.len > 0:
    var idxs: seq[int]
    for L in made: idxs.add d.layers.find(L)
    top = d.groupLayers(idxs, name)
  if top != nil:
    top.name = name
    top.meta = igSpecJson()
    d.cur = d.layers.find(top)
  d.endStep()
  d.markAll()
  status = what & ": " & $made.len & " layers in the group \"" & name & "\" (Edit Chart or Map... changes it)"

proc infographicCommand(name: string): bool =
  result = true
  case name
  of "Chart...", "Insert Chart...": startInfographic(false)
  of "Map...", "Insert Map...": startInfographic(true)
  of "Edit Chart or Map...": startInfographic(false, edit = true)
  else: result = false

proc chartFields() =
  var c = igDlg.chart
  row([90, -1]):
    label "Kind:"
    var k = ord(c.kind)
    var kinds: seq[string]
    for x in ChartKind2: kinds.add tr($x)
    if combo(kinds, k, w = dp(170)): c.kind = ChartKind2(k)
  row([90, -1]):
    label "Theme:"
    var t = max(0, chartThemes().find(c.theme))
    if combo(chartThemes(), t, w = dp(170)): c.theme = chartThemes()[t]
  label "Numbers (first row the series, first column the categories):"
  if editArea(igDlg.data, lines = 6):
    let dd = chartData(igDlg.data)
    if dd.labels.len > 0:
      c.labels = dd.labels
      c.series = dd.series
  row([90, -1]):
    label "Title:"
    edit(c.title)
  row([90, -1]):
    label "Subtitle:"
    edit(c.subtitle)
  row([90, -1]):
    label "Legend:"
    var l = ord(c.legend)
    if combo(["None", "Top", "Bottom", "Right"], l, w = dp(110)): c.legend = LegendPlace(l)
  row:
    checkbox("Grid", c.grid)
    checkbox("Numbers on it", c.valueLabels)
    checkbox("Smooth lines", c.smooth)
    checkbox("Dots", c.markers)
  row:
    checkbox("Arabic digits", c.arabicDigits)
    checkbox("Right to left", c.rtl)
    checkbox("From zero", c.startAtZero)
  row:
    label "Decimals:"
    spin(c.decimals, 0, 6, w = dp(50))
    label "Before:"
    edit(c.prefix, w = dp(50))
    label "After:"
    edit(c.suffix, w = dp(60))
  row([90, -1]):
    label "Font:"
    var f = if c.font.len > 0: c.font else: "FreeSans"
    if fontCombo(f, w = dp(180)): c.font = f
  row:
    label "Title size:"
    # (as big as the chart, until set: 28 and 14 for 800 x 500)
    var sized = c
    sized.w = igDlg.box.w
    sized.h = igDlg.box.h
    let (ts0, fs0) = sized.chartTextSizes
    let d = cur()
    let (tsSet, ts) = d.typeField(float32(ts0), dp(56), "igtitle", 1, 2000, size = true)
    if tsSet: c.titleSize = max(1.0, ts.float)
    label typeShort()
    label "Text:"
    let (fsSet, fs) = d.typeField(float32(fs0), dp(56), "igtext", 1, 1000, size = true)
    if fsSet: c.textSize = max(1.0, fs.float)
    label typeShort()
  row:
    label "Corners:"
    var r = int(c.radius)
    if spin(r, 0, 100, w = dp(56)): c.radius = r.float
    label "Gap:"
    var g = int(round((if c.gap > 0: c.gap else: 0.3) * 100))
    if spin(g, 0, 90, w = dp(56)): c.gap = g / 100
    label "%"
  row:
    label "Line width:"
    var lw = int(if c.lineWidth > 0: c.lineWidth else: 3)
    if spin(lw, 1, 40, w = dp(56)): c.lineWidth = lw.float
    label "Hole:"
    var h = int(round((if c.hole > 0: c.hole else: 0.55) * 100))
    if spin(h, 0, 90, w = dp(56)): c.hole = h / 100
    label "%"
  row:
    var own = c.background != 0
    if checkbox("Card behind it", own): c.background = if own: 0xFFFFFFFF'u32 else: 0'u32
    if own:
      var bg = c.background
      if colorWell(bg, "igbg", dp(40), alpha = true): c.background = max(bg, 1'u32)   # (see-through: a card of glass)
  igDlg.chart = c

proc mapFields() =
  var m = igDlg.map
  row([90, -1]):
    label "Region:"
    var regions = mapRegions()
    regions.add "The countries listed"
    var r = if igDlg.countries.len > 0: regions.high else: igDlg.region
    if combo(regions, r, w = dp(190)):
      if r == regions.high:
        if igDlg.countries.len == 0: igDlg.countries = "OM AE SA"
      else:
        igDlg.countries = ""
        igDlg.region = r
    if r == regions.high:
      if edit(igDlg.countries, w = dp(120)): discard
  m.region = if igDlg.countries.len > 0: igDlg.countries else: mapRegions()[clamp(igDlg.region, 0, mapRegions().high)]
  row([90, -1]):
    label "Theme:"
    var t = max(0, mapThemes().find(m.theme))
    if combo(mapThemes(), t, w = dp(150)): m.theme = mapThemes()[t]
  row([90, -1]):
    label "Projection:"
    var p = max(0, ["Equal Earth", "Mercator", "Plate Carree"].find(if m.projection.len > 0: m.projection
                                                                    else: "Equal Earth"))
    if combo(["Equal Earth", "Mercator", "Plate Carree"], p, w = dp(150)):
      m.projection = ["Equal Earth", "Mercator", "Plate Carree"][p]
  label "Countries and their numbers (a code or a name, then the number):"
  if editArea(igDlg.data, lines = 5): m.values = mapValues(igDlg.data)
  row([90, -1]):
    label "Title:"
    edit(m.title)
  row([90, -1]):
    label "Cities:"
    if edit(igDlg.cities):
      m.cities = @[]
      for c in igDlg.cities.split(','):
        if c.strip.len > 0: m.cities.add c.strip
  row:
    checkbox("Names", m.labels)
    checkbox("Numbers", m.showValues)
    checkbox("Scale", m.legend)
    checkbox("Graticule", m.graticule)
  row:
    label "Low:"
    var lo = if m.low != 0: m.low else: mapTheme(m.theme).low
    if colorWell(lo, "igmlow", dp(40)): m.low = lo or 0xFF000000'u32
    label "High:"
    var hi = if m.high != 0: m.high else: mapTheme(m.theme).high
    if colorWell(hi, "igmhigh", dp(40)): m.high = hi or 0xFF000000'u32
    label "Borders:"
    var b = int(round((if m.borders > 0: m.borders else: 0.6) * 10))
    if spin(b, 1, 50, w = dp(50)): m.borders = b / 10
  row:
    label "Decimals:"
    spin(m.decimals, 0, 6, w = dp(50))
    label "After:"
    edit(m.suffix, w = dp(60))
  igDlg.map = m

proc infographicDialogs() =
  if not igDlg.open: return
  let d = cur()
  if d == nil:
    igDlg.open = false
    return
  var ok = false
  dialog(igDlg.open, (if igDlg.isMap: "Map" else: "Chart"), 760):
    row:
      col(330):
        if igDlg.isMap: mapFields() else: chartFields()
      col(390):
        row:
          label "Size:"
          spin(igDlg.box.w, 40, 20000, w = dp(70))
          label "x"
          spin(igDlg.box.h, 40, 20000, w = dp(70))
          label "px"
        # (the preview: drawn again when the settings change)
        let key = igSpecJson()
        if key != igDlg.key:
          igDlg.key = key
          let k = min(380 / igDlg.box.w, 300 / igDlg.box.h)
          igDlg.preview = try: rasterizeSvg(igSvg(), max(1, int(igDlg.box.w.float * k)),
                                            max(1, int(igDlg.box.h.float * k)))
                          except CatchableError: nil
        let pr = place(dp(380), dp(300))
        fill(pr, color(255, 255, 255))
        if igDlg.preview != nil and igDlg.preview.w > 0:
          let k = min(pr.w / igDlg.preview.w, pr.h / igDlg.preview.h)
          let w = max(1, int(igDlg.preview.w.float * k))
          let h = max(1, int(igDlg.preview.h.float * k))
          drawBitmap(rect(pr.x + (pr.w - w) div 2, pr.y + (pr.h - h) div 2, w, h), igDlg.preview)
        box(pr, ui.theme.edge)
        label("Its parts are shape and type layers: sharp in a PDF, each still to change.", color = ui.theme.gray)
    row:
      spring()
      if button((if igDlg.editing != nil: "Change" else: "Insert"), isDefault = true, w = dp(90)): ok = true
      if button("Cancel", w = dp(80)): igDlg.open = false
  if ok:
    igDlg.open = false
    igMake()

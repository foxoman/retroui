## Tests of charts and maps for pages (retroui/infographics): every kind of
## chart and every theme drawn (and read back as SVG), numbers as written,
## data from a table, settings kept as JSON, maps of the world and of parts
## of it with values, labels, cities and a scale; odd input never a crash.

import std/[math, strutils, json, monotimes, times]
import retroui/[infographics, svgimport, photo, gfx]

proc ink(b: Bitmap; bg = 0xFFFFFFFF'u32): int =
  for c in b.px:
    if (c shr 24) > 0 and (c and 0xFFFFFF'u32) != (bg and 0xFFFFFF'u32): inc result

block numbers:
  doAssert numText(1234567.0) == "1,234,567"
  doAssert numText(12.0) == "12", "no point without decimals"
  doAssert numText(-1234.5, 2, "$") == "-$1,234.50"
  doAssert numText(45.0, 0, "", "%") == "45%"
  doAssert numText(1234.5, 1, arabicDigits = true) == "١٬٢٣٤٫٥"
  doAssert numText(NaN) == "" and numText(Inf) == ""

block chartsOfEveryKind:
  var c = ChartSpec(title: "Sales", subtitle: "in thousands", labels: @["Q1", "Q2", "Q3", "Q4"],
                    series: @[("2025", @[12.0, 15, 9, 20]), ("2026", @[14.0, -3, 12, 24])],
                    legend: lpTop, grid: true, valueLabels: true, markers: true, smooth: true, radius: 6,
                    w: 400, h: 260)
  for k in ChartKind2:
    for th in chartThemes():
      c.kind = k
      c.theme = th
      let svg = chartSvg(c)
      doAssert svg.startsWith("<svg") and svg.strip.endsWith("</svg>")
      let b = rasterizeSvg(svg, 400, 260)
      doAssert ink(b, chartTheme(th).background or 0xFFFFFFFF'u32) > 2000, $k & " " & th & " draws"
  # as layers: its text type, its marks shapes
  c.kind = ckColumn
  let d = newDoc(800, 600, 0xFFFFFFFF'u32)
  let made = d.placeSvg(chartSvg(c), rect(10, 10, 400, 260))
  var texts, shapes = 0
  for L in made:
    if L.isText: inc texts
    if L.isShape: inc shapes
  doAssert texts >= 6 and shapes >= 8, $texts & " " & $shapes
  # every legend place, right to left, Arabic labels and digits
  for lp in LegendPlace:
    c.legend = lp
    discard chartSvg(c)
  c.rtl = true
  c.labels = @["الأول", "الثاني", "الثالث", "الرابع"]
  c.arabicDigits = true
  doAssert "٢٤" in chartSvg(c)

block oddData:
  # nothing, one value, NaN, negatives only, huge numbers, a pie of zeros: drawn as they can be
  for kind in ChartKind2:
    for (labels, series) in [(newSeq[string](), newSeq[(string, seq[float])]()),
                             (@["a"], @[("s", @[5.0])]),
                             (@["a", "b"], @[("s", @[NaN, Inf])]),
                             (@["a", "b"], @[("s", @[-5.0, -9])]),
                             (@["a", "b"], @[("s", @[1e15, 3e15])]),
                             (@["a", "b"], @[("s", @[0.0, 0])])]:
      let svg = chartSvg(ChartSpec(kind: kind, labels: labels, series: series, w: 200, h: 120))
      doAssert svg.startsWith("<svg") and "nan" notin svg.toLowerAscii and "inf" notin svg.toLowerAscii
      discard rasterizeSvg(svg, 200, 120)
  discard chartSvg(ChartSpec(kind: ckColumn, w: 5, h: 5, labels: @["a"], series: @[("s", @[1.0])]))

block textAsBigAsTheChart:
  # a chart's text grows with it (a chart across an A4 page at 300 dpi: not a screen's 14 pixels);
  # sizes set are kept; the type layers placed are that big
  let small = ChartSpec(kind: ckColumn, title: "Chart", labels: @["Q1", "Q2"], series: @[("s", @[1.0, 2])],
                        w: 800, h: 500)
  doAssert small.chartTextSizes == (28.0, 14.0)
  var big = small
  big.w = 1600
  big.h = 1000
  doAssert big.chartTextSizes == (56.0, 28.0), $big.chartTextSizes
  big.textSize = 20
  doAssert big.chartTextSizes.text == 20 and big.chartTextSizes.title == 56
  big.textSize = 0
  let d = newDoc(2000, 1400, 0xFFFFFFFF'u32)
  var biggest = 0'f32
  for L in d.placeSvg(chartSvg(big), rect(100, 100, 1600, 1000)):
    if L.isText: biggest = max(biggest, L.text.spans[0].style.size)
  doAssert abs(biggest - 56) < 1, "the title as big as the chart: " & $biggest
  # a map's title too
  let m = mapSvg(MapSpec(region: "Middle East", title: "Map", w: 1800, h: 1000))
  doAssert "font-size=\"52.00\" font-weight=\"bold\"" in m, "the map's title doubled"

block dataAndSettings:
  let t = chartData("Month,2025,2026\nJan,10,12\nFeb,8,\nMar,15,17\n")
  doAssert t.labels == @["Jan", "Feb", "Mar"] and t.series.len == 2 and t.series[1][0] == "2026"
  doAssert t.series[0][1] == @[10.0, 8, 15] and t.series[1][1][1].isNaN
  let back = chartData(chartCsv(t.labels, t.series))
  doAssert back.labels == t.labels and back.series[0][1] == t.series[0][1]
  var c = ChartSpec(kind: ckDonut, title: "Share", labels: t.labels, series: t.series, theme: "Gulf",
                    legend: lpRight, decimals: 1, suffix: "%", colors: @[0xFFFF0000'u32], hole: 0.6, w: 500)
  let c2 = chartFrom(parseJson($c.toJson))
  doAssert c2.kind == ckDonut and c2.title == "Share" and c2.theme == "Gulf" and c2.legend == lpRight and
           c2.decimals == 1 and c2.suffix == "%" and c2.colors == @[0xFFFF0000'u32] and c2.hole == 0.6 and
           c2.labels == t.labels and c2.w == 500
  doAssert chartFrom(newJNull()).labels.len == 0 and chartFrom(parseJson("{\"w\": -5}")).w == 0

block maps:
  var m = MapSpec(region: "Middle East", values: @[("OM", 5.0), ("Saudi Arabia", 9.0), ("AE", 7.0)],
                  theme: "Sand", title: "Gulf", labels: true, showValues: true, legend: true,
                  cities: @["Muscat"], graticule: true, w: 600, h: 400)
  let t0 = getMonoTime()
  let svg = mapSvg(m)
  doAssert (getMonoTime() - t0).inMilliseconds < 2000
  doAssert "id=\"Oman\"" in svg and "id=\"Land\"" in svg and "Muscat" in svg
  let b = rasterizeSvg(svg, 600, 400)
  doAssert ink(b) > 50_000
  # the valued countries in the scale's colors: the highest the darkest
  for th in mapThemes():
    m.theme = th
    discard mapSvg(m)
  for p in ["Equal Earth", "Mercator", "Plate Carree"]:
    m.projection = p
    doAssert mapSvg(m).len > 1000
  # a region of the countries named; the world; nothing known
  m.region = "OM AE"
  doAssert "id=\"Oman\"" in mapSvg(m)
  m.region = "World"
  doAssert mapSvg(m).len > 10_000
  m.region = "Atlantis"
  discard mapSvg(m)
  doAssert mapValues("OM, 5\nSaudi Arabia 9\n\nbad\nAE;7.5") == @[("OM", 5.0), ("Saudi Arabia", 9.0), ("AE", 7.5)]
  let m2 = mapFrom(parseJson($m.toJson))
  doAssert m2.values == m.values and m2.cities == @["Muscat"] and m2.labels and m2.legend
  # as layers: the land one shape, each valued country its own, the names type
  let d = newDoc(800, 600, 0xFFFFFFFF'u32)
  m.region = "Middle East"
  let made = d.placeSvg(mapSvg(m), rect(0, 0, 600, 400))
  var names: seq[string]
  for L in made: names.add L.name
  doAssert "Oman" in names and "Land" in names, $names

echo "test_infographics: ok"

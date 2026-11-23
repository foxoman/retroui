## Charts and maps as SVG, for pages and designs: `chartSvg` draws a chart
## (columns, bars, stacked, lines, areas, pies, donuts, radar) from your
## numbers in a theme of its colors, with every part of it set -- title,
## legend, axes, grid, value labels, numbers, fonts, corners, gaps, line
## widths, markers, smooth lines, a donut's hole -- and `mapSvg` a map of
## the world or a part of it, countries colored by their values or as
## chosen, with labels, cities, a legend, in a theme. Their parts are
## shapes and text: placed in a document (`retroui/svgimport`'s
## `placeSvg`), they are shape and type layers, sharp in a PDF, each
## still to change.
##
## ```nim
## import retroui/[infographics, svgimport, photo]
## var c = ChartSpec(kind: ckColumn, title: "Sales", labels: @["Q1", "Q2", "Q3"],
##                   series: @[("2025", @[12.0, 15, 9]), ("2026", @[14.0, 18, 12])], theme: "Ocean")
## discard d.placeSvg(chartSvg(c), rect(40, 40, 800, 500))
## var m = MapSpec(region: "Middle East", values: @[("OM", 5.0), ("SA", 9.0), ("AE", 7.0)], theme: "Sand")
## discard d.placeSvg(mapSvg(m), rect(40, 600, 800, 500))
## ```

import std/[math, strutils, json]
from std/unicode import Rune, `$`
import charts, mapview

type
  ChartKind2* = enum
    ## What a chart of a page draws.
    ckColumn = "Columns", ckBar = "Bars", ckStackedColumn = "Stacked Columns", ckStackedBar = "Stacked Bars",
    ckLine = "Lines", ckArea = "Areas", ckPie = "Pie", ckDonut = "Donut", ckRadar = "Radar",
    ckScatter = "Scatter"
  LegendPlace* = enum
    lpNone = "None", lpTop = "Top", lpBottom = "Bottom", lpRight = "Right"
  ChartSpec* = object
    ## A chart for a page: its numbers and how it looks.
    kind*: ChartKind2
    title*, subtitle*: string
    labels*: seq[string]                         ## the categories (x), in order
    series*: seq[(string, seq[float])]           ## each series: its name, a number a category
    theme*: string                               ## `chartThemes` ("" the first)
    colors*: seq[uint32]                         ## the series' colors (ARGB) instead of the theme's
    w*, h*: int                                  ## its size (0: 800 x 500)
    font*: string                                ## its type's font ("" the kit's)
    titleSize*, textSize*: float                 ## (0: from its size -- `chartTextSizes`)
    legend*: LegendPlace
    grid*: bool                                  ## lines across at the axis' numbers
    xTitle*, yTitle*: string                     ## the axes' names
    valueLabels*: bool                           ## each bar's, point's or slice's number on it
    decimals*: int                               ## the numbers' decimals
    prefix*, suffix*: string                     ## before and after them ("$", "%", " OMR")
    arabicDigits*: bool                          ## the numbers in Arabic-Indic digits
    background*: uint32                          ## a card behind it (0: none, the theme's own when set)
    radius*: float                               ## the card's and the bars' corners
    gap*: float                                  ## between bars, part of a bar's room (0: 0.3)
    lineWidth*: float                            ## lines' and areas' width (0: 3)
    markers*: bool                               ## a dot at each point of a line
    smooth*: bool                                ## lines curved through their points
    hole*: float                                 ## a donut's hole, part of its size (0: 0.55)
    rtl*: bool                                   ## right to left: the categories from the right
    startAtZero*: bool                           ## the axis from 0 even when all is far above it
  ChartTheme* = object
    name*: string
    colors*: seq[uint32]
    background*, text*, grid*, axis*: uint32
  MapSpec* = object
    ## A map for a page: which part of the world, its colors, its values.
    region*: string                  ## "World", a region of `mapRegions`, or country codes "OM SA AE" to fit
    projection*: string              ## "Equal Earth" (default), "Mercator", "Plate Carree"
    values*: seq[(string, float)]    ## countries (code or name) and their numbers: colored on the scale
    colors*: seq[(string, uint32)]   ## countries colored as chosen (over the scale)
    theme*: string                   ## `mapThemes` ("" the first)
    low*, high*: uint32              ## the scale's colors (0: the theme's)
    w*, h*: int                      ## its size (0: 900 x 500)
    title*: string
    font*: string
    labels*: bool                    ## the colored countries' names
    showValues*: bool                ## ... and their numbers
    cities*: seq[string]             ## cities marked (names `cityLatLon` knows)
    legend*: bool                    ## the scale under it
    borders*: float                  ## the borders' width (0: 0.6)
    graticule*: bool                 ## lines of longitude and latitude every 30 degrees
    decimals*: int
    suffix*: string
  MapTheme* = object
    name*: string
    sea*, land*, border*, text*, low*, high*: uint32

const
  chartThemeList = [
    ChartTheme(name: "Office", colors: @[0xFF4472C4'u32, 0xFFED7D31'u32, 0xFFA5A5A5'u32, 0xFFFFC000'u32,
               0xFF5B9BD5'u32, 0xFF70AD47'u32], background: 0, text: 0xFF333333'u32, grid: 0xFFE3E3E3'u32,
               axis: 0xFF888888'u32),
    ChartTheme(name: "Ocean", colors: @[0xFF0B3C5D'u32, 0xFF328CC1'u32, 0xFF7EC8E3'u32, 0xFFD9B310'u32,
               0xFF1D2731'u32, 0xFFA2D5F2'u32], background: 0, text: 0xFF1D2731'u32, grid: 0xFFDCE8F0'u32,
               axis: 0xFF6E8CA0'u32),
    ChartTheme(name: "Sunset", colors: @[0xFFF94144'u32, 0xFFF3722C'u32, 0xFFF8961E'u32, 0xFFF9C74F'u32,
               0xFF90BE6D'u32, 0xFF43AA8B'u32], background: 0, text: 0xFF3A2E39'u32, grid: 0xFFF1E3DD'u32,
               axis: 0xFF9C7F79'u32),
    ChartTheme(name: "Forest", colors: @[0xFF2D6A4F'u32, 0xFF40916C'u32, 0xFF74C69D'u32, 0xFFB7E4C7'u32,
               0xFF1B4332'u32, 0xFFD8F3DC'u32], background: 0, text: 0xFF1B4332'u32, grid: 0xFFE2EFE6'u32,
               axis: 0xFF6C8F7C'u32),
    ChartTheme(name: "Pastel", colors: @[0xFFA8DADC'u32, 0xFFF4A261'u32, 0xFFE9C46A'u32, 0xFFCDB4DB'u32,
               0xFFBDE0FE'u32, 0xFFFFAFCC'u32], background: 0xFFFFFDF8'u32, text: 0xFF4A4A4A'u32,
               grid: 0xFFEEEAE2'u32, axis: 0xFFAAAAAA'u32),
    ChartTheme(name: "Mono", colors: @[0xFF111111'u32, 0xFF555555'u32, 0xFF888888'u32, 0xFFBBBBBB'u32,
               0xFF333333'u32, 0xFFDDDDDD'u32], background: 0, text: 0xFF111111'u32, grid: 0xFFE6E6E6'u32,
               axis: 0xFF777777'u32),
    ChartTheme(name: "Dark", colors: @[0xFF5BC0BE'u32, 0xFFF7B32B'u32, 0xFFE94F37'u32, 0xFF9B5DE5'u32,
               0xFF00BBF9'u32, 0xFFF15BB5'u32], background: 0xFF1C2541'u32, text: 0xFFE8EEF5'u32,
               grid: 0xFF2E3A5C'u32, axis: 0xFF8090B0'u32),
    ChartTheme(name: "Gulf", colors: @[0xFFC8102E'u32, 0xFF008751'u32, 0xFF8C6D1F'u32, 0xFF1F3A5F'u32,
               0xFFE9B44C'u32, 0xFF6B7F8E'u32], background: 0xFFFBF7F0'u32, text: 0xFF2B2B2B'u32,
               grid: 0xFFEDE4D3'u32, axis: 0xFFA08C6A'u32),
    ChartTheme(name: "Retro", colors: @[0xFF000080'u32, 0xFF008080'u32, 0xFF800000'u32, 0xFF808000'u32,
               0xFF800080'u32, 0xFF008000'u32], background: 0xFFC0C0C0'u32, text: 0xFF000000'u32,
               grid: 0xFFA0A0A0'u32, axis: 0xFF000000'u32)]
  mapThemeList = [
    MapTheme(name: "Atlas", sea: 0xFFDCEBF5'u32, land: 0xFFF2EFE6'u32, border: 0xFFB5AFA2'u32,
             text: 0xFF2B2B2B'u32, low: 0xFFFDE0C5'u32, high: 0xFFC2410C'u32),
    MapTheme(name: "Sand", sea: 0xFFF7F1E3'u32, land: 0xFFE8D8B9'u32, border: 0xFFFFFFFF'u32,
             text: 0xFF4A3B24'u32, low: 0xFFF2D49B'u32, high: 0xFF8C4A1F'u32),
    MapTheme(name: "Blue", sea: 0xFFFFFFFF'u32, land: 0xFFE5E9F0'u32, border: 0xFFFFFFFF'u32,
             text: 0xFF1F2937'u32, low: 0xFFBFDBFE'u32, high: 0xFF1E3A8A'u32),
    MapTheme(name: "Green", sea: 0xFFEFF6F3'u32, land: 0xFFDDE5DF'u32, border: 0xFFFFFFFF'u32,
             text: 0xFF1B4332'u32, low: 0xFFC7E9D3'u32, high: 0xFF1B6E43'u32),
    MapTheme(name: "Night", sea: 0xFF0B132B'u32, land: 0xFF1C2541'u32, border: 0xFF3A506B'u32,
             text: 0xFFE8EEF5'u32, low: 0xFF3A506B'u32, high: 0xFF5BC0BE'u32),
    MapTheme(name: "Mono", sea: 0xFFFFFFFF'u32, land: 0xFFEEEEEE'u32, border: 0xFFBBBBBB'u32,
             text: 0xFF111111'u32, low: 0xFFCCCCCC'u32, high: 0xFF111111'u32),
    MapTheme(name: "Retro", sea: 0xFF008080'u32, land: 0xFFC0C0C0'u32, border: 0xFF000000'u32,
             text: 0xFF000000'u32, low: 0xFFFFFF80'u32, high: 0xFF800000'u32)]
  regionList = [
    ("World", -180.0, -60.0, 180.0, 84.0), ("Middle East", 24.0, 10.0, 64.0, 42.0),
    ("Gulf", 46.0, 15.0, 61.0, 31.0), ("Arab World", -18.0, -2.0, 63.0, 40.0),
    ("Europe", -25.0, 34.0, 45.0, 71.0), ("Africa", -20.0, -36.0, 55.0, 38.0),
    ("Asia", 25.0, -11.0, 150.0, 56.0), ("North America", -170.0, 7.0, -50.0, 75.0),
    ("South America", -82.0, -56.0, -34.0, 13.0), ("Oceania", 110.0, -48.0, 180.0, 0.0)]

proc chartThemes*(): seq[string] =
  ## The chart themes' names.
  for t in chartThemeList: result.add t.name

proc chartTheme*(name: string): ChartTheme =
  ## A chart theme by its name (the first when not known).
  for t in chartThemeList:
    if t.name == name: return t
  chartThemeList[0]

proc mapThemes*(): seq[string] =
  ## The map themes' names.
  for t in mapThemeList: result.add t.name

proc mapTheme*(name: string): MapTheme =
  ## A map theme by its name (the first when not known).
  for t in mapThemeList:
    if t.name == name: return t
  mapThemeList[0]

proc mapRegions*(): seq[string] =
  ## The parts of the world a map can show by name.
  for r in regionList: result.add r[0]

proc finite(v: float): bool {.inline.} = v.classify notin {fcNan, fcInf, fcNegInf}

# ---- SVG pieces ------------------------------------------------------------------------------------------

proc hexOf(c: uint32): string = "#" & toHex(int(c and 0xFFFFFF), 6).toLowerAscii

proc fillOf(c: uint32): string =
  ## (fill="#rrggbb" and its opacity when it is not whole)
  result = "fill=\"" & hexOf(c) & "\""
  let a = int(c shr 24)
  if a < 255: result.add " fill-opacity=\"" & formatFloat(a / 255, ffDecimal, 3) & "\""

proc n(v: float): string = formatFloat(v, ffDecimal, 2)

proc esc(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"))

proc textEl(x, y: float; s: string; size: float; color: uint32; font: string; anchor = "start"; bold = false;
            rtl = false): string =
  "<text x=\"" & n(x) & "\" y=\"" & n(y) & "\" font-family=\"" & esc(if font.len > 0: font else: "FreeSans") &
    "\" font-size=\"" & n(size) & "\"" & (if bold: " font-weight=\"bold\"" else: "") & " " & fillOf(color) &
    " text-anchor=\"" & anchor & "\"" & (if rtl: " direction=\"rtl\"" else: "") & ">" & esc(s) & "</text>\n"

proc hasArabic(s: string): bool =
  for i in 0 ..< s.len:
    if ord(s[i]) in [0xD8, 0xD9, 0xDA, 0xDB]: return true

proc numText*(v: float; decimals = 0; prefix = ""; suffix = ""; arabicDigits = false): string =
  ## A number as a chart writes it: its decimals, thousands apart, before
  ## and after it what is asked, in Arabic-Indic digits when asked.
  if not finite(v): return ""
  let neg = v < 0
  var s = formatFloat(abs(v), ffDecimal, max(0, decimals))
  if s.endsWith("."): s.setLen(s.len - 1)          # (no decimals: no point)
  var whole = s
  var frac = ""
  let dot = s.find('.')
  if dot >= 0:
    whole = s[0 ..< dot]
    frac = s[dot .. ^1]
  var grouped = ""
  for i, ch in whole:
    if i > 0 and (whole.len - i) mod 3 == 0: grouped.add ','
    grouped.add ch
  result = (if neg: "-" else: "") & prefix & grouped & frac & suffix
  if arabicDigits:
    var o = ""
    for ch in result:
      if ch in '0' .. '9': o.add $Rune(0x0660 + ord(ch) - ord('0'))
      elif ch == '.': o.add $Rune(0x066B)
      elif ch == ',': o.add $Rune(0x066C)
      else: o.add ch
    result = o

proc mapIt2Names(s: seq[(string, seq[float])]): seq[string] =
  for (nm, _) in s: result.add nm

proc seriesColor(c: ChartSpec; th: ChartTheme; i: int): uint32 =
  if i < c.colors.len and c.colors[i] != 0: c.colors[i] else: th.colors[i mod th.colors.len]

proc smoothPath(pts: seq[(float, float)]): string =
  ## (a curve through the points: Catmull-Rom as cubic Béziers)
  if pts.len == 0: return
  result = "M" & n(pts[0][0]) & " " & n(pts[0][1])
  for i in 0 ..< pts.high:
    let p0 = pts[max(0, i - 1)]
    let p1 = pts[i]
    let p2 = pts[i + 1]
    let p3 = pts[min(pts.high, i + 2)]
    let c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
    let c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
    result.add " C" & n(c1[0]) & " " & n(c1[1]) & " " & n(c2[0]) & " " & n(c2[1]) & " " & n(p2[0]) & " " & n(p2[1])

proc roundTopRect(x, y, w, h, r: float; horizontal: bool): string =
  ## (a bar with its far end rounded: up for a column, right for a bar)
  let r = max(0.0, min(r, min(w, h) / 2))
  if r <= 0.01: return "<rect x=\"" & n(x) & "\" y=\"" & n(y) & "\" width=\"" & n(w) & "\" height=\"" & n(h) & "\" "
  if not horizontal:
    "<path d=\"M" & n(x) & " " & n(y + h) & " V" & n(y + r) & " Q" & n(x) & " " & n(y) & " " & n(x + r) & " " & n(y) &
      " H" & n(x + w - r) & " Q" & n(x + w) & " " & n(y) & " " & n(x + w) & " " & n(y + r) & " V" & n(y + h) & " Z\" "
  else:
    "<path d=\"M" & n(x) & " " & n(y) & " H" & n(x + w - r) & " Q" & n(x + w) & " " & n(y) & " " & n(x + w) & " " &
      n(y + r) & " V" & n(y + h - r) & " Q" & n(x + w) & " " & n(y + h) & " " & n(x + w - r) & " " & n(y + h) &
      " H" & n(x) & " Z\" "

# ---- charts ------------------------------------------------------------------------------------------------

proc sizeScale(w, h, refW, refH: float): float =
  ## (how much bigger than its reference a chart or a map is: its text and lines grow with it
  ## -- a chart across an A4 page at 300 dpi is not one for a screen)
  max(0.75, sqrt(max(1.0, w) * max(1.0, h) / (refW * refH)))

proc chartTextSizes*(c: ChartSpec): tuple[title, text: float] =
  ## The chart's title and text sizes: as set (`titleSize`, `textSize`), else
  ## 28 and 14 for 800 x 500 pixels and as much bigger as the chart is.
  let k = sizeScale((if c.w > 0: c.w else: 800).float, (if c.h > 0: c.h else: 500).float, 800, 500)
  result.title = if c.titleSize > 0: c.titleSize else: 28.0 * k
  result.text = if c.textSize > 0: c.textSize else: 14.0 * k

proc chartSvg*(c: ChartSpec): string =
  ## The chart as SVG: its shapes and its text (placed in a document,
  ## shape and type layers).
  let W = (if c.w > 0: c.w else: 800).float
  let H = (if c.h > 0: c.h else: 500).float
  let th = chartTheme(c.theme)
  let (ts, fs) = c.chartTextSizes
  let grow = sizeScale(W, H, 800, 500)     # (its lines as much thicker)
  let font = c.font
  let rtl = c.rtl or c.title.hasArabic
  var o = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & n(W) & "\" height=\"" & n(H) &
          "\" viewBox=\"0 0 " & n(W) & " " & n(H) & "\">\n"
  let bg = if c.background != 0: c.background else: th.background
  if bg != 0:
    o.add "<rect width=\"" & n(W) & "\" height=\"" & n(H) & "\" rx=\"" & n(c.radius) & "\" " & fillOf(bg) & "/>\n"
  let pad = max(16.0, min(W, H) * 0.04)
  var top = pad
  let tx = if rtl: W - pad else: pad
  let anchor0 = if rtl: "end" else: "start"
  if c.title.len > 0:
    o.add textEl(tx, top + ts * 0.8, c.title, ts, th.text, font, anchor0, bold = true, rtl = c.title.hasArabic)
    top += ts * 1.25
  if c.subtitle.len > 0:
    o.add textEl(tx, top + fs, c.subtitle, fs * 1.05, (th.text and 0x00FFFFFF'u32) or 0xB0000000'u32, font, anchor0,
                 rtl = c.subtitle.hasArabic)
    top += fs * 1.8
  # the legend
  var right = W - pad
  var bottom = H - pad
  let names = c.series.mapIt2Names()
  let pieLike = c.kind in {ckPie, ckDonut}
  let legendItems = if pieLike: c.labels else: names
  if c.legend != lpNone and legendItems.len > 0:
    let sw = fs * 0.9
    case c.legend
    of lpRight:
      var lw = 0.0
      for s in legendItems: lw = max(lw, s.len.float * fs * 0.55)
      let x = W - pad - lw - sw - 8
      var y = top + 8
      for i, s in legendItems:
        o.add "<rect x=\"" & n(x) & "\" y=\"" & n(y) & "\" width=\"" & n(sw) & "\" height=\"" & n(sw) & "\" rx=\"2\" " &
              fillOf(c.seriesColor(th, i)) & "/>\n"
        o.add textEl(x + sw + 6, y + sw * 0.85, s, fs, th.text, font, rtl = s.hasArabic)
        y += fs * 1.6
      right = x - pad
    of lpTop, lpBottom:
      var widths: seq[float]
      var total = 0.0
      for s in legendItems:
        widths.add sw + 6 + s.len.float * fs * 0.55 + 18
        total += widths[^1]
      var x = (W - total) / 2
      let y = if c.legend == lpTop: top + 4 else: H - pad - sw
      for i, s in legendItems:
        o.add "<rect x=\"" & n(x) & "\" y=\"" & n(y) & "\" width=\"" & n(sw) & "\" height=\"" & n(sw) & "\" rx=\"2\" " &
              fillOf(c.seriesColor(th, i)) & "/>\n"
        o.add textEl(x + sw + 6, y + sw * 0.85, s, fs, th.text, font, rtl = s.hasArabic)
        x += widths[i]
      if c.legend == lpTop: top += sw + 16 else: bottom -= sw + 16
    else: discard
  let num = proc (v: float): string = numText(v, c.decimals, c.prefix, c.suffix, c.arabicDigits)
  let nCat = c.labels.len
  if pieLike:
    # a pie or a donut: the first series, a slice a category
    let vals = if c.series.len > 0: c.series[0][1] else: @[]
    var total = 0.0
    for v in vals:
      if finite(v) and v > 0: total += v
    let cx = (pad + right) / 2
    let cy = (top + bottom) / 2
    let r = max(10.0, min(right - pad, bottom - top) / 2 - 4)
    let hole = if c.kind == ckDonut: (if c.hole > 0: min(0.9, c.hole) else: 0.55) else: 0.0
    var a0 = -PI / 2
    if total > 0:
      for i in 0 ..< min(vals.len, max(nCat, vals.len)):
        let v = vals[i]
        if not finite(v) or v <= 0: continue
        let a1 = a0 + v / total * 2 * PI
        let large = if a1 - a0 > PI: 1 else: 0
        let (x0, y0) = (cx + r * cos(a0), cy + r * sin(a0))
        let (x1, y1) = (cx + r * cos(a1), cy + r * sin(a1))
        var d = ""
        if v >= total * 0.9999:
          d = "M" & n(cx - r) & " " & n(cy) & " A" & n(r) & " " & n(r) & " 0 1 1 " & n(cx + r) & " " & n(cy) &
              " A" & n(r) & " " & n(r) & " 0 1 1 " & n(cx - r) & " " & n(cy) & " Z"
          if hole > 0:
            let h = r * hole
            d.add " M" & n(cx - h) & " " & n(cy) & " A" & n(h) & " " & n(h) & " 0 1 0 " & n(cx + h) & " " & n(cy) &
                  " A" & n(h) & " " & n(h) & " 0 1 0 " & n(cx - h) & " " & n(cy) & " Z"
        elif hole > 0:
          let h = r * hole
          let (u0, w0) = (cx + h * cos(a0), cy + h * sin(a0))
          let (u1, w1) = (cx + h * cos(a1), cy + h * sin(a1))
          d = "M" & n(x0) & " " & n(y0) & " A" & n(r) & " " & n(r) & " 0 " & $large & " 1 " & n(x1) & " " & n(y1) &
              " L" & n(u1) & " " & n(w1) & " A" & n(h) & " " & n(h) & " 0 " & $large & " 0 " & n(u0) & " " & n(w0) & " Z"
        else:
          d = "M" & n(cx) & " " & n(cy) & " L" & n(x0) & " " & n(y0) & " A" & n(r) & " " & n(r) & " 0 " & $large &
              " 1 " & n(x1) & " " & n(y1) & " Z"
        o.add "<path d=\"" & d & "\" " & fillOf(c.seriesColor(th, i)) &
              (if bg != 0: " stroke=\"" & hexOf(bg) & "\" stroke-width=\"2\"" else: "") & "/>\n"
        if c.valueLabels:
          let am = (a0 + a1) / 2
          let lr = if hole > 0: r * (1 + hole) / 2 else: r * 0.65
          let pct = v / total * 100
          o.add textEl(cx + lr * cos(am), cy + lr * sin(am) + fs * 0.35,
                       numText(pct, 0, "", "%", c.arabicDigits), fs, (if hole > 0: 0xFFFFFFFF'u32 else: 0xFFFFFFFF'u32),
                       font, "middle", bold = true)
        a0 = a1
      if hole > 0:
        o.add textEl(cx, cy + ts * 0.35, num(total), ts, th.text, font, "middle", bold = true)
    o.add "</svg>\n"
    return o
  if c.kind == ckRadar:
    let cx = (pad + right) / 2
    let cy = (top + bottom) / 2
    let r = max(10.0, min(right - pad, bottom - top) / 2 - fs * 2)
    var hi = 0.0
    for (_, vs) in c.series:
      for v in vs:
        if finite(v): hi = max(hi, v)
    let rng = niceRange(0, max(hi, 1e-9), 4)
    let k = max(1, nCat)
    proc at(i: int; f: float): (float, float) =
      let a = -PI / 2 + i.float / k.float * 2 * PI
      (cx + r * f * cos(a), cy + r * f * sin(a))
    if c.grid:
      for step in 1 .. 4:
        var d = ""
        for i in 0 ..< k:
          let (x, y) = at(i, step / 4)
          d.add (if i == 0: "M" else: " L") & n(x) & " " & n(y)
        o.add "<path d=\"" & d & " Z\" fill=\"none\" stroke=\"" & hexOf(th.grid) & "\" stroke-width=\"1\"/>\n"
    for i in 0 ..< k:
      let (x, y) = at(i, 1)
      o.add "<path d=\"M" & n(cx) & " " & n(cy) & " L" & n(x) & " " & n(y) & "\" stroke=\"" & hexOf(th.grid) &
            "\" stroke-width=\"1\"/>\n"
      let (lx, ly) = at(i, 1.12)
      if i < c.labels.len:
        o.add textEl(lx, ly + fs * 0.35, c.labels[i], fs, th.text, font, "middle", rtl = c.labels[i].hasArabic)
    let lw = if c.lineWidth > 0: c.lineWidth else: 3.0 * grow
    for si, (_, vs) in c.series:
      var d = ""
      for i in 0 ..< k:
        let v = if i < vs.len and finite(vs[i]): vs[i] else: 0.0
        let (x, y) = at(i, v / rng.hi)
        d.add (if i == 0: "M" else: " L") & n(x) & " " & n(y)
      let col = c.seriesColor(th, si)
      o.add "<path d=\"" & d & " Z\" " & fillOf((col and 0x00FFFFFF'u32) or 0x40000000'u32) & " stroke=\"" &
            hexOf(col) & "\" stroke-width=\"" & n(lw) & "\" stroke-linejoin=\"round\"/>\n"
    o.add "</svg>\n"
    return o
  # cartesian: columns, bars, stacked, lines, areas
  let horizontal = c.kind in {ckBar, ckStackedBar}
  let stacked = c.kind in {ckStackedColumn, ckStackedBar}
  var lo = 0.0
  var hi = 0.0
  var any = false
  for ci in 0 ..< nCat:
    var pos, neg = 0.0
    for (_, vs) in c.series:
      let v = if ci < vs.len: vs[ci] else: NaN
      if not finite(v): continue
      any = true
      if stacked:
        if v >= 0: pos += v else: neg += v
      else:
        lo = min(lo, v)
        hi = max(hi, v)
    if stacked:
      hi = max(hi, pos)
      lo = min(lo, neg)
  if not any: hi = 1
  if not c.startAtZero and not stacked and c.kind in {ckLine, ckArea} and any:
    var mn = Inf
    for (_, vs) in c.series:
      for v in vs:
        if finite(v): mn = min(mn, v)
    if mn > 0 and mn > hi * 0.5: lo = mn
  let rng = niceRange(lo, hi, 5)
  # the plot's room: the numbers' width at the left (or under bars), the categories' under
  var numW = 0.0
  var t = rng.lo
  var ticks: seq[float]
  while t <= rng.hi + rng.step * 0.01 and ticks.len < 50:
    ticks.add t
    numW = max(numW, num(t).len.float * fs * 0.55)
    t += rng.step
  var catW = 0.0
  for s in c.labels: catW = max(catW, s.len.float * fs * 0.55)
  var px0 = pad + (if c.yTitle.len > 0 and not horizontal: fs * 1.6 else: 0.0) +
            (if horizontal: catW + 10 else: numW + 10)
  var px1 = right
  var py0 = top + fs * 0.6
  var py1 = bottom - fs * 1.8 - (if c.xTitle.len > 0: fs * 1.6 else: 0.0)
  if rtl and not horizontal:
    let wdt = px0 - pad
    px0 = pad
    px1 = right - wdt
  if px1 - px0 < 20 or py1 - py0 < 20:
    o.add "</svg>\n"
    return o
  proc vPos(v: float): float =
    ## (a number's place along the value axis)
    let f = (v - rng.lo) / max(1e-12, rng.hi - rng.lo)
    if horizontal: px0 + f * (px1 - px0) else: py1 - f * (py1 - py0)
  # grid and numbers
  for tv in ticks:
    let p = vPos(tv)
    if horizontal:
      if c.grid:
        o.add "<path d=\"M" & n(p) & " " & n(py0) & " V" & n(py1) & "\" stroke=\"" & hexOf(th.grid) & "\" stroke-width=\"1\"/>\n"
      o.add textEl(p, py1 + fs * 1.3, num(tv), fs * 0.9, th.axis, font, "middle")
    else:
      if c.grid:
        o.add "<path d=\"M" & n(px0) & " " & n(p) & " H" & n(px1) & "\" stroke=\"" & hexOf(th.grid) & "\" stroke-width=\"1\"/>\n"
      if rtl: o.add textEl(px1 + 8, p + fs * 0.35, num(tv), fs * 0.9, th.axis, font, "start")
      else: o.add textEl(px0 - 8, p + fs * 0.35, num(tv), fs * 0.9, th.axis, font, "end")
  # the axis line at zero
  let z = vPos(max(rng.lo, min(rng.hi, 0.0)))
  if horizontal:
    o.add "<path d=\"M" & n(z) & " " & n(py0) & " V" & n(py1) & "\" stroke=\"" & hexOf(th.axis) & "\" stroke-width=\"1.2\"/>\n"
  else:
    o.add "<path d=\"M" & n(px0) & " " & n(z) & " H" & n(px1) & "\" stroke=\"" & hexOf(th.axis) & "\" stroke-width=\"1.2\"/>\n"
  # categories
  let k = max(1, nCat)
  let band = (if horizontal: py1 - py0 else: px1 - px0) / k.float
  proc catPos(i: int): float =
    let j = if rtl and not horizontal: k - 1 - i else: i
    (if horizontal: py0 else: px0) + (j.float + 0.5) * band
  for i, s in c.labels:
    let p = catPos(i)
    if horizontal: o.add textEl(px0 - 8, p + fs * 0.35, s, fs, th.text, font, "end", rtl = s.hasArabic)
    else: o.add textEl(p, py1 + fs * 1.3, s, fs, th.text, font, "middle", rtl = s.hasArabic)
  if c.xTitle.len > 0:
    o.add textEl((px0 + px1) / 2, bottom - 2, c.xTitle, fs, th.axis, font, "middle", rtl = c.xTitle.hasArabic)
  if c.yTitle.len > 0 and not horizontal:
    o.add "<text x=\"0\" y=\"0\" transform=\"translate(" & n(pad + fs) & " " & n((py0 + py1) / 2) &
          ") rotate(-90)\" font-family=\"" & esc(if font.len > 0: font else: "FreeSans") & "\" font-size=\"" & n(fs) &
          "\" " & fillOf(th.axis) & " text-anchor=\"middle\">" & esc(c.yTitle) & "</text>\n"
  let ns = max(1, c.series.len)
  let gap = if c.gap > 0: min(0.9, c.gap) else: 0.3
  if c.kind in {ckColumn, ckBar, ckStackedColumn, ckStackedBar}:
    let barRoom = band * (1 - gap)
    let bw = if stacked: barRoom else: barRoom / ns.float
    for ci in 0 ..< nCat:
      var pos, neg = 0.0
      for si, (_, vs) in c.series:
        let v = if ci < vs.len: vs[ci] else: NaN
        if not finite(v): continue
        let col = c.seriesColor(th, si)
        var a, b: float
        if stacked:
          if v >= 0:
            a = pos
            pos += v
            b = pos
          else:
            a = neg
            neg += v
            b = neg
        else:
          a = 0
          b = v
        let p0 = vPos(min(a, b))
        let p1 = vPos(max(a, b))
        let start = catPos(ci) - barRoom / 2 + (if stacked: 0.0 else: si.float * bw)
        let rr = if not stacked or si == c.series.high: c.radius * 0.5 else: 0.0
        if horizontal:
          o.add roundTopRect(p0, start, p1 - p0, bw, (if v >= 0: rr else: 0), true) & fillOf(col) & "/>\n"
          if c.valueLabels:
            o.add textEl(p1 + 6, start + bw / 2 + fs * 0.35, num(v), fs * 0.9, th.text, font)
        else:
          o.add roundTopRect(start, p1, bw, p0 - p1, (if v >= 0: rr else: 0), false) & fillOf(col) & "/>\n"
          if c.valueLabels:
            let ly = if stacked: (p0 + p1) / 2 + fs * 0.35 else: p1 - 6
            o.add textEl(start + bw / 2, ly, num(v), fs * 0.9, (if stacked: 0xFFFFFFFF'u32 else: th.text), font,
                         "middle")
  else:
    # lines and areas; scatter: points only, across by the categories' numbers when they are numbers
    let lw = if c.lineWidth > 0: c.lineWidth else: 3.0 * grow
    var xs: seq[float]
    if c.kind == ckScatter:
      for l in c.labels:
        try: xs.add parseFloat(l.strip)
        except ValueError:
          xs = @[]
          break
    var xlo = Inf
    var xhi = -Inf
    for x in xs:
      xlo = min(xlo, x)
      xhi = max(xhi, x)
    proc xPos(ci: int): float =
      if xs.len == nCat and nCat > 0 and xhi > xlo: px0 + band / 2 + (xs[ci] - xlo) / (xhi - xlo) * (px1 - px0 - band)
      else: catPos(ci)
    for si, (_, vs) in c.series:
      var pts: seq[(float, float)]
      for ci in 0 ..< nCat:
        let v = if ci < vs.len: vs[ci] else: NaN
        if finite(v): pts.add (xPos(ci), vPos(v))
      if pts.len == 0: continue
      let col = c.seriesColor(th, si)
      var d = ""
      if c.smooth: d = smoothPath(pts)
      else:
        for i, p in pts: d.add (if i == 0: "M" else: " L") & n(p[0]) & " " & n(p[1])
      if c.kind == ckArea:
        o.add "<path d=\"" & d & " L" & n(pts[^1][0]) & " " & n(z) & " L" & n(pts[0][0]) & " " & n(z) & " Z\" " &
              fillOf((col and 0x00FFFFFF'u32) or 0x59000000'u32) & "/>\n"
      if c.kind != ckScatter:
        o.add "<path d=\"" & d & "\" fill=\"none\" stroke=\"" & hexOf(col) & "\" stroke-width=\"" & n(lw) &
              "\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>\n"
      for p in pts:
        if c.markers or c.kind == ckScatter:
          o.add "<circle cx=\"" & n(p[0]) & "\" cy=\"" & n(p[1]) & "\" r=\"" & n(lw * 1.4) & "\" " & fillOf(col) &
                (if bg != 0: " stroke=\"" & hexOf(bg) & "\"" else: " stroke=\"#ffffff\"") & " stroke-width=\"" &
                n(lw * 0.6) & "\"/>\n"
      if c.valueLabels:
        var i = 0
        for ci in 0 ..< nCat:
          let v = if ci < vs.len: vs[ci] else: NaN
          if not finite(v): continue
          o.add textEl(pts[i][0], pts[i][1] - lw * 2 - 4, num(v), fs * 0.9, th.text, font, "middle")
          inc i
  o.add "</svg>\n"
  o

# ---- data and settings as text -----------------------------------------------------------------------------

proc chartData*(csv: string): tuple[labels: seq[string]; series: seq[(string, seq[float])]] =
  ## A chart's numbers from a table typed or pasted: the first row the
  ## series' names, the first column the categories, commas, tabs or
  ## semicolons between (`charts.parseCsv`).
  let t = parseCsv(csv)
  if t.headers.len == 0: return
  result.labels = t.labels(0)
  for c in 1 ..< t.headers.len:
    result.series.add (t.headers[c], t.column(c))

proc chartCsv*(labels: seq[string]; series: seq[(string, seq[float])]): string =
  ## The numbers as the table `chartData` reads.
  var head = @[""]
  for (nm, _) in series: head.add nm
  result = csvLine(head) & "\n"
  for i, l in labels:
    var row = @[l]
    for (_, vs) in series: row.add(if i < vs.len and finite(vs[i]): $vs[i] else: "")
    result.add csvLine(row) & "\n"

proc toJson*(c: ChartSpec): JsonNode =
  ## The chart's settings and numbers (kept with its layer, to make it again).
  result = %*{"kind": $c.kind, "title": c.title, "subtitle": c.subtitle, "theme": c.theme, "w": c.w, "h": c.h,
              "font": c.font, "titleSize": c.titleSize, "textSize": c.textSize, "legend": $c.legend,
              "grid": c.grid, "xTitle": c.xTitle, "yTitle": c.yTitle, "valueLabels": c.valueLabels,
              "decimals": c.decimals, "prefix": c.prefix, "suffix": c.suffix, "arabicDigits": c.arabicDigits,
              "background": int64(c.background), "radius": c.radius, "gap": c.gap, "lineWidth": c.lineWidth,
              "markers": c.markers, "smooth": c.smooth, "hole": c.hole, "rtl": c.rtl,
              "startAtZero": c.startAtZero, "data": chartCsv(c.labels, c.series)}
  var cs = newJArray()
  for x in c.colors: cs.add %int64(x)
  result["colors"] = cs

proc enumBy[T: enum](s: string; d: T): T =
  for e in T:
    if $e == s: return e
  d

proc chartFrom*(j: JsonNode): ChartSpec =
  ## A chart's settings back from `toJson`.
  if j == nil or j.kind != JObject: return
  template s(k: string): string = j{k}.getStr("")
  template f(k: string): float = j{k}.getFloat(0)
  template b(k: string): bool = j{k}.getBool(false)
  result = ChartSpec(kind: enumBy(s("kind"), ckColumn), title: s("title"), subtitle: s("subtitle"),
                     theme: s("theme"), w: clamp(j{"w"}.getInt(0), 0, 20000), h: clamp(j{"h"}.getInt(0), 0, 20000),
                     font: s("font"), titleSize: f("titleSize"), textSize: f("textSize"),
                     legend: enumBy(s("legend"), lpNone), grid: b("grid"), xTitle: s("xTitle"), yTitle: s("yTitle"),
                     valueLabels: b("valueLabels"), decimals: clamp(j{"decimals"}.getInt(0), 0, 6),
                     prefix: s("prefix"), suffix: s("suffix"), arabicDigits: b("arabicDigits"),
                     background: uint32(j{"background"}.getBiggestInt(0) and 0xFFFFFFFF'i64), radius: f("radius"),
                     gap: f("gap"), lineWidth: f("lineWidth"), markers: b("markers"), smooth: b("smooth"),
                     hole: f("hole"), rtl: b("rtl"), startAtZero: b("startAtZero"))
  let d = chartData(s("data"))
  result.labels = d.labels
  result.series = d.series
  if j.hasKey("colors") and j["colors"].kind == JArray:
    for x in j["colors"].elems: result.colors.add uint32(x.getBiggestInt(0) and 0xFFFFFFFF'i64)

# ---- maps --------------------------------------------------------------------------------------------------

proc project(lon, lat: float; proj: string): (float, float) =
  ## (a place on the flat map, in degrees' units: x east, y north)
  case proj
  of "Mercator":
    let la = clamp(lat, -82.0, 84.0) * PI / 180
    (lon, ln(tan(PI / 4 + la / 2)) * 180 / PI)
  of "Plate Carree": (lon, lat)
  else:
    # Equal Earth (Šavrič, Patterson, Jenny 2018)
    const a1 = 1.340264
    const a2 = -0.081106
    const a3 = 0.000893
    const a4 = 0.003796
    let m = sqrt(3.0) / 2
    let la = lat * PI / 180
    let th = arcsin(m * sin(la))
    let t2 = th * th
    let t6 = t2 * t2 * t2
    let x = 2 * sqrt(3.0) * (lon * PI / 180) * cos(th) / (3 * (a1 + 3 * a2 * t2 + t6 * (7 * a3 + 9 * a4 * t2)))
    let y = th * (a1 + a2 * t2 + t6 * (a3 + a4 * t2))
    (x * 180 / PI, y * 180 / PI)

proc mixArgb(a, b: uint32; t: float): uint32 =
  let t = clamp(t, 0.0, 1.0)
  for sh in [24, 16, 8, 0]:
    let x = float((a shr sh) and 255)
    let y = float((b shr sh) and 255)
    result = result or (uint32(round(x + (y - x) * t)) shl sh)

proc mapSvg*(m: MapSpec): string =
  ## The map as SVG: the sea, the land (one shape), each country colored by
  ## its value or as chosen (a shape of its own, named by its code), its
  ## labels, the cities, a legend.
  let W = (if m.w > 0: m.w else: 900).float
  let H = (if m.h > 0: m.h else: 500).float
  let th = mapTheme(m.theme)
  let low = if m.low != 0: m.low else: th.low
  let high = if m.high != 0: m.high else: th.high
  let proj = if m.projection.len > 0: m.projection else: "Equal Earth"
  let font = if m.font.len > 0: m.font else: "FreeSans"
  let bw = if m.borders > 0: m.borders else: 0.6
  # the countries asked for: their index, value, color
  var valueOf = newSeq[float](countryCount())
  var colorOf = newSeq[uint32](countryCount())
  for v in valueOf.mitems: v = NaN
  var vlo = Inf
  var vhi = -Inf
  for (code, v) in m.values:
    let i = countryIndex(code)
    if i >= 0 and finite(v):
      valueOf[i] = v
      vlo = min(vlo, v)
      vhi = max(vhi, v)
  for (code, col) in m.colors:
    let i = countryIndex(code)
    if i >= 0: colorOf[i] = col
  # the region: a named one, or the countries named (or valued) fitted
  var (lon0, lat0, lon1, lat1) = (-180.0, -60.0, 180.0, 84.0)
  var known = false
  for r in regionList:
    if r[0].toLowerAscii == m.region.strip.toLowerAscii:
      (lon0, lat0, lon1, lat1) = (r[1], r[2], r[3], r[4])
      known = true
  if not known and m.region.strip.len > 0:
    var bx0, by0 = Inf
    var bx1, by1 = -Inf
    for code in m.region.replace(",", " ").splitWhitespace:
      let i = countryIndex(code)
      if i < 0: continue
      for ring in countryRings(i):
        for (lo, la) in ring:
          bx0 = min(bx0, lo); bx1 = max(bx1, lo)
          by0 = min(by0, la); by1 = max(by1, la)
    if bx0 < bx1:
      let mx = max(2.0, (bx1 - bx0) * 0.15)
      let my = max(2.0, (by1 - by0) * 0.15)
      (lon0, lat0, lon1, lat1) = (bx0 - mx, by0 - my, bx1 + mx, by1 + my)
  # the region's box on the flat map, fitted in the picture (the title's room above, the legend's under)
  var fx0, fy0 = Inf
  var fx1, fy1 = -Inf
  for k in 0 .. 20:
    let f = k.float / 20
    for (lo, la) in [(lon0 + (lon1 - lon0) * f, lat0), (lon0 + (lon1 - lon0) * f, lat1),
                     (lon0, lat0 + (lat1 - lat0) * f), (lon1, lat0 + (lat1 - lat0) * f)]:
      let (x, y) = project(lo, la, proj)
      fx0 = min(fx0, x); fx1 = max(fx1, x)
      fy0 = min(fy0, y); fy1 = max(fy1, y)
  let top = if m.title.len > 0: 52.0 else: 8.0
  let bottom = if m.legend and vlo <= vhi: 46.0 else: 8.0
  let avW = W - 16
  let avH = H - top - bottom
  let k = min(avW / max(1e-9, fx1 - fx0), avH / max(1e-9, fy1 - fy0))
  let ox = 8 + (avW - (fx1 - fx0) * k) / 2
  let oy = top + (avH - (fy1 - fy0) * k) / 2
  proc P(lo, la: float): (float, float) =
    let (x, y) = project(lo, la, proj)
    (ox + (x - fx0) * k, oy + (fy1 - y) * k)
  proc ringsPath(i: int): string =
    for ring in countryRings(i):
      if ring.len < 3: continue
      var inside = false
      for (lo, la) in ring:
        if lo >= lon0 - 30 and lo <= lon1 + 30 and la >= lat0 - 30 and la <= lat1 + 30:
          inside = true
          break
      if not inside: continue
      var last = (-1e9, -1e9)
      for j, (lo, la) in ring:
        let (x, y) = P(lo, la)
        if j > 0 and abs(x - last[0]) + abs(y - last[1]) < 0.4: continue    # (closer than half a pixel)
        result.add (if j == 0: "M" else: "L") & n(x) & " " & n(y)
        last = (x, y)
      result.add "Z"
  var o = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" & n(W) & "\" height=\"" & n(H) &
          "\" viewBox=\"0 0 " & n(W) & " " & n(H) & "\">\n"
  o.add "<rect width=\"" & n(W) & "\" height=\"" & n(H) & "\" " & fillOf(th.sea) & "/>\n"
  if m.graticule:
    var d = ""
    var lo = -180.0
    while lo <= 180:
      if lo >= lon0 and lo <= lon1:
        for j in 0 .. 36:
          let la = lat0 + (lat1 - lat0) * j.float / 36
          let (x, y) = P(lo, la)
          d.add (if j == 0: "M" else: "L") & n(x) & " " & n(y)
      lo += 30
    var la = -60.0
    while la <= 90:
      if la >= lat0 and la <= lat1:
        for j in 0 .. 72:
          let lo2 = lon0 + (lon1 - lon0) * j.float / 72
          let (x, y) = P(lo2, la)
          d.add (if j == 0: "M" else: "L") & n(x) & " " & n(y)
      la += 30
    if d.len > 0:
      o.add "<path id=\"Graticule\" d=\"" & d & "\" fill=\"none\" stroke=\"" & hexOf(mixArgb(th.sea, th.text, 0.15)) &
            "\" stroke-width=\"0.6\"/>\n"
  # the land: every country not colored, as one shape
  var land = ""
  for i in 0 ..< countryCount():
    if finite(valueOf[i]) or colorOf[i] != 0: continue
    land.add ringsPath(i)
  if land.len > 0:
    o.add "<path id=\"Land\" d=\"" & land & "\" " & fillOf(th.land) & " stroke=\"" & hexOf(th.border) &
          "\" stroke-width=\"" & n(bw) & "\" stroke-linejoin=\"round\"/>\n"
  # the countries colored, each a shape
  for i in 0 ..< countryCount():
    var col = colorOf[i]
    if col == 0 and finite(valueOf[i]):
      col = mixArgb(low, high, if vhi > vlo: (valueOf[i] - vlo) / (vhi - vlo) else: 1.0)
    if col == 0: continue
    let d = ringsPath(i)
    if d.len == 0: continue
    o.add "<path id=\"" & esc(countryNameAt(i)) & "\" d=\"" & d & "\" " & fillOf(col) & " stroke=\"" &
          hexOf(th.border) & "\" stroke-width=\"" & n(bw) & "\" stroke-linejoin=\"round\"/>\n"
  # labels and cities
  let fs = max(9.0, min(W, H) / 40)
  let grow = sizeScale(W, H, 900, 500)        # (the title and the legend as much bigger as the map is)
  if m.labels or m.showValues:
    for i in 0 ..< countryCount():
      if not finite(valueOf[i]) and colorOf[i] == 0: continue
      let (lo, la) = countryLabelAt(i)
      if lo < lon0 or lo > lon1 or la < lat0 or la > lat1: continue
      let (x, y) = P(lo, la)
      var s = if m.labels: countryNameAt(i) else: ""
      if m.showValues and finite(valueOf[i]):
        s.add (if s.len > 0: " " else: "") & numText(valueOf[i], m.decimals, "", m.suffix)
      o.add textEl(x, y + fs * 0.35, s, fs, th.text, font, "middle")
  for name in m.cities:
    let c = cityLatLon(name)
    if not c.found: continue
    let (x, y) = P(c.lon, c.lat)
    o.add "<circle cx=\"" & n(x) & "\" cy=\"" & n(y) & "\" r=\"" & n(fs * 0.35) & "\" " & fillOf(th.text) &
          " stroke=\"#ffffff\" stroke-width=\"1\"/>\n"
    o.add textEl(x + fs * 0.6, y - fs * 0.4, name, fs, th.text, font, rtl = name.hasArabic)
  if m.title.len > 0:
    o.add textEl(16 * grow, 36 * grow, m.title, 26 * grow, th.text, font, bold = true, rtl = m.title.hasArabic)
  if m.legend and vlo <= vhi:
    # the scale: a band from the low color to the high, its ends' numbers
    let lw = min(260.0 * grow, W * 0.4)
    let x = 16.0 * grow
    let y = H - 34 * grow
    let steps = 24
    for s in 0 ..< steps:
      o.add "<rect x=\"" & n(x + lw * s.float / steps.float) & "\" y=\"" & n(y) & "\" width=\"" &
            n(lw / steps.float + 0.5) & "\" height=\"" & n(10 * grow) & "\" " &
            fillOf(mixArgb(low, high, s.float / float(steps - 1))) & "/>\n"
    o.add textEl(x, y + 26 * grow, numText(vlo, m.decimals, "", m.suffix), fs, th.text, font)
    o.add textEl(x + lw, y + 26 * grow, numText(vhi, m.decimals, "", m.suffix), fs, th.text, font, "end")
  o.add "</svg>\n"
  o

proc toJson*(m: MapSpec): JsonNode =
  ## The map's settings (kept with its layer, to make it again).
  var vals = newJArray()
  for (c, v) in m.values: vals.add %*[c, v]
  var cols = newJArray()
  for (c, v) in m.colors: cols.add %*[c, int64(v)]
  %*{"region": m.region, "projection": m.projection, "values": vals, "colors": cols, "theme": m.theme,
     "low": int64(m.low), "high": int64(m.high), "w": m.w, "h": m.h, "title": m.title, "font": m.font,
     "labels": m.labels, "showValues": m.showValues, "cities": m.cities, "legend": m.legend,
     "borders": m.borders, "graticule": m.graticule, "decimals": m.decimals, "suffix": m.suffix}

proc mapFrom*(j: JsonNode): MapSpec =
  ## A map's settings back from `toJson`.
  if j == nil or j.kind != JObject: return
  result = MapSpec(region: j{"region"}.getStr(""), projection: j{"projection"}.getStr(""),
                   theme: j{"theme"}.getStr(""), low: uint32(j{"low"}.getBiggestInt(0) and 0xFFFFFFFF'i64),
                   high: uint32(j{"high"}.getBiggestInt(0) and 0xFFFFFFFF'i64), w: clamp(j{"w"}.getInt(0), 0, 20000),
                   h: clamp(j{"h"}.getInt(0), 0, 20000), title: j{"title"}.getStr(""), font: j{"font"}.getStr(""),
                   labels: j{"labels"}.getBool(false), showValues: j{"showValues"}.getBool(false),
                   legend: j{"legend"}.getBool(false), borders: j{"borders"}.getFloat(0),
                   graticule: j{"graticule"}.getBool(false), decimals: clamp(j{"decimals"}.getInt(0), 0, 6),
                   suffix: j{"suffix"}.getStr(""))
  for x in j{"values"}.getElems:
    if x.kind == JArray and x.len == 2: result.values.add (x[0].getStr(""), x[1].getFloat(0))
  for x in j{"colors"}.getElems:
    if x.kind == JArray and x.len == 2: result.colors.add (x[0].getStr(""), uint32(x[1].getBiggestInt(0) and 0xFFFFFFFF'i64))
  for x in j{"cities"}.getElems: result.cities.add x.getStr("")

proc mapValues*(text: string): seq[(string, float)] =
  ## Countries and their numbers from lines "OM, 12" or "Oman 12" (a code
  ## or a name, then the number).
  for line in text.splitLines:
    let l = line.strip
    if l.len == 0: continue
    var cut = -1
    for i in countdown(l.high, 0):
      if l[i] in {',', '\t', ';', ' '}:
        cut = i
        break
    if cut <= 0: continue
    var v: float
    if toNumber(l[cut + 1 .. ^1].strip, v): result.add (l[0 ..< cut].strip(chars = {' ', ',', '\t', ';'}), v)

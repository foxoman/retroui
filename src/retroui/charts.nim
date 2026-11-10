## Charts for business apps: bars (grouped, stacked, 100 %, sideways),
## lines, areas, bars with a line on a second axis, pies and donuts,
## scatter and bubbles, waterfalls, funnels, gauges, candlesticks,
## histograms, heat maps, radars, tree maps and bullet charts -- with round
## axis numbers, a legend that hides a series when clicked, a tooltip (the
## mouse, a tap, or the arrow keys once the chart has the focus), click
## events, numbers formatted as money, shares or 1.2K / 3.4M, and data
## from CSV files. Empty, missing (NaN), infinite, negative and huge values
## are drawn as well as they can be, never a crash.
##
## .. code-block:: nim
##   import retroui
##   let t = readCsv("sales.csv")          # Month, 2025, 2026
##   app "Sales", 900, 600:
##     chart("Sales by month", chBar, t.labels("Month"),
##           [series("2025", t.column("2025")), series("2026", t.column("2026"))])
##     row([-1, -1]):
##       chart("2026 by month", chDonut, t.labels("Month"),
##             [series("2026", t.column("2026"))])
##       chart("Growth", chWaterfall, t.labels("Month"),
##             [series("Change", t.column("Change"))])
##
## `ChartOpts` sets the rest: titles, number format (`NumFormat`), the
## legend's place, data labels, the axis range, a gauge's target, the
## palette. `exportPng(ui.lastRect, "chart.png")` after a chart saves it.

import std/[math, strutils, algorithm, tables]
import std/unicode except strip   # (its strip cuts letters: docs/nim-bugs.md)
import uirelays/screen
import gfx, core, widgets, business, imaging

template th: untyped = ui.theme

type
  ChartKind* = enum
    ## The kinds of chart `chart` draws.
    chBar         ## vertical bars, the series side by side for each label
    chBarH        ## the same, sideways (long labels, rankings)
    chStacked     ## the series on top of each other
    chStacked100  ## ... as shares of each label's total
    chLine        ## a line per series
    chArea        ## lines with the area under them
    chStackedArea ## areas on top of each other
    chCombo       ## bars, and the `asLine` series (else the last) as lines
                  ## on a second axis at the right
    chPie         ## shares of a circle (the first series)
    chDonut       ## ... with the total in the middle
    chScatter     ## points at (`xs`, values)
    chBubble      ## ... sized by `sizes`
    chWaterfall   ## changes adding up: rises, falls, the total
    chFunnel      ## the stages of a pipeline, each narrower
    chGauge       ## one value on a dial, with a `target` and colored bands
    chCandle      ## open, high, low and close (`ohlcSeries`)
    chHistogram   ## how many of the first series' values fall in each bin
    chHeatmap     ## a table of values as colors (each series is a row)
    chRadar       ## each series around the labels
    chTreemap     ## shares as rectangles in a rectangle
    chBullet      ## values (the first series) against targets (the second)

  Series* = object
    ## Values with a name, one per label (`series`, `lineSeries`,
    ## `xySeries`, `ohlcSeries` make them).
    name*: string          ## shown in the legend and tooltips
    values*: seq[float]    ## one per label (NaN: no value there)
    color*: Color          ## alpha 0: from the palette
    colors*: seq[Color]    ## a color for each value (bars, slices), optional
    xs*: seq[float]        ## scatter, bubble: the x of each value
    sizes*: seq[float]     ## bubble: the size of each
    opens*, highs*, lows*: seq[float]  ## candlesticks (`values`: the closes)
    asLine*: bool          ## combo: a line on the right axis

  NumFormat* = object
    ## How numbers are written on the axes, in tooltips and labels.
    decimals*: int = -1    ## -1: what the number needs (axes: the step's)
    prefix*, suffix*: string  ## "$", " OMR"...
    short*: bool           ## 1.2K, 3.4M, 5.6B
    percent*: bool         ## 0.25 is written 25%
    thousands*: bool = true ## 1,234,567

  LegendAt* = enum
    ## Where the legend goes: `laAuto` right of the chart when it fits, else
    ## below it (a funnel or treemap: none, their labels are on the chart);
    ## right, below, or nowhere.
    laAuto, laRight, laBottom, laNone

  ChartOpts* = object
    ## What else a chart can be told; the defaults suit most data.
    title*, subtitle*: string  ## written above the chart ("": none)
    xTitle*, yTitle*: string  ## the axes' names
    format*: NumFormat     ## values, and the left (or only) value axis
    format2*: NumFormat    ## the right axis of a combo chart
    legend*: LegendAt      ## where the legend goes
    dataLabels*: bool      ## each value written on its bar, point or slice
    grid*: bool = true     ## light lines across at the axis numbers
    smooth*: bool          ## lines as curves
    markers*: bool = true  ## points on the lines (when there are not too many)
    lo*, hi*: float = NaN  ## the value axis (gauge: the dial) from, to (NaN: from the data)
    target*: float = NaN   ## gauge: the target mark
    bands*: seq[tuple[upTo: float; color: Color]]
      ## gauge, bullet: colored ranges (each up to its value)
    bins*: int             ## histogram: how many (0: from the count)
    totalAt*: seq[int]     ## waterfall: these bars show the running total (a
                           ## value there sets it: an opening balance)
    totalLabel*: string = "Total"  ## waterfall: the last bar ("": none)
    palette*: seq[Color]   ## the series' colors (empty: `chartColors`)
    hole*: float = 0.56    ## donut: the hole, a share of the radius
    frame*: bool = true    ## the white field with its border around it
    key*: string           ## tells apart two charts with the same title

  ChartEvent* = object
    ## What happened to a chart this frame.
    clicked*: bool         ## a bar, point or slice was clicked (or Enter)
    series*, index*: int   ## the one clicked, else the one under the mouse
                           ## (-1: none; -1 series: all series at `index`)
    hidden*: int           ## a legend entry was clicked (it is hidden or
                           ## shown again): its series (or slice), else -1

const
  chartColors* = [color(0, 0, 255), color(255, 0, 0), color(0, 128, 0),
                  color(255, 0, 255), color(0, 128, 128), color(128, 128, 0),
                  color(128, 0, 0), color(0, 0, 128), color(128, 0, 128),
                  color(255, 128, 0)]
    ## Series colors from the VGA palette (the default).
  businessColors* = [color(31, 78, 121), color(229, 115, 26), color(46, 139, 87),
                     color(197, 48, 48), color(110, 74, 156), color(214, 162, 25),
                     color(23, 140, 150), color(120, 120, 120), color(150, 90, 50),
                     color(90, 150, 210)]
    ## Quieter colors for reports (`ChartOpts.palette = @businessColors`).
  upColor = color(46, 139, 87)
  downColor = color(197, 48, 48)
  totalColor = color(31, 78, 121)
  MaxPoints = 100_000      ## more values than this are left out (drawing time)

# ---- series ---------------------------------------------------------------------------------------

proc series*(name: string; values: openArray[float]; color = Color()): Series =
  ## A series of values, one per label.
  Series(name: name, values: @values, color: color)

proc lineSeries*(name: string; values: openArray[float]; color = Color()): Series =
  ## A series a combo chart draws as a line on its right axis.
  Series(name: name, values: @values, color: color, asLine: true)

proc xySeries*(name: string; xs, ys: openArray[float]; sizes: openArray[float] = [];
               color = Color()): Series =
  ## Points for scatter and bubble charts.
  Series(name: name, xs: @xs, values: @ys, sizes: @sizes, color: color)

proc ohlcSeries*(name: string; opens, highs, lows, closes: openArray[float];
                 color = Color()): Series =
  ## Prices for candlesticks.
  Series(name: name, opens: @opens, highs: @highs, lows: @lows, values: @closes,
         color: color)

# ---- numbers ----------------------------------------------------------------------------------------

proc ok(v: float): bool {.inline.} = v == v and abs(v) <= 1e300
  ## A value that can be drawn (not NaN, not infinite or absurdly large).

proc iround(v: float): int {.inline.} =
  ## A pixel position: rounded, kept sane (NaN: 0).
  if v != v: 0 else: int(round(clamp(v, -1e6, 1e6)))

proc val(s: Series; i: int): float {.inline.} =
  if i >= 0 and i < s.values.len and i < MaxPoints and ok(s.values[i]): s.values[i] else: NaN

proc at(s: seq[float]; i: int): float {.inline.} =
  if i >= 0 and i < s.len and ok(s[i]): s[i] else: NaN

proc compact*(v: float): string =
  ## 1250 -> "1.3K", 2500000 -> "2.5M", 12 -> "12".
  let a = abs(v)
  if not ok(v): (if v != v: "-" elif v > 0: "inf" else: "-inf")
  elif a >= 1e12: formatFloat(v / 1e12, ffDecimal, 1) & "T"
  elif a >= 1e9: formatFloat(v / 1e9, ffDecimal, 1) & "B"
  elif a >= 1e6: formatFloat(v / 1e6, ffDecimal, 1) & "M"
  elif a >= 1e4: $iround((v / 1e3)) & "K"
  elif a >= 1e3: formatFloat(v / 1e3, ffDecimal, 1) & "K"
  elif v == round(v): $int(v)
  else: formatFloat(v, ffDecimal, 1)

proc fmtValue*(v: float; f = NumFormat()): string =
  ## `v` written as `f` says: `fmtValue(1234.5, NumFormat(prefix: "$"))` is
  ## "$1,234.50".
  if v != v: return "-"
  if abs(v) > 1e300: return (if v > 0: "inf" else: "-inf")
  var x = if f.percent: v * 100 else: v
  var s: string
  if abs(x) >= 1e15:
    s = formatFloat(x, ffScientific, 2)
  elif f.short and abs(x) >= 1000:
    let (d, u) = if abs(x) >= 1e12: (1e12, "T") elif abs(x) >= 1e9: (1e9, "B")
                 elif abs(x) >= 1e6: (1e6, "M") else: (1e3, "K")
    let y = x / d
    let dec = if f.decimals >= 0: f.decimals elif abs(y) >= 100 or y == round(y): 0 else: 1
    s = formatFloat(y, ffDecimal, dec)
    if s.endsWith('.'): s.setLen(s.len - 1)
    s.add u
  else:
    let dec = if f.decimals >= 0: min(f.decimals, 9)
              elif x == round(x): 0
              else: 2
    let k = pow(10.0, float(dec))
    if abs(x) * k < 1e15: x = round(x * k) / k     # (halves up, as people round)
    s = formatNumber(x, dec, f.thousands)
  f.prefix & s & (if f.percent: "%" else: "") & f.suffix

proc stepDecimals(step: float): int =
  ## How many decimals the numbers of an axis with this step need.
  var d = 0
  var s = abs(step)
  if s <= 0 or s != s: return 0
  while d < 6 and abs(s - round(s)) > 1e-6 * max(1.0, s):
    s *= 10
    inc d
  d

proc niceStep(span: float; ticks: int): float =
  let raw = span / max(1, ticks).float
  let mag = pow(10.0, floor(log10(max(raw, 1e-300))))
  let f = raw / mag
  (if f <= 1: 1.0 elif f <= 2: 2.0 elif f <= 5: 5.0 else: 10.0) * mag

proc niceRange*(lo, hi: float; ticks = 5): tuple[lo, hi, step: float] =
  ## Round axis ends and a 1, 2 or 5 step around `lo` .. `hi`.
  var a = lo
  var b = hi
  if not ok(a) and not ok(b): return (0.0, 1.0, 0.2)
  if not ok(a): a = b
  if not ok(b): b = a
  if b < a: swap(a, b)
  a = clamp(a, -1e299, 1e299)
  b = clamp(b, -1e299, 1e299)
  if b - a <= abs(b) * 1e-12 or b == a:
    if a == 0: b = 1
    elif a > 0:
      a = 0
    else:
      b = 0
  let step = niceStep(b - a, max(1, ticks))
  var x0 = floor(a / step) * step
  var x1 = ceil(b / step) * step
  if x1 <= x0: x1 = x0 + step
  (x0, x1, step)

proc toNumber*(s: string; v: var float): bool =
  ## Reads a number the way people write them in tables: "1,234.50",
  ## "$1,234", "12%", "(450)" for -450, "1.234,5" (a decimal comma), with
  ## Arabic-Indic digits, a Unicode minus, spaces. False when it is not one.
  var t = ""
  var neg = false
  for r in s.runes:
    let c = int(r)
    if c in 0x0660 .. 0x0669: t.add char(ord('0') + c - 0x0660)
    elif c in 0x06F0 .. 0x06F9: t.add char(ord('0') + c - 0x06F0)
    elif c == 0x066B: t.add '.'                     # Arabic decimal separator
    elif c == 0x066C: t.add ','                     # Arabic thousands separator
    elif c == 0x2212: t.add '-'
    elif c < 128: t.add char(c)
  t = t.strip
  if t.len == 0 or t.len > 64: return false
  if t[0] == '(' and t[^1] == ')':
    neg = true
    t = t[1 .. ^2].strip
  # what is not part of the number at the ends: currency signs, %, units
  var a = 0
  var b = t.high
  while a <= b and t[a] notin {'0'..'9', '-', '+', '.', ','}: inc a
  while b >= a and t[b] notin {'0'..'9', '.'}: dec b
  if a > b: return false
  t = t[a .. b].strip
  if t.len == 0: return false
  let commas = t.count(',')
  let dots = t.count('.')
  if commas > 0 and dots > 0:
    # the last of them is the decimal point
    if t.rfind(',') > t.rfind('.'):
      t = t.replace(".", "").replace(",", ".")
    else: t = t.replace(",", "")
  elif commas == 1 and dots == 0:
    let after = t.len - 1 - t.find(',')
    if after != 3: t = t.replace(",", ".")        # "1,5": a decimal comma
    else: t = t.replace(",", "")
  else: t = t.replace(",", "")
  t = t.replace(" ", "")
  try:
    var x = parseFloat(t)
    if neg: x = -x
    if x != x: return false
    v = x
    true
  except ValueError: false

# ---- CSV tables ------------------------------------------------------------------------------------

type DataTable* = object
  ## A table read from CSV text: its header row and its rows of cells.
  headers*: seq[string]    ## the first row's cells: the columns' names
  rows*: seq[seq[string]]  ## the other rows, each its cells as text
  error*: string           ## why reading failed ("" when it did not)

const
  MaxCsvBytes = 64 shl 20
  MaxCsvCells = 4_000_000
  MaxCsvCols = 1024
  MaxCellLen = 1 shl 16

proc parseCsv*(text: string; sep = '\0'; header = true): DataTable =
  ## Reads CSV text: fields separated by `sep` (`'\0'`: `,`, `;` or tab,
  ## whichever the first line has most of), quoted fields with `""` and
  ## line breaks in them, CRLF or LF lines, a byte-order mark. The first
  ## row is the header (`header` false, or a first row of numbers only: the
  ## columns are named "Column 1"...). Huge inputs are cut short.
  var s = text
  if s.len > MaxCsvBytes:
    s.setLen(MaxCsvBytes)
    result.error = "the file is too big: only its start is read"
  var i = if s.startsWith("\xEF\xBB\xBF"): 3 else: 0
  var d = sep
  if d == '\0':
    var counts = [0, 0, 0]
    var q = false
    var k = i
    while k < s.len and (q or s[k] notin {'\n', '\r'}):
      if s[k] == '"': q = not q
      elif not q:
        case s[k]
        of ',': inc counts[0]
        of ';': inc counts[1]
        of '\t': inc counts[2]
        else: discard
      inc k
    d = ','
    if counts[1] > counts[0] and counts[1] >= counts[2]: d = ';'
    elif counts[2] > counts[0] and counts[2] > counts[1]: d = '\t'
  var rows: seq[seq[string]]
  var row: seq[string]
  var cell = ""
  var cells = 0
  var quoted = false
  var any = false                     # something on this line
  template endCell() =
    if row.len < MaxCsvCols: row.add cell
    cell = ""
    inc cells
  template endRow() =
    if any or row.len > 0 or cell.len > 0:
      endCell()
      rows.add row
    row = @[]
    any = false
  while i < s.len and cells < MaxCsvCells:
    let c = s[i]
    if quoted:
      if c == '"':
        if i + 1 < s.len and s[i + 1] == '"':
          if cell.len < MaxCellLen: cell.add '"'
          inc i
        else: quoted = false
      elif cell.len < MaxCellLen: cell.add c
    elif c == '"' and cell.strip.len == 0:
      quoted = true
      cell = ""
      any = true
    elif c == d:
      endCell()
      any = true
    elif c == '\n' or c == '\r':
      endRow()
      if c == '\r' and i + 1 < s.len and s[i + 1] == '\n': inc i
    else:
      if cell.len < MaxCellLen: cell.add c
      any = true
    inc i
  if cells >= MaxCsvCells and result.error.len == 0:
    result.error = "too many cells: only the first " & $MaxCsvCells & " are read"
  endRow()
  for r in rows.mitems:
    for c in r.mitems: c = c.strip(leading = false, chars = {'\r'})
  var useHeader = header and rows.len > 0
  if useHeader:
    var allNum = rows[0].len > 0
    var v: float
    for c in rows[0]:
      if not toNumber(c, v): allNum = false
    if allNum: useHeader = false
  var width = 0
  for r in rows: width = max(width, r.len)
  if useHeader:
    result.headers = rows[0]
    rows.delete(0)
  for k in result.headers.len ..< width: result.headers.add "Column " & $(k + 1)
  for k, h in result.headers.mpairs:
    if h.strip.len == 0: h = "Column " & $(k + 1)
  result.rows = rows

proc readCsv*(path: string; sep = '\0'; header = true): DataTable =
  ## The CSV file `path` as a table (see `parseCsv`); `error` tells why
  ## when it cannot be read (it never raises).
  try:
    var f: File
    if not open(f, path): return DataTable(error: "cannot open " & path)
    defer: f.close()
    let size = f.getFileSize
    var data = newString(int(min(size, MaxCsvBytes.int64)))
    if data.len > 0: data.setLen(f.readBuffer(addr data[0], data.len))
    result = parseCsv(data, sep, header)
    if size > MaxCsvBytes: result.error = "the file is too big: only its start is read"
  except CatchableError as e:
    result = DataTable(error: "cannot read " & path & ": " & e.msg)

proc csvField*(s: string; sep = ','): string =
  ## `s` as one CSV field: in quotes (its `"` doubled) when it has `sep`,
  ## a quote, a line break or spaces at either end; as it is otherwise.
  var quote = s.len > 0 and (s[0] == ' ' or s[^1] == ' ')
  for c in s:
    if c == sep or c in {'"', '\n', '\r'}:
      quote = true
      break
  if not quote: return s
  result = "\""
  for c in s:
    if c == '"': result.add "\"\""
    else: result.add c
  result.add '"'

proc csvLine*(cells: openArray[string]; sep = ','): string =
  ## One CSV line (no line break at its end) of `cells`, each quoted as
  ## `csvField` says.
  for i, c in cells:
    if i > 0: result.add sep
    result.add csvField(c, sep)

proc toCsv*(t: DataTable; sep = ','; header = true): string =
  ## The table as CSV text: the headers first (`header` false: without
  ## them), then each row; CRLF line ends, which every spreadsheet reads.
  ## `parseCsv` reads it back to the same table.
  if header and t.headers.len > 0: result.add csvLine(t.headers, sep) & "\r\n"
  for r in t.rows: result.add csvLine(r, sep) & "\r\n"

proc writeCsv*(path: string; t: DataTable; sep = ','; header = true): bool =
  ## Saves the table to the CSV file `path` (see `toCsv`); false when it
  ## cannot be written (it never raises).
  try:
    writeFile(path, toCsv(t, sep, header))
    true
  except CatchableError: false

proc colIndex*(t: DataTable; name: string): int =
  ## The column called `name` (case does not matter), -1 if none.
  for i, h in t.headers:
    if cmpIgnoreCase(h.strip, name.strip) == 0: return i
  -1

proc cell*(t: DataTable; row, col: int): string =
  ## A cell ("" when it is not there).
  if row >= 0 and row < t.rows.len and col >= 0 and col < t.rows[row].len:
    t.rows[row][col]
  else: ""

proc column*(t: DataTable; col: int): seq[float] =
  ## The numbers of a column (NaN where a cell is not one).
  for r in 0 ..< t.rows.len:
    var v = NaN
    if not toNumber(t.cell(r, col), v): v = NaN
    result.add v

proc column*(t: DataTable; name: string): seq[float] =
  ## The numbers of the column called `name` (empty if there is none).
  let i = t.colIndex(name)
  if i >= 0: t.column(i) else: @[]

proc labels*(t: DataTable; col: int): seq[string] =
  ## The cells of a column as text (the labels of a chart).
  for r in 0 ..< t.rows.len: result.add t.cell(r, col).strip

proc labels*(t: DataTable; name: string): seq[string] =
  ## The cells of the column called `name` as text (none when there is no
  ## such column).
  let i = t.colIndex(name)
  if i >= 0: t.labels(i) else: @[]

proc numericColumns*(t: DataTable): seq[int] =
  ## The columns whose cells are (mostly) numbers.
  for c in 0 ..< t.headers.len:
    var n, num = 0
    var v: float
    for r in 0 ..< t.rows.len:
      let s = t.cell(r, c).strip
      if s.len == 0: continue
      inc n
      if toNumber(s, v): inc num
    if n > 0 and num * 10 >= n * 8: result.add c

# ---- saving a chart as a picture -------------------------------------------------------------------

type BlitRelay = proc (pixels: ptr UncheckedArray[uint32]; w, h: int; dst: Rect;
                       format: RGBAFormat): bool {.nimcall.}

var cap: tuple[want, armed, done, ok: bool; r: Rect; path: string; frames: int;
               buf: seq[uint32]; w: int; seen: seq[bool]; blit, draw: BlitRelay]

proc keep(pixels: ptr UncheckedArray[uint32]; w, h: int; dst: Rect) =
  ## Copies rows the screen is sent into the capture.
  if w <= 0 or h <= 0 or w > 32768 or h > 32768: return
  let y0 = dst.y * unitPx
  if y0 < 0 or y0 + h > 32768: return
  if cap.w != w:
    cap.w = w
    cap.buf.setLen(0)
    cap.seen.setLen(0)
  if cap.buf.len < (y0 + h) * w: cap.buf.setLen((y0 + h) * w)
  if cap.seen.len < y0 + h: cap.seen.setLen(y0 + h)
  for y in 0 ..< h:
    copyMem(addr cap.buf[(y0 + y) * w], addr pixels[y * w], w * sizeof(uint32))
    cap.seen[y0 + y] = true

proc capBlit(pixels: ptr UncheckedArray[uint32]; w, h: int; dst: Rect;
             format: RGBAFormat): bool {.nimcall.} =
  keep(pixels, w, h, dst)
  if cap.blit != nil: cap.blit(pixels, w, h, dst, format) else: false

proc capDraw(pixels: ptr UncheckedArray[uint32]; w, h: int; dst: Rect;
             format: RGBAFormat): bool {.nimcall.} =
  keep(pixels, w, h, dst)
  if cap.draw != nil: cap.draw(pixels, w, h, dst, format) else: false

proc capHook() {.nimcall.} =
  if cap.want and not cap.armed:
    # this frame is drawn whole, and the rows sent are kept
    cap.armed = true
    cap.frames = 0
    cap.buf.setLen(0)
    cap.seen.setLen(0)
    cap.w = 0
    cap.blit = drawRelays.blitRGBA
    cap.draw = drawRelays.drawRGBA
    if drawRelays.blitRGBA != nil: drawRelays.blitRGBA = capBlit
    if drawRelays.drawRGBA != nil: drawRelays.drawRGBA = capDraw
    invalidate()
  elif cap.armed:
    inc cap.frames
    let k = pxScale
    let d = rect(cap.r.x * k, cap.r.y * k, cap.r.w * k, cap.r.h * k)
    var all = d.w > 0 and d.h > 0 and cap.w > 0
    if all:
      for y in d.y ..< d.y + d.h:
        if y < 0 or y >= cap.seen.len or not cap.seen[y]:
          all = false
          break
    if all or cap.frames > 30:
      drawRelays.blitRGBA = cap.blit
      drawRelays.drawRGBA = cap.draw
      cap.armed = false
      cap.want = false
      cap.done = true
      cap.ok = false
      if all:
        let x0 = clamp(d.x, 0, cap.w)
        let x1 = clamp(d.x + d.w, 0, cap.w)
        if x1 > x0:
          let b = newBitmap(x1 - x0, d.h)
          for y in 0 ..< d.h:
            for x in 0 ..< b.w:
              b.px[y * b.w + x] = cap.buf[(d.y + y) * cap.w + x0 + x] or 0xFF000000'u32
          cap.ok = savePng(b, cap.path)
      cap.buf = @[]
      cap.seen = @[]

beginFrameHooks.add capHook

proc exportPng*(r: Rect; path: string) =
  ## Saves the part `r` of the window -- a chart: `ui.lastRect` right after
  ## it -- as the PNG file `path`, as it is drawn on the next frame (without
  ## tooltips); `exportResult` tells when it is written.
  if r.w <= 0 or r.h <= 0: return
  cap.want = true
  cap.done = false
  cap.ok = false
  cap.r = r
  cap.path = path
  ui.redraw = true

proc exportResult*(): tuple[done, ok: bool; path: string] =
  ## Whether the last `exportPng` is done, and whether it was written.
  (cap.done, cap.ok, cap.path)

proc exporting(): bool {.inline.} = cap.armed

# ---- drawing helpers -------------------------------------------------------------------------------

var hits: seq[tuple[r: Rect; s, i: int]]
  ## Where the bars, points and slices of the chart being drawn are.

type PieGeo = object
  on: bool
  cx, cy, r0, r1: float
  a0: float
  ends: seq[float]          ## where each slice ends (angles), NaN: hidden
  idx: seq[int]

var pie: PieGeo
var histEdges: seq[float]

proc palColor(o: ChartOpts; i: int): Color =
  if o.palette.len > 0: o.palette[i mod o.palette.len]
  else: chartColors[i mod chartColors.len]

proc seriesColor(o: ChartOpts; s: Series; k: int): Color =
  if s.color.a != 0: s.color else: palColor(o, k)

proc pointColor(o: ChartOpts; s: Series; k, i: int): Color =
  if i < s.colors.len and s.colors[i].a != 0: s.colors[i] else: seriesColor(o, s, k)

proc lum(c: Color): int = (299 * int(c.r) + 587 * int(c.g) + 114 * int(c.b)) div 1000

proc textOn(c: Color): Color =
  if lum(c) > 150: color(0, 0, 0) else: color(255, 255, 255)

proc gridColor(): Color = mixColor(th.field, th.fieldText, 0.13)

proc darker(c: Color): Color = mixColor(c, color(0, 0, 0), 0.35)
proc lighter(c: Color): Color = mixColor(c, color(255, 255, 255), 0.3)

proc shown(hidden, k: int): bool {.inline.} = k >= 30 or (hidden and (1 shl k)) == 0

proc fitText(s: string; maxW: int; st = TextStyle()): string =
  if maxW <= 4: "" elif textWidth(s, st) <= maxW: s else: ellipsize(s, maxW, st)

proc centerText(cx, y: int; s: string; c: Color; st = TextStyle()) =
  text(cx - textWidth(s, st) div 2, y, s, c, st)

proc noData(r: Rect) =
  let s = "No data"
  centerText(r.x + r.w div 2, r.y + (r.h - FontH) div 2, s, th.gray)

type Axis = object
  lo, hi, step: float
  p0, p1: float            ## the pixels of `lo` and `hi`

proc pos(a: Axis; v: float): float =
  ## The pixel of `v` (kept within a sane distance of the plot).
  let r = if a.hi == a.lo or a.hi != a.hi or a.lo != a.lo: a.p0
          else: a.p0 + (clamp(v, -1e300, 1e300) - a.lo) / (a.hi - a.lo) * (a.p1 - a.p0)
  if r != r: a.p0 else: clamp(r, -100_000.0, 100_000.0)

proc ipos(a: Axis; v: float): int = iround((pos(a, v)))

proc tickCount(a: Axis): int =
  if a.step <= 0: 0 else: clamp(iround(((a.hi - a.lo) / a.step)), 0, 60)

proc tickText(a: Axis; i: int; f: NumFormat): string =
  var g = f
  if g.decimals < 0:
    g.decimals = stepDecimals(a.step * (if f.percent: 100.0 else: 1.0))
  fmtValue(a.lo + a.step * float(i), g)

proc axisWidth(a: Axis; f: NumFormat): int =
  for i in 0 .. a.tickCount: result = max(result, textWidth(tickText(a, i, f)))

proc yAxis(a: Axis; plot: Rect; f: NumFormat; right, grid: bool) =
  ## Numbers along a vertical axis (and light lines across the plot).
  for i in 0 .. a.tickCount:
    let v = a.lo + a.step * float(i)
    let y = a.ipos(v)
    if y < plot.y - 1 or y > plot.y + plot.h + 1: continue
    let s = tickText(a, i, f)
    if right: text(plot.x + plot.w + dp(5), y - FontH div 2, s, th.fieldText)
    else: text(plot.x - dp(5) - textWidth(s), y - FontH div 2, s, th.fieldText)
    if grid and not right and i > 0: hline(plot.x + 1, y, plot.w - 1, gridColor())

proc xAxis(a: Axis; plot: Rect; f: NumFormat; grid: bool) =
  ## Numbers along a horizontal axis (and light lines up the plot).
  var lastEnd = -100000
  for i in 0 .. a.tickCount:
    let v = a.lo + a.step * float(i)
    let x = a.ipos(v)
    if x < plot.x - 1 or x > plot.x + plot.w + 1: continue
    let s = tickText(a, i, f)
    let tw = textWidth(s)
    if x - tw div 2 > lastEnd + dp(6):
      text(x - tw div 2, plot.y + plot.h + dp(4), s, th.fieldText)
      lastEnd = x + tw div 2
    if grid and i > 0: vline(x, plot.y, plot.h, gridColor())

proc catLabels(labels: openArray[string]; n: int; plot: Rect; slot: float) =
  ## The labels under the slots, every k-th when they do not fit.
  if n <= 0 or labels.len == 0: return
  var widest = 0
  for i in 0 ..< min(min(n, labels.len), 400): widest = max(widest, textWidth(labels[i]))
  # every label when each slot has room for some of it (shortened: "Muscat Ho..."
  # says more than nothing); else every k-th
  let k = if slot >= float(dp(52)): 1
          else: max(1, int(ceil(float(min(widest, dp(110)) + dp(6)) / max(slot, 1.0))))
  for i in countup(0, min(n, labels.len) - 1, k):
    let cx = plot.x + int(slot * (float(i) + 0.5))
    let s = fitText(labels[i], max(dp(12), int(slot * float(k)) - dp(4)))
    centerText(cx, plot.y + plot.h + dp(4), s, th.fieldText)

proc polyline(pts: openArray[(float, float)]; width: float; c: Color) =
  ## A line through the points, with round joins.
  if pts.len == 0: return
  for i in 1 ..< pts.len:
    thickLine(pts[i - 1][0], pts[i - 1][1], pts[i][0], pts[i][1], width, c)
  if width > 1.6:
    for i in 1 ..< pts.len - 1: disc(pts[i][0], pts[i][1], width / 2, c)

proc thinned(pts: seq[(float, float)]): seq[(float, float)] =
  ## Many more points than pixels across: per pixel column only the first,
  ## lowest, highest and last (the line looks the same, drawn much faster).
  if pts.len < 4096: return pts
  var i = 0
  while i < pts.len:
    let col = floor(pts[i][0])
    var j = i
    var lo = i
    var hi = i
    while j < pts.len and floor(pts[j][0]) == col:
      if pts[j][1] < pts[lo][1]: lo = j
      if pts[j][1] > pts[hi][1]: hi = j
      inc j
    result.add pts[i]
    for k in [min(lo, hi), max(lo, hi)]:
      if k != i and k != j - 1: result.add pts[k]
    if j - 1 != i: result.add pts[j - 1]
    i = j

proc smoothed(pts: seq[(float, float)]): seq[(float, float)] =
  ## A Catmull-Rom curve through the points.
  if pts.len < 3: return pts
  for i in 0 ..< pts.len - 1:
    let p0 = pts[max(0, i - 1)]
    let p1 = pts[i]
    let p2 = pts[i + 1]
    let p3 = pts[min(pts.high, i + 2)]
    for k in 0 ..< 8:
      let t = float(k) / 8
      let t2 = t * t
      let t3 = t2 * t
      template cr(a, b, c, d: float): float =
        0.5 * (2 * b + (c - a) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (3 * b - a - 3 * c + d) * t3)
      result.add (cr(p0[0], p1[0], p2[0], p3[0]), cr(p0[1], p1[1], p2[1], p3[1]))
  result.add pts[^1]

proc marker(x, y, r: float; c: Color; hot: bool) =
  let rr = if hot: r * 1.6 else: r
  disc(x, y, rr, c)
  disc(x, y, rr * 0.45, th.field)

proc annulus(cx, cy, r0, r1, a0, a1: float; c: Color) =
  ## A slice of a ring (a donut's piece, a gauge's band).
  if a1 <= a0 or r1 <= 0: return
  if r0 <= 0.5:
    pieSlice(cx, cy, r1, a0, a1, c)
    return
  var pts: seq[(float, float)]
  let n = clamp(int((a1 - a0) * r1 * float(pxScale) * 0.15) + 2, 2, 240)
  for i in 0 .. n:
    let t = a0 + (a1 - a0) * float(i) / float(n)
    pts.add (cx + r1 * cos(t), cy + r1 * sin(t))
  for i in countdown(n, 0):
    let t = a0 + (a1 - a0) * float(i) / float(n)
    pts.add (cx + r0 * cos(t), cy + r0 * sin(t))
  polygon(pts, c)

# ---- the kinds of chart --------------------------------------------------------------------------

proc catCount(labels: openArray[string]; ser: openArray[Series]): int =
  result = labels.len
  for s in ser: result = max(result, s.values.len)
  result = min(result, MaxPoints)

proc linesOf(kind: ChartKind; ser: openArray[Series]): seq[bool] =
  ## Which series a combo chart draws as lines.
  result = newSeq[bool](ser.len)
  if kind == chLine or kind == chArea or kind == chStackedArea:
    for x in result.mitems: x = true
  elif kind == chCombo:
    var any = false
    for i, s in ser:
      result[i] = s.asLine
      any = any or s.asLine
    if not any and ser.len > 1: result[^1] = true

proc categoryChart(kind: ChartKind; labels: openArray[string]; ser: openArray[Series];
                   o: ChartOpts; area: Rect; hidden: int; hot: (int, int)) =
  ## Bars, stacks, lines, areas, combos, waterfalls, candles.
  let n = catCount(labels, ser)
  if n == 0:
    noData(area)
    return
  let isLine = linesOf(kind, ser)
  let horiz = kind == chBarH
  var anyShown = false
  for k in 0 ..< ser.len:
    if shown(hidden, k): anyShown = true
  if not anyShown and kind notin {chWaterfall, chCandle}:
    noData(area)
    return
  # the ranges of the two value axes
  var lo, hi = NaN
  var lo2, hi2 = NaN
  template take(v: float; second = false) =
    if ok(v):
      if second:
        lo2 = (if lo2 != lo2: v else: min(lo2, v))
        hi2 = (if hi2 != hi2: v else: max(hi2, v))
      else:
        lo = (if lo != lo: v else: min(lo, v))
        hi = (if hi != hi: v else: max(hi, v))
  var running: seq[float]               # waterfall: the totals after each bar
  let totalBar = kind == chWaterfall and o.totalLabel.len > 0
  case kind
  of chStacked, chStackedArea:
    for i in 0 ..< n:
      var up, down = 0.0
      for k, s in ser:
        if not shown(hidden, k): continue
        let v = s.val(i)
        if ok(v):
          if v >= 0: up += v else: down += v
      take(up)
      take(down)
    take(0.0)
  of chStacked100:
    lo = 0
    hi = 100
  of chWaterfall:
    var run = 0.0
    take(0.0)
    let s = if ser.len > 0: ser[0] else: Series()
    for i in 0 ..< n:
      let v = s.val(i)
      if i in o.totalAt:
        if ok(v): run = v                # an opening balance, a subtotal given
      elif ok(v): run += v
      running.add run
      take(run)
    if totalBar: take(run)
  of chCandle:
    if ser.len > 0:
      let s = ser[0]
      for i in 0 ..< n:
        take(s.lows.at(i))
        take(s.highs.at(i))
        take(s.opens.at(i))
        take(s.val(i))
  else:
    for k, s in ser:
      if not shown(hidden, k): continue
      for i in 0 ..< min(n, s.values.len): take(s.val(i), kind == chCombo and isLine[k])
    if kind in {chBar, chBarH, chArea, chCombo}: take(0.0)
    if kind == chCombo:
      var anyLine = false
      for k in 0 ..< ser.len:
        if isLine[k] and shown(hidden, k): anyLine = true
      if not anyLine: (lo2, hi2) = (lo, hi)
    if kind == chLine and lo == lo and lo > 0 and lo <= hi / 3: take(0.0)
  if ok(o.lo): lo = o.lo
  if ok(o.hi): hi = o.hi
  # the plot: room for the axis numbers and the labels
  let lh = FontH + dp(6)
  var plot = area
  var vAxis, vAxis2: Axis
  if horiz:
    var widest = 0
    for i in 0 ..< min(min(n, labels.len), 400): widest = max(widest, textWidth(labels[i]))
    let lw = min(widest, area.w * 2 div 5) + dp(8)
    plot = rect(area.x + lw, area.y + dp(2), area.w - lw - dp(10),
                area.h - lh - dp(2) - (if o.xTitle.len > 0: FontH else: 0))
    let (a, b, st) = niceRange(lo, hi, clamp(plot.w div dp(70), 2, 8))
    vAxis = Axis(lo: a, hi: b, step: st, p0: float(plot.x), p1: float(plot.x + plot.w))
  else:
    let top = area.y + FontH div 2 + (if o.dataLabels: FontH else: 0)   # (room for the labels)
    let bottom = area.y + area.h - lh - (if o.xTitle.len > 0: FontH else: 0)
    let ticks = clamp((bottom - top) div (FontH * 2), 2, 8)
    let (a, b, st) = niceRange(lo, hi, ticks)
    vAxis = Axis(lo: a, hi: b, step: st)
    let w1 = axisWidth(vAxis, o.format) + dp(8)
    var w2 = 0
    if kind == chCombo:
      let (a2, b2, st2) = niceRange(lo2, hi2, ticks)
      vAxis2 = Axis(lo: a2, hi: b2, step: st2)
      w2 = axisWidth(vAxis2, o.format2) + dp(8)
    plot = rect(area.x + w1, top, area.w - w1 - max(w2, dp(6)), bottom - top)
    vAxis.p0 = float(plot.y + plot.h)
    vAxis.p1 = float(plot.y)
    vAxis2.p0 = vAxis.p0
    vAxis2.p1 = vAxis.p1
  if plot.w < dp(20) or plot.h < dp(16):
    noData(area)
    return
  # axes, grid, labels
  if horiz:
    xAxis(vAxis, plot, o.format, o.grid)
    let slot = float(plot.h) / float(n)
    var lastY = -100000
    for i in 0 ..< min(n, labels.len):
      let cy = plot.y + int(slot * (float(i) + 0.5))
      if cy - FontH div 2 >= lastY:
        let s = fitText(labels[i], plot.x - area.x - dp(8))
        text(plot.x - dp(5) - textWidth(s), cy - FontH div 2, s, th.fieldText)
        lastY = cy + FontH div 2
  else:
    yAxis(vAxis, plot, o.format, false, o.grid)
    if kind == chCombo: yAxis(vAxis2, plot, o.format2, true, false)
    let nn = if totalBar: n + 1 else: n
    var labs = @labels
    if totalBar:
      while labs.len < n: labs.add ""
      labs.setLen(n)
      labs.add o.totalLabel
    catLabels(labs, nn, plot, float(plot.w) / float(nn))
  if o.xTitle.len > 0:
    centerText(plot.x + plot.w div 2, area.y + area.h - FontH, o.xTitle, th.gray)
  if o.yTitle.len > 0 and not horiz:
    text(area.x, area.y - FontH div 2 + 1, o.yTitle, th.gray)
  pushClip(rect(plot.x - dp(8), area.y, plot.w + dp(16), plot.y + plot.h + dp(9) - area.y))
  let nn = if totalBar: n + 1 else: n
  let slot = (if horiz: plot.h.float else: plot.w.float) / float(nn)
  let zero = vAxis.pos(clamp(0.0, vAxis.lo, vAxis.hi))
  let small = style(size = 0.85)
  proc barRect(i: int; a, b: float; sub, subs: int; widthShare = 0.72): Rect =
    ## The rectangle of a bar from value a to b in slot i (sub of subs).
    let gw = slot * widthShare
    let bw = max(1.0, gw / float(max(1, subs)))
    let s0 = slot * float(i) + (slot - gw) / 2 + bw * float(sub)
    let p = vAxis.pos(a)
    let q = vAxis.pos(b)
    if horiz:
      let y0 = float(plot.y) + s0
      rect(iround((min(p, q))), iround((y0)), max(1, iround((abs(q - p)))),
           max(1, iround((y0 + bw)) - iround((y0))))
    else:
      let x0 = float(plot.x) + s0
      rect(iround((x0)), iround((min(p, q))), max(1, iround((x0 + bw)) - iround((x0))),
           max(1, iround((abs(q - p)))))
  proc drawBar(br: Rect; c: Color; isHot: bool) =
    let cc = if isHot: lighter(c) else: c
    fill(br, cc)
    if br.w >= 4 and br.h >= 3: box(br, darker(c))
  proc label(br: Rect; v: float; f: NumFormat; inside = false) =
    let s = fmtValue(v, f)
    let tw = textWidth(s, small)
    if horiz:
      if inside:
        if tw + dp(4) < br.w: text(br.x + (br.w - tw) div 2, br.y + (br.h - lineHeight(small)) div 2, s, th.selectText, small)
      else: text(br.x + br.w + dp(3), br.y + (br.h - lineHeight(small)) div 2, s, th.fieldText, small)
    else:
      if inside:
        if br.h > lineHeight(small) and tw + 2 < br.w:
          text(br.x + (br.w - tw) div 2, br.y + (br.h - lineHeight(small)) div 2, s, th.selectText, small)
      else:
        let y = if v < 0: br.y + br.h + 1 else: br.y - lineHeight(small) - 1
        text(br.x + (br.w - tw) div 2, y, s, th.fieldText, small)
  case kind
  of chBar, chBarH, chCombo:
    var bars: seq[int]
    for k in 0 ..< ser.len:
      if shown(hidden, k) and not isLine[k]: bars.add k
    for i in 0 ..< n:
      for j, k in bars:
        let v = ser[k].val(i)
        if not ok(v): continue
        let br = barRect(i, 0.0, v, j, bars.len)
        let c = pointColor(o, ser[k], k, i)
        drawBar(br, c, hot == (k, i) or hot == (-1, i))
        hits.add (br, k, i)
        if o.dataLabels: label(br, v, o.format)
  of chStacked, chStacked100:
    for i in 0 ..< n:
      var total = 0.0
      if kind == chStacked100:
        for k, s in ser:
          if shown(hidden, k):
            let v = s.val(i)
            if ok(v) and v > 0: total += v
      var up, down = 0.0
      for k, s in ser:
        if not shown(hidden, k): continue
        var v = s.val(i)
        if not ok(v): continue
        if kind == chStacked100:
          v = if total > 0 and v > 0: v / total * 100 else: 0.0
        let (a, b) = if v >= 0: (up, up + v) else: (down, down + v)
        if v >= 0: up += v else: down += v
        if v == 0: continue
        let br = barRect(i, a, b, 0, 1)
        let c = pointColor(o, s, k, i)
        drawBar(br, c, hot == (k, i) or hot == (-1, i))
        hits.add (br, k, i)
        if o.dataLabels:
          label(br, v, if kind == chStacked100: NumFormat(decimals: 0, suffix: "%") else: o.format,
                inside = true)
  of chWaterfall:
    let s = if ser.len > 0: ser[0] else: Series()
    var prev = 0.0
    let up = if o.palette.len >= 3: o.palette[0] else: upColor
    let down = if o.palette.len >= 3: o.palette[1] else: downColor
    let tot = if o.palette.len >= 3: o.palette[2] else: totalColor
    for i in 0 ..< nn:
      let isTotal = i >= n or i in o.totalAt
      let now = if i < n: running[i] else: (if n > 0: running[^1] else: 0.0)
      let (a, b) = if isTotal: (0.0, now) else: (prev, now)
      let v = if isTotal: now else: s.val(i)
      let br = barRect(i, a, b, 0, 1, 0.66)
      if isTotal or ok(v):
        let c = if isTotal: tot elif b >= a: up else: down
        drawBar(br, c, hot == (0, i) or hot == (-1, i))
        hits.add (br, 0, i)
        if o.dataLabels: label(br, (if isTotal: now else: v), o.format)
      # the line to the next bar
      if i + 1 < nn:
        let y = vAxis.ipos(now)
        let x0 = br.x + br.w
        let x1 = plot.x + int(slot * float(i + 1) + slot * 0.17)
        if x1 > x0: hline(x0, y, x1 - x0, th.gray)
      prev = now
  of chCandle:
    if ser.len > 0:
      let s = ser[0]
      let up = if o.palette.len >= 2: o.palette[0] else: upColor
      let down = if o.palette.len >= 2: o.palette[1] else: downColor
      for i in 0 ..< n:
        let op = s.opens.at(i)
        let cl = s.val(i)
        let h = s.highs.at(i)
        let l = s.lows.at(i)
        if not ok(op) or not ok(cl): continue
        let c = if cl >= op: up else: down
        let cx = plot.x + int(slot * (float(i) + 0.5))
        if ok(h) and ok(l):
          let y0 = vAxis.ipos(max(h, l))
          let y1 = vAxis.ipos(min(h, l))
          vline(cx, y0, max(1, y1 - y0), darker(c))
        let br = barRect(i, op, cl, 0, 1, 0.6)
        drawBar(br, c, hot == (0, i) or hot == (-1, i))
        hits.add (rect(plot.x + int(slot * float(i)), plot.y, max(1, int(slot)), plot.h), 0, i)
  else: discard
  # lines and areas
  if kind in {chLine, chArea, chStackedArea, chCombo}:
    let width = max(1.0, dpf(2.0))
    let mr = dpf(3.2)
    var base = newSeq[float](n)          # stacked areas: the top of the ones below
    var order: seq[int]
    for k in 0 ..< ser.len:
      if isLine[k] and shown(hidden, k): order.add k
    # areas first (later ones over earlier ones), then the lines over them
    if kind in {chArea, chStackedArea}:
      var tops = newSeq[seq[float]](ser.len)
      for k in order:
        var pts: seq[(float, float)]
        var bottom: seq[(float, float)]
        tops[k] = newSeq[float](n)
        for i in 0 ..< n:
          let v = ser[k].val(i)
          let b = if kind == chStackedArea: base[i] else: 0.0
          let t = if ok(v): b + (if kind == chStackedArea: max(v, 0.0) else: v) else: b
          tops[k][i] = t
          let x = float(plot.x) + slot * (float(i) + 0.5)
          pts.add (x, vAxis.pos(t))
          bottom.add (x, vAxis.pos(b))
        pts = thinned(pts)
        bottom = thinned(bottom)
        if o.smooth and pts.len < 2000: pts = smoothed(pts)
        var poly = pts
        for j in countdown(bottom.high, 0): poly.add bottom[j]
        if poly.len >= 3:
          polygon(poly, mixColor(seriesColor(o, ser[k], k), th.field, 0.62))
        if kind == chStackedArea: base = tops[k]
    base = newSeq[float](n)
    for k in order:
      let c = seriesColor(o, ser[k], k)
      let axis = if kind == chCombo: vAxis2 else: vAxis
      var run: seq[(float, float)]
      var all: seq[(float, float, int)]
      template flush() =
        if run.len > 0:
          let r2 = thinned(run)
          polyline(if o.smooth and r2.len < 2000: smoothed(r2) else: r2, width, c)
          run.setLen(0)
      for i in 0 ..< n:
        let v = ser[k].val(i)
        let x = float(plot.x) + slot * (float(i) + 0.5)
        if not ok(v):
          flush()
          continue
        let t = if kind == chStackedArea: base[i] + max(v, 0.0) else: v
        if kind == chStackedArea: base[i] = t
        let y = axis.pos(t)
        run.add (x, y)
        all.add (x, y, i)
      flush()
      if o.markers and n <= 60:
        for (x, y, i) in all: marker(x, y, mr, c, hot == (k, i) or hot == (-1, i))
      elif hot[1] >= 0:
        for (x, y, i) in all:
          if hot == (k, i) or hot == (-1, i): marker(x, y, mr, c, true)
      if o.dataLabels:
        for (x, y, i) in all:
          let s = fmtValue(ser[k].val(i), if kind == chCombo: o.format2 else: o.format)
          centerText(int(x), int(y) - lineHeight(small) - dp(3), s, th.fieldText, small)
    # hovering finds a whole column of values
    if kind != chCombo:
      for i in 0 ..< n:
        hits.add (rect(plot.x + int(slot * float(i)), plot.y, max(1, int(slot)), plot.h), -1, i)
    else:
      for i in 0 ..< n:
        hits.insert((rect(plot.x + int(slot * float(i)), plot.y, max(1, int(slot)), plot.h), -1, i), 0)
    if hot[0] == -1 and hot[1] in 0 ..< n:
      let x = plot.x + int(slot * (float(hot[1]) + 0.5))
      dots(rect(x, plot.y, 1, plot.h), th.gray)
  # the zero line and the axis
  if horiz:
    vline(iround((zero)), plot.y, plot.h, th.fieldText)
  else:
    hline(plot.x, iround((zero)), plot.w, th.fieldText)
    vline(plot.x, plot.y, plot.h + 1, th.fieldText)
  popClip()

proc histogramChart(ser: openArray[Series]; o: ChartOpts; area: Rect; hot: (int, int)) =
  ## How many values fall in each bin.
  histEdges.setLen(0)
  var vals: seq[float]
  if ser.len > 0:
    for i in 0 ..< min(ser[0].values.len, MaxPoints):
      let v = ser[0].val(i)
      if ok(v): vals.add v
  if vals.len == 0:
    noData(area)
    return
  var lo = vals.min
  var hi = vals.max
  if ok(o.lo): lo = o.lo
  if ok(o.hi): hi = o.hi
  let want = if o.bins > 0: clamp(o.bins, 1, 200)
             else: clamp(int(ceil(log2(float(vals.len)) + 1)), 1, 60)
  var (a, b, step) = niceRange(lo, hi, want)
  if step <= 0: step = 1
  let nb = clamp(iround(((b - a) / step)), 1, 400)
  var counts = newSeq[float](nb)
  for v in vals:
    if v < a or v > b: continue
    let k = clamp(int(floor((v - a) / step)), 0, nb - 1)
    counts[k] += 1
  for k in 0 .. nb: histEdges.add a + step * float(k)
  # bars side by side over a number axis
  let lh = FontH + dp(6)
  let top = area.y + FontH div 2
  let bottom = area.y + area.h - lh
  let (c0, c1, cs) = niceRange(0, counts.max, clamp((bottom - top) div (FontH * 2), 2, 8))
  var yA = Axis(lo: c0, hi: c1, step: cs)
  let w1 = axisWidth(yA, NumFormat()) + dp(8)
  let plot = rect(area.x + w1, top, area.w - w1 - dp(10), bottom - top)
  if plot.w < dp(20) or plot.h < dp(16):
    noData(area)
    return
  yA.p0 = float(plot.y + plot.h)
  yA.p1 = float(plot.y)
  yAxis(yA, plot, NumFormat(), false, o.grid)
  let xA = Axis(lo: a, hi: b, step: step * float(max(1, nb div max(1, plot.w div dp(60)))),
                p0: float(plot.x), p1: float(plot.x + plot.w))
  xAxis(xA, plot, o.format, false)
  let c = palColor(o, 0)
  for k in 0 ..< nb:
    let x0 = xA.ipos(histEdges[k])
    let x1 = xA.ipos(histEdges[k + 1])
    let y = yA.ipos(counts[k])
    let br = rect(x0, y, max(1, x1 - x0), max(0, plot.y + plot.h - y))
    if br.h > 0:
      fill(br, if hot == (0, k): lighter(c) else: c)
      box(br, darker(c))
    hits.add (rect(x0, plot.y, max(1, x1 - x0), plot.h), 0, k)
  hline(plot.x, plot.y + plot.h, plot.w, th.fieldText)
  vline(plot.x, plot.y, plot.h + 1, th.fieldText)

proc pieChart(kind: ChartKind; labels: openArray[string]; ser: openArray[Series];
              o: ChartOpts; area: Rect; hidden: int; hot: (int, int)) =
  pie = PieGeo()
  if ser.len == 0:
    noData(area)
    return
  let s = ser[0]
  let n = min(s.values.len, MaxPoints)
  var total = 0.0
  for i in 0 ..< n:
    let v = s.val(i)
    if ok(v) and v > 0 and shown(hidden, i): total += v
  if total <= 0 or not ok(total):
    noData(area)
    return
  let r1 = max(4.0, float(min(area.w, area.h)) / 2 - dpf(6))
  let cx = float(area.x) + float(area.w) / 2
  let cy = float(area.y) + float(area.h) / 2
  let r0 = if kind == chDonut: r1 * clamp(o.hole, 0.1, 0.9) else: 0.0
  pie = PieGeo(on: true, cx: cx, cy: cy, r0: r0, r1: r1, a0: -PI / 2)
  var a = -PI / 2
  let small = style(size = 0.85, bold = true)
  for i in 0 ..< n:
    let v = s.val(i)
    if not ok(v) or v <= 0 or not shown(hidden, i):
      pie.ends.add NaN
      continue
    let b = a + v / total * 2 * PI
    let mid = (a + b) / 2
    let isHot = hot == (0, i)
    let off = if isHot: dpf(6) else: 0.0
    let c = pointColor(o, s, i, i)
    let x = cx + cos(mid) * off
    let y = cy + sin(mid) * off
    annulus(x, y, r0, r1, a, b, c)
    # a thin gap between the slices
    if n > 1:
      thickLine(x + cos(a) * r0, y + sin(a) * r0, x + cos(a) * r1, y + sin(a) * r1,
                max(1.0, dpf(1.2)), th.field)
    pie.ends.add b
    pie.idx.add i
    # the share in the slice when it fits
    let pct = v / total
    if b - a > 0.32 and r1 - r0 > float(FontH):
      let lr = if r0 > 0: (r0 + r1) / 2 else: r1 * 0.62
      let t = if o.dataLabels: fmtValue(v, o.format) else: $iround((pct * 100)) & "%"
      let tw = textWidth(t, small)
      text(int(x + cos(mid) * lr) - tw div 2, int(y + sin(mid) * lr) - lineHeight(small) div 2,
           t, textOn(c), small)
    a = b
  if kind == chDonut and r0 > float(FontH) * 1.5:
    let t = fmtValue(total, NumFormat(short: total >= 1e6, decimals: o.format.decimals,
                                      prefix: o.format.prefix, suffix: o.format.suffix))
    # as big as fits in the hole
    let w1 = max(1, textWidth(t, true))
    let size = clamp(min(r0 / float(FontH) / 1.8, r0 * 1.5 / float(w1)), 0.8, 2.6)
    let big = style(bold = true, size = size)
    let tw = textWidth(t, big)
    let th1 = lineHeight(big)
    text(int(cx) - tw div 2, int(cy) - th1 div 2 - FontH div 2 + 1, t, th.fieldText, big)
    let cap = fitText(if s.name.len > 0: s.name else: "Total", int(r0 * 1.6))
    centerText(int(cx), int(cy) + th1 div 2 - FontH div 2 + 1, cap, th.gray)

proc pieTarget(px, py: int): int =
  ## The slice at the point, -1 if none.
  if not pie.on: return -1
  let dx = float(px) - pie.cx
  let dy = float(py) - pie.cy
  let d = sqrt(dx * dx + dy * dy)
  if d < pie.r0 or d > pie.r1 + dpf(6): return -1
  var t = arctan2(dy, dx)
  while t < pie.a0: t += 2 * PI
  var start = pie.a0
  var k = 0
  for e in pie.ends:
    if e == e:
      if t >= start and t < e: return pie.idx[k]
      start = e
      inc k
  -1

proc scatterChart(kind: ChartKind; ser: openArray[Series]; o: ChartOpts; area: Rect;
                  hidden: int; hot: (int, int)) =
  var xlo, xhi, ylo, yhi = NaN
  var smax = 0.0
  template take(lo, hi: var float; v: float) =
    if ok(v):
      lo = (if lo != lo: v else: min(lo, v))
      hi = (if hi != hi: v else: max(hi, v))
  for k, s in ser:
    if not shown(hidden, k): continue
    for i in 0 ..< min(s.values.len, MaxPoints):
      let x = if s.xs.len > 0: s.xs.at(i) else: float(i)
      let y = s.val(i)
      if not ok(x) or not ok(y): continue
      take(xlo, xhi, x)
      take(ylo, yhi, y)
      if kind == chBubble:
        let z = s.sizes.at(i)
        if ok(z): smax = max(smax, abs(z))
  if xlo != xlo:
    noData(area)
    return
  # a little room around the points (bubbles: more)
  let padK = if kind == chBubble: 0.12 else: 0.04
  let dy = max(yhi - ylo, max(abs(yhi), 1.0) * 0.1) * padK
  let dx = max(xhi - xlo, max(abs(xhi), 1.0) * 0.1) * padK
  ylo -= dy
  yhi += dy
  xlo -= dx
  xhi += dx
  if ok(o.lo): ylo = o.lo
  if ok(o.hi): yhi = o.hi
  let lh = FontH + dp(6)
  let top = area.y + FontH div 2
  let bottom = area.y + area.h - lh - (if o.xTitle.len > 0: FontH else: 0)
  let (ra, rb, rs) = niceRange(ylo, yhi, clamp((bottom - top) div (FontH * 2), 2, 8))
  var yA = Axis(lo: ra, hi: rb, step: rs)
  let w1 = axisWidth(yA, o.format) + dp(8)
  let plot = rect(area.x + w1, top, area.w - w1 - dp(12), bottom - top)
  if plot.w < dp(20) or plot.h < dp(16):
    noData(area)
    return
  yA.p0 = float(plot.y + plot.h)
  yA.p1 = float(plot.y)
  let (qa, qb, qs) = niceRange(xlo, xhi, clamp(plot.w div dp(70), 2, 8))
  let xA = Axis(lo: qa, hi: qb, step: qs, p0: float(plot.x), p1: float(plot.x + plot.w))
  yAxis(yA, plot, o.format, false, o.grid)
  xAxis(xA, plot, NumFormat(), o.grid)
  if o.xTitle.len > 0:
    centerText(plot.x + plot.w div 2, area.y + area.h - FontH, o.xTitle, th.gray)
  if o.yTitle.len > 0: text(area.x, area.y - FontH div 2 + 1, o.yTitle, th.gray)
  hline(plot.x, plot.y + plot.h, plot.w, th.fieldText)
  vline(plot.x, plot.y, plot.h + 1, th.fieldText)
  pushClip(rect(plot.x + 1, area.y, plot.w + dp(10), plot.y + plot.h - area.y))
  let maxR = clamp(float(min(plot.w, plot.h)) / 10, dpf(8), dpf(36))
  for k, s in ser:
    if not shown(hidden, k): continue
    let c = seriesColor(o, s, k)
    for i in 0 ..< min(s.values.len, MaxPoints):
      let x = if s.xs.len > 0: s.xs.at(i) else: float(i)
      let y = s.val(i)
      if not ok(x) or not ok(y): continue
      let px = xA.pos(x)
      let py = yA.pos(y)
      let isHot = hot == (k, i)
      if kind == chBubble:
        let z = s.sizes.at(i)
        let r = if ok(z) and smax > 0: max(dpf(2), sqrt(abs(z) / smax) * maxR) else: dpf(3)
        let cc = pointColor(o, s, k, i)
        disc(px, py, r, if isHot: lighter(cc) else: mixColor(cc, th.field, 0.25))
        ring(px, py, r, max(1.0, dpf(1)), darker(cc))
        hits.add (rect(int(px - r), int(py - r), int(2 * r) + 1, int(2 * r) + 1), k, i)
      else:
        let r = if isHot: dpf(5) else: dpf(3.5)
        disc(px, py, r, pointColor(o, s, k, i))
        let hr = max(r, dpf(6))
        hits.add (rect(int(px - hr), int(py - hr), int(2 * hr) + 1, int(2 * hr) + 1), k, i)
      if o.dataLabels:
        let st = style(size = 0.8)
        centerText(int(px), int(py) - lineHeight(st) - dp(4), fmtValue(y, o.format), th.fieldText, st)
  popClip()

proc funnelChart(labels: openArray[string]; ser: openArray[Series]; o: ChartOpts;
                 area: Rect; hidden: int; hot: (int, int)) =
  if ser.len == 0:
    noData(area)
    return
  let s = ser[0]
  var idx: seq[int]
  var vmax = 0.0
  for i in 0 ..< min(s.values.len, 200):
    let v = s.val(i)
    if ok(v) and shown(hidden, i):
      idx.add i
      vmax = max(vmax, abs(v))
  if idx.len == 0 or vmax <= 0:
    noData(area)
    return
  let gap = dp(3)
  let h = (area.h - gap * (idx.len - 1)) div idx.len
  if h < 4:
    noData(area)
    return
  let first = s.val(idx[0])
  # the stages' texts in a column at the right when there is room
  # (each given a value where declared: filled only in the loop, Nim 2.2
  # took `texts = shorter` below for a first value and never freed the
  # texts it held -- a leak every frame)
  var texts = newSeqOfCap[string](idx.len)
  var shorter = newSeqOfCap[string](idx.len)
  var shortest = newSeqOfCap[string](idx.len)
  var widest = 0
  for i in idx:
    let name = if i < labels.len: labels[i] else: ""
    let share = if first != 0 and ok(first): "  " & $iround(s.val(i) / first * 100) & "%" else: ""
    let value = fmtValue(s.val(i), o.format)
    texts.add (if name.len > 0: name & ": " else: "") & value & share
    shorter.add (if name.len > 0: name & ": " else: "") & value
    shortest.add (if name.len > 0: name else: value)
    widest = max(widest, textWidth(texts[^1]))
  let side = area.w >= dp(260)
  let tw = if side: min(widest + dp(10), area.w * 9 div 20) else: 0
  if side:
    # what fits: the share, the value, or just the name
    var fitsAll, fitsValue = true
    for j in 0 ..< texts.len:
      if textWidth(texts[j]) > tw - dp(8): fitsAll = false
      if textWidth(shorter[j]) > tw - dp(8): fitsValue = false
    if not fitsAll: texts = if fitsValue: shorter else: shortest
  let fw = area.w - tw
  let cx = area.x + fw div 2
  for j, i in idx:
    let v = abs(s.val(i))
    let wTop = max(dpf(6), float(fw) * 0.94 * v / vmax)
    let nextV = if j + 1 < idx.len: abs(s.val(idx[j + 1])) else: v * 0.85
    let wBot = max(dpf(4), float(fw) * 0.94 * nextV / vmax)
    let y0 = float(area.y + j * (h + gap))
    let y1 = y0 + float(h)
    let c = pointColor(o, s, i, i)
    let cc = if hot == (0, i): lighter(c) else: c
    polygon([(float(cx) - wTop / 2, y0), (float(cx) + wTop / 2, y0),
             (float(cx) + wBot / 2, y1), (float(cx) - wBot / 2, y1)], cc)
    hits.add (rect(area.x, int(y0), area.w, h), 0, i)
    if h < FontH: continue
    let ty = int(y0) + (h - FontH) div 2
    if side:
      text(area.x + fw + dp(8), ty, fitText(texts[j], tw - dp(8)), th.fieldText)
    else:
      let t = fitText(texts[j], int(min(wTop, wBot)) - dp(6))
      centerText(cx, ty, t, textOn(c))

proc gaugeChart(ser: openArray[Series]; o: ChartOpts; area: Rect; hot: (int, int)) =
  let v = if ser.len > 0: ser[0].val(0) else: NaN
  var lo = if ok(o.lo): o.lo else: 0.0
  var hi = o.hi
  if not ok(hi):
    var top = max(if ok(v): v else: 0.0, if ok(o.target): o.target else: 0.0)
    for b in o.bands:
      if ok(b.upTo): top = max(top, b.upTo)
    hi = niceRange(lo, max(top * 1.1, lo + 1), 5).hi
  if hi <= lo: hi = lo + 1
  let below = float(FontH) * (if ok(o.target): 3.2 else: 2.3)
  let r1 = max(8.0, min(float(area.w) / 2 - dpf(8), float(area.h) - below - dpf(6)))
  let cx = float(area.x) + float(area.w) / 2
  let cy = float(area.y) + dpf(6) + r1 + max(0.0, (float(area.h) - dpf(6) - r1 - below) / 2)
  let r0 = r1 * 0.72
  proc ang(x: float): float = PI + PI * clamp((x - lo) / (hi - lo), 0.0, 1.0)
  # the bands (green, amber, red thirds when none are given)
  var bands = o.bands
  if bands.len == 0:
    bands = @[(lo + (hi - lo) * 0.6, upColor), (lo + (hi - lo) * 0.85, color(230, 170, 30)),
              (hi, downColor)]
  annulus(cx, cy, r0, r1, PI, 2 * PI, mixColor(th.face, th.field, 0.4))
  var start = lo
  for (upTo, c) in bands:
    if not ok(upTo): continue
    let e = clamp(upTo, lo, hi)
    if e > start: annulus(cx, cy, r0 + (r1 - r0) * 0.55, r1, ang(start), ang(e), c)
    start = max(start, e)
  # the value's arc
  if ok(v):
    let c = palColor(o, 0)
    annulus(cx, cy, r0, r0 + (r1 - r0) * 0.5, PI, ang(v), if hot == (0, 0): lighter(c) else: c)
  # the target
  if ok(o.target):
    let t = ang(o.target)
    thickLine(cx + cos(t) * (r0 - dpf(4)), cy + sin(t) * (r0 - dpf(4)),
              cx + cos(t) * (r1 + dpf(4)), cy + sin(t) * (r1 + dpf(4)), max(2.0, dpf(2.5)), th.fieldText)
  # the needle
  if ok(v):
    let t = ang(v)
    thickLine(cx, cy, cx + cos(t) * r1 * 0.92, cy + sin(t) * r1 * 0.92, max(2.0, dpf(2.5)), th.fieldText)
    disc(cx, cy, max(3.0, dpf(5)), th.fieldText)
  # the numbers
  let small = style(size = 0.85)
  text(int(cx - r1), int(cy) + dp(4), fmtValue(lo, o.format), th.gray, small)
  let ht = fmtValue(hi, o.format)
  text(int(cx + r1) - textWidth(ht, small), int(cy) + dp(4), ht, th.gray, small)
  let vt = fmtValue(v, o.format)
  let big = style(bold = true, size = clamp(min(r1 / float(FontH) / 3.6,
                  r1 * 1.4 / float(max(1, textWidth(vt, true)))), 1.0, 2.2))
  centerText(int(cx), int(cy) + dp(6), vt, th.fieldText, big)
  if ok(o.target):
    centerText(int(cx), int(cy) + dp(6) + lineHeight(big),
               "Target " & fmtValue(o.target, o.format), th.gray, small)
  hits.add (rect(int(cx - r1), int(cy - r1), int(2 * r1), int(r1)), 0, 0)

proc heatmapChart(labels: openArray[string]; ser: openArray[Series]; o: ChartOpts;
                  area: Rect; hot: (int, int)) =
  let rows = min(ser.len, 400)
  var cols = labels.len
  for s in ser: cols = max(cols, s.values.len)
  cols = min(cols, 400)
  if rows == 0 or cols == 0:
    noData(area)
    return
  var lo, hi = NaN
  for k in 0 ..< rows:
    for i in 0 ..< cols:
      let v = ser[k].val(i)
      if ok(v):
        lo = (if lo != lo: v else: min(lo, v))
        hi = (if hi != hi: v else: max(hi, v))
  if ok(o.lo): lo = o.lo
  if ok(o.hi): hi = o.hi
  var rw = 0
  for k in 0 ..< rows: rw = max(rw, textWidth(ser[k].name))
  rw = min(rw, area.w div 3) + dp(6)
  let scaleH = FontH + dp(10)
  let plot = rect(area.x + rw, area.y, area.w - rw, area.h - FontH - dp(4) - scaleH)
  if plot.w < cols or plot.h < rows:
    noData(area)
    return
  let cw = float(plot.w) / float(cols)
  let ch = float(plot.h) / float(rows)
  let base = palColor(o, 0)
  proc colorOf(v: float): Color =
    if not ok(v) or lo != lo: return th.face
    if lo < 0 and hi > 0:
      if v < 0: mixColor(th.field, downColor, clamp(v / lo, 0.0, 1.0))
      else: mixColor(th.field, base, clamp(v / hi, 0.0, 1.0))
    else:
      mixColor(mixColor(th.field, base, 0.06), base, if hi > lo: clamp((v - lo) / (hi - lo), 0.0, 1.0) else: 1.0)
  let small = style(size = 0.8)
  for k in 0 ..< rows:
    let y0 = plot.y + int(ch * float(k))
    let y1 = plot.y + int(ch * float(k + 1))
    if y1 - y0 >= FontH div 2 or k mod max(1, int(ceil(float(FontH) / ch))) == 0:
      let s = fitText(ser[k].name, rw - dp(6))
      text(plot.x - dp(4) - textWidth(s), y0 + (y1 - y0 - FontH) div 2, s, th.fieldText)
    for i in 0 ..< cols:
      let x0 = plot.x + int(cw * float(i))
      let x1 = plot.x + int(cw * float(i + 1))
      let v = ser[k].val(i)
      let c = colorOf(v)
      let cr = rect(x0, y0, max(1, x1 - x0 - (if cw > 6: 1 else: 0)), max(1, y1 - y0 - (if ch > 6: 1 else: 0)))
      fill(cr, c)
      if hot == (k, i): box(cr, th.fieldText, 2)
      hits.add (cr, k, i)
      if ok(v) and (o.dataLabels or true):
        let t = fmtValue(v, NumFormat(short: true, decimals: o.format.decimals))
        if textWidth(t, small) + 4 <= cr.w and lineHeight(small) <= cr.h:
          text(cr.x + (cr.w - textWidth(t, small)) div 2, cr.y + (cr.h - lineHeight(small)) div 2,
               t, textOn(c), small)
  catLabels(labels, cols, plot, cw)
  # the scale
  let sy = area.y + area.h - scaleH + dp(4)
  let lt0 = fmtValue(lo, o.format)
  let ht0 = fmtValue(hi, o.format)
  let sw = max(dp(20), min(dp(200), plot.w - textWidth(lt0, small) - textWidth(ht0, small) - dp(12)))
  let sx = plot.x + plot.w - sw - textWidth(ht0, small) - dp(6)
  for x in 0 ..< sw:
    let v = if hi == hi and lo == lo: lo + (hi - lo) * float(x) / float(max(1, sw - 1)) else: NaN
    vline(sx + x, sy, dp(8), colorOf(v))
  box(rect(sx, sy, sw, dp(8)), th.edge)
  let lt = fmtValue(lo, o.format)
  text(sx - dp(4) - textWidth(lt, small), sy - dp(2), lt, th.fieldText, small)
  text(sx + sw + dp(4), sy - dp(2), fmtValue(hi, o.format), th.fieldText, small)

proc radarChart(labels: openArray[string]; ser: openArray[Series]; o: ChartOpts;
                area: Rect; hidden: int; hot: (int, int)) =
  let n = min(catCount(labels, ser), 200)
  if n < 3:
    noData(area)
    return
  var hi = NaN
  for k, s in ser:
    if not shown(hidden, k): continue
    for i in 0 ..< n:
      let v = s.val(i)
      if ok(v): hi = (if hi != hi: v else: max(hi, v))
  if ok(o.hi): hi = o.hi
  let (a, b, step) = niceRange(0, (if hi == hi and hi > 0: hi else: 1.0), 4)
  var widest = 0
  for i in 0 ..< min(n, labels.len): widest = max(widest, textWidth(labels[i]))
  let r = max(8.0, min(float(area.w) / 2 - float(min(widest, area.w div 4)) - dpf(10),
                       float(area.h) / 2 - float(FontH) * 1.2))
  let cx = float(area.x) + float(area.w) / 2
  let cy = float(area.y) + float(area.h) / 2
  proc ang(i: int): float = -PI / 2 + 2 * PI * float(i) / float(n)
  proc rad(v: float): float = r * clamp((v - a) / max(b - a, 1e-300), 0.0, 1.0)
  # the web
  let rings = clamp(iround(((b - a) / step)), 1, 10)
  for k in 1 .. rings:
    let rr = rad(a + step * float(k))
    for i in 0 ..< n:
      let t0 = ang(i)
      let t1 = ang((i + 1) mod n)
      line(int(cx + cos(t0) * rr), int(cy + sin(t0) * rr),
           int(cx + cos(t1) * rr), int(cy + sin(t1) * rr), gridColor())
  for i in 0 ..< n:
    let t = ang(i)
    line(int(cx), int(cy), int(cx + cos(t) * r), int(cy + sin(t) * r), gridColor())
    if i < labels.len:
      let s = fitText(labels[i], area.w div 4)
      let tw = textWidth(s)
      let lx = cx + cos(t) * (r + dpf(6))
      let ly = cy + sin(t) * (r + dpf(6))
      let x = if cos(t) > 0.3: int(lx) elif cos(t) < -0.3: int(lx) - tw else: int(lx) - tw div 2
      let y = if sin(t) > 0.3: int(ly) elif sin(t) < -0.3: int(ly) - FontH else: int(ly) - FontH div 2
      text(x, y, s, th.fieldText)
  let small = style(size = 0.8)
  for k in 1 ..< rings:
    let v = a + step * float(k)
    text(int(cx) + dp(3), int(cy - rad(v)) - lineHeight(small), fmtValue(v, o.format), th.gray, small)
  # the series: areas, then their outlines and points
  var shapes: seq[(int, seq[(float, float)])]
  for k, s in ser:
    if not shown(hidden, k): continue
    var pts: seq[(float, float)]
    for i in 0 ..< n:
      let v = s.val(i)
      let rr = if ok(v): rad(v) else: 0.0
      pts.add (cx + cos(ang(i)) * rr, cy + sin(ang(i)) * rr)
    shapes.add (k, pts)
  for (k, pts) in shapes:
    polygon(pts, mixColor(seriesColor(o, ser[k], k), th.field, 0.72))
  for (k, pts) in shapes:
    let c = seriesColor(o, ser[k], k)
    var closed = pts
    closed.add pts[0]
    polyline(closed, max(1.0, dpf(2)), c)
    for i, p in pts:
      marker(p[0], p[1], dpf(3), c, hot == (k, i) or hot == (-1, i))
      hits.add (rect(int(p[0] - dpf(7)), int(p[1] - dpf(7)), int(dpf(14)) + 1, int(dpf(14)) + 1), k, i)

proc treemapChart(labels: openArray[string]; ser: openArray[Series]; o: ChartOpts;
                  area: Rect; hidden: int; hot: (int, int)) =
  if ser.len == 0:
    noData(area)
    return
  let s = ser[0]
  var items: seq[(float, int)]
  var total = 0.0
  for i in 0 ..< min(s.values.len, 2000):
    let v = s.val(i)
    if ok(v) and v > 0 and shown(hidden, i):
      items.add (v, i)
      total += v
  if items.len == 0 or total <= 0 or area.w < 4 or area.h < 4:
    noData(area)
    return
  items.sort(proc (x, y: (float, int)): int = cmp(y[0], x[0]))
  let scale = float(area.w) * float(area.h) / total
  var keep: seq[(float, int)]
  var areas: seq[float]
  for (v, i) in items:
    let a = v * scale
    if a >= 0.01 and a == a:               # (smaller than a pixel's hundredth: left out)
      keep.add (v, i)
      areas.add a
  items = keep
  if items.len == 0:
    noData(area)
    return
  # squarified: rows along the short side, while the worst ratio improves
  type RF = tuple[x, y, w, h: float]
  var res = newSeq[RF](areas.len)
  var r: RF = (float(area.x), float(area.y), float(area.w), float(area.h))
  var i = 0
  while i < areas.len:
    let short = min(r.w, r.h)
    if short <= 0.5:
      for k in i ..< areas.len: res[k] = (r.x, r.y, 0.0, 0.0)
      break
    var j = i
    var sum = 0.0
    var best = Inf
    while j < areas.len:
      let s2 = sum + areas[j]
      let worst = max(short * short * areas[i] / (s2 * s2), s2 * s2 / (short * short * areas[j]))
      if worst > best: break
      best = worst
      sum = s2
      inc j
    if j == i:
      sum = areas[i]
      j = i + 1
    let thick = max(sum / short, 1e-9)
    var off = 0.0
    for k in i ..< j:
      let len = areas[k] / thick
      res[k] = if r.w >= r.h: (r.x, r.y + off, thick, len) else: (r.x + off, r.y, len, thick)
      off += len
    r = if r.w >= r.h: (r.x + thick, r.y, r.w - thick, r.h) else: (r.x, r.y + thick, r.w, r.h - thick)
    i = j
  let small = style(size = 0.85)
  for k, (v, idx) in items:
    let f = res[k]
    let cr = rect(iround((f.x)), iround((f.y)),
                  max(0, iround((f.x + f.w)) - iround((f.x)) - 1),
                  max(0, iround((f.y + f.h)) - iround((f.y)) - 1))
    if cr.w <= 0 or cr.h <= 0: continue
    let c = pointColor(o, s, idx, idx)
    fill(cr, if hot == (0, idx): lighter(c) else: c)
    hits.add (cr, 0, idx)
    let name = if idx < labels.len: labels[idx] else: ""
    if cr.w > dp(30) and cr.h > FontH + 4:
      pushClip(cr)
      text(cr.x + dp(4), cr.y + dp(3), fitText(name, cr.w - dp(8), style(bold = true)), textOn(c), true)
      if cr.h > FontH * 2 + 6:
        text(cr.x + dp(4), cr.y + dp(3) + FontH,
             fitText(fmtValue(v, o.format) & "  " & $iround((v / total * 100)) & "%", cr.w - dp(8), small),
             textOn(c), small)
      popClip()

proc bulletChart(labels: openArray[string]; ser: openArray[Series]; o: ChartOpts;
                 area: Rect; hot: (int, int)) =
  if ser.len == 0:
    noData(area)
    return
  let vals = ser[0]
  let n = min(catCount(labels, ser), 200)
  if n == 0:
    noData(area)
    return
  var hi = NaN
  for i in 0 ..< n:
    for v in [vals.val(i), (if ser.len > 1: ser[1].val(i) else: NaN)]:
      if ok(v): hi = (if hi != hi: v else: max(hi, v))
  for b in o.bands:
    if ok(b.upTo): hi = (if hi != hi: b.upTo else: max(hi, b.upTo))
  if ok(o.hi): hi = o.hi
  let (a, b, step) = niceRange(min(0.0, if ok(o.lo): o.lo else: 0.0), (if hi == hi: hi else: 1.0),
                               clamp(area.w div dp(80), 2, 8))
  var widest = 0
  for i in 0 ..< min(n, labels.len): widest = max(widest, textWidth(labels[i], true))
  let lw = min(widest, area.w div 3) + dp(10)
  let plot = rect(area.x + lw, area.y, area.w - lw - dp(10), area.h - FontH - dp(6))
  if plot.w < dp(20):
    noData(area)
    return
  let xA = Axis(lo: a, hi: b, step: step, p0: float(plot.x), p1: float(plot.x + plot.w))
  xAxis(xA, plot, o.format, false)
  let rowH = min(float(plot.h) / float(n), dpf(44))
  var bands = o.bands
  if bands.len == 0:
    bands = @[(a + (b - a) * 0.6, mixColor(th.face, th.fieldText, 0.25)),
              (a + (b - a) * 0.85, mixColor(th.face, th.field, 0.1)),
              (b, mixColor(th.face, th.field, 0.6))]
  for i in 0 ..< n:
    let y0 = float(plot.y) + rowH * float(i)
    let bh = rowH * 0.62
    let by = y0 + (rowH - bh) / 2
    var start = a
    for (upTo, c) in bands:
      if not ok(upTo): continue
      let e = clamp(upTo, a, b)
      if e > start:
        let x0 = xA.ipos(start)
        fill(rect(x0, int(by), xA.ipos(e) - x0, int(bh)), c)
      start = max(start, e)
    let v = vals.val(i)
    let c = pointColor(o, vals, 0, i)
    if ok(v):
      let x0 = xA.ipos(max(a, 0.0))
      let x1 = xA.ipos(v)
      let vh = bh * 0.4
      fill(rect(min(x0, x1), int(by + (bh - vh) / 2), max(1, abs(x1 - x0)), max(1, int(vh))),
           if hot == (0, i): lighter(c) else: c)
    if ser.len > 1:
      let t = ser[1].val(i)
      if ok(t):
        let x = xA.pos(t)
        thickLine(x, by + bh * 0.12, x, by + bh * 0.88, max(2.0, dpf(2.5)), th.fieldText)
    hits.add (rect(plot.x, int(y0), plot.w, max(1, int(rowH))), 0, i)
    if i < labels.len:
      let s = fitText(labels[i], lw - dp(10), style(bold = true))
      text(plot.x - dp(6) - textWidth(s, true), int(y0 + (rowH - float(FontH)) / 2), s, th.fieldText, true)

# ---- the tooltip ------------------------------------------------------------------------------------

proc tipLines(kind: ChartKind; labels: openArray[string]; ser: openArray[Series];
              o: ChartOpts; hidden: int; s, i: int): tuple[head: string; lines: seq[(string, Color)]] =
  let lab = if i >= 0 and i < labels.len: labels[i] else: ""
  case kind
  of chPie, chDonut, chFunnel, chTreemap:
    if ser.len == 0: return
    var total = 0.0
    for k in 0 ..< min(ser[0].values.len, MaxPoints):
      let v = ser[0].val(k)
      if ok(v) and v > 0 and (kind == chFunnel or shown(hidden, k)): total += v
    let v = ser[0].val(i)
    result.head = lab
    var line = fmtValue(v, o.format)
    if kind != chFunnel and total > 0 and ok(v):
      line.add "  (" & formatFloat(v / total * 100, ffDecimal, 1) & "%)"
    elif kind == chFunnel and ser[0].values.len > 0 and ok(ser[0].val(0)) and ser[0].val(0) != 0:
      line.add "  (" & formatFloat(v / ser[0].val(0) * 100, ffDecimal, 1) & "% of the first)"
    result.lines.add (line, pointColor(o, ser[0], i, i))
  of chHistogram:
    if i >= 0 and i + 1 < histEdges.len:
      result.head = fmtValue(histEdges[i], o.format) & " to " & fmtValue(histEdges[i + 1], o.format)
      var c = 0
      if ser.len > 0:
        for k in 0 ..< min(ser[0].values.len, MaxPoints):
          let v = ser[0].val(k)
          if ok(v) and v >= histEdges[i] and (v < histEdges[i + 1] or
             (i + 2 == histEdges.len and v <= histEdges[i + 1])): inc c
      result.lines.add ($c & (if c == 1: " value" else: " values"), palColor(o, 0))
  of chHeatmap:
    if s >= 0 and s < ser.len:
      result.head = ser[s].name & (if lab.len > 0: ", " & lab else: "")
      result.lines.add (fmtValue(ser[s].val(i), o.format), palColor(o, 0))
  of chScatter, chBubble:
    if s >= 0 and s < ser.len:
      let x = if ser[s].xs.len > 0: ser[s].xs.at(i) else: float(i)
      result.head = ser[s].name
      result.lines.add ("x " & fmtValue(x) & ", y " & fmtValue(ser[s].val(i), o.format),
                        seriesColor(o, ser[s], s))
      if kind == chBubble: result.lines.add ("size " & fmtValue(ser[s].sizes.at(i)), seriesColor(o, ser[s], s))
  of chGauge:
    result.head = if ser.len > 0: ser[0].name else: ""
    result.lines.add (fmtValue(if ser.len > 0: ser[0].val(0) else: NaN, o.format), palColor(o, 0))
    if ok(o.target): result.lines.add ("target " & fmtValue(o.target, o.format), th.fieldText)
  of chCandle:
    if ser.len > 0:
      let p = ser[0]
      result.head = lab
      result.lines.add ("open " & fmtValue(p.opens.at(i), o.format), th.fieldText)
      result.lines.add ("high " & fmtValue(p.highs.at(i), o.format), th.fieldText)
      result.lines.add ("low " & fmtValue(p.lows.at(i), o.format), th.fieldText)
      result.lines.add ("close " & fmtValue(p.val(i), o.format), th.fieldText)
  of chWaterfall:
    if ser.len > 0:
      let n = catCount(labels, ser)
      var run = 0.0
      for k in 0 ..< min(i + 1, n):
        let v = ser[0].val(k)
        if k in o.totalAt:
          if ok(v): run = v
        elif ok(v): run += v
      if i >= n or i in o.totalAt:
        result.head = if i >= n: o.totalLabel else: lab
        result.lines.add (fmtValue(run, o.format), totalColor)
      else:
        result.head = lab
        let v = ser[0].val(i)
        result.lines.add ((if v >= 0: "+" else: "") & fmtValue(v, o.format), if v >= 0: upColor else: downColor)
        result.lines.add ("total " & fmtValue(run, o.format), th.fieldText)
  of chBullet:
    if ser.len > 0:
      result.head = lab
      result.lines.add (fmtValue(ser[0].val(i), o.format), pointColor(o, ser[0], 0, i))
      if ser.len > 1: result.lines.add ("target " & fmtValue(ser[1].val(i), o.format), th.fieldText)
  else:
    result.head = lab
    let isLine = linesOf(kind, ser)
    var total = 0.0
    if kind == chStacked100:
      for k, x in ser:
        if shown(hidden, k):
          let v = x.val(i)
          if ok(v) and v > 0: total += v
    for k, x in ser:
      if not shown(hidden, k): continue
      if s >= 0 and k != s: continue
      let v = x.val(i)
      var t = (if x.name.len > 0: x.name & ": " else: "") &
              fmtValue(v, if kind == chCombo and isLine[k]: o.format2 else: o.format)
      if kind == chStacked100 and total > 0 and ok(v):
        t.add "  (" & formatFloat(max(v, 0.0) / total * 100, ffDecimal, 1) & "%)"
      result.lines.add (t, pointColor(o, x, k, i))

proc drawTip(x, y: int; head: string; lines: openArray[(string, Color)]) =
  if head.len == 0 and lines.len == 0: return
  pushLayer(LayerTip)
  let sw = dp(9)
  var w = textWidth(head, true)
  for (t, _) in lines: w = max(w, sw + dp(5) + textWidth(t))
  w = min(w + dp(12), max(dp(60), ui.w - dp(8)))
  let h = (if head.len > 0: FontH else: 0) + lines.len * FontH + dp(8)
  var tx = x + dp(14)
  var ty = y + dp(16)
  if tx + w > ui.w - 2: tx = max(2, x - w - dp(8))
  if ty + h > ui.h - 2: ty = max(2, y - h - dp(8))
  let r = rect(tx, ty, w, h)
  fill(rect(r.x + 2, r.y + 2, r.w, r.h), th.shadow)
  fill(r, th.tip)
  box(r, th.frame)
  var yy = r.y + dp(4)
  if head.len > 0:
    text(r.x + dp(6), yy, fitText(head, r.w - dp(12), style(bold = true)), th.tipText, true)
    yy += FontH
  for (t, c) in lines:
    fill(rect(r.x + dp(6), yy + (FontH - sw) div 2, sw, sw), c)
    text(r.x + dp(6) + sw + dp(5), yy, fitText(t, r.w - dp(12) - sw - dp(5)), th.tipText)
    yy += FontH
  popLayer()

# ---- the chart --------------------------------------------------------------------------------------

proc legendItems(kind: ChartKind; labels: openArray[string]; ser: openArray[Series];
                 o: ChartOpts; hidden: int): seq[tuple[name: string; c: Color; k: int; off: bool]] =
  case kind
  of chPie, chDonut, chFunnel, chTreemap:
    if ser.len == 0 or (kind in {chFunnel, chTreemap} and o.legend == laAuto): return
    var total = 0.0
    for i in 0 ..< min(ser[0].values.len, MaxPoints):
      let v = ser[0].val(i)
      if ok(v) and v > 0 and shown(hidden, i): total += v
    for i in 0 ..< min(ser[0].values.len, 60):
      var name = if i < labels.len: labels[i] else: "#" & $(i + 1)
      let v = ser[0].val(i)
      if kind in {chPie, chDonut} and total > 0 and ok(v) and v > 0 and shown(hidden, i):
        name.add " " & $iround((v / total * 100)) & "%"
      result.add (name, pointColor(o, ser[0], i, i), i, not shown(hidden, i))
  of chGauge, chHeatmap, chHistogram, chWaterfall, chCandle, chBullet: discard
  else:
    let named = ser.len > 1 or (ser.len == 1 and ser[0].name.len > 0)
    if not named: return
    for k, s in ser:
      if k >= 60: break
      result.add ((if s.name.len > 0: s.name else: "Series " & $(k + 1)),
                  seriesColor(o, s, k), k, not shown(hidden, k))

const chartKindNames*: array[ChartKind, string] = [
  "Bars", "Bars sideways", "Stacked bars", "Stacked 100%", "Lines", "Areas",
  "Stacked areas", "Bars and a line", "Pie", "Donut", "Scatter", "Bubbles",
  "Waterfall", "Funnel", "Gauge", "Candlesticks", "Histogram", "Heat map", "Radar",
  "Tree map", "Bullet"]
  ## Names of the kinds for people (a chart type combo box).

proc chartImpl(kind: ChartKind; labels: openArray[string]; ser: openArray[Series];
               o: ChartOpts; height, w: int): ChartEvent =
  result.series = -1
  result.index = -1
  result.hidden = -1
  let h = if height < 0: remainingH() elif height == 0: dp(250) else: height
  let r = place(if w > 0: w else: 0, max(h, FontH * 3), fill = w <= 0)
  # (a right-to-left interface does not mirror a chart: its axes, time and
  # values read as they do anywhere)
  beginKeepSides(r)
  defer: endKeepSides()
  let id = idOf("chart\0" & o.key & "\0" & o.title & "\0" & $ord(kind))
  var st = state(id)
  let hidden = st.aux
  let hotPrev = if st.aux2 > 0: ((st.aux2 - 1) div 1_000_000 - 1, (st.aux2 - 1) mod 1_000_000)
                else: (-2, -2)
  let hot = if exporting(): (-2, -2) else: hotPrev
  if o.frame:
    fill(r, th.field)
    box(r, th.edge)
  var inner = inset(r, dp(8))
  pushClip(inset(r, 1))
  # titles
  if o.title.len > 0:
    let t = fitText(o.title, inner.w, style(bold = true))
    centerText(r.x + r.w div 2, inner.y, t, th.fieldText, style(bold = true))
    inner.y += FontH
    inner.h -= FontH
  if o.subtitle.len > 0:
    let t = fitText(o.subtitle, inner.w)
    centerText(r.x + r.w div 2, inner.y, t, th.gray)
    inner.y += FontH
    inner.h -= FontH
  if o.title.len > 0 or o.subtitle.len > 0:
    inner.y += dp(4)
    inner.h -= dp(4)
  # the legend: at the right when there is room, else under the chart
  let items = if o.legend == laNone: @[] else: legendItems(kind, labels, ser, o, hidden)
  let sw = dp(10)
  var widest = 0
  for it in items: widest = max(widest, sw + dp(5) + textWidth(it.name))
  let right = items.len > 0 and (o.legend == laRight or
              (o.legend == laAuto and not isCompact() and inner.w >= dp(380) and
               widest + dp(16) <= inner.w div 3 and
               items.len * (FontH + dp(3)) <= inner.h))
  var legendRects: seq[(Rect, int)]
  if items.len > 0:
    if right:
      let lw = widest + dp(12)
      var y = inner.y + max(0, (inner.h - items.len * (FontH + dp(3))) div 2)
      for it in items:
        if y + FontH > inner.y + inner.h: break
        legendRects.add (rect(inner.x + inner.w - lw + dp(8), y, widest + dp(4), FontH + 2), it.k)
        y += FontH + dp(3)
      inner.w -= lw
    else:
      # rows under the chart, at most three
      var rowsY: seq[seq[(int, int)]] = @[@[]]     # (item, width)
      var x = 0
      for j, it in items:
        let iw = min(sw + dp(5) + textWidth(it.name), inner.w) + dp(14)
        if x > 0 and x + iw > inner.w:
          if rowsY.len >= 3: break
          rowsY.add @[]
          x = 0
        rowsY[^1].add (j, iw)
        x += iw
      let lh = rowsY.len * (FontH + dp(2)) + dp(4)
      var y = inner.y + inner.h - lh + dp(4)
      for rowItems in rowsY:
        var tw = 0
        for (_, iw) in rowItems: tw += iw
        var xx = inner.x + max(0, (inner.w - tw) div 2)
        for (j, iw) in rowItems:
          legendRects.add (rect(xx, y, iw - dp(10), FontH + 2), items[j].k)
          xx += iw
        y += FontH + dp(2)
      inner.h -= lh
  # legend clicks: hide or show again (before the plot takes the press)
  var nh = hidden
  for (lr, k) in legendRects:
    let hit = interact(id + uint32(1000 + k), lr, focusable = false)
    if hit.clicked and k < 30:
      nh = nh xor (1 shl k)
      result.hidden = k
  let plotHit = interact(id, inner)
  # the chart itself
  hits.setLen(0)
  pie.on = false
  case kind
  of chPie, chDonut: pieChart(kind, labels, ser, o, inner, hidden, hot)
  of chScatter, chBubble: scatterChart(kind, ser, o, inner, hidden, hot)
  of chFunnel: funnelChart(labels, ser, o, inner, hidden, hot)
  of chGauge: gaugeChart(ser, o, inner, hot)
  of chHistogram: histogramChart(ser, o, inner, hot)
  of chHeatmap: heatmapChart(labels, ser, o, inner, hot)
  of chRadar: radarChart(labels, ser, o, inner, hidden, hot)
  of chTreemap: treemapChart(labels, ser, o, inner, hidden, hot)
  of chBullet: bulletChart(labels, ser, o, inner, hot)
  else: categoryChart(kind, labels, ser, o, inner, hidden, hot)
  # the legend
  let small = TextStyle()
  for j, (lr, k) in legendRects:
    var it = items[0]
    for x in items:
      if x.k == k: it = x
    let off = it.off
    let b = rect(lr.x + 1, lr.y + (lr.h - sw) div 2, sw, sw)
    if off: box(b, th.gray) else: fill(b, it.c)
    if not off: box(b, darker(it.c))
    let tx = lr.x + sw + dp(6)
    let t = fitText(it.name, lr.x + lr.w - tx + dp(8), small)
    text(tx, lr.y + 1, t, if off: th.gray else: th.fieldText, small)
    if off: hline(tx, lr.y + 1 + FontH div 2, textWidth(t), th.gray)
    if hovered(lr): hline(tx, lr.y + FontH, textWidth(t), th.fieldText)
  popClip()
  # what is under the mouse, tapped, or chosen with the keys
  proc targetAt(px, py: int): (int, int) =
    if pie.on:
      let k = pieTarget(px, py)
      return (if k >= 0: (0, k) else: (-2, -2))
    for j in countdown(hits.high, 0):
      if hits[j].r.contains(point(px, py)): return (hits[j].s, hits[j].i)
    (-2, -2)
  var target = (-2, -2)
  var tipAt = (0, 0)
  let n = max(1, if kind in {chPie, chDonut, chFunnel, chTreemap, chHistogram, chBullet}:
                   (if kind == chHistogram: max(1, histEdges.len - 1)
                    elif ser.len > 0: ser[0].values.len else: 0)
                 else: catCount(labels, ser))
  if not exporting():
    if plotHit.focused and canInput():
      ui.takesEnter = true                # (Enter picks the point: #9)
      var c = st.caret
      case ui.key
      of KeyLeft, KeyUp: c = max(0, c - 1)
      of KeyRight, KeyDown: c = min(n - 1, c + 1)
      of KeyHome: c = 0
      of KeyEnd: c = n - 1
      else: discard
      if ui.key in {KeyLeft, KeyUp, KeyRight, KeyDown, KeyHome, KeyEnd}:
        ui.keyUsed = true
        st.caret = c
        st.anchor = 0
        st.scrollX = 1                   # the keys chose: show it
      if keyHit(KeyEnter):
        result.clicked = true
        result.series = if kind in {chBar, chBarH, chStacked, chStacked100, chLine, chArea,
                                     chStackedArea, chCombo, chRadar}: -1 else: 0
        result.index = st.caret
    if finger():
      if plotHit.clicked:
        let t = targetAt(ui.mx, ui.my)
        st.anchor = if t[1] >= 0: (t[0] + 1) * 1_000_000 + t[1] + 1 else: 0
        st.scrollX = 0
        if t[1] >= 0:
          result.clicked = true
          (result.series, result.index) = t
      if st.anchor > 0:
        target = ((st.anchor - 1) div 1_000_000 - 1, (st.anchor - 1) mod 1_000_000)
        tipAt = (ui.mx, ui.my)
    elif canHover() and mouseIn(inner) and canInput():
      target = targetAt(ui.mx, ui.my)
      tipAt = (ui.mx, ui.my)
      st.scrollX = 0
      if plotHit.clicked and target[1] >= 0:
        result.clicked = true
        (result.series, result.index) = target
    if target[1] < 0 and plotHit.focused and st.scrollX == 1 and st.caret < n:
      # the keys' choice: its first hit
      for x in hits:
        if x.i == st.caret:
          target = (x.s, x.i)
          tipAt = (x.r.x + x.r.w div 2, x.r.y)
          break
      if target[1] < 0 and pie.on: target = (0, st.caret)
    if target[1] >= 0 and not result.clicked:
      (result.series, result.index) = target
    if plotHit.focused and ui.focusMoved > 0: dots(inset(r, 2), th.fieldText)  # (keyboard users)
  # the tooltip
  if target[1] >= 0 and not exporting():
    let (head, lines) = tipLines(kind, labels, ser, o, hidden, target[0], target[1])
    drawTip(tipAt[0], tipAt[1], head, lines)
  let enc = if target[1] >= 0: (target[0] + 1) * 1_000_000 + target[1] + 1 else: 0
  if enc != st.aux2 or nh != st.aux:
    st.aux2 = enc
    st.aux = nh
    ui.redraw = true
  state(id) = st
  if accessOn:
    # (read as a picture: its title, its kind and series; the point the
    # keys or the mouse are on as its value)
    var about = chartKindNames[kind]
    for k, sr in ser:
      if shown(hidden, k) and sr.name.len > 0: about.add ", " & sr.name
    var v = ""
    if target[1] >= 0:
      let (head, lines) = tipLines(kind, labels, ser, o, hidden, target[0], target[1])
      v = head
      for l in lines: v.add ", " & l[0]
    accessNode(arImage, o.title, v, id = id, r = r, help = about)
  ui.lastId = id
  ui.lastRect = r

proc chart*(title: string; kind: ChartKind; labels: openArray[string];
            series: openArray[Series]; height = 0; w = 0;
            opts = ChartOpts()): ChartEvent {.discardable.} =
  ## A chart of `series` over `labels`, with everything a reader expects:
  ## round axis numbers, a legend (click an entry to hide that series), a
  ## tooltip (the mouse, a tap, or Left / Right once the chart has the
  ## focus), click events. `height` in pixels (0: a good height for the
  ## screen, -1: the room left); `opts` for the rest (its title is
  ## `title`).
  var o = opts
  if title.len > 0: o.title = title
  chartImpl(kind, labels, series, o, height, w)

proc chart*(kind: ChartKind; labels: openArray[string]; series: openArray[Series];
            opts: ChartOpts; height = 0; w = 0): ChartEvent {.discardable.} =
  ## `chart` with every option in `opts`.
  chartImpl(kind, labels, series, opts, height, w)

proc gauge*(title: string; value: float; lo = 0.0; hi = NaN; target = NaN;
            format = NumFormat(); height = 0; w = 0): ChartEvent {.discardable.} =
  ## A dial showing `value` (with a `target` mark) from `lo` to `hi`.
  chartImpl(chGauge, [], [series(title, [value])],
            ChartOpts(title: title, lo: lo, hi: hi, target: target, format: format),
            height, w)

proc tableSeries*(t: DataTable; kind: ChartKind; cols: openArray[int]): seq[Series] =
  ## The columns `cols` of a table as the series `kind` takes: one series
  ## per column for most kinds; x, y (and size) for scatter and bubbles;
  ## open, high, low, close for candlesticks; values and targets for
  ## bullets.
  var c: seq[int]
  for i in cols:
    if i >= 0 and i < t.headers.len: c.add i
  if c.len == 0: return
  case kind
  of chScatter, chBubble:
    if c.len == 1:
      result.add xySeries(t.headers[c[0]], [], t.column(c[0]))
    else:
      result.add xySeries(t.headers[c[1]], t.column(c[0]), t.column(c[1]),
                          if kind == chBubble and c.len > 2: t.column(c[2]) else: @[])
  of chCandle:
    if c.len >= 4:
      result.add ohlcSeries(t.headers[c[3]], t.column(c[0]), t.column(c[1]),
                            t.column(c[2]), t.column(c[3]))
    else:
      for i in c: result.add series(t.headers[i], t.column(i))
  else:
    for i in c: result.add series(t.headers[i], t.column(i))

proc chart*(title: string; kind: ChartKind; t: DataTable; labelCol: string;
            valueCols: openArray[string]; height = 0; w = 0;
            opts = ChartOpts()): ChartEvent {.discardable.} =
  ## A chart of a table's columns: the labels from `labelCol`, the values
  ## from `valueCols` (see `tableSeries`):
  ## `chart("Sales", chBar, readCsv("sales.csv"), "Month", ["2025", "2026"])`.
  var cols: seq[int]
  for n in valueCols: cols.add t.colIndex(n)
  var o = opts
  if title.len > 0: o.title = title
  chartImpl(kind, t.labels(labelCol), tableSeries(t, kind, cols), o, height, w)

# ---- the charts of before ----------------------------------------------------------------------------

proc barChart*(values: openArray[float]; labels: openArray[string] = [];
               title = ""; w = 0; h = 170; colors: openArray[Color] = []) =
  ## Vertical bars, one per value, with a labeled axis (see `chart` for more).
  var s = series("", values)
  if colors.len > 0:
    for i in 0 ..< values.len: s.colors.add colors[i mod colors.len]
  discard chartImpl(chBar, labels, [s], ChartOpts(title: title, legend: laNone), h, w)

proc lineChart*(series: openArray[seq[float]]; labels: openArray[string] = [];
                names: openArray[string] = []; title = ""; w = 0; h = 170) =
  ## One line per series over the same x points (see `chart` for more).
  var ser: seq[Series]
  for k, s in series:
    ser.add Series(name: (if k < names.len: names[k] else: ""), values: s)
  discard chartImpl(chLine, labels, ser,
                    ChartOpts(title: title, legend: if names.len > 0: laRight else: laNone), h, w)

proc pieChart*(values: openArray[float]; labels: openArray[string] = [];
               title = ""; w = 0; h = 170) =
  ## Slices of a circle, with a legend of shares (see `chart` for more).
  discard chartImpl(chPie, labels, [series("", values)],
                    ChartOpts(title: title, legend: laRight), h, w)


# ---- live graphs: a graph that moves as values come -----------------------------------------------

type LiveGraphCache = ref object
  bmp: Bitmap
  version: int
  look: uint64
  seen: int                      ## (the frame it was last drawn in)

var liveGraphs: Table[string, LiveGraphCache]

const
  lgBack = 0xFF000000'u32        ## (Task Manager's: black, a dark green grid, a green line)
  lgGrid = 0xFF00552B'u32
  lgGreen = color(0, 255, 0)

proc argbOf(c: Color): uint32 =
  0xFF000000'u32 or (uint32(c.r) shl 16) or (uint32(c.g) shl 8) or uint32(c.b)

proc liveGraph*(key: string; values: openArray[float]; version: int; maxValue = 100.0;
                w = 0; h = 0; color = Color(); step = 0; label = ""; caption = "";
                fillUnder = false) =
  ## A graph of the last `values` (the newest at the right) that moves left
  ## as values come, on a grid that moves with it -- the processor's graph
  ## of a task manager: black, a dark green grid, a green line (`color`
  ## another). `key` names the graph (its picture is kept); `version` grows
  ## by one with each new value (a sample's number): the graph is drawn
  ## whole once, then only moved a step and its new part drawn, so a frame
  ## costs a copy of the picture whatever the number of values. `maxValue`
  ## is the top; `step` the design pixels between two values (0: the width
  ## over 60 values); `label` and `caption` are written over it, top left
  ## and top right; `fillUnder` fills below the line with its color, darker.
  ## `w` 0 fills the width; `h` 0 is 80 design pixels.
  let r = place(if w > 0: w else: 0, if h > 0: h else: dp(80), fill = w <= 0)
  ui.lastRect = r
  if r.w <= 0 or r.h <= 0: return
  let k = max(1, pxScale)
  let bw = r.w * k
  let bh = r.h * k
  let stepPx = clamp(if step > 0: dp(step) * k else: bw div 60, 1, bw)
  let grid = max(4, dp(12) * k)                      # (the grid's squares)
  let ink = if color.a == 0: lgGreen else: color
  let line = argbOf(ink)
  let under = argbOf(mixColor(ink, color(0, 0, 0), 0.6))
  let look = uint64(line) xor (uint64(maxValue * 1000) shl 32) xor (uint64(stepPx) shl 24) xor
             uint64(ord(fillUnder))
  var c = liveGraphs.getOrDefault(key)
  if c == nil:
    c = LiveGraphCache(version: -1)
    liveGraphs[key] = c
    # (graphs no longer drawn let go of their pictures)
    if liveGraphs.len > 16:
      var gone: seq[string]
      for name, g in liveGraphs:
        if ui.frameNo - g.seen > 600 and name != key: gone.add name
      for name in gone: liveGraphs.del name
  c.seen = ui.frameNo
  let n = values.len
  let phase = (version * stepPx) mod grid
  proc yOf(v: float): int =
    let t = if maxValue > 0 and v == v: clamp(v / maxValue, 0.0, 1.0) else: 0.0
    clamp(bh - 1 - int(t * float(bh - 1) + 0.5), 0, bh - 1)
  proc back(b: Bitmap; x: int) =
    ## (one column of the background: black and the grid's lines)
    let vertical = ((x + phase) mod grid) == 0
    for y in 0 ..< bh:
      b.px[y * bw + x] = if vertical or (bh - 1 - y) mod grid == 0: lgGrid else: lgBack
  proc segment(b: Bitmap; x0, v0, x1, v1: int) =
    ## (the line from one value to the next, `k` pixels thick, and what is
    ## under it)
    var prev = v0
    for x in x0 .. x1:
      let y = if x1 == x0: v1 else: v0 + (v1 - v0) * (x - x0) div (x1 - x0)
      if x >= 0 and x < bw:
        let lo = max(0, min(y, prev) - k div 2)
        let hi = min(bh - 1, max(y, prev) + (k - 1) div 2)
        if fillUnder:
          for yy in hi + 1 ..< bh: b.px[yy * bw + x] = under
        for yy in lo .. hi: b.px[yy * bw + x] = line
      prev = y
  if c.bmp == nil or c.bmp.w != bw or c.bmp.h != bh or c.look != look or
     version != c.version + 1 and version != c.version:
    # drawn whole: a new size, a new look, or values missed
    c.bmp = newBitmap(bw, bh)
    c.bmp.opaque = true
    for x in 0 ..< bw: back(c.bmp, x)
    var x1 = bw - 1
    for i in countdown(n - 1, 1):
      let x0 = x1 - stepPx
      segment(c.bmp, x0, yOf(values[i - 1]), x1, yOf(values[i]))
      x1 = x0
      if x1 < 0: break
    c.bmp.changed()
  elif version == c.version + 1:
    # a value more: the picture moved left a step, the new part drawn
    let b = c.bmp
    for y in 0 ..< bh:
      let row = y * bw
      moveMem(addr b.px[row], addr b.px[row + stepPx], (bw - stepPx) * sizeof(uint32))
    for x in max(0, bw - stepPx) ..< bw: back(b, x)
    if n >= 2: segment(b, bw - 1 - stepPx, yOf(values[n - 2]), bw - 1, yOf(values[n - 1]))
    b.changed()
  c.version = version
  c.look = look
  drawBitmap(r, c.bmp)
  let st = style(size = 0.85)
  if label.len > 0: text(r.x + dp(4), r.y + dp(2), label, ink, st)
  if caption.len > 0:
    text(r.x + r.w - dp(4) - textWidth(caption, st), r.y + dp(2), caption, ink, st)
  if accessOn:
    accessNode(arImage, label, (if n > 0: formatFloat(values[n - 1], ffDecimal, 1) else: ""),
               r = r, help = caption)

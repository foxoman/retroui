## Chart Viewer: a CSV file as a chart -- pick the kind of chart and the
## columns, hover the chart for its numbers, save it as a PNG. All the work
## is the kit's (`retroui/charts`): this file only lays it out.
##
##   nim c -r -d:release examples/charts.nim [sales.csv]
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils]
import retroui

const sample = """Month,North,South,East,Target
Jan,120,80,45,200
Feb,135,95,50,210
Mar,150,90,62,220
Apr,170,110,58,230
May,160,125,70,240
Jun,190,130,81,250
Jul,210,128,88,260
Aug,205,140,92,270
Sep,230,150,99,280
Oct,250,162,105,290
Nov,270,170,118,300
Dec,300,185,125,310
"""

var
  table = parseCsv(sample)
  path = (let a = appArguments(); if a.len >= 1: a[0] else: "")   # (no command line in an APK)
  kind = 0                      # chartKindNames
  labelCol = 0
  useCols: seq[bool]            # the value columns shown
  pickOpen = false
  valuesOpen = false
  status = "A sample table: open a CSV file to chart your own."
  cols: seq[Column]
  rows: seq[seq[string]]
  row0 = 0
  chartR: Rect

proc load(t: DataTable; name: string) =
  ## Shows a table: its first text column as the labels, its first
  ## numbers as the values.
  table = t
  let nums = t.numericColumns
  labelCol = 0
  for c in 0 ..< t.headers.len:
    if c notin nums:
      labelCol = c
      break
  useCols = newSeq[bool](t.headers.len)
  var n = 0
  for c in nums:
    if c != labelCol and n < 3:
      useCols[c] = true
      inc n
  cols.setLen(0)
  for h in t.headers: cols.add column(h, max(70, min(160, h.len * 9)))
  rows = t.rows
  status = if t.error.len > 0: t.error
           else: name & ": " & $t.rows.len & " rows, " & $t.headers.len & " columns"

if path.len > 0: load(readCsv(path), path.extractFilename)
else: load(table, "Sample")

proc pngPath(): string =
  if path.len > 0: path.changeFileExt("") & "-chart.png"
  else: dataDir("chartviewer") / "chart.png"

app "Chart Viewer", 1000, 700:
  toolbar:
    if toolButton(pxOpen, "Open a CSV file", size = 1.3): pickOpen = true
    if toolButton(pxSave, "Save the chart as a PNG picture", size = 1.3):
      createDir(pngPath().parentDir)
      exportPng(chartR, pngPath())
      status = "Saving " & pngPath() & "..."
  statusbar(status)
  let res = exportResult()
  if res.done and status.startsWith("Saving"):
    status = if res.ok: "Saved " & res.path else: "Could not save " & res.path
  # the choices: at the left, or above the chart on a phone
  template choices() =
    label "&Chart:"
    combo(chartKindNames, kind)
    label "&Labels:"
    combo(table.headers, labelCol)
    label "&Values:"
    checkList(table.headers, useCols, rows = min(8, max(1, table.headers.len)))
  template view() =
    var picked: seq[int]
    for c, on in useCols:
      if on: picked.add c
    let k = ChartKind(kind)
    chart(chartKindNames[k] & " of " & (if path.len > 0: path.extractFilename else: "the sample"),
          k, table.labels(labelCol), tableSeries(table, k, picked),
          height = max(dp(220), remainingH() * 3 div 5),
          opts = ChartOpts(palette: @businessColors, target: 250))
    chartR = ui.lastRect
    grid(cols, rows, row0, height = -1)
  if isCompact():
    row([-1, -1]):
      col:
        label "&Chart:"
        combo(chartKindNames, kind)
      col:
        label "&Labels:"
        combo(table.headers, labelCol)
    expander("&Values", valuesOpen):
      checkList(table.headers, useCols, rows = min(6, max(1, table.headers.len)))
    view()
  else:
    row([180, -1]):
      col: choices()
      col: view()
  if filePicker(pickOpen, path, fmOpen, ["*.csv", "*.tsv", "*.txt"], "Open a table"):
    load(readCsv(path), path.extractFilename)

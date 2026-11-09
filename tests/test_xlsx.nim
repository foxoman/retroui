## Tests of the Excel reader and writer (retroui/xlsx).

import std/os
import retroui/xlsx

let dir = currentSourcePath().parentDir / "data" / "xlsx"

block reading:
  let book = readXlsx(dir / "sample.xlsx")
  doAssert book.len == 2
  doAssert book[0].name == "Sohar" and book[1].name == "Visa tracker"
  let r = book[0].rows
  doAssert r[0][0] == "Mercure Sohar – Payroll Oct 2026", r[0][0]
  doAssert r[1].len == 0, "an empty row stays (rows keep their numbers)"
  doAssert r[2] == @["Staff No", "Employee Name", "الاسم", "Basic", "DOJ", "Active", "Total"], $r[2]
  doAssert r[3][0] == "SOH-1042" and r[3][2] == "مريم سالم الهنائي"
  doAssert r[3][3] == "610", r[3][3]
  doAssert r[3][4] == "2018-09-02", "a date cell: " & r[3][4]
  doAssert r[3][5] == "TRUE" and r[4][5] == "FALSE"
  doAssert r[4][3] == "350.1", "no float noise: " & r[4][3]
  doAssert r[4][4] == "2020-01-05 08:30", r[4][4]
  doAssert r[5][1] == "  spaced  " and r[5][2] == "a & b < c" and r[5][3] == "0.1"
  let v = book[1].rows
  doAssert v[1] == @["Rajesh Nair", "2026-11-12", "K4410293"] or
           v[1][0 .. 2] == @["Rajesh Nair", "2026-11-12", "K4410293"], $v[1]
  doAssert v[2][5] == "2025-06-04", "a custom date format: " & v[2][5]
  doAssert v[2][6] == "1234.5", "a number with a currency format stays a number"
  doAssert v[9][4] == "far cell"

block roundTrip:
  let p = getTempDir() / "retro-test.xlsx"
  writeXlsx(p, [XlsxSheet(name: "Staff", rows: @[@["No", "Name", "Basic"],
                                               @["0123", "Ali & Co <x>", "610.5"],
                                               @["7", "", "1e3"]])])
  let back = readXlsx(p)
  doAssert back.len == 1 and back[0].name == "Staff"
  doAssert back[0].rows[1] == @["0123", "Ali & Co <x>", "610.5"], $back[0].rows[1]
  doAssert back[0].rows[2][0] == "7" and back[0].rows[2][1] == ""
  removeFile(p)

block notExcel:
  let p = getTempDir() / "retro-not.xlsx"
  writeFile(p, "this is not a zip")
  var failed = false
  try: discard readXlsx(p)
  except XlsxError: failed = true
  doAssert failed
  removeFile(p)

echo "xlsx tests passed"

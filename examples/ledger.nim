## Ledger: a small business app -- invoices, customers, stock and reports.
## Shows the business widgets working together: tree, splitter, sortable
## and editable grid, form dialog with date picker, number fields and
## auto-complete, charts, CSV import/export with the file dialog, and saved
## settings. On a narrow (phone) screen the tree becomes tabs.
##
##   nimble ledger              (or: nim c -r examples/ledger.nim)
##   retroapk examples/ledger.nim --install     (Android)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[strutils, algorithm]
import retroui

type
  Invoice = object
    number: int
    customer: string
    date: Date
    amount: float
    paid: bool
    notes: string
  Product = object
    code, name: string
    stock, reorder: int
    price: float

var
  customers = @["Al Noor Trading", "Muscat Office Supply", "Sohar Steel",
                "Nizwa Dates Co.", "Salalah Fisheries", "Gulf Print House",
                "Sur Boatworks", "Ibri Builders"]
  invoices: seq[Invoice]
  products = @[
    Product(code: "P-100", name: "Copy paper A4", stock: 120, reorder: 50, price: 2.75),
    Product(code: "P-101", name: "Toner black", stock: 8, reorder: 10, price: 39.0),
    Product(code: "P-102", name: "Folders (box)", stock: 45, reorder: 20, price: 6.5),
    Product(code: "P-103", name: "Stapler", stock: 15, reorder: 5, price: 4.2),
    Product(code: "P-104", name: "Desk lamp", stock: 3, reorder: 4, price: 18.9),
    Product(code: "P-105", name: "Envelopes C5", stock: 300, reorder: 100, price: 0.12)]

# sample data: invoices over this year
block:
  var seed = 7
  proc rnd(n: int): int =
    seed = (seed * 1103515245 + 12345) and 0x7FFFFFFF
    (seed shr 8) mod n
  let y = today().year
  for i in 0 ..< 48:
    invoices.add Invoice(number: 1001 + i, customer: customers[rnd(customers.len)],
                         date: date(y, 1 + i div 4, 1 + rnd(28)),
                         amount: float(50 + rnd(2400)) + float(rnd(100)) / 100,
                         paid: rnd(3) != 0)

var
  settings = loadSettings("retro-ledger")
  scheme = settings.getInt("scheme", 0)
  navW = settings.getInt("navWidth", 170)
  section = "Sales/Invoices"
  salesOpen, stockOpen, reportsOpen = true
  status = ""
  # invoices page
  invCols = @[column("No.", 56, alRight), column("Customer", 170),
              column("Date", 86), column("Amount", 96, alRight, editable = true),
              column("Status", 60)]
  view: seq[int]                 # invoices shown, after filter and sort
  invSel = 0
  sortCol = 2
  sortDesc = true
  filterText = ""
  unpaidOnly = false
  # invoice dialog
  editOpen = false
  editIndex = -1
  draft: Invoice
  askDelete = false
  # customers and products
  custCols = @[column("Customer", 180), column("Invoices", 70, alRight),
               column("Total", 100, alRight), column("Open", 100, alRight)]
  custSel = 0
  custSort = (col: 0, desc: false)
  remind: seq[bool]
  prodCols = @[column("Code", 60), column("Product", 150, editable = true),
               column("Stock", 60, alRight, editable = true),
               column("Reorder at", 76, alRight, editable = true),
               column("Price", 76, alRight, editable = true)]
  prodSel = 0
  # files
  fileOpen = false
  fileMode = fmSave
  filePath = ""
  showAbout = false
  askQuit = false

proc setScheme(i: int) =
  scheme = clamp(i, 0, 2)
  ui.theme = [Classic, Gray, Dark][scheme]

proc refilter() =
  view.setLen(0)
  let q = filterText.toLowerAscii
  for i, inv in invoices:
    if unpaidOnly and inv.paid: continue
    if q.len > 0 and q notin inv.customer.toLowerAscii and q notin $inv.number:
      continue
    view.add i
  view.sort(proc (a, b: int): int =
    let x = invoices[a]
    let y = invoices[b]
    result = case sortCol
      of 0: cmp(x.number, y.number)
      of 1: cmp(x.customer, y.customer)
      of 2: cmp(dayNumber(x.date), dayNumber(y.date))
      of 3: cmp(x.amount, y.amount)
      else: cmp(x.paid, y.paid)
    if sortDesc: result = -result)
  invSel = clamp(invSel, 0, max(0, view.high))

proc invCell(r, c: int): string =
  let inv = invoices[view[r]]
  case c
  of 0: $inv.number
  of 1: inv.customer
  of 2: $inv.date
  of 3: formatNumber(inv.amount)
  else: (if inv.paid: "Paid" else: "Open")

proc total(paid: bool): float =
  for inv in invoices:
    if inv.paid == paid: result += inv.amount

proc startEdit(index: int) =
  editIndex = index
  draft = if index >= 0: invoices[index]
          else: Invoice(number: 1001 + invoices.len, date: today())
  editOpen = true

proc exportCsv(path: string) =
  var s = "number,customer,date,amount,paid\n"
  for inv in invoices:
    s.add $inv.number & ",\"" & inv.customer.replace("\"", "\"\"") & "\"," &
          intToStr(inv.date.year, 4) & "-" & intToStr(inv.date.month, 2) & "-" &
          intToStr(inv.date.day, 2) & "," &
          formatFloat(inv.amount, ffDecimal, 2) & "," & $inv.paid & "\n"
  writeFile(path, s)

proc importCsv(path: string): int =
  for line in lines(path):
    var cells: seq[string]
    var cur = ""
    var quoted = false
    for ch in line:
      if ch == '"': quoted = not quoted
      elif ch == ',' and not quoted:
        cells.add cur
        cur = ""
      else: cur.add ch
    cells.add cur
    if cells.len < 5 or cells[0] == "number": continue
    var inv: Invoice
    try:
      inv.number = parseInt(cells[0])
      inv.amount = parseFloat(cells[3])
    except ValueError: continue
    inv.customer = cells[1]
    discard parseDate(cells[2], inv.date)
    inv.paid = cells[4] == "true"
    invoices.add inv
    inc result

setScheme(scheme)
block:
  var f: UiFont
  if uiFontOfKey(settings.get("font", ""), f): setUiFont(f)

# ---- pages -----------------------------------------------------------------------

proc invoicesPage() =
  let bw = if ui.touch: 84 else: 74
  if available() >= 500:
    row([44, -1, 110, bw, bw]):
      label "F&ind:"
      if edit(filterText): invSel = 0
      checkbox "&Unpaid only", unpaidOnly
      if button("&New..."): startEdit(-1)
      if button("&Delete", enabled = view.len > 0): askDelete = true
  else:                                  # a phone held upright
    row([44, -1]):
      label "F&ind:"
      if edit(filterText): invSel = 0
    row([-1, bw, bw]):
      checkbox "&Unpaid only", unpaidOnly
      if button("&New..."): startEdit(-1)
      if button("&Delete", enabled = view.len > 0): askDelete = true
  refilter()
  let ev = grid(invCols, view.len, invCell, invSel, height = -1,
                sortColumn = sortCol, sortDescending = sortDesc)
  if ev.sorted:
    sortCol = ev.sortColumn
    sortDesc = ev.sortDescending
  if ev.edited:
    var v: float
    if parseNumber(ev.text, v): invoices[view[ev.row]].amount = v
  if ev.activated and view.len > 0: startEdit(view[invSel])
  contextMenu:
    if menuItem("&Edit...") and view.len > 0: startEdit(view[invSel])
    if menuItem("Mark &paid") and view.len > 0: invoices[view[invSel]].paid = true
    menuSeparator()
    if menuItem("&Delete") and view.len > 0: askDelete = true
  status = $view.len & " invoices   open " & formatNumber(total(false)) &
           "   paid " & formatNumber(total(true))

proc customersPage() =
  if remind.len != customers.len: remind.setLen(customers.len)
  var rows: seq[seq[string]]
  for c in customers:
    var n = 0
    var sum, open = 0.0
    for inv in invoices:
      if inv.customer == c:
        inc n
        sum += inv.amount
        if not inv.paid: open += inv.amount
    rows.add @[c, $n, formatNumber(sum), formatNumber(open)]
  sortRows(rows, custSort.col, custSort.desc)
  let ev = grid(custCols, rows, custSel, height = 9, sortColumn = custSort.col,
                sortDescending = custSort.desc)
  if ev.sorted: custSort = (ev.sortColumn, ev.sortDescending)
  row([-1, -1]):
    group "Send a &reminder to":
      checkList customers, remind, rows = 5
    group "Customer":
      if custSel in 0 ..< rows.len:
        label rows[custSel][0], bold = true
        label "Open amount: " & rows[custSel][3]
        if link("Open the website"): openUrl("https://nim-lang.org")
  var n = 0
  for r in remind: n += ord(r)
  status = $customers.len & " customers, " & $n & " reminders selected"

proc productsPage() =
  proc cell(r, c: int): string =
    let p = products[r]
    case c
    of 0: p.code
    of 1: p.name
    of 2: $p.stock
    of 3: $p.reorder
    else: formatNumber(p.price)
  let ev = grid(prodCols, products.len, cell, prodSel, height = -1)
  if ev.edited:
    var v: float
    case ev.col
    of 1: products[ev.row].name = ev.text
    of 2: (if parseNumber(ev.text, v): products[ev.row].stock = int(v))
    of 3: (if parseNumber(ev.text, v): products[ev.row].reorder = int(v))
    of 4: (if parseNumber(ev.text, v): products[ev.row].price = v)
    else: discard
  var low = 0
  for p in products:
    if p.stock <= p.reorder: inc low
  status = $products.len & " products, " & $low & " to reorder"

proc reportsPage() =
  var months: array[12, float]
  var monthsPaid: array[12, float]
  for inv in invoices:
    months[inv.date.month - 1] += inv.amount
    if inv.paid: monthsPaid[inv.date.month - 1] += inv.amount
  var names: seq[string]
  for m in monthNames: names.add m[0 .. 2]
  let h = max(130, (remainingH() - Gap) div 2)
  barChart(months, names, "Sales by month", h = h)
  row([-1, -1]):
    lineChart([@months, @monthsPaid], names, ["Billed", "Paid"], "Billed and paid", h = h)
    var byCust: seq[float]
    for c in customers:
      var s = 0.0
      for inv in invoices:
        if inv.customer == c: s += inv.amount
      byCust.add s
    var short: seq[string]
    for c in customers: short.add c.split(' ')[0]
    pieChart(byCust, short, "By customer", h = h)
  status = "Total billed " & formatNumber(total(true) + total(false))

# ---- the window ---------------------------------------------------------------------

app "Ledger", 820, 560:
  if closeRequested():
    cancelClose()
    askQuit = true

  menubar:
    menu "&File":
      if menuItem("&New invoice...", "Ctrl+N"): startEdit(-1)
      if menuItem("&Import CSV..."):
        fileMode = fmOpen
        fileOpen = true
      if menuItem("&Export CSV...", "Ctrl+S"):
        fileMode = fmSave
        filePath = "invoices.csv"
        fileOpen = true
      menuSeparator()
      if menuItem("E&xit"): askQuit = true
    menu "&View":
      for i, s in ["&Classic", "&Gray", "&Dark"]:
        if menuItem(s, checked = scheme == i): setScheme(i)
      menuSeparator()
      submenu "Date &format":
        if menuItem("dd/mm/yyyy", checked = dateStyle == dsDMY): dateStyle = dsDMY
        if menuItem("mm/dd/yyyy", checked = dateStyle == dsMDY): dateStyle = dsMDY
        if menuItem("yyyy-mm-dd", checked = dateStyle == dsISO): dateStyle = dsISO
      submenu "&Zoom":
        for z in 0 .. 3:
          if menuItem(if z == 0: "&Automatic" else: "&" & $z & "x",
                      checked = z > 0 and zoomLevel() == z): setZoom(z)
      submenu "F&ont":
        for f in builtinUiFonts:
          if menuItem($f, checked = uiFont() == f): setUiFont(f)
    menu "&Help":
      if menuItem("&About Ledger..."): showAbout = true

  toolbar:
    if toolButton(pxNew, "New invoice"): startEdit(-1)
    if toolButton(pxOpen, "Import CSV"):
      fileMode = fmOpen
      fileOpen = true
    if toolButton(pxSave, "Export CSV"):
      fileMode = fmSave
      filePath = "invoices.csv"
      fileOpen = true
    toolSeparator()
    if toolButton(pxPrint, "Print"): status = "No printer here -- export CSV instead"
    if toolButton(pxHelp, "About"): showAbout = true

  statusbar(status, platformName())

  let narrow = ui.w < 600
  if narrow:
    # a phone: tabs instead of the tree
    var t = ["Sales/Invoices", "Sales/Customers", "Stock/Products",
             "Reports/Sales"].find(section)
    if t < 0: t = 0
    tabs(t, ["Invoices", "Customers", "Stock", "Reports"]):
      section = ["Sales/Invoices", "Sales/Customers", "Stock/Products",
                 "Reports/Sales"][t]
      case t
      of 0: invoicesPage()
      of 1: customersPage()
      of 2: productsPage()
      else: reportsPage()
  else:
    split(navW, -1):
      tree(section, -1):
        branch "Sales", salesOpen:
          leaf "Invoices"
          leaf "Customers"
        branch "Stock", stockOpen:
          leaf "Products"
        branch "Reports", reportsOpen:
          leaf "Sales"
    do:
      case section
      of "Sales/Invoices", "Sales": invoicesPage()
      of "Sales/Customers": customersPage()
      of "Stock/Products", "Stock": productsPage()
      else: reportsPage()

  # the invoice form
  dialog editOpen, (if editIndex < 0: "New Invoice" else: "Invoice " & $draft.number), 360:
    form 80:
      field "Number:": label $draft.number
      field "&Customer:": comboEdit draft.customer, customers
      field "&Date:": datePicker draft.date
      field "&Amount:": numberEdit draft.amount, lo = 0
      field "Status:": checkbox "&Paid", draft.paid
    label "&Notes:"
    editArea draft.notes, lines = 3
    row:
      space available() - 2 * (72 + Gap) + Gap
      if button("OK", isDefault = true, enabled = draft.customer.len > 0):
        if editIndex < 0: invoices.add draft
        else: invoices[editIndex] = draft
        if draft.customer notin customers: customers.add draft.customer
        editOpen = false
      if button("Cancel"): editOpen = false

  if fileDialog(fileOpen, filePath, fileMode, ["CSV Files (*.csv)", "All Files (*.*)"]):
    try:
      if fileMode == fmSave:
        exportCsv(filePath)
        status = "Saved " & filePath
      else:
        status = "Imported " & $importCsv(filePath) & " invoices"
    except IOError, OSError:
      status = "Could not use " & filePath

  case msgBox(askDelete, "Delete", "Delete invoice " &
              (if view.len > 0: $invoices[view[invSel]].number else: "") & "?",
              ["&Delete", "Cancel"], miQuestion)
  of 1:
    if view.len > 0: invoices.delete(view[invSel])
  else: discard

  dialog showAbout, "About Ledger", 300:
    row:
      msgIcon miInfo
      col:
        label "Ledger", bold = true
        label "A retro business example."
        if link("retro on GitHub"): openUrl("https://github.com")
    row:
      space available() - 72
      if button("OK", isDefault = true): showAbout = false

  case msgBox(askQuit, "Ledger", "Quit Ledger?", ["&Yes", "&No"], miQuestion)
  of 1:
    settings.put("scheme", scheme)
    settings.put("navWidth", navW)
    settings.put("font", uiFontKey(uiFont()))
    try: saveSettings("retro-ledger", settings)
    except IOError, OSError: discard
    quitApp()
  else: discard

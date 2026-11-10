## Invoice: a business document from an HTML template and some data --
## `renderTemplate` fills the template, `reportFromHtml` lays it out on A4
## pages -- shown page by page, saved as a PDF file and printed. Change the
## customer, the lines or the VAT at the left and the pages follow.
##
##   nim c -r -d:release examples/invoice.nim
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, json]
import retroui
import retroui/report

const invoiceTemplate = """
<html><head><title>Invoice {{number}}</title></head><body>
<header><span>{{company.name}}</span><span>Invoice {{number}}</span></header>
<footer><span>{{company.web}}</span><span>Page {page} of {pages}</span></footer>

<table class="plain"><tr>
  <td width="60%"><h1>{{company.name}}</h1>{{company.address}}<br>Tel. {{company.phone}}</td>
  <td align="right"><h2>INVOICE</h2>No. <b>{{number}}</b><br>Date: {{date}}<br>Due: {{due}}</td>
</tr></table>

<h3>Bill to</h3>
<p><b>{{customer.name}}</b><br>{{customer.address}}</p>

<table>
<thead><tr><th width="50%">Description</th><th align="right">Qty</th>
           <th align="right">Unit price</th><th align="right">Amount</th></tr></thead>
<tbody>
{{#lines}}<tr><td>{{name}}</td><td>{{qty|n0}}</td><td>{{price|n2}}</td><td>{{amount|n2}}</td></tr>{{/lines}}
{{^lines}}<tr><td colspan="4"><i>Nothing ordered yet.</i></td></tr>{{/lines}}
</tbody>
<tfoot>
<tr><td colspan="3" align="right">Subtotal</td><td>{{subtotal|n2}}</td></tr>
<tr><td colspan="3" align="right">VAT {{vatRate}}%</td><td>{{vat|n2}}</td></tr>
<tr><td colspan="3" align="right">Total ({{currency}})</td><td>{{total|n2}}</td></tr>
</tfoot>
</table>

<p style="text-align: right"><span style="color: #a00000">Please pay by {{due}}.</span></p>
<p dir="rtl">شكراً لتعاملكم معنا. يرجى ذكر رقم الفاتورة {{number}} عند الدفع.</p>
<hr>
<p style="text-align: center"><small>{{company.name}} &middot; {{company.web}}</small></p>
</body></html>
"""

type Line = object
  name: string
  qty, price: float

var
  number = "INV-2026-0042"
  customer = "Sohar Steel & Co."
  address = "Sohar Industrial Estate, Oman"
  vatRate = 5.0
  lines = @[Line(name: "Paper A4, 80 g, box of 5 reams", qty: 10, price: 4.5),
            Line(name: "Toner cartridge", qty: 2, price: 31.25),
            Line(name: "Desk chair", qty: 1, price: 119)]
  doc: Report
  shown = ""                    # the data `doc` was made from
  saveOpen = false
  pdfPath = dataDir("invoice") / "invoice.pdf"
  status = ""
  detailsOpen = true

proc invoiceData(): JsonNode =
  ## What the template is filled from.
  var items = newJArray()
  var subtotal = 0.0
  for l in lines:
    let amount = l.qty * l.price
    subtotal += amount
    items.add %*{"name": l.name, "qty": l.qty, "price": l.price, "amount": amount}
  let vat = subtotal * vatRate / 100
  %*{"number": number, "date": $today(), "due": $today().addDays(30), "currency": "OMR",
     "company": {"name": "Acme Trading LLC", "address": "Building 12, Way 3021, Muscat",
                 "phone": "+968 2400 0000", "web": "acme.example"},
     "customer": {"name": customer, "address": address},
     "lines": items, "subtotal": subtotal, "vatRate": vatRate, "vat": vat,
     "total": subtotal + vat}

proc details() =
  ## The invoice's fields and lines.
  form 90:
    field "&Number": edit(number)
    field "&Customer": edit(customer)
    field "&Address": edit(address)
    field "&VAT %": numberEdit(vatRate, decimals = 1, w = 80, lo = 0, hi = 100)
  label "Lines:", bold = true
  var gone = -1
  for i, l in lines.mpairs:
    withId(i):
      row([-1, 50, 80, 28]):
        # (the boxes of a line have no label each: named for screen readers)
        let n = $(i + 1)
        accessName("Line " & n & ": item")
        edit(l.name)
        accessName("Line " & n & ": quantity")
        numberEdit(l.qty, decimals = 0, w = 50, lo = 0)
        accessName("Line " & n & ": price")
        numberEdit(l.price, decimals = 2, w = 80, lo = 0)
        accessName("Remove line " & n)
        if button("x", w = dp(28)): gone = i
  if gone >= 0: lines.delete(gone)
  if button("Add a &line"): lines.add Line(name: "New item", qty: 1, price: 0)

app "Invoice", 1100, 760:
  # the document, made again when the data changed
  let data = invoiceData()
  if $data != shown:
    shown = $data
    doc = reportFromHtml(renderTemplate(invoiceTemplate, data))
  toolbar:
    if toolButton(pxSave, "Save as PDF", size = 1.3): saveOpen = true
    if toolButton(pxPrint, "Print", size = 1.3):
      status = doc.printReport().message
    if toolButton(pxPdf, "Open the saved PDF", size = 1.3, enabled = fileExists(pdfPath)):
      openFile(pdfPath)
  let hint = "Edit the invoice " & (if isCompact(): "above" else: "at the left") &
             "; save it as PDF or print it."
  statusbar(if status.len > 0: status else: hint, $doc.pageCount & " page(s)")
  if isCompact():
    expander("&Details", detailsOpen): details()
    reportView(doc, key = "invoice")
  else:
    row([380, -1]):
      col: details()
      col:
        let ev = reportView(doc, key = "invoice")
        if ev.link.len > 0: openUrl(ev.link)
  if filePicker(saveOpen, pdfPath, fmSave, ["*.pdf"], "Save the invoice as PDF"):
    try:
      createDir(pdfPath.parentDir)
      doc.savePdf(pdfPath)
      status = "Saved " & pdfPath
    except IOError, OSError:
      status = "Could not save " & pdfPath

## retroui/report and retroui/templates: documents laid out on pages (tables
## that go on over pages with their header, rows never cut, groups kept
## together, titles kept with what follows, right-to-left Arabic, pictures,
## headers and footers), PDF and PNG out, Mustache templates, the HTML
## that `reportFromHtml` reads, printing (with a fake CUPS), and the
## preview by mouse, keyboard and finger -- headless.

import std/[os, strutils, json, times, sequtils]
import retroui
import retroui/report
import retroui/uirelays/input
import harness

fakeDriver()
startApp("report", W, H)

let dataDir = currentSourcePath.parentDir / "data" / "report"
let tmp = getTempDir() / "retro-test-report"
createDir(tmp)

proc find(r: Report; s: string): seq[tuple[page: int; t: PageText]] =
  ## Every piece of text equal to `s`, with its page.
  for p in 0 ..< r.pageCount:
    for t in r.pageTexts(p):
      if t.text == s: result.add (p, t)

proc allText(r: Report): string =
  for p in 0 ..< r.pageCount:
    for t in r.pageTexts(p): result.add t.text & "\n"

proc linesOnFirstPage(): int =
  ## How many one-line paragraphs fit on an A4 page.
  let d = newReport("count")
  for i in 1 .. 200: d.paragraph("Line " & $i)
  for t in d.pageTexts(0):
    if t.text.startsWith("Line "): inc result

# ---- layout -----------------------------------------------------------------------------------

block tablesOverPages:
  var doc = newReport("Invoice 42", author = "Acme")
  doc.header("Acme", "", "{title}")
  doc.footer("", "Page {page} of {pages}", "")
  doc.heading("Invoice 42")
  doc.paragraph("Hello world")
  var t = newTable(["Item", "Qty", "Price"], widths = [-3.0, -1, -1],
                   aligns = [alLeft, alRight, alRight])
  for i in 1 .. 300: t.addRow(["Item " & $i, "Q" & $i, "P" & $i])
  t.addTotals(["Total", "", "90300"])
  doc.table(t)
  let n = doc.pageCount
  doAssert n >= 6, $n
  let bottom = A4.h - doc.margins.bottom
  var qRight = -1.0
  for p in 0 ..< n:
    let ts = doc.pageTexts(p)
    # the header row comes again at the top of every page, once
    let heads = ts.filterIt(it.text == "Item")
    doAssert heads.len == 1, "page " & $(p + 1)
    doAssert heads[0].bold
    if p > 0: doAssert abs(heads[0].y - (doc.margins.top + 3)) < 1, "at the top"
    doAssert ts.anyIt(it.text == "Page " & $(p + 1) & " of " & $n)
    doAssert ts.anyIt(it.text == "Acme") and ts.anyIt(it.text == "Invoice 42")
    for x in ts:
      if x.text.startsWith("Item ") or x.text.startsWith("Q") or x.text.startsWith("P") and
         not x.text.startsWith("Page"):
        doAssert x.y + pdfLineHeight(x.size) <= bottom + 0.01, "inside the margins"
      if x.text.startsWith("Q"):
        # right-aligned: every right edge the same
        if qRight < 0: qRight = x.x + x.w
        doAssert abs(x.x + x.w - qRight) < 0.05
  # every row once and whole: its cells on one page, on one line
  for i in 1 .. 300:
    let a = doc.find("Item " & $i)
    let b = doc.find("Q" & $i)
    let c = doc.find("P" & $i)
    doAssert a.len == 1 and b.len == 1 and c.len == 1, $i
    doAssert a[0].page == c[0].page and abs(a[0].t.y - c[0].t.y) < 0.01
  let total = doc.find("Total")
  doAssert total.len == 1 and total[0].page == n - 1 and total[0].t.bold
  doAssert doc.find("90300")[0].page == n - 1

block rowTallerThanAPage:
  # its lines go on over the pages, with the header again; nothing is lost
  let d = newReport("tall")
  var t = newTable(["Note", "By"], widths = [-3.0, -1])
  let words = (1 .. 3000).mapIt("w" & $it)
  t.addRow([words.join(" "), "Ali"])
  t.addRow(["after", "Sara"])
  d.table(t)
  let n = d.pageCount
  doAssert n >= 3, $n
  var got: seq[string]
  for p in 0 ..< n:
    doAssert d.pageTexts(p).countIt(it.text == "Note") == 1
    for x in d.pageTexts(p):
      if x.text.startsWith("w"):
        got.add x.text.split(' ')
        doAssert x.y + pdfLineHeight(x.size) <= A4.h - d.margins.bottom + 0.01
  doAssert got == words, "every word once, in order"
  doAssert d.find("Ali")[0].page == 0 and d.find("after")[0].page == n - 1

block speed:
  # 100+ pages of tables, laid out and written as PDF
  let t0 = epochTime()
  let doc = newReport("Speed")
  doc.footer("", "Page {page} of {pages}", "")
  var t = newTable(["Date", "Description", "Debit", "Credit", "Balance"],
                   widths = [-1.2, -4.0, -1, -1, -1.2], aligns = [alLeft, alLeft, alRight, alRight, alRight])
  for i in 1 .. 4000:
    t.addRow(["27/10/2026", "Payment for invoice INV-" & $i & ", paper and toner",
              $(i * 3) & ".00", "", $(i * 7) & ".50"])
  doc.table(t)
  let pdf = doc.pdfBytes()
  let dt = epochTime() - t0
  echo doc.pageCount, " pages of tables: ", pdf.len div 1024, " KB in ",
       formatFloat(dt * 1000, ffDecimal, 0), " ms"
  doAssert doc.pageCount >= 100
  doAssert dt < (when defined(release) or defined(danger): 1.0 else: 15.0), "well under a second"

block keptGroups:
  let n = linesOnFirstPage()
  doAssert n > 30
  proc build(keep: bool): Report =
    result = newReport("keep")
    for i in 1 .. n - 4: result.paragraph("Line " & $i)
    var t = newTable(["A", "B"])
    for i in 1 .. 8: t.addRow(["a" & $i, "b" & $i])
    if keep:
      result.keepTogether:
        result.heading("Totals", 3)
        result.table(t)
    else:
      result.heading("Totals", 3)
      result.table(t)
  let loose = build(false)
  doAssert loose.find("Totals")[0].page == 0
  doAssert loose.find("a8")[0].page == 1, "without keepTogether the table goes on over the page"
  let kept = build(true)
  doAssert kept.find("Totals")[0].page == 1, "the group moves to the next page"
  doAssert kept.find("a1")[0].page == 1 and kept.find("a8")[0].page == 1
  # a group taller than a page is not moved: it just flows
  let big = newReport("big")
  big.paragraph("first")
  big.keepTogether:
    for i in 1 .. 2 * n: big.paragraph("Row " & $i)
  doAssert big.find("Row 1")[0].page == 0

block headingsStayWithText:
  let n = linesOnFirstPage()
  let d = newReport("h")
  for i in 1 .. n - 1: d.paragraph("Line " & $i)
  d.heading("Chapter 2", 2)
  d.paragraph("Its first line")
  doAssert d.find("Chapter 2")[0].page == 1, "a title never ends a page alone"
  doAssert d.find("Its first line")[0].page == 1

block wrapping:
  let d = newReport("w")
  let words = (1 .. 200).mapIt("word" & $it).join(" ")
  d.paragraph(words)
  d.paragraph("x".repeat(400))
  let left = d.margins.left
  let right = A4.w - d.margins.right
  var lines = 0
  var xs = 0
  for t in d.pageTexts(0):
    if t.text.startsWith("word"):
      inc lines
      doAssert t.x >= left - 0.01 and t.x + t.w <= right + 0.5, "inside the margins"
    if t.text.startsWith("xxx"):
      inc xs
      doAssert t.x + t.w <= right + 0.5, "a long word is broken"
  doAssert lines > 5 and xs >= 2
  # every word once, in order
  var all = ""
  for t in d.pageTexts(0):
    if t.text.startsWith("word"): all.add t.text & " "
  doAssert all.strip == words
  # `\n` starts a new line
  let d2 = newReport("n")
  d2.paragraph("one\ntwo")
  doAssert d2.find("two")[0].t.y > d2.find("one")[0].t.y

block rightToLeft:
  let d = newReport("rtl")
  d.paragraph("مرحبا بالعالم")
  d.paragraph("Hello world")
  d.paragraph("Hello", rtl = 1)
  d.paragraph("وسط", align = alCenter)
  let right = A4.w - d.margins.right
  let ar = d.find("مرحبا بالعالم")[0].t
  doAssert abs(ar.x + ar.w - right) < 0.5, "Arabic sits at the right"
  doAssert abs(d.find("Hello world")[0].t.x - d.margins.left) < 0.01
  let h = d.find("Hello")[0].t
  doAssert abs(h.x + h.w - right) < 0.5, "rtl = 1: at the right"
  # in HTML, text-align: left puts Arabic at the left
  let hl = reportFromHtml("<p style=\"text-align: left\">مرحبا</p>")
  doAssert abs(hl.find("مرحبا")[0].t.x - hl.margins.left) < 0.5, "text-align overrides"
  let c = d.find("وسط")[0].t
  doAssert abs((c.x + c.w / 2) - (d.margins.left + right) / 2) < 0.5
  # a long Arabic paragraph wraps, every line at the right
  let d2 = newReport("rtl2")
  d2.paragraph(repeat("كلمة عربية ", 80))
  var rows = 0
  for t in d2.pageTexts(0):
    inc rows
    doAssert abs(t.x + t.w - right) < 0.5
  doAssert rows > 2

block pagesAndBreaks:
  let d = newReport("p", page = landscape(Letter))
  d.pageBreak()                      # nothing before it: no blank page
  d.paragraph("one")
  d.pageBreak()
  d.paragraph("two")
  d.space(50)
  d.rule()
  d.list(["apples", "pears"])
  d.list(["first", "second"], numbered = true)
  doAssert d.pageCount == 2
  doAssert d.find("one")[0].page == 0 and d.find("two")[0].page == 1
  doAssert d.find("•").len == 2 and d.find("2.").len == 1
  let b = d.renderPage(0, 1.0)
  doAssert b.w == 792 and b.h == 612
  doAssert d.renderPage(5) == nil
  # changes after laying out are seen
  d.paragraph("three")
  doAssert d.find("three").len == 1
  d.page = A5
  doAssert d.renderPage(0, 1.0).w == int(A5.w + 0.5), "a new page size is seen"
  d.margins.left = 100
  doAssert abs(d.find("one")[0].t.x - 100) < 0.01, "new margins too"

block pictures:
  let pic = newBitmap(100, 50, 0xFFFF0000'u32)
  let path = tmp / "red.png"
  doAssert savePng(pic, path)
  let d = newReport("pics")
  d.image(pic, w = 200)
  doAssert d.imageFile(path, 100, 50, alCenter)
  doAssert not d.imageFile(tmp / "missing.png")
  d.image(nil)
  d.image(newBitmap(4000, 100, 0xFF0000FF'u32))        # too wide: made to fit
  let b = d.renderPage(0, 1.0)
  let x = int(d.margins.left + 100)
  let y = int(d.margins.top + 50)
  doAssert (b.px[y * b.w + x] and 0xFFFFFF) == 0xFF0000, "the picture is drawn"
  let pdf = d.pdfBytes()
  doAssert pdf.contains("/Subtype /Image")
  # pictures in table cells, from Nim and from HTML
  let d2 = newReport("cells")
  var t = newTable(["Logo", "Name"])
  t.addRow([imageCell(pic, 60, 30, text = "under"), cell("Acme")])
  d2.table(t)
  let under = d2.find("under")[0].t
  doAssert under.y > d2.find("Acme")[0].t.y + 25, "the text goes under the picture"
  let h = reportFromHtml("<table><tr><td><img src=\"red.png\" width=\"80\">Logo</td>" &
                         "<td>Acme</td></tr></table>", tmp)
  doAssert h.find("Logo")[0].t.y > h.find("Acme")[0].t.y + 25
  let hb = h.renderPage(0, 1.0)
  let hx = int(h.margins.left + 10)
  let hy = int(h.margins.top + 10)
  doAssert (hb.px[hy * hb.w + hx] and 0xFFFFFF) == 0xFF0000, "the cell's picture is drawn"

block outputs:
  let d = newReport("Out")
  d.heading("Out")
  d.paragraph([span("bold", bold = true), span(" italic", italic = true), span(" mono", mono = true),
               span(" red", color = color(200, 0, 0)), span(" under", underline = true),
               span(" link", link = "https://example.com")])
  let lk = d.pageTexts(0).filterIt(it.link.len > 0)
  doAssert lk.len == 1 and lk[0].text == "link" and lk[0].link == "https://example.com"
  doAssert d.pageTexts(0).anyIt(it.text.strip == "red" and it.color == color(200, 0, 0))
  d.savePdf(tmp / "out.pdf")
  let pdf = readFile(tmp / "out.pdf")
  doAssert pdf.startsWith("%PDF-") and pdf.contains("/Count 1") and pdf.contains("/Title (Out)")
  doAssert pdf == d.pdfBytes(), "the same bytes again"
  doAssert d.savePng(0, tmp / "out.png", 72)
  doAssert readFile(tmp / "out.png").startsWith("\x89PNG")
  doAssert not d.savePng(3, tmp / "none.png")
  let b = d.renderPage(0, 2.0)
  doAssert b.w == int(A4.w * 2 + 0.5)
  var dark = 0
  for p in b.px:
    if (p and 0xFF) < 100: inc dark
  doAssert dark > 500, "text is drawn"

block nonsense:
  # nothing in it, odd sizes, NaN: a page, no crash
  let d = newReport("", page = (NaN, -1.0))
  doAssert d.pageCount == 1
  d.margins = (Inf, -5.0, NaN, 1e9)
  d.size = NaN
  d.paragraph("", size = NaN)
  d.heading("", level = 99)
  d.space(Inf)
  d.space(-3)
  var t = newTable(widths = [NaN, -Inf, 1e300])
  t.addRow(newSeq[string]())
  t.addRow(["a", "b", "c", "d", "e"])
  t.addRow([cell("wide", colspan = 99)])
  d.table(t)
  d.table(newTable())
  d.endKeep()
  d.beginKeep()
  doAssert d.pageCount >= 1
  discard d.pdfBytes()
  discard d.renderPage(0, NaN)

# ---- templates --------------------------------------------------------------------------------

block templates:
  let data = %*{"name": "Ali <&> \"Sons\"", "n": 3, "price": 1234.5, "neg": -0.004,
                "items": [{"name": "Paper", "qty": 2}, {"name": "Ink", "qty": 0}],
                "empty": [], "flag": true, "off": false, "zero": 0,
                "co": {"name": "Acme", "addr": {"city": "Muscat"}},
                "tags": ["a", "b"], "html": "<b>x</b>"}
  doAssert renderTemplate("Hi {{name}}!", data) == "Hi Ali &lt;&amp;&gt; &quot;Sons&quot;!"
  doAssert renderTemplate("{{{html}}} {{& html}} {{html}}", data) ==
    "<b>x</b> <b>x</b> &lt;b&gt;x&lt;/b&gt;"
  doAssert renderTemplate("{{co.name}} in {{co.addr.city}}{{co.nope}}{{nope.x}}", data) ==
    "Acme in Muscat"
  doAssert renderTemplate("{{#items}}[{{name}}:{{qty}}]{{/items}}", data) == "[Paper:2][Ink:0]"
  doAssert renderTemplate("{{#items}}{{#qty}}{{name}} {{/qty}}{{/items}}", data) == "Paper "
  doAssert renderTemplate("{{^empty}}none{{/empty}}{{#empty}}x{{/empty}}", data) == "none"
  doAssert renderTemplate("{{#flag}}yes{{/flag}}{{#off}}no{{/off}}{{^off}}off{{/off}}", data) ==
    "yesoff"
  doAssert renderTemplate("{{#co}}{{name}}/{{addr.city}}{{/co}}", data) == "Acme/Muscat"
  doAssert renderTemplate("{{#tags}}<{{.}}>{{/tags}}", data) == "<a><b>"
  doAssert renderTemplate("{{#items}}{{co.name}}{{/items}}", data) == "AcmeAcme", "outer names"
  doAssert renderTemplate("{{! a comment }}x{{> partial}}", data) == "x"
  doAssert renderTemplate("{{price|n2}} {{price|n0}} {{n|n1}} {{neg|n2}} {{name|upper}}", data) ==
    "1,234.50 1,235 3.0 0.00 ALI &lt;&amp;&gt; &quot;SONS&quot;"
  doAssert renderTemplate("{{price}} {{zero}} {{flag}}", data) == "1234.5 0 true"
  # broken templates still give their best
  doAssert renderTemplate("a {{name", data) == "a {{name"
  doAssert renderTemplate("{{#items}}open", data) == "openopen"
  doAssert renderTemplate("x{{/nothing}}y", data) == "xy"
  doAssert renderTemplate("{{}}", data) == ""
  doAssert renderTemplate("{{x}}", nil) == ""
  # from Nim values
  type Line = object
    name: string
    qty: int
  type Inv = object
    number: int
    lines: seq[Line]
  doAssert renderTemplate("#{{number}}{{#lines}} {{name}}x{{qty}}{{/lines}}",
                          Inv(number: 7, lines: @[Line(name: "a", qty: 1)])) == "#7 ax1"
  # deep nesting is cut, not a crash
  let deep = "{{#a}}".repeat(500) & "x" & "{{/a}}".repeat(500)
  discard renderTemplate(deep, %*{"a": true})

# ---- HTML ---------------------------------------------------------------------------------------

block html:
  let d = reportFromHtml("""
    <html><head><title>From HTML</title><style>p { color: red }</style></head><body>
    <script>document.write("no")</script>
    <header><span>Left</span><span>Right</span></header>
    <footer>Page {page} of {pages}</footer>
    <h1>Title &amp; more</h1>
    <h2 style="text-align: center">Centered</h2>
    <p>Plain <b>bold</b> <i>italic</i> <u>under</u> <code>mono</code>
       <span style="color: #c00000; font-weight: bold">red</span>
       <font color="blue">blue</font> <a href="https://x.example">link</a><br>after break</p>
    <p style="text-align:right">right side</p>
    <p dir="rtl">مرحبا</p>
    <ul><li>one</li><li>two</li></ul>
    <ol><li>first</li><li>second</li></ol>
    <hr>
    <table border="1">
      <thead><tr><th width="50%">Name</th><th align="right">Qty</th></tr></thead>
      <tbody><tr><td>Paper</td><td>2</td></tr>
             <tr><td colspan="2" bgcolor="#eeeeee">spanning</td></tr></tbody>
      <tfoot><tr><td>Total</td><td>2</td></tr></tfoot>
    </table>
    <div style="page-break-before: always"><p>second page</p></div>
    <p>&lt;not a tag&gt; &euro;5 &#169; &#x41;</p>
    <table><tr><td>outer<table><tr><td>inner</td></tr></table></td></tr></table>
    </body></html>""")
  doAssert d.title == "From HTML"
  doAssert d.pageCount == 2
  let all = d.allText
  doAssert "no" notin all.splitLines and "color" notin all, "scripts and styles are left out"
  let h1 = d.find("Title & more")
  doAssert h1.len == 1 and h1[0].t.bold and h1[0].t.size > d.size * 1.5
  let c = d.find("Centered")[0].t
  doAssert abs(c.x + c.w / 2 - A4.w / 2) < 1
  doAssert d.pageTexts(0).anyIt(it.text.strip == "bold" and it.bold)
  doAssert d.pageTexts(0).anyIt(it.text.strip == "italic" and it.italic)
  doAssert d.pageTexts(0).anyIt(it.text.strip == "mono" and it.mono)
  doAssert d.pageTexts(0).anyIt(it.text.strip == "red" and it.bold and it.color == color(0xC0, 0, 0))
  doAssert d.pageTexts(0).anyIt(it.text.strip == "blue" and it.color.b > 200)
  doAssert d.pageTexts(0).anyIt(it.text.strip == "link" and it.link == "https://x.example")
  doAssert d.find("after break")[0].t.y > d.find("link")[0].t.y, "<br> breaks the line"
  let rs = d.find("right side")[0].t
  doAssert abs(rs.x + rs.w - (A4.w - d.margins.right)) < 0.5
  let ar = d.find("مرحبا")[0].t
  doAssert abs(ar.x + ar.w - (A4.w - d.margins.right)) < 0.5
  doAssert d.find("•").len == 2 and d.find("1.").len == 1 and d.find("2.").len == 1
  doAssert d.find("Name")[0].t.bold
  let q = d.find("Qty")[0].t
  let two = d.pageTexts(0).filterIt(it.text == "2")
  doAssert two.len == 2 and abs(two[0].x + two[0].w - (q.x + q.w)) < 0.5, "th align is the column's"
  doAssert d.find("spanning").len == 1
  doAssert d.find("Total")[0].t.bold
  doAssert d.find("second page")[0].page == 1
  doAssert d.find("<not a tag> €5 © A").len == 1
  doAssert d.find("inner").len == 1
  doAssert d.find("Left")[0].page == 0 and d.find("Right").len == 2
  doAssert d.find("Page 2 of 2").len == 1
  # broken HTML: still a document
  for bad in ["<", "<<<>>>", "<table><tr><td>x", "</p></table></td>", "<p <b>x",
              "<img src=\"/nonexistent.png\">", "&#99999999;&#xFFFFFFFFF;&",
              "<span style=\"font-size: 1e9px\">huge</span>", "<td colspan=\"-5\">x</td>"]:
    let r = reportFromHtml(bad)
    doAssert r.pageCount >= 1
    discard r.pdfBytes()

block invoiceTemplate:
  let tpl = readFile(dataDir / "invoice.html")
  var data = parseJson(readFile(dataDir / "invoice.json"))
  let d = reportFromHtml(renderTemplate(tpl, data), dataDir)
  doAssert d.title == "Invoice INV-2026-0042"
  doAssert d.pageCount == 1
  let all = d.allText
  for want in ["INVOICE", "INV-2026-0042", "Paper A4, 80 g, box of 5 reams", "45.00", "62.50",
               "226.50", "11.33", "237.83", "Sohar Steel & Co. <Head Office>", "Page 1 of 1"]:
    doAssert want in all, want
  # what the data says is text, never markup
  data["customer"]["name"] = %"<script>x</script><b>bold?</b>"
  let d2 = reportFromHtml(renderTemplate(tpl, data), dataDir)
  doAssert d2.find("<script>x</script><b>bold?</b>").len == 1
  # no items: the template's "nothing" row
  data["items"] = %*[]
  let d3 = reportFromHtml(renderTemplate(tpl, data), dataDir)
  doAssert d3.find("Nothing ordered.").len == 1

# ---- printing (a fake CUPS) -------------------------------------------------------------------

when defined(posix) and not defined(android) and not defined(macosx) and not defined(wasm):
  block printing:
    let bin = tmp / "bin"
    createDir(bin)
    let log = tmp / "lp.log"
    proc script(name, body: string) =
      writeFile(bin / name, "#!/bin/sh\n" & body & "\n")
      setFilePermissions(bin / name, {fpUserRead, fpUserWrite, fpUserExec})
    script("lp", "for a in \"$@\"; do echo \"$a\"; done > " & quoteShell(log) &
                 "\necho 'request id is Office-7 (1 file(s))'")
    script("lpstat", "echo 'system default destination: Office'")
    let oldPath = getEnv("PATH")
    putEnv("PATH", bin)
    let d = newReport("Invoice: 42/7")
    d.paragraph("print me")
    var res = d.printReport()
    doAssert res.ok, res.message
    doAssert "request id is Office-7" in res.message
    let args = readFile(log).strip.splitLines
    doAssert args.len == 3 and args[0] == "-t" and args[1] == "Invoice: 42/7", $args
    doAssert fileExists(args[2]) and readFile(args[2]).startsWith("%PDF-")
    res = d.printReport(printer = "Lab")
    doAssert res.ok and readFile(log).strip.splitLines[2 .. 3] == @["-d", "Lab"]
    # a printer that fails
    script("lp", "echo 'lp: The printer or class does not exist.'\nexit 1")
    res = d.printReport()
    doAssert not res.ok and "does not exist" in res.message
    # no default printer and none set up
    script("lpstat", "case \"$1\" in -d) echo 'no system default destination';; *) exit 1;; esac")
    res = d.printReport()
    doAssert not res.ok and res.message == "No printer is set up.", res.message
    # no CUPS at all
    putEnv("PATH", tmp / "nowhere")
    res = d.printReport()
    doAssert not res.ok and "CUPS" in res.message
    putEnv("PATH", oldPath)
    doAssert not printPdf(tmp / "missing.pdf").ok

# ---- the preview: mouse, keys, fingers -----------------------------------------------------------

proc whiteRun(y: int): tuple[x, w: int] =
  ## The longest run of white pixels on line `y`: a page.
  var x = 0
  while x < W:
    if px(x, y) == 0xFFFFFF:
      var n = 0
      while x + n < W and px(x + n, y) == 0xFFFFFF: inc n
      if n > result.w: result = (x, n)
      x += n
    else: inc x

block preview:
  let doc = newReport("Preview")
  doc.paragraph([span("Open the site", link = "https://retro.example", size = 30)])
  for i in 1 .. 300: doc.paragraph("Line " & $i)
  let pages = doc.pageCount
  doAssert pages >= 4
  var ev: ReportViewEvent
  var clicked = ""
  view = proc () =
    ev = reportView(doc, key = "p")
    if ev.link.len > 0: clicked = ev.link
  run(3)
  doAssert ev.pages == pages and ev.page == 0
  # the desk: gray around white pages; find where it starts
  var deskY = -1
  for y in Pad + max(CtrlH - 1, EditH) ..< H:
    if px(Pad + 6, y) == 0x808080:
      deskY = y
      break
  doAssert deskY > 0, "the gray desk"
  let (pageX, pageW) = whiteRun(deskY + 40)
  doAssert pageX > Pad
  doAssert pageW > 500, "fit width: " & $pageW
  # a click on the link reports it
  let z = float(pageW) / A4.w
  let lk = doc.pageTexts(0).filterIt(it.link.len > 0)[0]
  let lx = pageX + int((lk.x + 20) * z)
  let ly = deskY + dp(12) + int((lk.y + lk.size / 2) * z)
  down(lx, ly)
  run()
  up(lx, ly)
  run(2)
  doAssert clicked == "https://retro.example", clicked
  # the wheel goes down the pages
  move(W div 2, H div 2)
  for i in 1 .. 20:
    queue.add Event(kind: MouseWheelEvent, y: -1)
    run()
  doAssert reportViewPage("p") >= 1, "the wheel scrolls"
  # keys (the desk has the focus since the click); the pages glide there
  key(KeyEnd)
  run(12)
  doAssert ev.page == pages - 1, "End: the last page"
  key(KeyHome)
  run(12)
  doAssert ev.page == 0
  key(KeyPageDown)
  key(KeyPageDown)
  key(KeyPageDown)
  run(12)
  doAssert ev.page >= 1, "Page Down"
  key(KeyHome)
  run(12)
  # the page buttons: |<  <  Page 1 of N  >  >|
  let rowH = max(CtrlH - 1, EditH)
  let by = Pad + rowH div 2
  let bw = CtrlH + 1
  let nextX = Pad + 2 * (bw + Gap) + labelWidth("Page 1 of " & $pages) + Gap + bw div 2
  down(nextX, by)
  run()
  up(nextX, by)
  run(12)
  doAssert ev.page == 1, "the next-page button: " & $ev.page
  let lastX = nextX + bw + Gap
  down(lastX, by)
  run()
  up(lastX, by)
  run(12)
  doAssert ev.page == pages - 1, "the last-page button"
  key(KeyHome)
  run(12)
  # zooming out with the keyboard: 50%, the page narrower and centered
  key(KeyMinus)
  key(KeyMinus)
  run(2)
  let w50 = whiteRun(deskY + 30).w
  doAssert abs(w50 - int(A4.w * 0.5 * 96 / 72)) <= 2, "50%: " & $w50
  # Ctrl + the wheel zooms back in
  move(W div 2, H div 2)
  queue.add Event(kind: MouseWheelEvent, y: 1, mods: {CtrlPressed}, hasMods: true)
  run()
  queue.add Event(kind: MouseMoveEvent, x: W div 2, y: H div 2, hasMods: true)   # Ctrl let go
  run(2)
  let w75 = whiteRun(deskY + 30).w
  doAssert w75 > w50 + 50, "Ctrl + the wheel: " & $w75
  # a mouse drag moves the pages
  key(KeyHome)
  run(2)
  let cx = W div 2
  let cy = H - 40
  for k in 1 .. 3:
    down(cx, cy)
    run()
    for i in 1 .. 10:
      move(cx, cy - i * 30)
      run()
    up(cx, cy - 300)
    run(2)
  doAssert ev.page >= 1, "a mouse drag scrolls: " & $ev.page
  # a finger too, and a finger's drag is not a click
  key(KeyHome)
  run(2)
  clicked = ""
  ui.touch = true
  for k in 1 .. 3:
    down(cx, cy)
    run()
    for i in 1 .. 10:
      move(cx, cy - i * 35)
      run()
    up(cx, cy - 350)
    run(2)
  doAssert ev.page >= 1, "a finger scrolls: " & $ev.page
  doAssert clicked == ""
  ui.touch = false
  # the standard scroll bar: a click in its track below the thumb pages down
  key(KeyHome)
  run(2)
  var deskBottom = deskY + 10         # (above the sideways bar, if there is one; below
                                      # the focus rectangle's dots)
  while deskBottom < H and px(Pad + 6, deskBottom) == 0x808080: inc deskBottom
  let sbX = W - Pad - SbW div 2
  let sbY = deskBottom - SbW - 6
  for i in 1 .. 3:
    down(sbX, sbY)
    run()
    up(sbX, sbY)
    run()
  run(2)
  doAssert ev.page >= 1, "the scroll bar: " & $ev.page
  # a new document in the same view starts at the top
  let other = newReport("Other")
  other.paragraph("short")
  view = proc () =
    ev = reportView(other, key = "p")
  run(3)
  doAssert ev.pages == 1 and ev.page == 0

block letterheadBehindEveryPage:
  # a picture behind every page (the letterhead), under the text
  let d = newReport("letter")
  d.setBackground(newBitmap(20, 28, 0xFF2040A0'u32))
  for i in 1 .. 120: d.paragraph("Line " & $i)
  doAssert d.pageCount >= 2
  for p in 0 ..< d.pageCount:
    let bmp = d.renderPage(p, 0.5)
    doAssert (bmp.px[bmp.w * 3 + 3] and 0xFFFFFF'u32) == 0x2040A0'u32, "the paper is the picture, page " & $p
  doAssert d.find("Line 1").len == 1, "the text over it"
  doAssert d.pdfBytes.count("/Subtype /Image") >= 1

echo "test_report: ok"

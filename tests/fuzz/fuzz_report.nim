## Fuzzer for reports: random Mustache templates filled from random JSON,
## random and damaged HTML, and random documents built with the Nim
## procs -- laid out, written as PDF (whose cross-reference table is
## checked), drawn as pictures now and then, and shown in the preview (on
## the fake driver). A Defect or a crash is a bug; so is an input that
## takes more than two seconds and more than 2 ms a page (a hang in the
## making).
##
##   nim c -d:release --stackTrace:on --lineTrace:on tests/fuzz/fuzz_report.nim
##   tests/fuzz/fuzz_report 20000            # iterations
##   tests/fuzz/fuzz_report 20000 7 120      # ... with seed 7, at most 120 seconds
##
## Inputs that fail are saved as crash-report-*.txt in the current folder.

import std/[os, random, strutils, times, monotimes, sets, json, math]
import retroui
import retroui/report
import retroui/uirelays/input
import ../harness

let iters = if paramCount() >= 1: parseInt(paramStr(1)) else: 20000
let seed = if paramCount() >= 2: parseInt(paramStr(2)) else: int(epochTime() * 1000) mod 100000
let budget = if paramCount() >= 3: parseInt(paramStr(3)) else: 300
randomize(seed)

const
  tags = ["p", "div", "span", "b", "i", "u", "em", "strong", "code", "small", "big", "font",
          "a", "img", "br", "hr", "h1", "h2", "h3", "h4", "h6", "ul", "ol", "li", "blockquote",
          "pre", "table", "thead", "tbody", "tfoot", "tr", "td", "th", "center", "header",
          "footer", "title", "script", "style", "head", "body", "html", "section", "x-y"]
  attrs = ["href", "src", "style", "color", "align", "colspan", "width", "height", "border",
           "class", "dir", "bgcolor", "alt"]
  values = ["right", "center", "left", "rtl", "ltr", "3", "-1", "0", "999999", "50%", "120px",
            "1e309px", "nan", "color: red; font-weight: bold", "font-size: 400px",
            "font-size: -3em", "text-align: right", "page-break-before: always", "plain",
            "page-break", "#c00", "rgb(300,-2,x)", "background: #eee", "x.png",
            "/dev/null", "https://e.x/?a=(1)", "", "\t", "font-style: italic"]
  texts = ["hello", "  spaced   out  ", "Invoice {{n}}", "{{name}}", "{{{raw}}}",
           "{{#items}}<tr><td>{{name}}</td><td>{{price|n2}}</td></tr>{{/items}}",
           "{{^items}}none{{/items}}", "{{#a.b}}x{{/a.b}}", "{{.}}", "{{!c}}", "{{",
           "}}", "{{#x}}", "{{/x}}", "&amp; &lt;&gt; &#169; &#x1F600; &#0; &bogus; &euro;",
           "مرحبا بالعالم {{n}}", "Page {page} of {pages}", "<", ">", "&", "\0\x01\x7f\xFF",
           repeat('w', 500), repeat("word ", 200), "line\nbreak", "‮‏"]

proc randomJson(depth: int): JsonNode =
  case rand(if depth > 4: 5 else: 8)
  of 0: result = newJNull()
  of 1: result = newJBool(rand(1) == 0)
  of 2: result = newJInt(rand(-1_000_000 .. 1_000_000))
  of 3: result = newJFloat([1234.5, -0.004, NaN, Inf, 1e300, 0.0, 11.325][rand(6)])
  of 4, 5: result = newJString(texts[rand(texts.high)])
  of 6, 7:
    result = newJArray()
    for _ in 0 ..< rand(0 .. 5): result.add randomJson(depth + 1)
  else:
    result = newJObject()
    for k in ["name", "items", "n", "a", "b", "raw", "price", "x"]:
      if rand(2) == 0: result[k] = randomJson(depth + 1)

proc randomPage(depth: int): string =
  for _ in 0 ..< rand(0 .. 6):
    case rand(9)
    of 0 .. 3: result.add texts[rand(texts.high)]
    of 4: result.add "<!--" & texts[rand(texts.high)] & (if rand(3) == 0: "" else: "-->")
    of 5: result.add "</" & tags[rand(tags.high)] & ">"
    else:
      let t = tags[rand(tags.high)]
      result.add "<" & t
      for _ in 0 ..< rand(0 .. 3):
        result.add " " & attrs[rand(attrs.high)]
        case rand(3)
        of 0: discard
        of 1: result.add "=\"" & values[rand(values.high)] & "\""
        of 2: result.add "='" & values[rand(values.high)] & "'"
        else: result.add "=" & values[rand(values.high)].replace(" ", "")
      result.add(if rand(8) == 0: "/>" else: ">")
      if depth < 10 and rand(3) > 0: result.add randomPage(depth + 1)
      if rand(4) > 0: result.add "</" & t & ">"

proc mutate(s: string): string =
  result = s
  for _ in 0 ..< rand(1 .. 6):
    if result.len == 0: result = "<"
    case rand(5)
    of 0: result[rand(result.high)] = char(rand(255))
    of 1: result.insert(["<", ">", "&", "\"", "{{", "}}", "{{#", "{{/", "</td>", "<tr>"][rand(9)],
                        rand(result.high))
    of 2:
      let i = rand(result.high)
      result.delete(i .. min(result.high, i + rand(30)))
    of 3: result = result[0 ..< rand(result.len)]
    else: result.insert(randomPage(0), rand(result.high))
    if result.len > 100_000: result.setLen(100_000)

proc randomSize(): float =
  [0.0, 1.0, 10.0, 72.0, 500.0, NaN, Inf, -5.0, 1e9][rand(8)]

proc randomDoc(): Report =
  let pages = [A4, Letter, landscape(A4), (mm(100), mm(80)), (NaN, 1e9), (0.0, 0.0)]
  result = newReport(texts[rand(texts.high)], page = pages[rand(pages.high)])
  if rand(3) == 0: result.margins = (randomSize(), randomSize(), randomSize(), randomSize())
  if rand(4) == 0: result.size = randomSize()
  if rand(2) == 0: result.header(texts[rand(texts.high)], "", "{page}/{pages}")
  if rand(2) == 0: result.footer("", texts[rand(texts.high)], "")
  for _ in 0 ..< rand(0 .. 30):
    case rand(12)
    of 0: result.heading(texts[rand(texts.high)], rand(-2 .. 7))
    of 1, 2:
      result.paragraph(texts[rand(texts.high)], [alLeft, alCenter, alRight][rand(2)],
                       size = if rand(3) == 0: randomSize() else: 0.0, rtl = rand(-1 .. 1))
    of 3:
      result.paragraph([span(texts[rand(texts.high)], bold = rand(1) == 0, italic = rand(1) == 0,
                             mono = rand(1) == 0, underline = rand(1) == 0,
                             size = if rand(3) == 0: randomSize() else: 0.0,
                             link = if rand(3) == 0: "https://x.example" else: ""),
                        span(texts[rand(texts.high)])])
    of 4:
      var t = newTable(["A", "B", "C"][0 .. rand(2)], grid = rand(1) == 0, zebra = rand(1) == 0)
      for i in 0 ..< rand(0 .. 3): t.widths.add randomSize() * float(rand(-1 .. 1))
      for _ in 0 ..< rand(0 .. 120):
        if rand(9) == 0: t.addRow([cell(texts[rand(texts.high)], colspan = rand(-1 .. 5))])
        else:
          var row: seq[string]
          for _ in 0 ..< rand(0 .. 5): row.add texts[rand(texts.high)]
          t.addRow(row)
      if rand(1) == 0: t.addTotals(["Total", "", "1"])
      t.plain = rand(4) == 0
      result.table(t)
    of 5: result.pageBreak()
    of 6: result.space(randomSize())
    of 7: result.rule()
    of 8: result.list(["a", texts[rand(texts.high)]], numbered = rand(1) == 0)
    of 9: result.image(newBitmap(rand(1 .. 40), rand(1 .. 40), 0xFF336699'u32),
                       randomSize(), randomSize(), [alLeft, alCenter, alRight][rand(2)])
    of 10: result.beginKeep()
    of 11: result.endKeep()
    else: discard

proc checkPdf(pdf: string) =
  doAssert pdf.startsWith("%PDF-1.") and pdf.endsWith("%%EOF\n")
  let sx = pdf.rfind("startxref")
  let at = parseInt(pdf[sx + 9 .. ^1].strip.splitLines[0])
  doAssert pdf.continuesWith("xref", at)
  let lines = pdf[at .. min(pdf.high, at + 200)].splitLines
  let n = parseInt(lines[1].split(' ')[1])
  # spot-check some objects
  for k in 0 ..< min(n - 1, 5):
    let i = 1 + (k * 7919) mod max(1, n - 1)
    let e = pdf[at + lines[0].len + 1 + lines[1].len + 1 + 20 * i ..< at + lines[0].len + 1 +
                lines[1].len + 1 + 20 * i + 10]
    doAssert pdf.continuesWith($i & " 0 obj", parseInt(e)), "object " & $i

var seen: HashSet[string]
var bugs = 0
proc report(what: string; input: string) =
  let key = what.splitLines[0]
  if key in seen: return
  seen.incl key
  inc bugs
  let f = getCurrentDir() / ("crash-report-" & $bugs & ".txt")
  writeFile(f, input)
  echo "BUG ", what
  echo "   saved ", f

fakeDriver()
startApp("fuzz report", W, H)
var shown = newReport("start")
view = proc () =
  discard reportView(shown, height = 300, key = "fuzz")

let tpl0 = readFile(currentSourcePath.parentDir.parentDir / "data" / "report" / "invoice.html")
var corpus = @[tpl0, randomPage(0)]
let t0 = getMonoTime()
var slowest = 0'i64
var done = 0
var pagesMade = 0
for it in 0 ..< iters:
  if (getMonoTime() - t0).inSeconds > budget: break
  var input = ""
  var n = 0
  let start = getMonoTime()
  try:
    var doc: Report
    case rand(2)
    of 0:
      # a template filled from random data, read as HTML
      let tpl = if rand(1) == 0: randomPage(0) else: mutate(corpus[rand(corpus.high)])
      let data = randomJson(0)
      input = "TEMPLATE:\n" & tpl & "\nDATA:\n" & $data
      var html = renderTemplate(tpl, data)
      # (sections in sections over long lists multiply: a 20 MB page takes
      # seconds, as it should -- hangs are what is looked for)
      if html.len > 1_000_000: html.setLen(1_000_000)
      doc = reportFromHtml(html, getTempDir())
      if html.len > 50 and corpus.len < 200 and rand(10) == 0: corpus.add tpl
    of 1:
      let html = mutate(corpus[rand(corpus.high)])
      input = "HTML:\n" & html
      doc = reportFromHtml(html)
    else:
      input = "BUILDER (seed " & $seed & ", iteration " & $it & ")"
      doc = randomDoc()
    n = doc.pageCount
    doAssert n >= 1
    pagesMade += n
    for p in 0 ..< min(n, 3): discard doc.pageTexts(p)
    if it mod 4 == 0: checkPdf(doc.pdfBytes())
    if it mod 25 == 0: discard doc.renderPage(rand(n - 1), [0.2, 0.5, 1.0][rand(2)])
    if it mod 50 == 0:
      shown = doc
      queue.add Event(kind: MouseWheelEvent, y: rand(-3 .. 3))
      run(1)
  except Exception as e:
    report($e.name & ": " & e.msg & "\n" & e.getStackTrace(), input)
  let ms = (getMonoTime() - start).inMilliseconds
  slowest = max(slowest, ms)
  # (a document of thousands of pages may take seconds: more than 2 ms a
  # page is what is looked for -- 8 times that under the sanitizers, which
  # make it 7 times slower)
  const slower = when defined(retroSanitized): 8 else: 1
  if ms > 2000 * slower and ms > 2 * slower * n:
    report("slow: " & $ms & " ms for " & $n & " pages", input)
  inc done
  if it mod 5000 == 0 and it > 0: echo "round ", it, " (slowest ", slowest, " ms)"
let all = (getMonoTime() - t0).inMilliseconds
echo "report fuzz (seed ", seed, "): ", done, " documents, ", pagesMade, " pages in ", all,
     " ms, slowest ", slowest, " ms, bugs: ", bugs
if bugs > 0: quit(1)

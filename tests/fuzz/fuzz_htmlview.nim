## Fuzzer for the HTML reader (htmlview) and the Markdown it makes: random
## pages built from tags, attributes, entities and text, and damaged copies
## of real-looking pages, read into Markdown, laid out and drawn (on the
## fake driver). A Defect or a crash is a bug; so is an input that takes
## more than a second (a hang in the making).
##
##   nim c -d:release --stackTrace:on --lineTrace:on tests/fuzz/fuzz_htmlview.nim
##   tests/fuzz/fuzz_htmlview 20000          # iterations
##   tests/fuzz/fuzz_htmlview 20000 7        # ... with seed 7
##
## Inputs that fail are saved as crash-html-*.html in the current folder.

import std/[os, random, strutils, times, monotimes, sets]
import retroui, retroui/htmlview
import ../harness

let iters = if paramCount() >= 1: parseInt(paramStr(1)) else: 20000
randomize(if paramCount() >= 2: parseInt(paramStr(2)) else: int(epochTime() * 1000) mod 100000)

const
  tags = ["p", "div", "span", "b", "i", "u", "s", "em", "strong", "code", "kbd", "mark",
          "a", "img", "br", "hr", "h1", "h2", "h3", "h6", "ul", "ol", "li", "dl", "dt",
          "dd", "blockquote", "pre", "table", "thead", "tbody", "tr", "td", "th",
          "caption", "font", "q", "sub", "sup", "small", "script", "style", "title",
          "head", "body", "html", "form", "input", "button", "select", "option",
          "textarea", "iframe", "svg", "math", "xmp", "plaintext", "noscript",
          "section", "article", "center", "details", "summary", "figure", "x-custom"]
  attrs = ["href", "src", "alt", "style", "color", "align", "colspan", "start",
           "class", "type", "checked", "title", "id"]
  values = ["x.html", "javascript:alert(1)", "#top", "https://a.b/c?d=e&f=g",
            "color: red", "background: yellow", "text-align: right", "3", "-1",
            "999999999999", "language-nim", "checkbox", "", "a(b)|c<d>", "\t\n",
            "data:text/html,<b>", "rgb(300, -1, 50%)", "#zzz", "#fff"]
  texts = ["hello", "  spaced   out  ", "*star* _under_ `tick`", "[x](y)", "# not",
           "1. not", "| pipe |", "&amp; &lt;&gt; &#169; &#x1F600; &#0; &bogus;",
           "مرحبا بالعالم", "<", ">", "&", "\\", "``` fence", "---", "> quote",
           "line\nbreak", "‏‮", "\0\x01\x7f", repeat('w', 300)]

proc randomPage(depth: int): string =
  let n = rand(0 .. 6)
  for _ in 0 ..< n:
    case rand(9)
    of 0 .. 3: result.add texts[rand(texts.high)]
    of 4:
      result.add "<!--" & texts[rand(texts.high)] & (if rand(3) == 0: "" else: "-->")
    of 5:
      result.add "</" & tags[rand(tags.high)] & ">"
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
      if depth < 12 and rand(3) > 0: result.add randomPage(depth + 1)
      if rand(4) > 0: result.add "</" & t & ">"

proc mutate(s: string): string =
  result = s
  for _ in 0 ..< rand(1 .. 6):
    if result.len == 0: result = "<"
    case rand(6)
    of 0:
      let i = rand(result.high)
      result[i] = char(rand(255))
    of 1:
      let i = rand(result.high)
      result.insert(["<", ">", "&", "\"", "'", "/", "=", "<!--", "]]>", "</"][rand(9)], i)
    of 2:
      let i = rand(result.high)
      result.delete(i .. min(result.high, i + rand(20)))
    of 3:
      let i = rand(result.high)
      let j = rand(result.high)
      result.insert(result[min(i, j) .. min(result.high, min(i, j) + rand(60))], max(i, j))
    of 4:
      result = result[0 ..< rand(result.len)]
    else:
      let i = rand(result.high)
      result.insert(randomPage(0), i)
    if result.len > 200_000: result.setLen(200_000)

var seen: HashSet[string]
var bugs = 0
proc report(what: string; input: string) =
  if what in seen: return
  seen.incl what
  inc bugs
  let f = getCurrentDir() / ("crash-html-" & $bugs & ".html")
  writeFile(f, input)
  echo "BUG ", what
  echo "   saved ", f

fakeDriver()
startApp("fuzz html", W, H)
var page = ""
view = proc () =
  discard htmlView(page, height = 300, key = "fuzz")
  discard htmlBlock(page, w = 200)

let base = randomPage(0) & "<table><tr><th>a<td>b</table><ul><li>x<li>y</ul><pre>p</pre>"
var corpus = @[base]
let t0 = getMonoTime()
var slowest = 0'i64
for it in 0 ..< iters:
  let src = if rand(2) == 0: randomPage(0) else: mutate(corpus[rand(corpus.high)])
  let start = getMonoTime()
  try:
    let md = htmlToMarkdown(src)
    discard htmlTitle(src)
    discard decodeEntities(src)
    if it mod 8 == 0:
      page = src
      run(1)
    if md.len > 20 and corpus.len < 200 and rand(10) == 0: corpus.add src
  except Exception as e:
    report($e.name & ": " & e.msg & "\n" & e.getStackTrace(), src)
  let ms = (getMonoTime() - start).inMilliseconds
  slowest = max(slowest, ms)
  if ms > (when defined(retroSanitized): 8000 else: 1000):      # (the sanitizers: 7 times slower)
    report("slow: " & $ms & " ms", src)
  if it mod 5000 == 0 and it > 0:
    echo "round ", it, " (slowest ", slowest, " ms)"
let all = (getMonoTime() - t0).inMilliseconds
echo "html fuzz: ", iters, " pages in ", all, " ms, slowest ", slowest, " ms, bugs: ", bugs
if bugs > 0: quit(1)

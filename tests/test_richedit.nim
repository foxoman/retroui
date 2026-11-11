## Tests of the rich text editor (`retroui/richedit`): HTML in and out, plain
## text, the commands, undo, the keys and the mouse -- headless, on the
## fake driver.
##
##   nim c -r tests/test_richedit.nim

import std/[strutils, sequtils, times, monotimes, random, os]
from std/unicode import runes, toUTF8
import retroui, retroui/richedit, retroui/spell
import retroui/uirelays/input
import harness

fakeDriver()
startApp("richedit", W, H)

proc texts(d: RichDoc): seq[string] =
  for p in d.paras: result.add paraText(p)

proc runOf(d: RichDoc; para: int; word: string): RichRun =
  ## The run of paragraph `para` that has `word`.
  for r in d.paras[para].runs:
    if word in r.text: return r
  doAssert false, "no run with " & word & " in " & $d.paras[para].runs

proc sel(d: var RichDoc; p0, o0, p1, o1: int) =
  richSelect(d, RichPos(para: p0, off: o0), RichPos(para: p1, off: o1))

# ---- HTML in -------------------------------------------------------------------------------------

block htmlBasics:
  let d = richFromHtml("<p>Hello <b>bold</b> and <i>it</i>, <u>u</u> <s>s</s> <code>c</code></p>")
  doAssert d.paras.len == 1
  doAssert paraText(d.paras[0]) == "Hello bold and it, u s c", paraText(d.paras[0])
  doAssert runOf(d, 0, "bold").style.bold
  doAssert not runOf(d, 0, "Hello").style.bold
  doAssert runOf(d, 0, "it").style.italic
  doAssert runOf(d, 0, "u").style.underline
  doAssert d.paras[0].runs.anyIt(it.text == "s" and it.style.strike)
  doAssert d.paras[0].runs.anyIt(it.text == "c" and it.style.mono)

block htmlSpansAndFonts:
  let d = richFromHtml("""<div><span style="color:#ff0000;font-weight:bold">red</span>
    <span style="font-size:22pt">big</span> <font color="navy" size="1">small</font>
    <span style="font-family:'Courier New'">mono</span>
    <span style="font-style:italic;text-decoration:underline line-through">deco</span>
    <span style="color:rgb(0, 128, 0)">green</span> <span style="color:black">black</span></div>""")
  doAssert d.paras.len == 1, $d.texts
  let red = runOf(d, 0, "red").style
  doAssert red.bold and red.color == color(255, 0, 0)
  doAssert abs(runOf(d, 0, "big").style.size - 2.0) < 0.01, $runOf(d, 0, "big").style.size
  let sm = runOf(d, 0, "small").style
  doAssert sm.color == color(0, 0, 128) and abs(sm.size - 0.7) < 0.01
  doAssert runOf(d, 0, "mono").style.mono
  let dc = runOf(d, 0, "deco").style
  doAssert dc.italic and dc.underline and dc.strike
  doAssert runOf(d, 0, "green").style.color == color(0, 128, 0)
  doAssert runOf(d, 0, "black").style.color.a == 0, "black is the normal color"
  doAssert paraText(d.paras[0]) == "red big small mono deco green black", paraText(d.paras[0])

block htmlParagraphs:
  let d = richFromHtml("<div>one</div><div><br></div><div>three<br>four</div>a<br><br>b")
  doAssert d.texts == @["one", "", "three", "four", "a", "", "b"], $d.texts
  let o = richFromHtml("""<p class=MsoNormal>Hi<o:p></o:p></p>
    <p class=MsoNormal><o:p>&nbsp;</o:p></p><p class=MsoNormal>Bye&nbsp;&nbsp;now<o:p></o:p></p>""")
  doAssert o.texts == @["Hi", "", "Bye  now"], $o.texts
  let ws = richFromHtml("<p>  lots   of\n\n spaces  <b> here </b> </p>")
  doAssert ws.texts == @["lots of spaces here"], $ws.texts

block htmlLists:
  let d = richFromHtml("""<ul><li>a<ul><li>b</li><li>c<ol><li>d</li></ol></li></ul></li>
    <li>e</li></ul><ol><li>one</li><li>two</li></ol><p>after</p>""")
  doAssert d.texts == @["a", "b", "c", "d", "e", "one", "two", "after"], $d.texts
  doAssert d.paras[0].kind == pkBullet and d.paras[0].level == 0
  doAssert d.paras[1].kind == pkBullet and d.paras[1].level == 1
  doAssert d.paras[3].kind == pkNumber and d.paras[3].level == 2
  doAssert d.paras[4].kind == pkBullet and d.paras[4].level == 0
  doAssert d.paras[5].kind == pkNumber and d.paras[6].kind == pkNumber
  doAssert d.paras[7].kind == pkNormal

block htmlQuotesHeadingsPre:
  let d = richFromHtml("""<h1>Title</h1><h3>Small</h3><blockquote type="cite"><div>q1</div>
    <blockquote>q2</blockquote></blockquote>
    <blockquote style="margin:0 0 0 40px;border:none;padding:0px">indented</blockquote>
    <pre>line 1
  line 2</pre><p style="text-align:center">mid</p><p align=right>right</p>
    <p style="margin-left:80px">deep</p>""")
  doAssert d.texts == @["Title", "Small", "q1", "q2", "indented", "line 1", "  line 2",
                        "mid", "right", "deep"], $d.texts
  doAssert d.paras[0].kind == pkHeading and d.paras[0].level == 0
  doAssert d.paras[1].kind == pkHeading and d.paras[1].level == 2
  doAssert d.paras[2].kind == pkQuote and d.paras[2].level == 0
  doAssert d.paras[3].kind == pkQuote and d.paras[3].level == 1
  doAssert d.paras[4].kind == pkNormal and d.paras[4].level == 1, "Gmail's indent"
  doAssert d.paras[5].runs[0].style.mono and d.paras[6].runs[0].style.mono
  doAssert d.paras[7].align == alCenter and d.paras[8].align == alRight
  doAssert d.paras[9].level == 2

block htmlLinksAndJunk:
  let d = richFromHtml("""<html><head><title>T</title><style>p{color:red}</style>
    <script>alert(1)</script></head><body><!-- c --><p>See <a href="https://x.org/?a=1&amp;b=2">the
    <b>site</b></a> &amp; <a href="javascript:alert(1)">bad</a> &lt;3 &#169; &#x41;</p>
    <div style="display:none">hidden preheader</div><img src="x.png" alt="logo">
    <table><tr><td>c1</td><td>c2</td></tr></table></body></html>""")
  doAssert d.texts == @["See the site & bad <3 © A", "c1 c2"], $d.texts
  doAssert runOf(d, 0, "the").style.link == "https://x.org/?a=1&b=2"
  doAssert runOf(d, 0, "site").style.link == "https://x.org/?a=1&b=2" and
           runOf(d, 0, "site").style.bold
  doAssert runOf(d, 0, "bad").style.link == "", "no scripts in links"

block htmlArabic:
  let d = richFromHtml("""<p dir="rtl">مرحبا <b>بالعالم</b></p><p dir="rtl" style="text-align:left">يسار</p>""")
  doAssert paraText(d.paras[0]) == "مرحبا بالعالم"
  doAssert runOf(d, 0, "بالعالم").style.bold
  doAssert d.paras[0].align == alLeft, "its start (the right)"
  doAssert d.paras[1].align == alRight, "the left of an Arabic paragraph is its end"
  let h = toHtml(d)
  doAssert "dir=\"rtl\"" in h and "text-align:left" in h, h

block htmlNeverRaises:
  randomize(7)
  let pieces = ["<p>", "</p>", "<b>", "</i>", "<ul>", "<li>", "</ul>", "<ol>", "<blockquote>",
                "</blockquote>", "<a href='x'>", "</a>", "<br>", "&amp;", "&#", "&#x110000;",
                "<", ">", "\"", "text ", "مرحبا", "<pre>", "</pre>", "<span style='font-size:", "'>",
                "<font size=+9>", "<h2>", "<table><tr><td>", "<!--", "<script>", "<style>", "\n",
                "<div style=\"display:none\">", "</div>", "<td>", "<o:p>", "<![CDATA[", "]]>"]
  for round in 0 ..< 400:
    var s = ""
    for k in 0 ..< rand(1 .. 40): s.add pieces[rand(pieces.high)]
    let d = richFromHtml(s)
    doAssert d.paras.len >= 1
    discard toHtml(d)
    discard toPlainText(d)
  doAssert richFromHtml("").paras.len == 1
  doAssert richFromHtml(repeat("<div>", 5000) & "deep" & repeat("</div>", 5000)).texts == @["deep"]

# ---- HTML out, and back ----------------------------------------------------------------------------

proc same(a, b: RichDoc): bool =
  if a.paras.len != b.paras.len: return false
  for i in 0 ..< a.paras.len:
    if a.paras[i] != b.paras[i]: return false
  true

block roundTrips:
  let samples = [
    "<p>Hello <b>bold <i>both</i></b> <u>under</u> <s>gone</s></p>",
    "<p><span style=\"color:#c00000;font-size:16.5pt\">big red</span> <code>mono</code></p>",
    "<ul><li>a<ul><li>b</li><li>c</li></ul></li><li>d</li></ul><ol><li>1</li><li>2<ol><li>2.1</li></ol></li></ol>",
    "<blockquote><p>q</p><blockquote><p>qq</p></blockquote><p>q again</p></blockquote><p>after</p>",
    "<h1>H1</h1><h2>H2</h2><p>text</p>",
    "<p>see <a href=\"https://nim-lang.org\">Nim <b>here</b></a> and <a href=\"mailto:a@b.c\">mail</a></p>",
    "<p dir=\"rtl\">مرحبا <i>بالعالم</i></p><p style=\"text-align:center\">mid</p><p style=\"margin-left:40px\">in</p>",
    "<p>two  spaces &nbsp; and&nbsp;trailing&nbsp;</p><p><br></p><p>&nbsp;lead</p>",
    "<p>&lt;tags&gt; &amp; &quot;quotes&quot;</p>"]
  for s in samples:
    let d = richFromHtml(s)
    let h = toHtml(d)
    let d2 = richFromHtml(h)
    doAssert same(d, d2), "round trip of " & s & "\n" & h & "\n" & $d.paras & "\n" & $d2.paras
    doAssert toHtml(d2) == h, "stable: " & h
  # what the spaces became
  let sp = richFromHtml(samples[7])
  doAssert sp.texts == @["two spaces   and trailing ", "", " lead"], $sp.texts
  # an empty paragraph, a list item
  let h = toHtml(richFromHtml("<p>a</p><p><br></p><ul><li><br></li></ul>"))
  doAssert "<p style=\"margin:0\"><br></p>" in h and "<li><br>" in h, h

block htmlShape:
  var d = richDoc("Hello\n\nworld")
  let h = toHtml(d)
  doAssert h == "<p style=\"margin:0\">Hello</p>\n<p style=\"margin:0\"><br></p>\n" &
                "<p style=\"margin:0\">world</p>\n", h
  doAssert "<style" notin h and "class=" notin h

# ---- plain text -------------------------------------------------------------------------------------

block plainText:
  let d = richFromHtml("""<p>Hi <a href="https://x.org">our site</a>, <a href="https://y.org">https://y.org</a>
    <a href="mailto:me@x.org">me@x.org</a></p><ul><li>one<ul><li>two</li></ul></li></ul>
    <ol><li>first</li><li>second</li></ol><blockquote>q<blockquote>qq</blockquote></blockquote>
    <p style="margin-left:40px">ind</p>""")
  let t = toPlainText(d)
  doAssert t == "Hi our site <https://x.org>, https://y.org me@x.org\n- one\n  - two\n1. first\n" &
                "2. second\n> q\n>> qq\n    ind", t
  doAssert toPlainText(richDoc("a\nb")) == "a\nb"
  doAssert isEmpty(richDoc("")) and isEmpty(richDoc("  \n ")) and not isEmpty(richDoc("x"))

# ---- commands ------------------------------------------------------------------------------------------

block boldAcrossRunsAndParas:
  var d = richFromHtml("<p>one <i>two</i> three</p><p>four five</p>")
  sel(d, 0, 4, 1, 4)                     # "two three\nfour"
  richBold(d)
  doAssert runOf(d, 0, "two").style.bold and runOf(d, 0, "two").style.italic
  doAssert runOf(d, 0, "three").style.bold and not runOf(d, 0, "one").style.bold
  doAssert runOf(d, 1, "four").style.bold and not runOf(d, 1, "five").style.bold
  doAssert richState(d).bold
  richBold(d)                            # all bold: off again
  doAssert not runOf(d, 0, "three").style.bold and not runOf(d, 1, "four").style.bold
  doAssert runOf(d, 0, "two").style.italic
  sel(d, 0, 0, 0, 7)                     # "one two": half italic
  doAssert not richState(d).italic
  richItalic(d)
  doAssert runOf(d, 0, "one").style.italic and richState(d).italic
  richUnderline(d)
  richStrike(d)
  richMono(d)
  let s = richState(d)
  doAssert s.underline and s.strike and s.mono
  doAssert d.paras[0].runs.len == 2, $d.paras[0].runs   # (runs of one style joined)

block colorAndSize:
  var d = richDoc("alpha beta gamma")
  sel(d, 0, 6, 0, 10)
  richColor(d, color(255, 0, 0))
  richSize(d, 1.3)
  let b = runOf(d, 0, "beta").style
  doAssert b.color == color(255, 0, 0) and abs(b.size - 1.3) < 0.001
  doAssert runOf(d, 0, "alpha").style.color.a == 0
  richColor(d, Color())
  richSize(d, 1.0)
  doAssert d.paras[0].runs.len == 1, "back to one run"

block caretWordAndTypingStyle:
  var d = richDoc("hello world")
  sel(d, 0, 2, 0, 2)                     # in "hello"
  richBold(d)
  doAssert runOf(d, 0, "hello").style.bold and not runOf(d, 0, "world").style.bold
  doAssert richSelection(d).a == richSelection(d).b, "the caret stays"
  sel(d, 0, 5, 0, 5)                     # between the words: what is typed next
  richBold(d)
  doAssert not richState(d).bold, "after a bold word, Bold switches it off"
  richItalic(d)
  doAssert richState(d).italic
  richInsert(d, "X")
  let x = runOf(d, 0, "X").style
  doAssert x.italic and not x.bold, $x
  doAssert paraText(d.paras[0]) == "helloX world"

block listsAlignIndent:
  var d = richDoc("a\nb\nc")
  sel(d, 0, 0, 1, 1)
  richList(d, pkBullet)
  doAssert d.paras[0].kind == pkBullet and d.paras[1].kind == pkBullet and d.paras[2].kind == pkNormal
  doAssert richParaKind(d) == pkBullet
  richList(d, pkNumber)                  # bullets -> numbers
  doAssert d.paras[0].kind == pkNumber and d.paras[1].kind == pkNumber
  richIndent(d, 1)
  doAssert d.paras[0].level == 1
  richIndent(d, -5)
  doAssert d.paras[0].level == 0
  richList(d, pkNumber)                  # all numbered: off
  doAssert d.paras[0].kind == pkNormal
  richList(d, pkQuote)
  doAssert d.paras[1].kind == pkQuote
  richAlign(d, alCenter)
  doAssert d.paras[0].align == alCenter and d.paras[2].align == alLeft
  sel(d, 2, 0, 2, 0)
  richList(d, pkHeading)
  doAssert d.paras[2].kind == pkHeading

block links:
  var d = richDoc("see the docs now")
  sel(d, 0, 4, 0, 12)
  richLink(d, "nim-lang.org/docs")
  doAssert runOf(d, 0, "the docs").style.link == "nim-lang.org/docs"
  sel(d, 0, 6, 0, 6)                     # in the link: all of it changes
  richLink(d, "www.nim-lang.org")
  doAssert runOf(d, 0, "the docs").style.link == "https://www.nim-lang.org"
  doAssert richState(d).link == "https://www.nim-lang.org"
  richLink(d, "")
  doAssert d.paras[0].runs.len == 1 and d.paras[0].runs[0].style.link == ""
  sel(d, 0, 16, 0, 16)                   # at the end, nothing to link: the address goes in
  richInsert(d, " ")
  richLink(d, "me@foxoman.net")
  doAssert paraText(d.paras[0]) == "see the docs now me@foxoman.net"
  doAssert runOf(d, 0, "me@").style.link == "mailto:me@foxoman.net"
  richInsert(d, "!")                     # typing after a link is not linked
  doAssert runOf(d, 0, "!").style.link == ""
  sel(d, 0, 0, 0, 3)
  richLink(d, "javascript:alert(1)")
  doAssert runOf(d, 0, "see").style.link == ""

block insertAndClear:
  var d = richDoc("start end")
  sel(d, 0, 6, 0, 6)
  richInsert(d, "one\ntwo\nthree ")
  doAssert d.texts == @["start one", "two", "three end"], $d.texts
  doAssert richCaret(d) == RichPos(para: 2, off: 6)
  var sig = richFromHtml("<p>--</p><p><b>Sultan</b> Al Isaiee</p>")
  sel(d, 0, 0, 0, 0)
  richInsertDoc(d, sig)
  doAssert d.texts == @["--", "Sultan Al Isaieestart one", "two", "three end"], $d.texts
  doAssert runOf(d, 1, "Sultan").style.bold
  # clear formatting
  var c = richFromHtml("<h2>Head <b>bold</b></h2><p style='text-align:center'><a href='x'>l</a> <i>i</i></p>")
  sel(c, 0, 0, 1, 3)
  richClearFormat(c)
  doAssert c.paras[0].kind == pkNormal and c.paras[1].align == alLeft
  doAssert not runOf(c, 0, "bold").style.bold and not runOf(c, 1, "i").style.italic
  doAssert runOf(c, 1, "l").style.link == "x", "links stay"

block undoRedo:
  var d = richDoc("abc")
  sel(d, 0, 0, 0, 3)
  richBold(d)
  richInsert(d, "x")                     # replaces the selection
  doAssert d.texts == @["x"]
  richUndo(d)
  doAssert d.texts == @["abc"] and runOf(d, 0, "abc").style.bold
  doAssert richSelection(d) == (RichPos(para: 0, off: 0), RichPos(para: 0, off: 3))
  richUndo(d)
  doAssert not runOf(d, 0, "abc").style.bold
  doAssert not richCanUndo(d) and richCanRedo(d)
  richRedo(d)
  richRedo(d)
  doAssert d.texts == @["x"]
  richUndo(d)
  richList(d, pkBullet)                  # a new change: no redo after it
  doAssert not richCanRedo(d)
  richUndo(d)
  doAssert d.paras[0].kind == pkNormal

# ---- the editor: keys and the mouse --------------------------------------------------------------

var
  doc = richDoc("")
  edRect: Rect
  changes = 0
  showBar = true

view = proc () =
  if showBar: richToolbar(doc)
  if richEdit(doc, height = 300, placeholder = "Write here"): inc changes
  edRect = ui.lastRect

proc ctrl(k: KeyCode) = key(k, {CtrlPressed})
proc clickAt(x, y: int; clicks = 1) =
  down(x, y, clicks)
  run()
  up(x, y)
  run()

run(3)

block focusAndType:
  doAssert doc.isEmpty
  clickAt(edRect.x + 40, edRect.y + 10)
  doAssert richFocused(doc)
  typeText("Hello world")
  run()
  doAssert doc.texts == @["Hello world"], $doc.texts
  doAssert changes > 0
  key(KeyEnter)
  typeText("second")
  run()
  doAssert doc.texts == @["Hello world", "second"], $doc.texts
  # Shift+Home selects the line; Ctrl+B makes it bold
  key(KeyHome, {ShiftPressed})
  ctrl(KeyB)
  run()
  doAssert runOf(doc, 1, "second").style.bold
  doAssert not runOf(doc, 0, "Hello").style.bold
  # typing replaces the selection, in its style
  key(KeyEnd)
  key(KeyLeft, {ShiftPressed, CtrlPressed})
  typeText("2nd")
  run()
  doAssert doc.texts == @["Hello world", "2nd"], $doc.texts
  doAssert runOf(doc, 1, "2nd").style.bold

block undoTyping:
  ctrl(KeyA)
  key(KeyDelete)
  run()
  doAssert doc.isEmpty
  typeText("one two three")
  run()
  ctrl(KeyZ)
  run()
  doAssert doc.texts == @["one two "], $doc.texts
  ctrl(KeyZ)
  run()
  doAssert doc.texts == @["one "], $doc.texts
  ctrl(KeyY)
  run()
  doAssert doc.texts == @["one two "], $doc.texts
  key(KeyZ, {CtrlPressed, ShiftPressed})
  run()
  doAssert doc.texts == @["one two three"], $doc.texts
  ctrl(KeyZ)
  ctrl(KeyZ)
  ctrl(KeyZ)
  run()
  doAssert doc.isEmpty, $doc.texts

block listKeys:
  doc = richDoc("")
  run()
  clickAt(edRect.x + 40, edRect.y + 10)
  key(Key8, {CtrlPressed, ShiftPressed})
  typeText("apple")
  key(KeyEnter)
  typeText("pear")
  run()
  doAssert doc.texts == @["apple", "pear"] and doc.paras[1].kind == pkBullet, $doc.paras
  key(KeyTab)                            # Tab in a list: deeper
  run()
  doAssert doc.paras[1].level == 1
  key(KeyTab, {ShiftPressed})
  run()
  doAssert doc.paras[1].level == 0
  key(KeyEnter)
  run()
  doAssert doc.paras.len == 3 and doc.paras[2].kind == pkBullet
  key(KeyEnter)                          # Enter on an empty item: out of the list
  run()
  doAssert doc.paras.len == 3 and doc.paras[2].kind == pkNormal, $doc.paras
  typeText("plain")
  key(KeyUp)
  key(KeyHome)
  key(KeyBackspace)                      # at an item's start: its bullet goes first
  run()
  doAssert doc.paras[1].kind == pkNormal and doc.texts == @["apple", "pear", "plain"]
  key(KeyBackspace)                      # then it joins the one before
  run()
  doAssert doc.texts == @["applepear", "plain"], $doc.texts
  doAssert doc.paras[0].kind == pkBullet
  # quotes: Enter on an empty quoted line leaves the quote
  doc = richFromHtml("<blockquote>quoted</blockquote>")
  run()
  clickAt(edRect.x + 200, edRect.y + 10)
  key(KeyEnd)
  key(KeyEnter)
  key(KeyEnter)
  typeText("reply")
  run()
  doAssert doc.texts == @["quoted", "reply"], $doc.texts
  doAssert doc.paras[0].kind == pkQuote and doc.paras[1].kind == pkNormal

block clipboard:
  doc = richFromHtml("<p>copy <b>this</b> text</p>")
  run()
  clickAt(edRect.x + 200, edRect.y + 10)
  richSelect(doc, RichPos(para: 0, off: 5), RichPos(para: 0, off: 9))
  ctrl(KeyC)
  run()
  doAssert getClipboardText() == "this"
  key(KeyEnd)
  ctrl(KeyV)                             # pasted with its formatting
  run()
  doAssert doc.texts == @["copy this textthis"], $doc.texts
  doAssert doc.paras[0].runs[^1].style.bold
  putClipboardText("plain\nlines")       # text from elsewhere: plain
  ctrl(KeyV)
  run()
  doAssert doc.texts == @["copy this textthisplain", "lines"], $doc.texts
  doAssert doc.paras[1].runs[0].style.bold, "plain text takes the style at the caret"
  ctrl(KeyA)
  ctrl(KeyX)
  run()
  doAssert doc.isEmpty and getClipboardText() == "copy this textthisplain\nlines"

block mouse:
  doc = richDoc("first line here\nsecond line")
  run()
  # a double click selects a word, a triple click the paragraph
  let y1 = edRect.y + 2 + dp(6) + FontH div 2
  clickAt(edRect.x + 2 + dp(6) + 1, y1)
  doAssert richCaret(doc) == RichPos(para: 0, off: 0), $richCaret(doc)
  clickAt(edRect.x + 2 + dp(6) + textWidth("first li"), y1, clicks = 2)
  doAssert richSelectedText(doc) == "line ", richSelectedText(doc)
  clickAt(edRect.x + 2 + dp(6) + 10, y1 + FontH, clicks = 3)
  doAssert richSelectedText(doc) == "second line", richSelectedText(doc)
  # a drag selects
  let x0 = edRect.x + 2 + dp(6)
  down(x0 + 1, y1)
  run()
  move(x0 + textWidth("second"), y1 + FontH)
  run()
  up(x0 + textWidth("second"), y1 + FontH)
  run()
  doAssert richSelectedText(doc) == "first line here\nsecond", richSelectedText(doc)
  # Shift+click extends it
  queue.add Event(kind: MouseMoveEvent, x: x0 + textWidth("first line"), y: y1)
  queue.add Event(kind: MouseDownEvent, x: x0 + textWidth("first line"), y: y1,
                  button: LeftButton, clicks: 1, mods: {ShiftPressed}, hasMods: true)
  run()
  up(x0 + textWidth("first line"), y1)
  run()
  doAssert richSelectedText(doc) == "first line", richSelectedText(doc)

block toolbarClicks:
  doc = richDoc("make me bold")
  run()
  richSelect(doc, RichPos(para: 0, off: 8), RichPos(para: 0, off: 12))
  run()
  # the tool bar's first button is Bold
  let barY = edRect.y - Gap - CtrlH div 2
  clickAt(Pad + 8, barY)
  doAssert runOf(doc, 0, "bold").style.bold, $doc.paras
  doAssert not runOf(doc, 0, "make").style.bold

block arabic:
  doc = richDoc("مرحبا بالعالم\nHello")
  run()
  let l0 = edRect.x + 2 + dp(6)
  richSelect(doc, RichPos(para: 0, off: 0), RichPos(para: 0, off: 0))
  run()
  let start = richCaretRect(doc)
  richSelect(doc, RichPos(para: 0, off: paraText(doc.paras[0]).len),
              RichPos(para: 0, off: paraText(doc.paras[0]).len))
  run()
  let finish = richCaretRect(doc)
  let w = textWidth("مرحبا بالعالم")
  doAssert start.x > edRect.x + edRect.w - SbW - dp(30), "an Arabic paragraph starts at the right: " & $start
  doAssert finish.x < start.x and abs((start.x - finish.x) - w) <= 3, $(start, finish, w)
  richSelect(doc, RichPos(para: 1, off: 0), RichPos(para: 1, off: 0))
  run()
  doAssert richCaretRect(doc).x <= l0 + 1, "Hello starts at the left"
  # the Left arrow goes on through Arabic text (to the left on screen)
  richSelect(doc, RichPos(para: 0, off: 0), RichPos(para: 0, off: 0))
  clickAt(start.x - 2, start.y + 2)
  let before = richCaretRect(doc).x
  key(KeyLeft)
  run()
  doAssert richCaret(doc).off > 0 and richCaretRect(doc).x < before, $richCaret(doc)

block wrappedLines:
  # a paragraph longer than the editor is wide wraps; Home, End, Up and
  # Down go by the lines shown
  var words = ""
  for i in 0 ..< 60: words.add "word" & $i & " "
  doc = richDoc(words.strip & "\nlast")
  run()
  clickAt(edRect.x + 2 + dp(6) + 1, edRect.y + 2 + dp(6) + FontH div 2)
  doAssert richCaret(doc) == RichPos(para: 0, off: 0)
  key(KeyEnd)
  run()
  let e1 = richCaret(doc)
  doAssert e1.para == 0 and e1.off > 10 and e1.off < paraText(doc.paras[0]).len, $e1
  doAssert paraText(doc.paras[0])[e1.off] == ' ', "the end of a wrapped line: before its space"
  key(KeyDown)
  run()
  let d1 = richCaret(doc)
  doAssert d1.para == 0 and d1.off > e1.off, $d1
  key(KeyHome)
  run()
  doAssert richCaret(doc).off == e1.off + 1, "Home: the line's start"
  key(KeyDown, {})
  key(KeyDown)
  key(KeyDown)
  key(KeyDown)
  run()
  doAssert richCaret(doc).para == 1
  key(KeyUp)
  run()
  doAssert richCaret(doc).para == 0
  ctrl(KeyHome)
  key(KeyRight, {CtrlPressed})
  run()
  doAssert richCaret(doc).off == 6, $richCaret(doc)      # "word0 |"
  key(KeyRight, {CtrlPressed, ShiftPressed})
  run()
  doAssert richSelectedText(doc) == "word1 "
  ctrl(KeyEnd)
  key(KeyLeft, {CtrlPressed})
  run()
  doAssert richCaret(doc) == RichPos(para: 1, off: 0)
  key(KeyLeft)
  run()
  doAssert richCaret(doc).para == 0 and richCaret(doc).off == paraText(doc.paras[0]).len

block joinAndDelete:
  doc = richDoc("one two\nthree")
  run()
  clickAt(edRect.x + 40, edRect.y + 10)
  ctrl(KeyEnd)
  key(KeyBackspace, {CtrlPressed})        # a word at a time
  run()
  doAssert doc.texts == @["one two", ""], $doc.texts
  key(KeyBackspace)                       # joins the line before
  run()
  doAssert doc.texts == @["one two"]
  key(KeyHome)
  key(KeyDelete, {CtrlPressed})
  run()
  doAssert doc.texts == @["two"], $doc.texts
  key(KeyEnd)
  key(KeyEnter)
  typeText("x")
  key(KeyUp)
  key(KeyEnd)
  key(KeyDelete)                          # at a paragraph's end: the next one joins
  run()
  doAssert doc.texts == @["twox"], $doc.texts
  # a line end typed (as some on-screen keyboards send Enter)
  key(KeyEnd)
  typeText("\n")
  typeText("y")
  run()
  doAssert doc.texts == @["twox", "y"], $doc.texts

block linkKeysAndClicks:
  doc = richDoc("visit nim today")
  showBar = false
  run()
  clickAt(edRect.x + 2 + dp(6) + textWidth("visit n"), edRect.y + 2 + dp(6) + FontH div 2)
  doAssert richCaret(doc).off == 7
  ctrl(KeyK)                              # the link dialog: the caret's word gets it
  run()
  typeText("nim-lang.org")
  key(KeyEnter)
  run()
  doAssert runOf(doc, 0, "nim").style.link == "nim-lang.org", $doc.paras
  # Ctrl+click: reported, not followed
  let lx = edRect.x + 2 + dp(6) + textWidth("visit n")
  let ly = edRect.y + 2 + dp(6) + FontH div 2
  doAssert richLinkAt(doc, lx, ly) == "nim-lang.org"
  var seen = ""
  let before = view
  view = proc () =
    before()
    if richClickedLink(doc).len > 0: seen = richClickedLink(doc)
  queue.add Event(kind: MouseMoveEvent, x: lx, y: ly)
  queue.add Event(kind: MouseDownEvent, x: lx, y: ly, button: LeftButton, clicks: 1,
                  mods: {CtrlPressed}, hasMods: true)
  run()
  up(lx, ly)
  run()
  view = before
  doAssert seen == "nim-lang.org"
  # the menu (a right click): Select all, then Bold from the keys
  queue.add Event(kind: MouseMoveEvent, x: lx, y: ly)
  queue.add Event(kind: MouseDownEvent, x: lx, y: ly, button: RightButton, clicks: 1)
  queue.add Event(kind: MouseUpEvent, x: lx, y: ly, button: RightButton)
  run()
  key(KeyUp)                              # (the last item: Select all)
  key(KeyEnter)
  run()
  doAssert richSelectedText(doc) == "visit nim today", richSelectedText(doc)
  showBar = true

block placeholderAndEmpty:
  doc = richDoc("")
  ui.focus = 0
  run()
  # the placeholder shows (gray) where the text would start
  let x = edRect.x + 2 + dp(6) + 2
  let y = edRect.y + 2 + dp(6)
  var gray = 0
  for yy in y ..< y + FontH:
    for xx in x ..< x + textWidth("Write here"):
      # (gray text: its pixels gray, from the text's gray to the white)
      let p = px(xx, yy)
      if p != 0xFFFFFF and (p shr 16) == (p and 0xFF) and (p and 0xFF) >= 0x80: inc gray
  doAssert gray > 10, "the placeholder is drawn"

block bigDocument:
  var s = ""
  for i in 0 ..< 2000:
    s.add "<p>Paragraph " & $i & " with <b>some bold</b> and <i>italic</i> words, " &
          "long enough to wrap onto a second line in the editor of this test.</p>"
  doc = richFromHtml(s)
  doAssert doc.paras.len == 2000
  run()                                  # (laid out once)
  clickAt(edRect.x + 40, edRect.y + 10)
  var worst = 0.0
  for i in 0 ..< 30:
    let t0 = getMonoTime()
    typeText("x")
    key(KeyDown)
    run()
    worst = max(worst, (getMonoTime() - t0).inMicroseconds.float / 1000)
  # (the sanitizers make it some 7 times slower)
  doAssert worst < (when defined(retroSanitized): 400 else: 60),
    "a keystroke in a 2000-paragraph mail: " & $worst & " ms"
  echo "  2000 paragraphs: worst keystroke frame ", worst, " ms"
  ctrl(KeyEnd)
  run()
  doAssert richCaret(doc).para == 1999
  let t0 = getMonoTime()
  key(KeyPageUp)
  run()
  doAssert (getMonoTime() - t0).inMilliseconds < 60
  doAssert richCaret(doc).para < 1999

block baseStyle:
  # a reply: what is typed on an empty line takes the doc's base (Outlook's blue)
  let blue = color(0x1F, 0x49, 0x7D)
  var d = richDoc()
  d.base = RichStyle(color: blue)
  richInsert(d, "Thanks")
  doAssert d.paras[0].runs[0].style.color == blue
  doAssert "color:#1f497d" in toHtml(d).toLowerAscii
  # a line that has text keeps following it
  var d2 = richFromHtml("<p>plain</p>")
  d2.base = RichStyle(color: blue)
  richSelect(d2, RichPos(para: 0, off: 5), RichPos(para: 0, off: 5))
  richInsert(d2, " more")
  doAssert d2.paras[0].runs[^1].style.color.a == 0

# ---- spelling and AutoCorrect -----------------------------------------------------------------------

# (the user's dictionary and AutoCorrect list in a folder of the test's)
let spellData = getTempDir() / "retro-test-richedit-spell"
removeDir(spellData)
createDir(spellData)
putEnv("XDG_DATA_HOME", spellData)

proc typeRunes(s: string) =
  ## Like `typeText`, a whole character an event (Arabic letters too).
  for r in s.runes:
    queue.add Event(kind: KeyDownEvent, key: KeyNone)
    var e = Event(kind: TextInputEvent)
    let u = r.toUTF8
    for i, c in u: e.text[i] = c
    queue.add e

proc rightClick(x, y: int) =
  queue.add Event(kind: MouseMoveEvent, x: x, y: y)
  queue.add Event(kind: MouseDownEvent, x: x, y: y, button: RightButton, clicks: 1)
  queue.add Event(kind: MouseUpEvent, x: x, y: y, button: RightButton)
  run()

proc xAt(off: int; para = 0): int =
  ## Where the caret at byte `off` is drawn.
  richSelect(doc, RichPos(para: para, off: off), RichPos(para: para, off: off))
  run()
  richCaretRect(doc).x

proc reds(x0, x1, y0, y1: int): int =
  ## The red pixels (the misspelled words' lines) in that box.
  for y in max(0, y0) ..< min(H, y1):
    for x in max(0, x0) ..< min(W, x1):
      let p = px(x, y)
      if (p shr 16) > 200 and ((p shr 8) and 0xFF) < 90 and (p and 0xFF) < 90: inc result

block replaceAndUndo:
  var d = richFromHtml("<p>one <i>twoo</i> three</p>")
  richReplace(d, RichPos(para: 0, off: 4), RichPos(para: 0, off: 8), "two")
  doAssert d.texts == @["one two three"], $d.texts
  doAssert runOf(d, 0, "two").style.italic, "the word's style is kept"
  doAssert richCaret(d) == RichPos(para: 0, off: 7)
  richUndo(d)
  doAssert d.texts == @["one twoo three"] and runOf(d, 0, "twoo").style.italic
  doAssert not richCanUndo(d), "one undo step"

if spellAvailable("en-US"):
  block spellLines:
    showBar = false
    doc = richFromHtml("<p>This sentense has <b>mistakse</b> and a <a href=\"https://x.y\">lnik</a>" &
                       " in <code>codde</code> here</p>")
    doc.spell = true
    ui.focus = 0
    run()
    let t = paraText(doc.paras[0])
    let bad = richMisspelled(doc, 0)
    doAssert bad.mapIt(t[it.a ..< it.b]) == @["sentense", "mistakse"], $bad.mapIt(t[it.a ..< it.b])
    # red waves under those two, under the words, and nowhere else
    let top = richCaretRect(doc).y
    let lineH = richCaretRect(doc).h
    var spans: seq[(int, int)]
    for (a, b) in bad: spans.add (xAt(a), xAt(b))
    ui.focus = 0
    run()
    for (xa, xb) in spans:
      doAssert reds(xa, xb, top + lineH div 2, top + lineH + 3) > (xb - xa) div 2,
               "a red line under the word"
    doAssert reds(edRect.x, edRect.x + edRect.w, top, top + lineH div 2) == 0, "under the text, not over it"
    var outside = 0
    for x in edRect.x ..< edRect.x + edRect.w - SbW:
      if spans.allIt(x < it[0] - 1 or x > it[1] + 1): outside += reds(x, x + 1, top, top + lineH + 3)
    doAssert outside == 0, "only under the misspelled words: " & $outside

  block notUnderTheWordTyped:
    doc = richDoc("")
    doc.spell = true
    run()
    clickAt(edRect.x + 40, edRect.y + 10)
    typeText("Gudz")              # (a word in no dictionary: Windows' took "Gud")
    run()
    doAssert richMisspelled(doc, 0).len == 1
    let r = richCaretRect(doc)
    doAssert reds(edRect.x, edRect.x + edRect.w, r.y, r.y + r.h + 3) == 0,
             "no red line while the word is typed"
    typeText(" day")
    run()
    doAssert reds(edRect.x, edRect.x + edRect.w, r.y, r.y + r.h + 3) > 4, "once it is left: red"
    key(KeyLeft, {CtrlPressed})
    key(KeyLeft, {CtrlPressed})
    key(KeyRight)                         # (into it, by the arrows: shown)
    run()
    doAssert reds(edRect.x, edRect.x + edRect.w, r.y, r.y + r.h + 3) > 4

  block arabicLine:
    doc = richDoc("قرأت كتابب جميلا")
    doc.spell = true
    ui.focus = 0
    run()
    # (where the system's checker knows the word is wrong: a Mac's Arabic,
    # on GitHub's machines, takes it)
    if spellAvailable("ar") and isMisspelled("كتابب", "ar"):
      let t = paraText(doc.paras[0])
      let bad = richMisspelled(doc, 0)
      doAssert bad.len == 1 and t[bad[0].a ..< bad[0].b] == "كتابب", $bad
      # right to left: the word's start is at its right
      let xa = xAt(bad[0].a)
      let xb = xAt(bad[0].b)
      doAssert xb < xa, "Arabic goes right to left"
      ui.focus = 0
      run()
      let top = richCaretRect(doc).y
      doAssert reds(xb, xa, top, top + richCaretRect(doc).h + 3) > (xa - xb) div 2

  block suggestionMenu:
    doc = richFromHtml("<p>We <b>recieve</b> mail</p>")
    doc.spell = true
    run()
    let y = edRect.y + 2 + dp(6) + FontH div 2
    rightClick(xAt(6), y)                 # on "recieve": its suggestions first
    key(KeyDown)
    key(KeyEnter)                         # the first: "receive"
    run()
    doAssert doc.texts == @["We receive mail"], $doc.texts
    doAssert runOf(doc, 0, "receive").style.bold, "it keeps the word's bold"
    doAssert richMisspelled(doc, 0).len == 0
    ctrl(KeyZ)                            # one undo step
    run()
    doAssert doc.texts == @["We recieve mail"] and runOf(doc, 0, "recieve").style.bold
    # Ignore All: not marked again (this session)
    rightClick(xAt(6), y)
    key(KeyI)
    run()
    doAssert richMisspelled(doc, 0).len == 0 and doc.texts == @["We recieve mail"]
    # Add to Dictionary: kept in the user's words
    doc = richDoc("Regards, Foxomann")
    doc.spell = true
    run()
    doAssert richMisspelled(doc, 0).len == 1
    rightClick(xAt(12), y)
    key(KeyA)
    run()
    doAssert richMisspelled(doc, 0).len == 0
    doAssert "Foxomann" in readFile(spellWordsFile())
    # a right click elsewhere: the usual menu (its first item Undo)
    rightClick(xAt(3), y)
    key(KeyEsc)
    run()

  block f7:
    # (words every system's checker takes as wrong: a Mac's knows "mornin";
    # its first suggestion is the system's own)
    doc = richDoc("Good mornnig all\nthe meatting is at nine")
    doc.spell = true
    run()
    clickAt(edRect.x + 2 + dp(6) + 1, edRect.y + 2 + dp(6) + FontH div 2)
    key(KeyF7)
    run()
    doAssert richSelectedText(doc) == "mornnig", richSelectedText(doc)
    doAssert ui.popup != 0, "its menu is open"
    let first = spellSuggest("mornnig")
    key(KeyDown)
    key(KeyEnter)
    run()
    doAssert first.len > 0 and doc.texts[0] == "Good " & first[0] & " all",
             $doc.texts & " " & $first
    key(KeyF7)
    run()
    doAssert richSelectedText(doc) == "meatting", richSelectedText(doc)
    key(KeyEsc)
    run()
    doAssert ui.popup == 0

block autoCorrectTyping:
  showBar = false
  doc = richDoc("")
  doc.autoCorrect = true
  run()
  clickAt(edRect.x + 40, edRect.y + 10)
  typeText("teh cat adn i ")
  run()
  doAssert doc.texts == @["The cat and I "], $doc.texts
  # Ctrl+Z right after a correction: what was typed, then the typing
  typeText("dont")
  run()
  typeText(" ")
  run()
  doAssert doc.texts == @["The cat and I don't "], $doc.texts
  ctrl(KeyZ)
  run()
  doAssert doc.texts == @["The cat and I dont "], $doc.texts
  ctrl(KeyZ)
  run()
  doAssert doc.texts == @["The cat and I "], $doc.texts
  # Enter ends a word too
  typeText("see thier")
  key(KeyEnter)
  run()
  doAssert doc.texts == @["The cat and I see their", ""], $doc.texts
  ctrl(KeyZ)
  run()
  doAssert doc.texts == @["The cat and I see thier", ""], $doc.texts
  # addresses are left alone
  doc = richDoc("")
  doc.autoCorrect = true
  run()
  clickAt(edRect.x + 40, edRect.y + 10)
  typeText("Mail www.teh.com or me@teh.org now.")
  run()
  doAssert doc.texts == @["Mail www.teh.com or me@teh.org now."], $doc.texts
  # ... and links
  doc = richFromHtml("<p>A <a href=\"https://x.y\">tehx</a></p>")
  doc.autoCorrect = true
  run()
  clickAt(edRect.x + 40, edRect.y + 10)
  richSelect(doc, RichPos(para: 0, off: 5), RichPos(para: 0, off: 5))   # (in the link: "teh|x")
  typeText(" ")
  run()
  doAssert doc.texts == @["A teh x"], $doc.texts
  # off: nothing changes
  doc = richDoc("")
  run()
  clickAt(edRect.x + 40, edRect.y + 10)
  typeText("teh ")
  run()
  doAssert doc.texts == @["teh "]
  # Arabic
  doc = richDoc("")
  doc.autoCorrect = true
  run()
  clickAt(edRect.x + 40, edRect.y + 10)
  typeRunes("ذهبت الى السوق ان شاء الله ")
  run()
  doAssert doc.texts == @["ذهبت إلى السوق إن شاء الله "], $doc.texts
  ctrl(KeyZ)
  run()
  doAssert doc.texts == @["ذهبت إلى السوق ان شاء الله "], $doc.texts
  showBar = true

echo "richedit: all tests passed"

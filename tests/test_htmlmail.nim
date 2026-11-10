## HTML mail in the HTML views: pages as mail programs write them (a
## newsletter, an Outlook reply, a Gmail reply, an Arabic mail, a plain
## one in <pre>, a receipt) laid out by the kit -- what shows and what
## stays hidden, columns, links, pictures, right-to-left lines -- the
## mouse and the keys on them, how fast it is, and that damaged pages do
## no harm. On the fake driver (no display).
##
##   nim c -r --hints:off tests/test_htmlmail.nim
##   nim c -r --hints:off -d:release tests/test_htmlmail.nim     # the timings that count

import std/[os, strutils, monotimes, times, random, sequtils]
import retroui
import retroui/htmlview
import retroui/uirelays/input
import harness

fakeDriver()
startApp("html mail", W, H)
setSmoothScrolling(false)

const mailDir = currentSourcePath().parentDir / "data" / "mail"
proc sample(name: string): string = readFile(mailDir / name)

let
  newsletter = sample("newsletter.html")
  outlook = sample("outlook_reply.html")
  gmail = sample("gmail_reply.html")
  arabic = sample("arabic.html")
  plain = sample("plain_pre.html")
  receipt = sample("receipt.html")
  samples = [("newsletter", newsletter), ("outlook", outlook), ("gmail", gmail),
             ("arabic", arabic), ("plain", plain), ("receipt", receipt)]

proc word(info: HtmlPageInfo; t: string): Rect =
  ## The first piece of text drawn that has `t` in it.
  for w in info.words:
    if t in w.text: return w.r
  doAssert false, "not drawn: " & t

proc hasWord(info: HtmlPageInfo; t: string): bool =
  for w in info.words:
    if t in w.text: return true

proc image(info: HtmlPageInfo; part: string): tuple[src: string; r: Rect; shown: bool] =
  for i in info.images:
    if part in i.src: return i
  doAssert false, "no picture " & part

proc right(r: Rect): int = r.x + r.w

# ---- what stays hidden ------------------------------------------------------------------------

block hidden:
  for (name, html) in samples:
    let txt = htmlToText(html)
    for w in [880, 380]:
      let info = htmlPageInfo(html, w)
      for bad in ["PREHEADER", "SECRET", "HIDDEN SPAN", "MOBILE ONLY", "behavior:url",
                  "font-family", "mso-", "@font-face", "WordSection", "panose", "v\\:*",
                  "<o:p>", "shapedefaults"]:
        doAssert bad notin info.text, name & " draws " & bad
        doAssert bad notin txt, name & "'s text has " & bad
      doAssert info.height > 100 and info.words.len > 10, name
      doAssert info.right <= w + 1, name & " is wider than its room: " & $info.right & " > " & $w

# ---- the newsletter ----------------------------------------------------------------------------

block newsletterLayout:
  let wide = htmlPageInfo(newsletter, 880)
  # the 600-pixel column, centered; the hero keeps the aspect its attributes give
  let hero = wide.image("cid:hero-beans@sohar")
  doAssert not hero.shown and hero.r.w == 600 and hero.r.h == 300, $hero
  doAssert abs(hero.r.x - (880 - 600) div 2) <= 12, "centered: " & $hero.r
  # pictures it wants (not the one it has itself)
  for src in ["cid:hero-beans@sohar", "https://cdn.sohar-coffee.example/img/logo-white.png",
              "https://cdn.sohar-coffee.example/img/bag-dhofar.jpg"]:
    doAssert src in wide.wantedImages, src
  doAssert not wide.wantedImages.anyIt(it.startsWith("data:"))
  let dot = wide.images.filterIt(it.src.startsWith("data:"))
  doAssert dot.len == 1 and dot[0].shown and dot[0].r.w == 24 and dot[0].r.h == 24, $dot
  # the products: side by side, then (narrow) one above the other
  let a = wide.image("bag-dhofar")
  let b = wide.image("bag-jabal")
  doAssert a.r.y == b.r.y and b.r.x >= right(a.r), $a.r & " " & $b.r
  let narrow = htmlPageInfo(newsletter, 380)
  let na = narrow.image("bag-dhofar")
  let nb = narrow.image("bag-jabal")
  doAssert nb.r.y > na.r.y + na.r.h and na.r.w <= 380, $na.r & " " & $nb.r
  doAssert narrow.image("cid:hero").r.w <= 380 and narrow.image("cid:hero").r.h * 2 ==
    narrow.image("cid:hero").r.w, "made smaller, its aspect kept"
  # the old two columns: tables aligned left and right
  let brew = wide.word("Brewing class")
  let free = wide.word("Free delivery")
  doAssert brew.y == free.y and free.x > brew.x + 200, $brew & " " & $free
  # the "button": a table cell with a background, its link over its words
  let shop = wide.word("Shop the harvest")
  var onButton = false
  for l in wide.links:
    if l.url == "https://sohar-coffee.example/shop?utm_campaign=nov" and
       l.r.contains(point(shop.x + 2, shop.y + 2)):
      onButton = true
  doAssert onButton
  # six tables deep, as builders nest them
  doAssert "The Dhofar lot is the best we have roasted in five years." in wide.text
  # the footer's links, the text as a mail program's plain part
  let txt = htmlToText(newsletter)
  doAssert "Unsubscribe <https://sohar-coffee.example/unsubscribe?u=8f2a&id=99c1>" in txt, txt
  doAssert "November’s beans are here" in txt
  doAssert "Shop the harvest → <https://sohar-coffee.example/shop?utm_campaign=nov>" in txt
  doAssert "\nDhofar Highlands\n" in txt, "inline blocks are blocks of the text"

# ---- an Outlook reply -----------------------------------------------------------------------------

block outlookReply:
  let info = htmlPageInfo(outlook, 616)
  let txt = htmlToText(outlook)
  for line in ["From: Sultan Al Isaiee <sultan@example.com>",
               "Sent: Monday, November 3, 2026 8:41 AM",
               "Subject: Induction training for November joiners",
               "Name\tDepartment\tStart date", "Ahmed Al Harthy\tFront Office\t9 Nov 2026"]:
    doAssert line in txt, "missing: " & line & "\n" & txt
  # MsoNormal paragraphs have no margins: one blank line is an <o:p>&nbsp;</o:p>
  let hi = info.word("Hi Sultan,")
  let thanks = info.word("Thanks for the update")
  doAssert thanks.y - hi.y >= 2 * hi.h and thanks.y - hi.y <= 3 * hi.h + 4, $hi & " " & $thanks
  # the quoted header comes after the signature, under its rule
  doAssert info.word("From:").y > info.word("maryam@example.com").y
  # the table: its columns as wide as its cells say (120pt: 160 px), in a row
  let n = info.word("Name")
  let d = info.word("Department")
  let s = info.word("Start date")
  doAssert n.y == d.y and d.y == s.y
  doAssert d.x - n.x in 160 .. 185 and s.x - d.x in 160 .. 185, $n & " " & $d & " " & $s

# ---- a Gmail reply ------------------------------------------------------------------------------

block gmailReply:
  let txt = htmlToText(gmail)
  doAssert "Sounds good, I will bring the printed schedules." in txt
  doAssert "the updated drill plan <https://intranet.example/safety/fire-2026.pdf>" in txt, txt
  doAssert "> Hi Khalid," in txt, txt
  doAssert "> > Sultan, do we have a date for the November induction yet?" in txt, txt
  doAssert "sultan@example.com> wrote:" in txt and "<mailto:" notin txt
  # quotes indented, each deeper one more; bars in two colors
  let info = htmlPageInfo(gmail, 600)
  let top = info.word("Sounds good")
  let q1 = info.word("Hi Khalid")
  let q2 = info.word("do we have a date")
  doAssert q1.x > top.x and q2.x > q1.x, $top & " " & $q1 & " " & $q2
  view = proc () = discard htmlView(gmail, height = 420, key = "gm")
  run(3)
  var blue, green = 0
  for y in 0 ..< 430:
    for x in 0 ..< 120:
      case px(x, y)
      of 0x3C6EC8'u32: inc blue
      of 0x288C50'u32: inc green
      else: discard
  doAssert blue > 20 and green > 20, "quote bars: " & $blue & " " & $green

# ---- an Arabic mail -----------------------------------------------------------------------------

block arabicMail:
  let info = htmlPageInfo(arabic, 600)
  # right to left: lines end at the right
  let first = info.word("السلام")
  doAssert abs(right(first) - 600) <= 2, $first
  # the table's first column is at the right
  doAssert info.word("الوقت").x > info.word("الموضوع").x
  doAssert info.word("09:00").x > info.word("الترحيب").x
  # English inside keeps its order
  doAssert info.hasWord("HR Policies") and info.hasWord("Mercure Sohar")
  # the paragraph marked left to right is at the left
  doAssert info.word("This message is also available").x <= 2
  # list items at the right, their bullets after them
  let item = info.word("نسخة من البطاقة")
  doAssert right(item) >= 560, $item
  let txt = htmlToText(arabic)
  doAssert "- نسخة من البطاقة المدنية" in txt, txt
  doAssert "09:30\tسياسات الموارد البشرية HR Policies\tمريم البلوشية" in txt, txt

# ---- a plain mail in <pre> -------------------------------------------------------------------------

block plainMail:
  let info = htmlPageInfo(plain, 600)
  let txt = htmlToText(plain)
  doAssert "  Clean    86.1    89.4    +3.3" in txt, txt
  doAssert "  Check-in 78.0    74.2    -3.8" in txt
  doAssert "> Do we have the Q3 numbers yet? The GM asked for them before" in txt
  doAssert "> > Reminder: reports are due" in txt
  # lines kept; columns line up (one font width for all)
  let clean = info.word("Clean")
  let food = info.word("Food")
  doAssert clean.x == food.x and clean.w == food.w, $clean & " " & $food
  # a long line wraps rather than leaving the view
  let narrow = htmlPageInfo(plain, 300)
  doAssert narrow.right <= 300 and "guest-satisfaction" in narrow.text
  doAssert "https://quality.example/reports/2026/q3?view=summary&dept=all" in info.links.mapIt(it.url)

# ---- a receipt -----------------------------------------------------------------------------------

block receiptColumns:
  for w in [600, 380]:
    let info = htmlPageInfo(receipt, w)
    let amounts = ["OMR 26.000", "OMR 77.800", "OMR 17.000", "OMR 130.050", "OMR 136.553"].mapIt(info.word(it))
    for a in amounts: doAssert abs(right(a) - right(amounts[0])) <= 1, "amounts align right " & $w
    doAssert abs(right(amounts[0]) - right(info.word("AMOUNT"))) <= 1
    let qty = info.word("QTY")
    let item = info.word("ITEM")
    let unit = info.word("UNIT PRICE")
    doAssert item.x < qty.x and qty.x < unit.x and unit.x < info.word("AMOUNT").x
    doAssert right(info.word("Lever arch files")) < qty.x, "the item column holds its words"
    doAssert info.word("Toner cartridge").x == item.x
    doAssert right(info.word("OMR 136.553")) <= w
  let txt = htmlToText(receipt)
  doAssert "Toner cartridge HP 59A (black)\t2\tOMR 38.900\tOMR 77.800" in txt, txt
  doAssert "View online <https://supplies.example/r/INV-2026-1187>" in txt

# ---- flexible boxes and grids --------------------------------------------------------------------

block flexAndGrid:
  # a row: side by side, the room shared as grow says, placed as
  # justify-content says, the boxes across it as align-items says
  let row = htmlPageInfo("""<div style="display:flex; gap:10px; width:400px">
    <div style="flex:1; background:#eee">Alpha</div><div style="flex:2; background:#ddd">Beta</div>
    <span>Gamma</span></div>""", 600)
  let a = row.word("Alpha")
  let b = row.word("Beta")
  let g = row.word("Gamma")
  doAssert a.y == b.y and b.y == g.y, "one row: " & $(a, b, g)
  doAssert a.x < b.x and b.x < g.x
  doAssert g.x + g.w <= 400 + 2 and g.x + g.w >= 400 - 2, "the last at the right, the room shared: " & $g
  doAssert b.x - a.x < (g.x - b.x) * 3, "Beta's share twice Alpha's: " & $(a.x, b.x, g.x)
  let between = htmlPageInfo("""<div style="display:flex; justify-content:space-between; width:300px">
    <b>One</b><b>Two</b><b>Three</b></div>""", 600)
  doAssert between.word("One").x <= 2
  doAssert abs(between.word("Three").x + between.word("Three").w - 300) <= 2
  let mid = between.word("Two")
  doAssert abs((mid.x + mid.w div 2) - 150) <= 6, "the middle one in the middle: " & $mid
  let centered = htmlPageInfo("""<div style="display:flex; justify-content:center; align-items:center;
    height:100px; width:300px"><span>Mid</span><div style="height:60px">Tall</div></div>""", 600)
  let m = centered.word("Mid")
  doAssert m.x > 100 and m.x < 150, "centered along: " & $m
  doAssert m.y > centered.word("Tall").y, "centered across (beside a taller box): " & $m
  # wrapped onto more rows; a column
  let wrapped = htmlPageInfo("""<div style="display:flex; flex-wrap:wrap; width:200px">
    <div style="width:120px">First</div><div style="width:120px">Second</div></div>""", 600)
  doAssert wrapped.word("Second").y > wrapped.word("First").y and wrapped.word("Second").x == wrapped.word("First").x
  let col = htmlPageInfo("""<div style="display:flex; flex-direction:column; align-items:flex-end;
    gap:8px; width:300px"><span>Top</span><span>Bottom</span></div>""", 600)
  doAssert col.word("Bottom").y > col.word("Top").y
  doAssert abs(col.word("Top").x + col.word("Top").w - 300) <= 2, "at the end of the column"
  # right to left: the first at the right
  let rtlRow = htmlPageInfo("""<div dir="rtl" style="display:flex; width:300px"><b>واحد</b><b>اثنان</b></div>""", 600)
  doAssert rtlRow.word("واحد").x > rtlRow.word("اثنان").x
  # a grid: three columns, a box over two; as many columns of 100 as fit
  let grid = htmlPageInfo("""<div style="display:grid; grid-template-columns:repeat(3, 1fr); gap:10px;
    width:320px"><div>A1</div><div>A2</div><div>A3</div><div style="grid-column:span 2">B12</div>
    <div>B3</div></div>""", 600)
  doAssert grid.word("A1").y == grid.word("A3").y and grid.word("B12").y > grid.word("A1").y
  doAssert grid.word("A2").x == 110 and grid.word("A3").x == 220, $(grid.word("A2"), grid.word("A3"))
  doAssert grid.word("B12").x == 0 and grid.word("B3").x == 220
  let fill = htmlPageInfo("""<div style="display:grid; grid-template-columns:repeat(auto-fill, minmax(100px, 1fr));
    width:350px"><i>c1</i><i>c2</i><i>c3</i><i>c4</i></div>""", 600)
  doAssert fill.word("c3").y == fill.word("c1").y and fill.word("c4").y > fill.word("c1").y
  doAssert fill.word("c4").x == 0

block gridAreasAndPositions:
  # named areas: the head over both columns, the side under it at the left
  let areas = htmlPageInfo("""<div style="display:grid; grid-template-columns:100px 1fr;
    grid-template-areas:'head head' 'side main' 'foot foot'; gap:10px; width:400px">
    <div style="grid-area:main">Main</div><div style="grid-area:head">Head</div>
    <div style="grid-area:side">Side<br>more<br>lines</div><div style="grid-area:foot">Foot</div></div>""", 600)
  let hd = areas.word("Head")
  let sd = areas.word("Side")
  let mn = areas.word("Main")
  let ft = areas.word("Foot")
  doAssert hd.x == 0 and hd.y < sd.y, "the head first, over the columns: " & $(hd, sd)
  doAssert sd.x == 0 and mn.x == 110 and mn.y == sd.y, "side, then main beside it: " & $(sd, mn)
  doAssert ft.y > areas.word("lines").y, "the foot under the tallest of the row: " & $(ft, areas.word("lines"))
  # lines: a box over two rows, the others round it; rows of given pixels
  let lines = htmlPageInfo("""<div style="display:grid; grid-template-columns:repeat(3, 100px);
    grid-template-rows:40px 40px; width:300px">
    <div style="grid-column:2; grid-row:1 / 3">Tall</div><i>p1</i><i>p2</i><i>p3</i><i>p4</i></div>""", 600)
  doAssert lines.word("Tall").x == 100 and lines.word("Tall").y < 40
  doAssert lines.word("p1").x == 0 and lines.word("p2").x == 200, "round the tall one: " & $(lines.word("p1"), lines.word("p2"))
  doAssert lines.word("p3").x == 0 and lines.word("p3").y >= 40 and lines.word("p4").x == 200,
           "the second row of 40 pixels, the tall one still in its middle: " & $(lines.word("p3"), lines.word("p4"))
  let lastCol = htmlPageInfo("""<div style="display:grid; grid-template-columns:repeat(4, 50px); width:200px">
    <b style="grid-column:-2">End</b><b>Next</b></div>""", 600)
  doAssert lastCol.word("End").x == 150, "-2: the last column: " & $lastCol.word("End")
  # position: relative moves it, absolute takes it out of the flow into the
  # positioned box around it, fixed into the page
  let rel = htmlPageInfo("""<p>Before</p><div style="position:relative; left:30px; top:5px">Moved</div>
    <p>After</p>""", 600)
  let plain = htmlPageInfo("""<p>Before</p><div>Moved</div><p>After</p>""", 600)
  doAssert rel.word("Moved").x == plain.word("Moved").x + 30 and
           rel.word("Moved").y == plain.word("Moved").y + 5, "relative: moved, " & $(rel.word("Moved"), plain.word("Moved"))
  doAssert rel.word("After").y == plain.word("After").y, "the rest where it was"
  let abso = htmlPageInfo("""<div style="position:relative; width:300px; height:80px; border:1px solid #000">
    Card<span style="position:absolute; top:6px; right:6px">Badge</span>
    <div style="position:absolute; bottom:0; left:0">Corner</div></div><p>Below</p>""", 600)
  let badge = abso.word("Badge")
  doAssert abs(badge.x + badge.w - (300 - 6 - 1)) <= 3 and badge.y >= 6 and badge.y < 12,
           "at the box's top right: " & $badge
  let corner = abso.word("Corner")
  doAssert corner.x <= 2 and corner.y + corner.h >= 76 and corner.y + corner.h <= 82,
           "at its bottom left: " & $corner
  doAssert abso.word("Card").y < 10 and abso.word("Card").x < 10, "the text as if they were not there"
  doAssert abso.word("Below").y > 80, "after the box: " & $abso.word("Below")
  let fixed = htmlPageInfo("""<div style="margin:40px; position:relative">x
    <b style="position:fixed; top:0; left:0">Pinned</b></div>""", 600)
  doAssert fixed.word("Pinned").x <= 1 and fixed.word("Pinned").y <= 1, "fixed: to the page " & $fixed.word("Pinned")

# ---- tables: what browsers do with them ------------------------------------------------------------

block tables:
  # widths in pixels and percents, colspan, rowspan
  let t = "<table width=400 cellspacing=0 cellpadding=0 border=0><tr><td width=100>a</td>" &
          "<td width=50%>b</td><td>c</td></tr><tr><td colspan=2>wide</td><td rowspan=2>tall</td></tr>" &
          "<tr><td>x</td><td>y</td></tr></table>"
  let info = htmlPageInfo(t, 600)
  let a = info.word("a")
  let b = info.word("b")
  let c = info.word("c")
  doAssert b.x - a.x == 100 and c.x - b.x == 200, $a & " " & $b & " " & $c
  doAssert info.word("x").y > info.word("wide").y and info.word("tall").x == c.x
  # nested tables, the inner one 100% of its cell
  let n = "<table width=300 cellpadding=0 cellspacing=0><tr><td width=100>L</td><td>" &
          "<table width=100% cellpadding=0 cellspacing=0><tr><td>R1</td><td align=right>R2</td></tr></table>" &
          "</td></tr></table>"
  let ni = htmlPageInfo(n, 600)
  doAssert ni.word("R1").x == 100 and right(ni.word("R2")) == 300, $ni.word("R2")
  # a long word in a narrow cell is broken, nothing leaves the room
  let lw = "<table width=120><tr><td>" & repeat("x", 300) & "</td></tr></table>"
  doAssert htmlPageInfo(lw, 600).right <= 600
  # align=center tables, <center>
  let ctr = htmlPageInfo("<table align=center width=200><tr><td>mid</td></tr></table>", 600)
  doAssert ctr.word("mid").x in 200 .. 210, $ctr.word("mid")
  let cc = htmlPageInfo("<center><table width=200><tr><td>c</td></tr></table></center>", 600)
  doAssert abs(cc.word("c").x + cc.word("c").w div 2 - 300) <= 3, "the table and its text centered"

# ---- lists, quotes, rules, headings, styles -----------------------------------------------------------

block flow:
  let h = "<style>.big{font-size:24px} p.x{margin:0} #n{color:red} div > b {font-style:italic}</style>" &
          "<h1>Head</h1><p class=x>one</p><p class=x>two</p><ol start=3><li>c<li>d</ol>" &
          "<ul><li>a<ul><li>nested</li></ul></li></ul><hr><blockquote>q<blockquote>qq</blockquote></blockquote>" &
          "<p style='text-align:right'>R</p><p align=center>C</p><span class=big>BIG</span>"
  let info = htmlPageInfo(h, 400)
  let gap = info.word("two").y - info.word("one").y
  doAssert gap >= info.word("one").h and gap <= info.word("one").h + 4, "no margins between: " & $gap
  doAssert info.word("BIG").h > info.word("one").h
  doAssert info.word("Head").h > info.word("one").h
  doAssert right(info.word("R")) == 400
  doAssert abs(info.word("C").x + info.word("C").w div 2 - 200) <= 2
  doAssert info.word("nested").x > info.word("a").x
  doAssert info.word("qq").x > info.word("q").x
  let txt = htmlToText(h)
  doAssert "3. c\n4. d" in txt, txt
  doAssert "> q" in txt and "> > qq" in txt
  # floats: text goes around a picture aligned left
  let f = htmlPageInfo("<p><img src='x.png' width=100 height=100 align=left>" &
                       repeat("word ", 200) & "</p>", 400)
  doAssert f.words[0].r.x >= 100, "beside the picture: " & $f.words[0].r
  doAssert f.words[^1].r.x < 100 or f.words[^1].r.y >= 100

# ---- the mouse and the keys -----------------------------------------------------------------------

proc contentOrigin(r: Rect): Point =
  ## Where the page's top left is in a view at `r` (scrolled to the top).
  point(r.x + 1 + dp(12), r.y + 1 + dp(12))

block linksAndSelection:
  var ev: HtmlEvent
  var r: Rect
  var hovered = ""
  view = proc () =
    let e = htmlView(gmail, height = 420, key = "sel")
    r = ui.lastRect
    if e.link.len > 0: ev = e
    if e.hover.len > 0: hovered = e.hover
  run(3)
  let o = contentOrigin(r)
  let cw = r.w - SbW - 1 - 2 * dp(12)
  let info = htmlPageInfo(gmail, cw)
  # the link under the pointer, then clicked
  let l = info.word("updated")   # (the link: "the updated drill plan", wherever its line breaks)
  move(o.x + l.x + 5, o.y + l.y + 3)
  run(2)
  doAssert hovered == "https://intranet.example/safety/fire-2026.pdf", hovered
  down(o.x + l.x + 5, o.y + l.y + 3)
  run()
  up(o.x + l.x + 5, o.y + l.y + 3)
  run(2)
  doAssert ev.link == "https://intranet.example/safety/fire-2026.pdf", ev.link
  # a drag selects; Ctrl+C copies it
  let s = info.word("Sounds good")
  down(o.x + s.x + 1, o.y + s.y + 3)
  run()
  move(o.x + s.x + 60, o.y + s.y + 3)
  run()
  move(o.x + right(s) + 30, o.y + s.y + 3)
  run()
  up(o.x + right(s) + 30, o.y + s.y + 3)
  run()
  key(KeyC, {CtrlPressed})
  run()
  doAssert getClipboardText() == "Sounds good, I will bring the printed schedules.", getClipboardText()
  # across paragraphs: their breaks kept
  let one = info.word("One question")
  let th = info.word("Thanks,")
  down(o.x + one.x + 1, o.y + one.y + 3)
  run()
  move(o.x + th.x + 20, o.y + th.y + 3)
  run()
  up(o.x + right(th) + 5, o.y + th.y + 3)
  run()
  key(KeyC, {CtrlPressed})
  run()
  let got = getClipboardText()
  doAssert got.startsWith("One question: should the housekeeping team") and got.endsWith("\n\nThanks,"), got
  # a double click: a word
  let k = info.word("Khalid")
  down(o.x + k.x + 6, o.y + k.y + 3, clicks = 2)
  run()
  up(o.x + k.x + 6, o.y + k.y + 3)
  run()
  key(KeyC, {CtrlPressed})
  run()
  doAssert getClipboardText() == "Khalid", getClipboardText()
  # Ctrl+A: all of it
  key(KeyA, {CtrlPressed})
  run()
  key(KeyC, {CtrlPressed})
  run()
  let all = getClipboardText()
  doAssert all.startsWith("Sounds good") and "Sultan, do we have a date" in all and
           all.endsWith("Khalid"), all
  # a click elsewhere: no selection; Ctrl+C then copies the whole page
  down(o.x + 300, o.y + 380)
  run()
  up(o.x + 300, o.y + 380)
  run()
  key(KeyC, {CtrlPressed})
  run()
  doAssert getClipboardText() == all

block scrollingKeysWheel:
  let id = idOf("htmlviewkeys")
  view = proc () = discard htmlView(newsletter, height = 300, key = "keys")
  run(2)
  let r = ui.lastRect
  click(r, dx = 40, dy = 40)                   # (it takes the focus)
  key(KeyEnd)
  run(2)
  let bottom = state(id).scrollY
  doAssert bottom > 500, $bottom
  key(KeyHome)
  run(2)
  doAssert state(id).scrollY == 0
  key(KeyPageDown)
  run(2)
  doAssert state(id).scrollY in 200 .. 300, $state(id).scrollY
  key(KeyUp)
  run(2)
  let up1 = state(id).scrollY
  doAssert up1 < 280
  key(KeySpace)
  run(2)
  doAssert state(id).scrollY > up1
  key(KeyHome)
  run(2)
  move(r.x + 100, r.y + 100)
  queue.add Event(kind: MouseWheelEvent, y: -2)
  run(2)
  doAssert state(id).scrollY > 0, "the wheel scrolls it"

block anchors:
  var filler = ""
  for i in 0 ..< 80: filler.add "<p>line " & $i & "</p>"
  let page = "<p><a href='#end'>To the end</a></p>" & filler & "<h2 id='end'>The end</h2>" & filler
  let id = idOf("htmlviewanchor")
  var ev: HtmlEvent
  view = proc () =
    let e = htmlView(page, height = 200, key = "anchor")
    if e.link.len > 0: ev = e
  run(2)
  let o = contentOrigin(ui.lastRect)
  down(o.x + 10, o.y + 4)
  run()
  up(o.x + 10, o.y + 4)
  run(3)
  doAssert ev.link == "", "links in the page scroll it, not reported"
  let info = htmlPageInfo(page, ui.lastRect.w - SbW - 1 - 2 * dp(12))
  doAssert state(id).scrollY > 0 and abs(state(id).scrollY - info.word("The end").y) < 30,
    $state(id).scrollY & " " & $info.word("The end").y

# ---- zoom -------------------------------------------------------------------------------------------

proc ctrlUp() =
  ## Ctrl let go.
  queue.add Event(kind: KeyUpEvent, key: KeyNone, hasMods: true)
  run()

proc ctrlKey(k: KeyCode; times = 1) =
  for _ in 0 ..< times:
    key(k, {CtrlPressed})
    run()

block zoomLayout:
  # at 1.5 the text is half as large again, laid out again in the same width
  let one = htmlPageInfo(gmail, 560)
  let big = htmlPageInfo(gmail, 560, zoom = 1.5)
  let a = one.word("Khalid")
  let b0 = big.word("Khalid")
  doAssert b0.h * 10 >= a.h * 13 and b0.w * 10 >= a.w * 13, $a & " -> " & $b0
  # (the phrase may wrap before "plan" when larger)
  let b = big.word("the updated drill")
  doAssert big.height * 10 >= one.height * 14, $one.height & " -> " & $big.height
  doAssert big.right <= 561 and big.text == one.text
  # its links are where their words are drawn now
  let l = big.links.filterIt(it.url == "https://intranet.example/safety/fire-2026.pdf")
  doAssert l.anyIt(it.r.contains(point(b.x + 5, b.y + 3))), $l & " " & $b
  # smaller at 0.5, larger at 1.1
  let font = uiFont()
  setUiFont(ufSans)
  let s1 = htmlPageInfo(gmail, 560)
  let sHalf = htmlPageInfo(gmail, 560, zoom = 0.5)
  doAssert sHalf.height * 10 <= s1.height * 7, $s1.height & " -> " & $sHalf.height
  doAssert sHalf.word("the updated drill").w * 10 <= s1.word("the updated drill").w * 6
  doAssert htmlPageInfo(gmail, 560, zoom = 1.1).word("Khalid").h > s1.word("Khalid").h
  setUiFont(font)
  # the extremes do no harm (0 and NaN: 1; beyond 0.5 .. 3: those)
  doAssert htmlPageInfo(gmail, 560, zoom = 0).height == one.height
  doAssert htmlPageInfo(gmail, 560, zoom = NaN).height == one.height
  doAssert htmlPageInfo(gmail, 560, zoom = 99).height == htmlPageInfo(gmail, 560, zoom = 3).height
  for (name, html) in samples:
    for z in [0.01, 0.5, 2.25, 3.0, Inf, -1.0]:
      let info = htmlPageInfo(html, 320, zoom = z)
      doAssert info.height > 0 and info.words.len > 10, name & " at " & $z
  # a block at the zoom the app gives
  view = proc () = discard htmlBlock(gmail, w = 400, zoom = 2.0)
  run(2)
  doAssert ui.lastRect.h == htmlPageInfo(gmail, 400, zoom = 2.0).height

block zoomInTheView:
  let id = idOf("htmlviewzoom")
  var z = 1.0
  var ev: HtmlEvent
  view = proc () =
    let e = htmlView(gmail, z, height = 420, key = "zoom")
    if e.link.len > 0: ev = e
  run(3)
  let r = ui.lastRect
  move(r.x + 100, r.y + 100)
  run()
  # Ctrl+wheel over it: a step a notch, as browsers step (up: to a size the
  # font draws larger)
  let up1 = htmlZoomStep(1.0, true)
  doAssert up1 > 1.0 and lineHeight(style(size = up1)) > lineHeight(style(size = 1.0)), $up1
  queue.add Event(kind: MouseWheelEvent, y: 1, mods: {CtrlPressed}, hasMods: true)
  run(2)
  doAssert z == up1, $z
  queue.add Event(kind: MouseWheelEvent, y: -1, mods: {CtrlPressed}, hasMods: true)
  run(2)
  doAssert z == htmlZoomStep(up1, false), $z
  ctrlKey(Key0)
  doAssert z == 1.0, $z
  queue.add Event(kind: MouseWheelEvent, y: -1, mods: {CtrlPressed}, hasMods: true)
  run(2)
  doAssert z == 0.9, $z
  # Ctrl+plus (or =), minus and 0, the pointer over it; up to 3 and down to 0.5
  ctrlKey(KeyEqual)
  doAssert z == 1.0, $z
  ctrlKey(KeyPlus)
  doAssert z == up1, $z
  ctrlKey(KeyMinus)
  doAssert z == htmlZoomStep(up1, false), $z
  ctrlKey(KeyEqual, 14)
  doAssert z == 3.0, $z
  ctrlKey(KeyMinus, 16)
  doAssert z == 0.5, $z
  ctrlKey(Key0)
  doAssert z == 1.0, $z
  ctrlUp()
  # two fingers pinching: 1.25 and 1.2 times as far apart, 1.5
  let c = point(r.x + 200, r.y + 150)
  for (ph, sc) in [(gsBegin, 1.0), (gsChange, 1.25), (gsChange, 1.2), (gsEnd, 1.0)]:
    queue.add Event(kind: GestureEvent, phase: ph, scale: float32(sc), x: c.x, y: c.y)
    run()
  doAssert abs(z - 1.5) < 0.001, $z
  # the app's own zoom (View > Zoom) is laid out too
  z = 1.5
  run(2)
  let cw = r.w - SbW - 1 - 2 * dp(12)
  let info = htmlPageInfo(gmail, cw, zoom = 1.5)
  # at 1.5 the link is clicked where it is drawn now
  let l = info.word("updated")   # (the link: "the updated drill plan", wherever its line breaks)
  state(id).scrollY = max(0, l.y - 40)
  run(2)
  let o = contentOrigin(r)
  let p = point(o.x + l.x + 5, o.y + l.y + 3 - state(id).scrollY)
  doAssert p.y > r.y and p.y < r.y + r.h - SbW, $p & " " & $r
  move(p.x, p.y)
  run()
  down(p.x, p.y)
  run()
  up(p.x, p.y)
  run(2)
  doAssert ev.link == "https://intranet.example/safety/fire-2026.pdf", ev.link
  # a word chosen stays chosen at another zoom
  let k = info.word("Khalid")
  state(id).scrollY = max(0, k.y - 40)
  run(2)
  let kp = point(o.x + k.x + 6, o.y + k.y + 3 - state(id).scrollY)
  down(kp.x, kp.y, clicks = 2)
  run()
  up(kp.x, kp.y)
  run()
  ctrlKey(KeyMinus)
  doAssert z == 1.25, $z
  ctrlKey(KeyC)
  ctrlUp()
  doAssert getClipboardText() == "Khalid", getClipboardText()

block zoomKeepsItsPlace:
  let id = idOf("htmlviewzoomplace")
  var z = 1.0
  view = proc () = discard htmlView(newsletter, z, height = 300, key = "zoomplace")
  run(3)
  let r = ui.lastRect
  let cw = r.w - SbW - 1 - 2 * dp(12)
  const mark = "On orders over OMR 15"
  # a line at the top: the keys keep it there
  state(id).scrollY = htmlPageInfo(newsletter, cw).word(mark).y
  run(2)
  move(r.x + 60, r.y + 60)
  ctrlKey(KeyEqual)
  let z1 = z
  doAssert z1 > 1.0
  run()
  let at = htmlPageInfo(newsletter, cw, zoom = z1).word(mark).y
  doAssert abs(state(id).scrollY - at) <= 16, $state(id).scrollY & " vs " & $at
  ctrlUp()
  # Ctrl+wheel keeps the line under the pointer under it
  let top = r.y + 1 + dp(12)
  let shown = top + at - state(id).scrollY                  # (where the line is on the screen)
  move(r.x + 120, shown + 4)
  run()
  queue.add Event(kind: MouseWheelEvent, y: 2, mods: {CtrlPressed}, hasMods: true)
  run(2)
  let z2 = z
  doAssert z2 > z1, $z
  let now = top + htmlPageInfo(newsletter, cw, zoom = z2).word(mark).y - state(id).scrollY
  doAssert abs(now - shown) <= 24, "the line moved from " & $shown & " to " & $now
  ctrlUp()
  # zoomed far in, the page wider than the view scrolls sideways (Shift+wheel)
  z = 3.0
  run(2)
  let wide = htmlPageInfo(newsletter, cw, zoom = 3.0)
  if wide.right > cw:
    let x0 = state(id).scrollX
    queue.add Event(kind: MouseWheelEvent, y: -2, mods: {ShiftPressed}, hasMods: true)
    run(2)
    doAssert state(id).scrollX > x0, "sideways"
    queue.add Event(kind: KeyUpEvent, key: KeyNone, hasMods: true)
    run()
  z = 1.0
  run(2)
  doAssert state(id).scrollX == 0, "back in the width: nothing to the side"

# ---- pictures ---------------------------------------------------------------------------------------

block pictures:
  # from the app: none at first (wanted), then it comes
  var have = false
  let src: HtmlImageSource = proc (s: string): Bitmap =
    if have and s == "cid:hero-beans@sohar": newBitmap(300, 100, 0xFF336699'u32) else: Bitmap()
  var info = htmlPageInfo(newsletter, 880, images = src)
  doAssert "cid:hero-beans@sohar" in info.wantedImages and not info.image("cid:hero").shown
  have = true
  htmlImagesChanged()
  info = htmlPageInfo(newsletter, 880, images = src)
  let hero = info.image("cid:hero")
  doAssert hero.shown and hero.r.w == 600 and hero.r.h == 200, $hero     # (its own aspect now)
  doAssert "cid:hero-beans@sohar" notin info.wantedImages
  # files next to the page; never outside it
  let dir = getTempDir() / "retro-htmlmail"
  removeDir(dir)
  createDir(dir / "page" / "pics")
  let png = encodePng(newBitmap(8, 4, 0xFF00FF00'u32))
  writeFile(dir / "page" / "pics" / "a.png", png)
  writeFile(dir / "outside.png", png)
  let page = "<img src='pics/a.png'><img src='../outside.png' width=8 height=4><img src='" &
             dir / "outside.png" & "' width=8 height=4><img src='pics/../../outside.png' width=8 height=4>" &
             "<img src='file://" & dir / "outside.png" & "' width=8 height=4>"
  let pi = htmlPageInfo(page, 400, baseDir = dir / "page")
  doAssert pi.images.len == 5 and pi.images[0].shown and pi.images[0].r.w == 8, $pi.images
  for k in 1 .. 4: doAssert not pi.images[k].shown, "outside the page's folder: " & pi.images[k].src
  doAssert not htmlPageInfo(page, 400).images[0].shown, "no folder: no files"
  removeDir(dir)
  # data: pictures, damaged ones too
  let bad = "<img src='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAAB!!!' alt='broken'>" &
            "<img src='data:image/png;base64," & repeat("A", 5000) & "'><img src='data:,'>"
  let bi = htmlPageInfo(bad, 400)
  doAssert bi.wantedImages.len == 0 and bi.images.allIt(not it.shown)
  # a picture too wide is made smaller, its aspect kept
  let big = htmlPageInfo("<img src='cid:x' width=1200 height=600>", 300)
  doAssert big.images[0].r.w == 300 and big.images[0].r.h == 150, $big.images[0]
  # drawn: the picture, and the box of one that is not there
  let shown: HtmlImageSource = proc (s: string): Bitmap = newBitmap(40, 20, 0xFFFF0000'u32)
  view = proc () =
    discard htmlView("<p><img src='cid:red' width=40 height=20></p>", height = 100, key = "pic",
                     images = shown)
  run(3)
  var red = 0
  for y in 0 ..< 120:
    for x in 0 ..< 100:
      if px(x, y) == 0xFF0000'u32: inc red
  doAssert red >= 40 * 20 - 40, $red

# ---- in the flow, the old way ------------------------------------------------------------------------

block blocksAndOldCalls:
  var ev: HtmlEvent
  view = proc () =
    beginCol()
    let e = htmlBlock("<p>card <a href='https://x.example/'>link</a></p>", w = 300)
    if e.link.len > 0: ev = e
    discard htmlView("<b>old call</b>", height = 80)
    endCol()
  run(3)
  doAssert htmlToMarkdown("<p>a <b>b</b></p>") == "a <b>b</b>"
  doAssert htmlTitle(newsletter) == "Sohar Coffee Roasters — November Beans"

# ---- how fast --------------------------------------------------------------------------------------

proc bigNewsletter(target: int): string =
  ## The newsletter with its middle repeated until it is `target` bytes.
  let a = newsletter.find("<!-- two products side by side -->")
  let b = newsletter.find("<!-- footer -->")
  let middle = newsletter[a ..< b]
  var mid = ""
  var k = 0
  while newsletter.len - middle.len + mid.len < target:
    mid.add middle.replace("Dhofar Highlands", "Dhofar Highlands " & $k)
    inc k
  newsletter[0 ..< a] & mid & newsletter[b .. ^1]

block speed:
  let big = bigNewsletter(200_000)
  doAssert big.len >= 200_000
  # read, styled and laid out: the first time (nothing kept)
  var best = high(int64)
  for k in 0 ..< 3:
    let page = big & "<!-- " & $k & " -->"
    let t0 = getMonoTime()
    let info = htmlPageInfo(page, 880)
    let us = (getMonoTime() - t0).inMicroseconds
    best = min(best, us)
    doAssert info.height > 20_000
  # laid out again at another width (the page read already)
  let t1 = getMonoTime()
  discard htmlPageInfo(big & "<!-- 2 -->", 600)
  let relayUs = (getMonoTime() - t1).inMicroseconds
  # zoomed: measured and laid out again at the new size
  let tz = getMonoTime()
  doAssert htmlPageInfo(big & "<!-- 2 -->", 600, zoom = 1.5).height > 20_000
  let zoomUs = (getMonoTime() - tz).inMicroseconds
  # a frame while it scrolls (drawn and rasterized)
  let id = idOf("htmlviewbig")
  var pos = 0
  view = proc () =
    state(id).scrollY = pos
    discard htmlView(big, height = 460, key = "big")
  run(3)
  let t2 = getMonoTime()
  const frames = 60
  for k in 0 ..< frames:
    pos = k * 157
    run(1)
  let frameUs = (getMonoTime() - t2).inMicroseconds div (frames + 1)
  echo "200 KB newsletter: read + styled + laid out ", formatFloat(float(best) / 1000, ffDecimal, 1),
       " ms, laid out again ", formatFloat(float(relayUs) / 1000, ffDecimal, 1),
       " ms, a frame scrolling ", formatFloat(float(frameUs) / 1000, ffDecimal, 2), " ms, zoomed ",
       formatFloat(float(zoomUs) / 1000, ffDecimal, 1), " ms"
  when defined(release):
    doAssert best < 50_000, "too slow: " & $best & " us"
    doAssert zoomUs < 50_000, "zooming too slow: " & $zoomUs & " us"
    doAssert frameUs < 16_000, "frames too slow: " & $frameUs & " us"
  else:
    doAssert best < 2_000_000

# ---- hostile pages ----------------------------------------------------------------------------------

block hostile:
  let t0 = getMonoTime()
  var deep = ""
  for i in 0 ..< 3000: deep.add "<table><tr><td><div><blockquote><ul><li><span>"
  deep.add "bottom"
  discard htmlPageInfo(deep, 600)
  discard htmlToText(deep)
  var spans = "<table><tr><td colspan=100000 rowspan=99999>x</td><td colspan=-5>y</td></tr>" &
              "<tr><td rowspan=0>z</td></tr></table>"
  discard htmlPageInfo(spans, 600)
  let huge = "<div style='width:99999999px;height:99999999px;padding:9999999px;margin:-9999999px;" &
             "font-size:99999px;line-height:99999999px;border:999999px solid red'>big</div>" &
             "<img src='cid:a' width=999999999 height=999999999><p style='font-size:0'>zero</p>" &
             "<table width=99999999 cellpadding=999999 cellspacing=999999><tr><td>t</td></tr></table>"
  let hi = htmlPageInfo(huge, 600)
  doAssert hi.right < 10_000_000
  # a word of a million letters, a line of <pre> as long: broken into lines, quickly
  let t1 = getMonoTime()
  let word = htmlPageInfo("<p>" & repeat("w", 1_000_000) & "</p><pre>" & repeat("p", 300_000) & "</pre>", 300)
  doAssert word.right <= 300 and word.height > 1000
  doAssert (getMonoTime() - t1).inMilliseconds < 10_000
  var wide = "<table><tr>"
  for i in 0 ..< 5000: wide.add "<td>c" & $i & "</td>"
  wide.add "</tr></table>"
  discard htmlPageInfo(wide, 600)
  var many = ""
  for i in 0 ..< 20000: many.add "<p class='a b c' style='color:red;margin:1px'>p</p>"
  discard htmlPageInfo(many, 600)
  var css = "<style>"
  for i in 0 ..< 3000: css.add "div div div div div div p.c" & $i & " > span, "
  css.add "a { color: red } </style>"
  for i in 0 ..< 60: css.add "<div>"
  css.add "<p class=c1><span>s</span></p>"
  discard htmlPageInfo(css, 600)
  let ms = (getMonoTime() - t0).inMilliseconds
  doAssert ms < 30_000, "hostile pages take " & $ms & " ms"

# ---- damaged pages: no harm ---------------------------------------------------------------------------

proc mutate(s: string): string =
  result = s
  for _ in 0 ..< rand(1 .. 8):
    if result.len == 0: result = "<"
    case rand(7)
    of 0:
      let i = rand(result.high)
      result[i] = char(rand(255))
    of 1:
      let i = rand(result.high)
      result.insert(["<", ">", "&", "\"", "'", "/", "=", "<!--", "]]>", "</td>", "<table>",
                     "<tr>", " colspan=9", " style='display:inline-block;float:left'",
                     "<blockquote>", "\xD8\xA7", "&#x202E;", "<img src='data:image/gif;base64,R0lGODlh'>"][rand(17)], i)
    of 2:
      let i = rand(result.high)
      result.delete(i .. min(result.high, i + rand(40)))
    of 3:
      let i = rand(result.high)
      let j = rand(result.high)
      result.insert(result[min(i, j) .. min(result.high, min(i, j) + rand(200))], max(i, j))
    of 4:
      result = result[0 ..< rand(result.len)]
    else:
      let i = rand(result.high)
      result.delete(i .. min(result.high, i + rand(3)))
    if result.len > 300_000: result.setLen(300_000)

block fuzz:
  randomize(20261103)
  let iters = when defined(release): 3000 else: 300
  var slowest = 0'i64
  let t0 = getMonoTime()
  for it in 0 ..< iters:
    let src = mutate(samples[rand(samples.high)][1])
    let start = getMonoTime()
    try:
      discard htmlToText(src)
      let info = htmlPageInfo(src, rand(20 .. 900))
      doAssert info.height >= 0
      if it mod 25 == 0:
        view = proc () =
          discard htmlView(src, height = 200, key = "fuzz")
          discard htmlBlock(src, w = 150)
        run(1)
    except CatchableError as e:
      doAssert false, "damaged page: " & e.msg & "\n" & src
    slowest = max(slowest, (getMonoTime() - start).inMilliseconds)
  echo "html mail fuzz: ", iters, " pages in ", (getMonoTime() - t0).inMilliseconds,
       " ms, slowest ", slowest, " ms"
  doAssert slowest < 2000

echo "html mail tests passed"

## A sample book made with the kit's layout engine (retroui/photobook),
## the one Retro Photo's Layout menu drives: a small book in Arabic, bound
## on the right, with facing pages -- a title page with margins of its own
## and the master's items hidden on it, its title's two lines made one
## width with kashidas (point text justified); master pages with a running
## head, a paragraph rule under it and the page number at the outer edge; a
## story that goes on through as many pages as it needs, in two columns,
## with footnotes numbered again on each page; a picture the text keeps out
## of, round its shape; a band across a spread (one shape, on both pages);
## the tashkeel in a color of its own; a table at the end, sorted by its
## second column, its header kept with the rows. Saved as
## a book (.rpb: every page opens in Retro Photo),
## as a PDF with the type as type, and its spreads as pictures.
##
##   nim c -r -d:release examples/book.nim [output folder]
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, math, strutils, unicode]
import retroui/[imaging, photo, photobook, photopdf, photoshapes, textengine]
{.push warning[UnusedImport]: off.}
import retroui/[photostyles, photodevelop]      # (for what they set up in retroui/photo)
{.pop.}

const
  ink = 0xFF1B1B2F'u32
  red = 0xFFB3261E'u32
  sand = 0xFFF6EFE2'u32
  teal = 0xFF1F6F78'u32

let outDir = if paramCount() >= 1: paramStr(1) else: "build/book"
createDir(outDir)

proc runesTo(s: string; b: int): int = s[0 ..< b].runeLen
  ## (the letters before byte `b`: where a note's reference goes)

proc st(size: float; color = ink; style = "Regular"): CharStyle =
  CharStyle(family: "FreeSerif", style: style, size: size, color: color, hScale: 1, vScale: 1)

# ---- the book: A5 at 150 pixels an inch, facing pages, bound on the right ----------------

var setup = bookSetup(148, 210, dpi = 150, facing = true, binding = bindRight, marginMm = 16)
setup.columns = 2
setup.numbers = nsArabicIndic
setup.paper = sand
let b = newBook(setup, pages = 2, name = "حكاية البحّار")

# ---- the master: a head and a rule at the top, the page number at the outer edge ---------

let m = b.addMaster("A")
for side in [psLeft, psRight]:
  let md = b.masterDoc(m, side)
  let box = b.marginBox(side)
  var head = newText("حكاية البحّار", st(17, teal), 0, 0)
  head.x = box.x.float32
  head.y = float32(box.y - 44)
  head.boxW = box.w.float32
  head.boxH = 30
  head.para.rtl = 2
  head.para.align = textCenter
  # (the rule under it: the paragraph's own Rule Below, as wide as the column)
  head.para.ruleBelow = ParaRule(on: true, weight: 2, color: teal, offset: 8)
  discard md.addTextLayer(head)
  var folio = newText("<#>", st(18, red), 0, 0)
  folio.x = box.x.float32
  folio.y = float32(box.y + box.h + 14)
  folio.boxW = box.w.float32
  folio.boxH = 30
  folio.para.rtl = 1
  # (the outer edge: the left of a left page, the right of a right one)
  folio.para.align = if side == psLeft: textLeft else: textRight
  discard md.addTextLayer(folio)
  md.markAll()

# ---- page 1: the title ------------------------------------------------------------------------

block:
  # (on the master, its running head and number hidden here; margins of its own, wider)
  b.setMaster(0, m.id)
  b.setHideMaster(0, true)
  b.setPageMargins(0, PageMargins(own: true, top: 140, bottom: 140, inside: 120, outside: 120, columns: 1))
  let d = b.doc(0)
  let box = b.marginBox(0)
  # the title: point text whose two lines are justified -- the shorter one lengthened with
  # kashidas to the longer one's width, as a scribe would
  var big = st(92, ink, "Bold")
  big.markColor = red                          # (the tashkeel in red, as in a schoolbook)
  var title = newText("", big, 0, 0)
  title.spans = @[TextSpan(text: "حِكَايَةُ البَحَّارِ\n", style: big), TextSpan(text: "في بحر عُمان", style: st(70, teal, "Bold"))]
  title.para.rtl = 2
  title.para.align = justifyAll
  title.para.kashida = kaLong
  let natural = layoutText(title)
  var wTitle = 0'f32
  for ln in natural.lines: wTitle = max(wTitle, ln.x1 - ln.x0)
  title.x = float32(d.w) / 2 - wTitle / 2 - natural.lines[0].x0 + title.x
  title.y = float32(box.y + 220)
  discard d.addTextLayer(title)
  var sub = newText("كتاب صغير صُنع بمحرّك التخطيط في Retro Nim UI\nصفحات متقابلة، تجليد من اليمين، أرقام هندية",
                    st(26, teal), 0, 0)
  sub.x = box.x.float32
  sub.y = float32(box.y + 470)
  sub.boxW = box.w.float32
  sub.boxH = 140
  sub.para.rtl = 2
  sub.para.align = textCenter
  discard d.addTextLayer(sub)
  # a sun over the sea
  let art = d.addLayer("Sun")
  let cx = d.w div 2
  let cy = box.y + 800
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      let r = hypot(float(x - cx), float(y - cy))
      if r < 110: art.px[y * d.w + x] = red
      elif y > cy + 150 and y < cy + 290 and x > box.x and x < box.x + box.w and
           (y - cy - 150 + int(8 * sin(x.float / 22))) mod 34 < 6:
        art.px[y * d.w + x] = teal
  inc art.ver
  d.markAll()

# ---- page 2 on: the story, in two columns, round a picture ------------------------------------

const para = "كان يا ما كان في قديم الزمان بحّارٌ يحبّ البحر ويعرف نجومه واحدةً واحدة. " &
             "كلّ صباح يرفع شراعه ويمضي حيث تأخذه الريح، وكلّ مساء يعود بحكايةٍ جديدة يرويها لأهل المرفأ. " &
             "قال لهم يومًا: البحر كتابٌ مفتوح، صفحاته الأمواج وسطوره الدروب التي تتركها السفن. " &
             "ومن يقرأه بصبرٍ يجد في كلّ صفحة مرسىً لم يعرفه أحدٌ قبله.\n"

block:
  b.setMaster(1, m.id)
  let d = b.doc(1)
  var text = ""
  for k in 1 .. 44: text.add para
  var story = newText(text, st(21), 0, 0)
  story.para.rtl = 2
  story.para.align = justifyLeft
  story.para.spaceAfter = 10
  story.spans[0].style.leading = 34
  # (notes at the foot of the column, numbered in Arabic-Indic figures, again on each page)
  story.noteOpts = NoteOptions(numbers: nsArabicIndic, restart: true, between: 4)
  let firstStop = text.find("نجومه") + "نجومه".len
  discard story.insertNote(text.runesTo(firstStop), "كان البحّارة يعرفون طريقهم بالنجوم قبل البوصلة.")
  discard story.insertNote(text.runesTo(text.find("المرفأ") + "المرفأ".len),
                           "المرفأ: حيث ترسو السفن وتُفرغ حمولتها.")
  let L = d.addTextLayer(b.boxed(story, 1))
  # a boat the text keeps out of, round its shape
  let box = b.marginBox(1)
  let boat = d.addLayer("Boat")
  let bx = box.x + box.w div 2
  let by = box.y + 330
  for y in by - 150 ..< by + 90:
    for x in bx - 170 ..< bx + 170:
      let dx = x - bx
      let dy = y - by
      # (a hull, a mast, a sail)
      if dy >= 30 and dy < 80 and abs(dx) < 160 - (dy - 30) * 2: boat.px[y * d.w + x] = ink
      elif abs(dx) < 4 and dy >= -140 and dy < 30: boat.px[y * d.w + x] = ink
      elif dx > 8 and dy >= -130 and dy < 20 and dx < (dy + 130) * 7 div 10: boat.px[y * d.w + x] = red
  inc boat.ver
  boat.wrap = 2
  boat.wrapGap = 14
  d.markAll()
  d.rewrap()
  let added = b.autoflow(1, L)
  echo "the story took ", added, " more pages: ", b.pages.len, " in all"
  # a band under the spread: one shape of this page that reaches across the spine -- its
  # other part is on the facing page
  discard d.addShapeLayer(ShapeData(path: rectPath(float(box.x - d.w), float(d.h - 46), float(box.x + box.w),
                                                   float(d.h - 40)), fill: solidPaint(teal)), "Band")
  d.markAll()
  discard b.syncSpread(1)

# ---- the last page: a table -- the sailor's stars, sorted by the month, its header kept --------

block:
  discard b.insertPage(master = m.id)
  let at = b.pages.high
  let d = b.doc(at)
  let box = b.marginBox(at)
  var cells = "النجم\tالشهر\tالجهة"
  for (star, month, side) in [("سهيل", "8", "الجنوب"), ("الثريا", "11", "الشرق"), ("الجدي", "1", "الشمال"),
                              ("العيوق", "12", "الشمال الشرقي"), ("السماك", "4", "الشرق")]:
    cells.add "\n" & star & "\t" & month & "\t" & side
  var t = newText(cells, st(22), box.x.float32, float32(box.y + 40))
  t.boxW = box.w.float32
  t.boxH = 420
  t.para.rtl = 2
  t.table = tableTheme("Plain Grid")
  t.table.widths = @[2'f32, 1, 2]
  t.table.headerRows = 1
  discard t.sortTable(1)                       # (by the month, as numbers: 1, 4, 8, 11, 12)
  discard d.addTextLayer(t)
  d.markAll()

# ---- saved: the book, its PDF, its spreads ---------------------------------------------------

b.saveBook(outDir / "book.rpb")
b.saveBookPdf(outDir / "book.pdf", pdfPreset(ppPrint))
var n = 0
var i = 0
while i < b.pages.len:
  inc n
  discard b.spreadPicture(i).savePng(outDir / ("spread-" & align($n, 2, '0') & ".png"))
  i += b.spreadOf(i).len
  b.park()
echo n, " spreads, ", b.pages.len, " pages: ", outDir
for i in 0 ..< b.pages.len: stdout.write b.label(i), " "
echo ""
b.close()

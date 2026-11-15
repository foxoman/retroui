## A sample book made with the kit's layout engine (retroui/photobook),
## the one Retro Photo's Layout menu drives: a small book in Arabic, bound
## on the right, with facing pages -- a title page; master pages with a
## running head, a rule and the page number at the outer edge; a story
## that goes on through as many pages as it needs, in two columns; a
## picture the text keeps out of, round its shape; a band across a spread
## (one shape, on both pages); the tashkeel in a color of its own. Saved as
## a book (.rpb: every page opens in Retro Photo),
## as a PDF with the type as type, and its spreads as pictures.
##
##   nim c -r -d:release examples/book.nim [output folder]
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, math, strutils]
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
  discard md.addTextLayer(head)
  let rule = md.addLayer("Rule")
  for y in box.y - 12 ..< box.y - 10:
    for x in box.x ..< box.x + box.w: rule.px[y * md.w + x] = teal
  inc rule.ver
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
  let d = b.doc(0)
  let box = b.marginBox(0)
  var title = newText("حِكَايَةُ البَحَّارِ", st(92, ink, "Bold"), 0, 0)
  title.spans[0].style.markColor = red         # (the tashkeel in red, as in a schoolbook)
  title.x = box.x.float32
  title.y = float32(box.y + 220)
  title.boxW = box.w.float32
  title.boxH = 190
  title.para.rtl = 2
  title.para.align = textCenter
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

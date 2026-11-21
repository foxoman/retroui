## Tests of a book's lists (retroui/booklists): the table of contents from the paragraph
## styles (each a level) or from the type's size, in the pages' order, top to bottom on a
## page, a master's text left out; the index's words found on their pages as whole words, in
## any case, Arabic with or without its marks, sorted; both as text boxes (a table of two
## columns, the numbers at the edge); and hyphenation's own words.

import std/[strutils]
import retroui/[photo, photobook, textengine, booklists, hyphenate]

proc st(size: float32): CharStyle = CharStyle(family: "", size: size, color: 0xFF202020'u32, hScale: 1, vScale: 1)

block tocAndIndex:
  let b = newBook(bookSetup(148, 210, dpi = 100, facing = false), pages = 5, name = "T")
  let m = b.addMaster("A")
  discard b.masterDoc(m, psRight).addTextLayer(newText("Running head", st(30), 40, 20))
  for i in 0 ..< 5: b.setMaster(i, m.id)
  let pages = [("Muscat and the coast", "Muscat lies on the sea. Sohar is north of it."),
               ("The interior", "Nizwa and its fort; Muscat again. Muscatel is not Muscat."),
               ("Dhofar", "Salalah in the south."),
               ("عُمان", "مسقط عاصمة عمان."),
               ("Sohar", "The port of SOHAR.")]
  for i, (h, body) in pages:
    var t = newText(h, st(30), 40, 60)
    t.para.styleName = if i == 3: "Section" else: "Chapter"
    discard b.doc(i).addTextLayer(t)
    var bt = b.boxed(newText(body, st(16)), i)
    bt.y += 80
    discard b.doc(i).addTextLayer(bt)
  # (a smaller heading higher on page 3: it comes first there)
  var sub = newText("Before Dhofar", st(30), 40, 30)
  sub.para.styleName = "Section"
  discard b.doc(2).addTextLayer(sub)
  let toc = b.tocEntries(@["Chapter", "Section"])
  var names: seq[string]
  for e in toc: names.add e.text
  doAssert names == @["Muscat and the coast", "The interior", "Before Dhofar", "Dhofar", "عُمان", "Sohar"], $names
  doAssert toc[2].level == 1 and toc[3].level == 0 and toc[4].label == "4"
  # by size: the 30-pixel text
  let bySize = b.tocEntries(minSize = 25)
  doAssert bySize.len == 6 and "Running head" notin $bySize, "a master's text left out"
  # the index: whole words, any case, Arabic without its marks
  let ix = b.indexEntries(@["Muscat", "Sohar", "fort", "عُمان", "Paris"])
  var got: seq[string]
  for e in ix: got.add e.term & ":" & e.labels.join(",")
  doAssert got == @["fort:2", "Muscat:1,2", "Sohar:1,5", "عُمان:4"], $got
  # as text boxes
  var tt = tocText(toc, "Contents", st(16), 400)
  doAssert not tt.table.on and tt.para.tabs.len == 1 and tt.para.tabs[0].align == tabRight and
           tt.para.tabs[0].leader.len > 0 and "Dhofar\t3" in tt.plainText
  let lay = layoutText(tt)
  doAssert lay.overflow == -1 and lay.glyphs.len > 40
  for ln in lay.lines[1 .. ^1]: doAssert abs(ln.x1 - 400) < 1, "each number at the edge: " & $ln.x1
  # set as the layout program's dialog says: the number before, or none; something between; sorted;
  # a style for a level and for the title; a dashed leader
  let before = tocText(toc, "", st(16), 400, o = TocOptions(numbers: tnBefore, between: " -- "))
  doAssert "3 -- Dhofar" in before.plainText and before.para.tabs.len == 0, before.plainText
  let bare = tocText(toc, "", st(16), 400, o = TocOptions(numbers: tnNone, sorted: true))
  doAssert bare.plainText.startsWith("    Before Dhofar\nDhofar") and "\t" notin bare.plainText, bare.plainText
  var big = st(20)
  big.fauxBold = true
  var tts = st(40)
  let styled = tocText(toc, "Contents", st(16), 400,
                       o = TocOptions(levelStyles: @[big], titleStyle: tts, leader: "- "))
  doAssert styled.spans[0].style.size == 40 and styled.para.tabs[0].leader == "- "
  var chapterSized, sectionSized = false
  for sp in styled.spans:
    if "Muscat" in sp.text and sp.style.size == 20 and sp.style.fauxBold: chapterSized = true
    if "Before Dhofar" in sp.text and sp.style.size == 16: sectionSized = true
  doAssert chapterSized and sectionSized, "the first level in its style, the second as the list"
  # text on a hidden layer: only when asked
  for L in b.doc(2).layers:
    if L.isText and "Before Dhofar" in L.text.plainText: L.visible = false
  doAssert b.tocEntries(@["Chapter", "Section"]).len == 5 and b.tocEntries(@["Chapter", "Section"], hidden = true).len == 6
  var it = indexText(ix, "Index", st(14), 400)
  doAssert "Muscat\t1, 2" in it.plainText and "\nM\n" in it.plainText and it.para.tabs.len == 1
  let itAr = indexText(ix, "الفهرس", st(14), 400, rtl = true)
  doAssert "Muscat\t1، 2" in itAr.plainText and itAr.para.rtl == 2
  b.close()

block hyphenationWords:
  doAssert hyphenated("international") == "in-ter-na-tional"
  doAssert hyphenPoints("associates") == @[2, 4]   # (the patterns' own exception: as-so-ciates)

echo "test_booklists: ok"

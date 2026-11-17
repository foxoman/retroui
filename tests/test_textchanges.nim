## Tests of what the layout programs' stories have (retroui/textengine): Paragraph Shading and
## Borders, Conditional Text, Track Changes, Notes -- and the document showing them as they
## print (retroui/photo's `effectiveText`).

import retroui/[textengine, photo]

proc txt(s: string): TextData =
  var st = defaultStyle()
  st.size = 20
  result = newText(s, st, 10, 10)
  result.boxW = 300
  result.boxH = 400

block shadingAndBorders:
  var t = txt("A heading\nA paragraph with some words in it that runs over a line or two.")
  var shaded = t.para
  shaded.shading = 0xFFFFE08A'u32
  shaded.shadeOffsets = [4'f32, 0, 4, 0]
  t.para = shaded
  let lay = layoutText(t)
  doAssert lay.backs.len >= 2, $lay.backs.len                 # (each paragraph its fill)
  let b = lay.backs[0]
  doAssert b.color == 0xFFFFE08A'u32
  doAssert abs(b.x0 - 10) < 0.5 and abs(b.x1 - 310) < 0.5    # (the column's width)
  let first = lay.lines[0]
  doAssert b.y - b.thick / 2 <= first.baseline - first.ascent - 3.5
  # as wide as the text, a border round it
  var u = txt("Short")
  var p = u.para
  p.shadeToText = true
  p.shading = 0xFF102030'u32
  p.border = 0xFFCC0000'u32
  p.borderWidths = [2'f32, 2, 2, 2]
  u.para = p
  let l2 = layoutText(u)
  doAssert l2.backs[0].x1 < 200 and l2.backs[0].x1 >= l2.lines[0].x1 - 0.5
  var reds = 0
  for dcr in l2.decorations:
    if dcr.color == 0xFFCC0000'u32: inc reds
  doAssert reds == 4
  # kept in a document
  let j = u.toJson
  let back = textFrom(j)
  doAssert back.para.shading == 0xFF102030'u32 and back.para.border == 0xFFCC0000'u32
  doAssert back.para.borderWidths == [2'f32, 2, 2, 2] and back.para.shadeToText

block conditionalText:
  var t = txt("Price: 10 OMR. Price: 25 USD.")
  t.applyCondition(7, 14, "Oman")
  t.applyCondition(22, 29, "US")
  t.applyCondition(22, 29, "Print")
  doAssert t.conditionsOf == @["Oman", "US", "Print"]
  doAssert t.withConditions(["Oman"]).plainText == "Price:  Price: 25 USD."
  # (text under two conditions: hidden only when both are)
  doAssert t.withConditions(["US"]).plainText == t.plainText
  doAssert t.withConditions(["US", "Print"]).plainText == "Price: 10 OMR. Price: "
  t.applyCondition(22, 29, "US", on = false)
  doAssert t.styleAt(23).condition == "Print"
  doAssert textFrom(t.toJson).styleAt(8).condition == "Oman"
  # the document hides them as it prints
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  let L = d.addTextLayer(t)
  d.conditions = @[TextCondition(name: "Oman", visible: false), TextCondition(name: "Print", visible: true)]
  doAssert d.effectiveText(L).plainText == "Price:  Price: 25 USD."

block trackChanges:
  var t = txt("The quick fox.")
  t.track = true
  t.trackedInsert(10, "brown ", defaultStyle(), "Sultan|2026-11-17")
  doAssert t.plainText == "The quick brown fox."
  t.trackedDelete(4, 10, "Sultan|2026-11-17")                 # ("quick ": struck, kept)
  doAssert t.plainText == "The quick brown fox."
  doAssert t.withoutDeleted.plainText == "The brown fox."
  let ch = t.changesOf
  doAssert ch.len == 2 and not ch[0].added and ch[0].text == "quick " and ch[1].added and
           ch[1].text == "brown " and ch[0].who == "Sultan" and ch[0].at == "2026-11-17", $ch
  # (deleting what a change added: gone for good)
  var t2 = t
  t2.trackedDelete(10, 16, "Sultan|2026-11-17")
  doAssert t2.plainText == "The quick fox." and t2.changesOf.len == 1
  # shown: added underlined, deleted struck
  let shown = t.showingChanges
  doAssert shown.styleAt(5).strike and shown.styleAt(11).underline
  var acc = t
  acc.acceptChanges()
  doAssert acc.plainText == "The brown fox." and acc.changesOf.len == 0
  var rej = t
  rej.rejectChanges()
  doAssert rej.plainText == "The quick fox." and rej.changesOf.len == 0
  # one of them accepted alone
  var one = t
  one.acceptChanges(10, 16)
  doAssert one.plainText == "The quick brown fox." and one.changesOf.len == 1
  doAssert textFrom(t.toJson).changesOf.len == 2 and textFrom(t.toJson).track
  # the document: as it prints, and while it is typed in
  let d = newDoc(400, 300, 0xFFFFFFFF'u32)
  let L = d.addTextLayer(t)
  doAssert d.effectiveText(L).plainText == "The brown fox."
  if L.uid == 0: L.uid = 77
  d.rawText = L.uid
  doAssert d.effectiveText(L).plainText == "The quick brown fox."

block notes:
  var t = txt("Check these numbers again.")
  t.addMemo(6, 19, "Sultan|2026-11-17", "Are they from the 2025 report?")
  let ms = t.memosOf
  doAssert ms.len == 1 and ms[0].a == 6 and ms[0].b == 19 and ms[0].who == "Sultan" and
           ms[0].text == "Are they from the 2025 report?", $ms
  doAssert t.plainText == "Check these numbers again."       # (not in the text)
  doAssert textFrom(t.toJson).memosOf.len == 1
  t.removeMemo(6, 19)
  doAssert t.memosOf.len == 0

echo "text changes ok"

## Tests of diagrams placed in a document (`retroui/diagrams`): each kind made of shape and type
## layers in one group that keeps what it was made from (and gives it back); a family tree's
## highlighted boxes in the accent, a stack's boxes beside its line, a tree too wide made smaller
## to fit; a timeline's dot a date and a date for each side; a numbered list in Arabic-Indic
## digits; a note's two labels on one baseline; a title's rule; a carousel of slides, its groups
## side by side (none inside another), its page numbers "3 / 8" on the canvas and in an exported
## slide; a ".rpd" keeping small layers only where they have pixels, read back the same.

import std/[os, json, strutils]
import retroui/[gfx, photo, photocc, diagrams, textengine, screenexport, zip]

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

proc kidsOf(d: Doc; g: Layer): seq[Layer] =
  let k = d.layers.find(g)
  for j in d.blockStart(k) ..< k: result.add d.layers[j]

proc shapesNamed(ls: seq[Layer]; prefix: string): seq[Layer] =
  for L in ls:
    if L.isShape and L.name.startsWith(prefix): result.add L

block eachKind:
  for k in DiagramKind:
    let s = defaultDiagram(k)
    let d = newDoc(1080, 1100, s.theme.paper, 72, "x")
    let g = d.placeDiagram(s, rect(80, 80, 920, 900))
    check g != nil and g.group and g.isDiagram, $k & ": a group, marked a diagram"
    let kids = d.kidsOf(g)
    var texts, shapes = 0
    for L in kids:
      if L.isText: inc texts
      if L.isShape: inc shapes
    check texts > 0 and shapes > 0, $k & ": shape and type layers (" & $shapes & " and " & $texts & ")"
    let back = g.diagramOf
    check back.ok and back.spec.kind == k and back.spec.data == s.data and back.box == rect(80, 80, 920, 900) and
          back.spec.theme.accent == s.theme.accent, $k & ": what it was made from, given back"
    for L in kids:
      let b = d.layerBox(L)
      doAssert b.w <= 0 or (b.x >= 60 and b.x + b.w <= 1020), $k & ": " & L.name & " in its box"
    check true, $k & ": inside its box"

block tree:
  var s = defaultDiagram(dkTree)
  let d = newDoc(1080, 1100, s.theme.paper, 72, "x")
  let g = d.placeDiagram(s, rect(80, 80, 920, 0))
  let kids = d.kidsOf(g)
  var hi = 0
  var dashed = 0
  for L in kids.shapesNamed("Box "):
    if L.shape.fill.kind == spColor and L.shape.fill.color == s.theme.accent: inc hi
    if L.shape.dashes.len > 0: inc dashed
  check hi == 3 and dashed == 3, "the three highlighted boxes filled in the accent, three dashed"
  # (Greek's children stacked: one under another, left of its line -- Arabic first)
  var greek, latin, cyr: Rect
  for L in kids.shapesNamed("Box "):
    if "اليونانية" in L.name: greek = d.layerBox(L)
    if "اللاتينية" in L.name: latin = d.layerBox(L)
    if "الكريلية" in L.name: cyr = d.layerBox(L)
  let line = greek.x + greek.w div 2
  check latin.y > greek.y + greek.h and cyr.y > latin.y + latin.h and latin.x + latin.w < line + 2 and
        cyr.x + cyr.w < line + 2, "a stack: under its parent, one under another, left of its line"
  check kids.shapesNamed("Highlighted lines").len == 1, "the highlighted path's lines in a layer of their own"
  # (too wide for its box: made smaller)
  s.data = "Root\n" & "  One | ١\n  Two | ٢\n  Three | ٣\n  Four | ٤\n  Five | ٥\n  Six | ٦\n  Seven | ٧"
  let narrow = d.placeDiagram(s, rect(100, 600, 300, 0))
  var x0 = 10000
  var x1 = -1
  for L in d.kidsOf(narrow):
    let b = d.layerBox(L)
    if b.w > 0:
      x0 = min(x0, b.x)
      x1 = max(x1, b.x + b.w)
  check x0 >= 98 and x1 <= 402, "a tree too wide for its box made smaller to fit (" & $x0 & ".." & $x1 & ")"

block timeline:
  let s = defaultDiagram(dkTimeline)
  let (parts, _) = diagramParts(s, rect(0, 0, 920, 0))
  var dots = 0
  var right = false
  for p in parts:
    if not p.isText and (p.name == "Dots" or p.name == "Highlighted dots"): dots += p.shape.path.subs.len
    if p.isText and p.text.plainText.startsWith("٥٦٨ م"): right = true
  check dots == 5, "a dot a date"
  check right, "\"568 CE / ٥٦٨ م\": the Arabic date on its own side"

block numbered:
  var s = defaultDiagram(dkList)
  let (parts, _) = diagramParts(s, rect(0, 0, 920, 0))
  var nums = 0
  for p in parts:
    if p.isText and p.text.plainText in ["1", "2", "3", "4"]:
      doAssert p.text.spans[0].style.digits == 1
      inc nums
  check nums == 4, "four numbers, in Arabic-Indic digits"
  s.arabicDigits = false
  let (plain, _) = diagramParts(s, rect(0, 0, 920, 0))
  for p in plain:
    if p.isText and p.text.plainText == "1": check p.text.spans[0].style.digits == 0, "... or as typed"

block note:
  let s = defaultDiagram(dkNote)
  let (parts, _) = diagramParts(s, rect(0, 0, 920, 0))
  var bases: seq[float]
  for p in parts:
    if p.isText and p.text.plainText in ["Note", "ملاحظة"]:
      let L = layoutText(p.text)
      bases.add L.lines[0].baseline.float
  check bases.len == 2 and abs(bases[0] - bases[1]) < 0.6, "a note's two labels on one baseline"

block title:
  let s = defaultDiagram(dkTitle)
  let (parts, _) = diagramParts(s, rect(0, 0, 920, 0))
  var rule = false
  for p in parts:
    if not p.isText and p.name == "Rule" and p.shape.fill.color == s.theme.accent: rule = true
  check rule, "a title's short rule, in the accent"

block carousel:
  let d = newCarousel(defaultCarousel())
  check d.boards.len == 8 and d.boards[0].color == diagramTheme("Parchment").paper, "eight slides, in the paper"
  var deep = 0
  var groups = 0
  for L in d.layers:
    if L.group:
      inc groups
      if L.depth > 0: inc deep
  check groups == 15 and deep == 0, "each slide's groups side by side, none inside another (" & $groups & ")"
  var numbers: seq[string]
  for L in d.layers:
    if L.isText and "<#>" in L.text.plainText: numbers.add d.effectiveText(L).plainText
  check numbers.len == 8 and "3 / 8" in numbers and "8 / 8" in numbers, "page numbers: " & numbers.join(", ")
  let it = d.artboardItems(@[2])[0]
  let one = d.itemDoc(it)
  var shown = ""
  for L in one.layers:
    if L.isText and "<#>" in L.text.plainText: shown = one.effectiveText(L).plainText
  check shown == "3 / 8", "an exported slide says its number too"
  let c = slideContent(d.boards[1].r)
  let b = d.boards[1].r
  check c.x > b.x and c.x + c.w < b.x + b.w and c.y > b.y + 150 and c.y + c.h < b.y + b.h - 100,
        "a slide's room for a diagram, between its header and its footer"

block rpdCropped:
  let d = newCarousel(CarouselSpec(slides: 3, w: 540, h: 675, theme: diagramTheme("Sea"), samples: true,
                                   frame: SlideFrame(enTitle: "T", arTitle: "ع", pageNumbers: true)))
  discard d.addLayer("Empty")
  let path = getTempDir() / "retro_diagrams_test.rpd"
  d.saveRpd(path)
  let e = loadRpd(path)
  check e.layers.len == d.layers.len and e.boards.len == 3, "read back: every layer, every slide"
  var same = true
  for i in 0 ..< d.layers.len:
    if not d.layers[i].group and d.layers[i].px != e.layers[i].px: same = false
  check same, "every layer's pixels the same"
  check e.layers[^1].name == "Empty" and e.layers[^1].px.len == e.w * e.h, "an empty layer: kept, empty"
  var j: JsonNode
  for z in zipEntries(path):
    if z.name == "document.json": j = parseJson(readEntry(path, z))
  var cropped, whole, none = 0
  for lj in j["layers"].getElems:
    if lj.hasKey("box"): inc cropped
    elif lj.hasKey("file"): inc whole
    elif not lj{"group"}.getBool: inc none
  check cropped > 10 and none >= 2, "small layers kept only where they have pixels (" & $cropped & "), " &
        "empty ones not at all (" & $none & "), the rest whole (" & $whole & ")"
  removeFile(path)

echo "test_diagrams: ", passed, " passed"

## Tests of `retroui/otshape` (OpenType shaping) and of the variable fonts
## of `retroui/ttf`, against independent references:
##
## * shaping: 4097 runs whose glyphs, clusters, advances and offsets must
##   equal what HarfBuzz 15.0.0 (uharfbuzz 0.57, cluster level
##   "characters") gives for the same font, text, direction, script,
##   language, features and axis values -- Arabic (FreeSerif, Noto Sans
##   Arabic with its weight and width axes), Latin (EB Garamond), a font
##   with only a legacy `kern` table (FreeSerif-KernOnly) and a small font
##   made to hold every GSUB and GPOS lookup type, context format and
##   lookup flag;
## * variable fonts: outlines, bounds and advances at several axis values
##   against fontTools' `varLib.instancer` (static instances) and the
##   advances against HarfBuzz;
## * the feature list and names, the axes and named instances, the speed.
##
## How the data in tests/data/fonts was made (Python, fontTools 4.66 and
## uharfbuzz 0.57; nothing of it is needed to run this test):
##
## * OTLayoutTest.ttf: `fontTools.fontBuilder` glyphs (plain boxes) plus a
##   feature file compiled by `feaLib`, each contextual lookup's format
##   chosen on purpose, `WRITE_GPOS7` on; made for these tests (public domain).
## * VarTest.ttf: six masters drawn with `fontBuilder` (wght 100..900 with
##   masters at 100, 400, 650, 900; wdth 50..100; a wdth 50 wght 900
##   corner), `varLib.build` without HVAR (advances from phantom points),
##   an avar map, then two `TupleVariation`s only one glyph uses (embedded
##   peaks, sparse points) and GSUB feature variations (`rvrn`: "o" turns
##   into "O" from wght 650, "H" into "A" when narrow and light); made for
##   these tests (public domain).
## * NotoSansArabic-Subset.ttf: Noto Sans Arabic[wdth,wght] from
##   github.com/google/fonts (OFL, NotoSansArabic-OFL.txt) cut by
##   `fontTools.subset` to the basic Arabic letters, marks, digits and some
##   punctuation, with its joining, ligature, mark and kern features.
## * EBGaramond-Subset.ttf: EB Garamond[wght] from github.com/google/fonts
##   (OFL, EBGaramond-OFL.txt) cut to ASCII and a few accents with liga,
##   dlig, kern, mark, smcp, onum, frac, ss01, case..., made static at
##   wght 400 by `varLib.instancer`.
## * ReemKufi-Subset.ttf: Reem Kufi[wght] from github.com/google/fonts
##   (OFL, ReemKufi-OFL.txt) made static at wght 400 by `varLib.instancer`
##   and cut to the Arabic letters, tashkeel and the test lines: a font that
##   builds ب ت ي ق... from a dotless letter and dot glyphs (`ccmp`), placed
##   by `mark` -- the dots are the letter's, not tashkeel.
## * otshape-cases.txt.z (zlib): one run per line, "font|ltr or rtl|script|
##   language|features|axis values|code points (hex)|HarfBuzz's glyphs",
##   each glyph "gid=cluster@xOffset,yOffset+xAdvance"; the texts are fixed
##   strings and seeded random ones (letters, tashkeel, Quranic marks,
##   tatweel, ZWJ/ZWNJ, CGJ, digits, brackets, spaces).
## * instances/: `varLib.instancer.instantiateVariableFont` of VarTest and
##   of the Noto subset at the axis values in instances/list.txt, which
##   also holds HarfBuzz's advance of every glyph there.
##
## * FreeSerif-KernOnly.ttf: GNU FreeSerif 0412 (GPL v3 or later with the
##   font exception, src/retroui/fonts/LICENSE-FreeFont.txt) cut by
##   `pyftsubset` to ASCII, Latin-1 and the quotes, its legacy `kern` table
##   kept and its OpenType layout dropped.
##
## FreeSerif.ttf is the built-in GNU FreeFont subset in src/retroui/fonts
## (the "serif" and "kernonly" runs were shaped again by HarfBuzz when they
## took the place of Amiri and the DejaVu Sans subset the kit had before).

import std/[os, strutils, monotimes, times, tables]
import std/unicode except splitWhitespace
import retroui/[ttf, otshape, codec]

let dir = currentSourcePath().parentDir / "data" / "fonts"
let fontDir = currentSourcePath().parentDir.parentDir / "src" / "retroui" / "fonts"

var faces: Table[string, Face]
proc face(key: string): Face =
  if key notin faces:
    let path = case key
               of "serif": fontDir / "FreeSerif.ttf"
               of "kernonly": dir / "FreeSerif-KernOnly.ttf"
               of "noto": dir / "NotoSansArabic-Subset.ttf"
               of "garamond": dir / "EBGaramond-Subset.ttf"
               of "layout": dir / "OTLayoutTest.ttf"
               of "var": dir / "VarTest.ttf"
               else: dir / key
    faces[key] = parseFace(readFile(path))
  faces[key]

proc serialize(gs: seq[ShapedGlyph]): string =
  for g in gs:
    if result.len > 0: result.add ' '
    result.add $g.gid & "=" & $g.cluster & "@" & $g.xOff & "," & $g.yOff & "+" & $g.xAdv

proc axisValues(s: string): seq[(string, float)] =
  for kv in s.split(','):
    if kv.len == 0: continue
    let x = kv.split('=')
    result.add (x[0], parseFloat(x[1]))

block shapingMatchesHarfBuzz:
  let packed = readFile(dir / "otshape-cases.txt.z")
  var bytes = newSeq[byte](packed.len)
  for i, c in packed: bytes[i] = byte(c)
  let raw = zlibDecompress(bytes)
  var text = newString(raw.len)
  for i, b in raw: text[i] = char(b)
  var total, bad: int
  var perFont: Table[string, (int, int)]
  for line in text.splitLines:
    if line.len == 0: continue
    let p = line.split('|')
    var f = face(p[0])
    if p[5].len > 0: f = f.variation(axisValues(p[5]))
    var cps: seq[int]
    for h in p[6].splitWhitespace: cps.add parseHexInt(h)
    var feats: seq[Feature]
    for x in p[4].split(','):
      if x.len > 1: feats.add (x[1 .. ^1], x[0] == '+')
    let got = f.shape(cps, p[1] == "rtl", p[2], p[3], feats)
    for g in got: doAssert g.yAdv == 0
    let s = serialize(got)
    inc total
    var pf = perFont.getOrDefault(p[0])
    inc pf[0]
    if s != p[7]:
      inc bad
      inc pf[1]
      if bad <= 5:
        echo "shaping differs: ", line.rsplit('|', 1)[0]
        echo "  harfbuzz: ", p[7]
        echo "  otshape:  ", s
    perFont[p[0]] = pf
  for k, v in perFont: echo "  ", k, ": ", v[0] - v[1], " of ", v[0], " runs as HarfBuzz"
  echo "shaping: ", total - bad, " of ", total, " runs exactly as HarfBuzz"
  doAssert total == 4306
  doAssert bad == 0

proc lsbShift(f: Face; g: int): float32 =
  ## (xMin - lsb): where a static glyph's left phantom point is.
  let (hh, _) = f.tableRange("hhea")
  let (hm, _) = f.tableRange("hmtx")
  let data = f.fontData
  template u16(i: int): int = (ord(data[i]) shl 8) or ord(data[i + 1])
  let nh = u16(hh + 34)
  let at = if g < nh: hm + 4 * g + 2 else: hm + 4 * nh + 2 * (g - nh)
  var lsb = u16(at)
  if lsb >= 0x8000: lsb -= 0x10000
  let b = f.bounds(g)
  if b == (0, 0, 0, 0): return 0
  float32(b.x0 - lsb)

block variationsMatchInstancer:
  for line in readFile(dir / "instances" / "list.txt").splitLines:
    if line.len == 0: continue
    let p = line.split('|')
    let base = face(p[0])
    let v = base.variation(axisValues(p[1]))
    let inst = parseFace(readFile(dir / p[2]))
    let hbAdv = p[3].splitWhitespace
    doAssert hbAdv.len == base.numGlyphs
    var points = 0
    var worst = 0.0'f32
    for g in 0 ..< base.numGlyphs:
      doAssert v.advance(g) == inst.advance(g), "advance of glyph " & $g & " at " & p[1]
      doAssert v.advance(g) == parseInt(hbAdv[g]), "HarfBuzz's advance of glyph " & $g
      # (the instancer keeps the outline where it is and moves the left side
      # bearing; a variation moves the outline as HarfBuzz and FreeType do)
      let sh = base.lsbShift(g) - inst.lsbShift(g)
      let a = v.contours(g, 2)
      let b = inst.contours(g, 2)
      doAssert a.len == b.len
      for k in 0 ..< a.len:
        doAssert a[k].len == b[k].len
        for i in 0 ..< a[k].len:
          inc points
          let d = max(abs(a[k][i][0] - (b[k][i][0] + sh)), abs(a[k][i][1] - b[k][i][1]))
          worst = max(worst, d)
      let ba = v.bounds(g)
      let bb = inst.bounds(g)
      let s = int(sh)
      doAssert abs(ba.x0 - bb.x0 - s) <= 1 and abs(ba.x1 - bb.x1 - s) <= 1 and
               abs(ba.y0 - bb.y0) <= 1 and abs(ba.y1 - bb.y1) <= 1
    # (the instancer rounds each point, and a component and its offset
    # separately: up to 1 unit)
    doAssert worst <= 1.001, "outline differs by " & $worst
    echo "variation ", p[0], " ", p[1], ": ", base.numGlyphs, " advances as the instancer and ",
         "HarfBuzz, ", points, " outline points within ", worst.formatFloat(ffDecimal, 3)

block axesAndInstances:
  let f = face("var")
  let ax = f.axes
  doAssert ax.len == 2
  doAssert ax[0].tag == "wght" and ax[0].minV == 100 and ax[0].defV == 400 and ax[0].maxV == 900
  doAssert ax[1].tag == "wdth" and ax[1].minV == 50 and ax[1].defV == 100 and ax[1].maxV == 100
  doAssert ax[0].name == "Weight" and ax[1].name == "Width"
  let ins = f.instances
  doAssert ins.len == 3
  # (fvar keeps user values: the design value 300 of "Light" is 230.43 through the axis map)
  doAssert ins[0].name == "Light" and abs(ins[0].coords[0][1] - 230.4348) < 0.001 and
           ins[0].coords[0][0] == "wght" and ins[0].coords[1] == ("wdth", 100.0)
  doAssert ins[1].name == "Bold" and ins[1].coords == @[("wght", 650.0), ("wdth", 100.0)]
  doAssert ins[2].name == "Condensed Black" and ins[2].coords == @[("wght", 900.0), ("wdth", 50.0)]
  let noto = face("noto")
  doAssert noto.axes.len == 2 and noto.instances.len > 0
  # a static font has none, and its variation is itself
  let serif = face("serif")
  doAssert serif.axes.len == 0 and serif.instances.len == 0
  doAssert serif.variation([("wght", 700.0)]) == serif

block variationIsKeptAndLeavesTheFaceAlone:
  let f = parseFace(readFile(dir / "VarTest.ttf"))
  let o = f.glyphOf(ord('o'))
  let plainAdv = f.advance(o)
  let plainOutline = f.contours(o)
  let plainBox = f.bounds(o)
  let bold = f.variation([("wght", 900.0)])
  doAssert bold != f
  doAssert f.variation([("wght", 900.0), ("wdth", 100.0)]) == bold   # kept
  doAssert f.variation([("wght", 400.0)]) == f                      # the default
  doAssert bold.advance(o) == 500 and plainAdv == 500
  doAssert bold.contours(o) != plainOutline
  doAssert f.advance(o) == plainAdv and f.contours(o) == plainOutline and f.bounds(o) == plainBox
  let narrow = f.variation([("wdth", 50.0)])
  doAssert narrow.advance(o) == 300
  doAssert bold.bounds(o).x1 - bold.bounds(o).x0 < plainBox.x1 - plainBox.x0 + 1
  let m1 = f.render(o, 48)
  let m2 = narrow.render(o, 48)
  doAssert m1.w > 0 and m2.w > 0 and m2.w < m1.w
  # a variable font shapes at its axis values (advances and GPOS deltas)
  let noto = face("noto")
  var cps: seq[int]
  for r in "سلام".runes: cps.add int(r)
  let a = noto.shape(cps, true, "arab")
  let b = noto.variation([("wght", 900.0)]).shape(cps, true, "arab")
  var wa, wb = 0
  for g in a: wa += g.xAdv
  for g in b: wb += g.xAdv
  doAssert wb > wa

block featureListAndNames:
  let serif = face("serif")
  let tags = serif.featureTags
  for t in ["ccmp", "fina", "init", "kern", "liga", "mark", "medi", "mkmk", "rlig"]:
    doAssert t in tags, t
  for i in 1 ..< tags.len: doAssert tags[i - 1] < tags[i]
  doAssert serif.hasLayout
  doAssert not face("kernonly").hasLayout
  doAssert face("kernonly").featureTags.len == 0
  doAssert serif.featureName("liga") == "Standard Ligatures"
  doAssert serif.featureName("kern") == "Kerning"
  doAssert serif.featureName("init") == "Initial Forms"
  let lay = face("layout")
  doAssert lay.featureName("ss01") == "Alternate a and b"      # the font's own name
  doAssert lay.featureName("ss02") == "Stylistic Set 2"
  doAssert lay.featureName("cv03") == "Round context"
  doAssert lay.featureName("cv01") == "Character Variant 1"
  doAssert lay.featureName("xyz1") == "xyz1"

block noLayoutFont:
  # nominal glyphs and the kern pairs ttf.nim reads, split as HarfBuzz does
  let sans = face("kernonly")
  var cps: seq[int]
  for c in "AVATAR": cps.add ord(c)
  let gs = sans.shape(cps, false)
  doAssert gs.len == 6
  var pen = 0
  var plain = 0
  for i, g in gs:
    doAssert g.gid == sans.glyphOf(cps[i])
    doAssert g.cluster == i
    pen += g.xAdv
    plain += sans.advance(g.gid)
    if i > 0: plain += sans.kerning(gs[i - 1].gid, g.gid)
  doAssert pen == plain

block emptyAndOdd:
  let serif = face("serif")
  doAssert serif.shape(@[], true).len == 0
  doAssert serif.shape(@[0x10FFFF, 0xFFFF, 0xD800], false).len == 3   # missing, not crashing
  doAssert serif.shape(@[0x200D], true).len == 1

block speed:
  let serif = face("serif")
  let para = "بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ الْحَمْدُ لِلَّهِ رَبِّ الْعَالَمِينَ الرَّحْمَٰنِ الرَّحِيمِ مَالِكِ " &
             "يَوْمِ الدِّينِ إِيَّاكَ نَعْبُدُ وَإِيَّاكَ نَسْتَعِينُ اللغة العربية من أكثر اللغات انتشارا في العالم، " &
             "يتحدثها أكثر من أربعمائة مليون نسمة، وهي لغة رسمية في اثنتين وعشرين دولة. "
  var cps: seq[int]
  while cps.len < 1000:
    for r in para.runes:
      if cps.len < 1000: cps.add int(r)
  discard serif.shape(cps, true, "arab")
  var best = 1e9
  for _ in 0 ..< 20:
    let t0 = getMonoTime()
    let gs = serif.shape(cps, true, "arab")
    best = min(best, float((getMonoTime() - t0).inNanoseconds) / 1e6)
    doAssert gs.len > 900
  echo "speed: 1000 Arabic characters (FreeSerif) shaped in ", best.formatFloat(ffDecimal, 2), " ms"
  when defined(release) and not defined(otshapeNoTiming):
    doAssert best < 2.0

echo "otshape ok"

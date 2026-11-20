## Fonts with PostScript (CFF) outlines (`retroui/cff`): an .otf made from a TrueType font by
## tools/gencff.py -- the same glyphs, its quadratic curves written as the cubic ones that are
## exactly them -- read by the kit, each of its glyphs drawn as the TrueType font draws it,
## its advances the same, Arabic shaped by it as by the TrueType one (its GSUB and GPOS as
## they were), its faces named without reading it all, a PDF made with it (its outlines made
## TrueType go in as one), and what is not such a font refused.

import std/[os, strutils, unicode]
import retroui/[ttf, cff, otshape, pdf]

const data = currentSourcePath().parentDir / "data" / "fonts"

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

let ttfData = readFile(data / "NotoSansArabic-Subset.ttf")
let otfData = readFile(data / "NotoSansArabic-Subset-CFF.otf")
let a = parseFace(ttfData)
let b = parseFace(otfData)

block converted:
  let t = otfToTtf(otfData)
  check t.len > 12 and t[0 .. 3] == "\x00\x01\x00\x00", "made a font with TrueType outlines"
  check otfToTtf(ttfData) == "" and otfToTtf("OTTO") == "" and otfToTtf("") == "",
        "what is not a CFF font: nothing"
  check b.numGlyphs == a.numGlyphs and b.family == a.family and b.unitsPerEm == a.unitsPerEm,
        "its glyphs, family and em as they were: " & $b.numGlyphs & " " & b.family

block drawnTheSame:
  # (each glyph at 64 pixels: no pixel's coverage off by more than a quarter)
  var worst, worstG = 0
  var advances = true
  for g in 0 ..< a.numGlyphs:
    let ma = a.render(g, 64, hint = false)
    let mb = b.render(g, 64, hint = false)
    proc cov(m: Mask; x, y: int): int =
      let i = x - m.left
      let j = y - m.top
      if i < 0 or j < 0 or i >= m.w or j >= m.h: 0 else: int(m.a[j * m.w + i])
    for y in min(ma.top, mb.top) - 1 .. max(ma.top + ma.h, mb.top + mb.h) + 1:
      for x in min(ma.left, mb.left) - 1 .. max(ma.left + ma.w, mb.left + mb.w) + 1:
        let d = abs(cov(ma, x, y) - cov(mb, x, y))
        if d > worst: (worst, worstG) = (d, g)
    if a.advance(g) != b.advance(g): advances = false
  check worst <= 64, "every glyph drawn as the TrueType font draws it (coverage off by " & $worst &
        " of 255 at most, glyph " & $worstG & ")"
  check advances, "every advance the same"

block shapedTheSame:
  let word = "بسم الله الرحمن الرحيم".toRunes
  var cps: seq[int]
  for r in word: cps.add r.int
  let sa = a.shape(cps, rtl = true)
  let sb = b.shape(cps, rtl = true)
  var same = sa.len == sb.len
  if same:
    for i in 0 ..< sa.len:
      if sa[i].gid != sb[i].gid or sa[i].xAdv != sb[i].xAdv or sa[i].xOff != sb[i].xOff or
         sa[i].yOff != sb[i].yOff:
        same = false
  check same and sa.len > 10, "Arabic shaped as the TrueType font shapes it (" & $sa.len & " glyphs)"

block named:
  let fi = faceInfo(data / "NotoSansArabic-Subset-CFF.otf")
  check fi.len == 1 and fi[0].family == a.family, "its face named without reading it all"
  let tmp = getTempDir() / "retro-cff-test.otf"
  writeFile(tmp, "OTTO" & repeat('\0', 60))
  check faceInfo(tmp).len == 0, "a damaged one: no face"
  removeFile(tmp)

block inAPdf:
  let sub = subsetTtf(fontData(b), [0, b.glyphOf(0x0628), b.glyphOf(0x0627)])
  check sub.len > 100 and parseFace(sub, loose = true).numGlyphs == b.numGlyphs,
        "cut down for a PDF as a TrueType font is (" & $sub.len & " bytes)"

if failures > 0:
  echo "test_cff: ", failures, " failed"
  quit(1)
echo "test_cff: all passed"

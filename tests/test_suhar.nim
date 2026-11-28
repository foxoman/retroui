## Suhar App, the UI's font, and the faults found with Suhar (tests/data/fonts/Suhar*-Test.ttf,
## cut from Suhar App by tools/gensuhartestfonts.py; Suhar is under the SIL Open Font License,
## tests/data/fonts/Suhar-OFL.txt):
##
## - Suhar App is the default font, Suhar App Read a paragraph's (`TextStyle.read`), FreeFont's
##   three still to choose; a letter Suhar has not drawn comes from FreeFont;
## - a combining mark is drawn where it goes when its outline crosses the baseline (a damma's
##   foot under it, a kasra's top over it): by the font's GPOS, and by the kit without one;
## - a font with Arabic and GSUB's joining forms but no presentation forms draws its own Arabic,
##   joined (it fell back to the built-in font);
## - tall lines: room for fully vowelled Arabic;
## - `setRightToLeft`: the layout mirrored, not only the text's direction;
## - one variable font file as the UI's font, its bold the font at another weight.

import std/[os, unicode, strutils]
import retroui, retroui/[typeset, ttf]
import harness

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

fakeDriver()
startApp("suhar", W, H)
view = proc () = discard
run(2)

let fonts = currentSourcePath().parentDir / "data" / "fonts"

# ---- Suhar App, the default; Suhar App Read for paragraphs; FreeFont to choose ------------------------

check uiFont() == ufSuhar and fontName(faceOf(style())) == "Suhar App", "the UI's font: Suhar App, by default"
check fontName(faceOf(style(bold = true))) == "Suhar App" and isBold(faceOf(style(bold = true))),
      "its bold its own"
check fontName(faceOf(style(read = true))) == "Suhar App Read", "a paragraph's text: Suhar App Read"
check ufSuhar in builtinUiFonts and ufSans in builtinUiFonts and ufSerif in builtinUiFonts and
      ufMono in builtinUiFonts, "FreeSans, FreeSerif and FreeMono still to choose"
setUiFont(ufSans)
check fontName(faceOf(style())) == "FreeSans" and fontName(faceOf(style(read = true))) == "FreeSans",
      "FreeSans chosen: its paragraphs FreeSans too"
setUiFont(ufSuhar)
block:
  var s = loadSettings("suhar-test")
  s["look.font"] = "sans"
  s["look.fontv"] = "3"                 # (kept before Suhar: FreeSans was the default)
  restoreAppearance(s)
  check uiFont() == ufSuhar, "a look kept before Suhar, its font the old default: Suhar now"
  s["look.font"] = "serif"
  restoreAppearance(s)
  check uiFont() == ufSerif, "... a font chosen then (FreeSerif): kept"
  setUiFont(ufSuhar)
  storeAppearance(s)
  check s.getOrDefault("look.font", "") == "suhar", "Suhar kept as \"suhar\""
let thai = shape("ภาษา", fSuhar)
check not thai.missing and thai.glyphs.len > 0 and thai.glyphs[0].face != fSuhar,
      "a letter Suhar has not drawn (Thai): drawn, from FreeFont"
let ar = shape("مرحبا بكم", fSuhar)
check not ar.missing and shapesOwnArabic(fSuhar), "Suhar's Arabic: its own, shaped by its tables"
var allSuhar = true
for g in ar.glyphs:
  if g.face != fSuhar: allSuhar = false
check allSuhar, "... every letter from Suhar"
check textWidth("Sohar, صحار", style(read = true)) > 0, "the reading cut measures"

# ---- the symbols drawn into Suhar App (tools/suharsymbols.py) ------------------------------------------------

block symbols:
  const drawn = "∀∂∃∅∆∇∈∉∋∏∗∝⌀▁☎♀♂♭♮♯⟨⟩⁁"
  var fromSuhar = true
  var what = ""
  for id in [fSuhar, styled(fSuhar, true, false), styled(fSuhar, false, true), styled(fSuhar, true, true),
             fSuharRead, styled(fSuharRead, true, false), styled(fSuharRead, false, true),
             styled(fSuharRead, true, true)]:
    for r in drawn.runes:
      let run = shape($r, id)
      if run.missing or run.glyphs.len != 1 or run.glyphs[0].face != id or run.glyphs[0].gid == 0:
        fromSuhar = false
        what = $r & " in " & fontName(id)
  check fromSuhar, "the symbols the kit writes or names drawn in Suhar App's eight faces, none from FreeFont" &
                   (if what.len > 0: " (" & what & ")" else: "")
  for r in drawn.runes:
    let f = face(fSuhar)
    let b = f.bounds(f.glyphOf(int(r)))
    doAssert b.x1 > b.x0 and b.y1 > b.y0, $r & ": an outline"
  check true, "... each with an outline"
  proc inkOf(s: string; st: TextStyle): int =
    view = proc () = styledText(s, st)
    run(2)
    for p in pixels:
      if (p and 0xFF) < 128: inc result
  check inkOf("♀", style(bold = true, size = 4)) > inkOf("♀", style(size = 4)),
        "... drawn in each face's weight: the bold's heavier"

# ---- marks that cross the baseline ------------------------------------------------------------------------

proc markOk(base: FaceId; what: string) =
  ## (the damma and the fathatan wholly above the baseline where they are drawn, the kasra
  ## wholly under it: none left at the baseline, inside its letter)
  let f = face(base)
  let em = float32(f.unitsPerEm)
  for (s, mark, above) in [("صُ", 0x064F, true), ("بً", 0x064B, true), ("بِ", 0x0650, false)]:
    let r = shape(s, base)
    let gid = f.glyphOf(mark)
    var found = false
    for g in r.glyphs:
      if int(g.gid) != gid: continue
      found = true
      let b = f.bounds(int(g.gid))
      let lo = float32(b.y0) + g.y * em
      let hi = float32(b.y1) + g.y * em
      if above: check lo > 0, what & ": U+" & toHex(mark, 4) & " above its letter (its foot was under the baseline)"
      else: check hi < 0, what & ": U+" & toHex(mark, 4) & " under its letter (its top was over the baseline)"
    check found, what & ": U+" & toHex(mark, 4) & " drawn"

proc inkOf(s: string): int =
  ## (the dark pixels of `s` drawn large)
  view = proc () = styledText(s, style(size = 4))
  run(2)
  for p in pixels:
    if (p and 0xFF) < 128: inc result

setUiFontFile(readFile(fonts / "SuharMarks-Test.ttf"))
markOk(fUserBold, "a font with GPOS")
markOk(fUser, "its regular")
check inkOf("بُ") > inkOf("ب") + 20, "the damma's ink there, not hidden in its letter"
setUiFontFile(readFile(fonts / "SuharMarksNoLayout-Test.ttf"))
markOk(fUser, "a font without GSUB and GPOS (placed by the kit)")
check inkOf("بِ") > inkOf("ب") + 20, "... the kasra's ink there"

# ---- Arabic without presentation forms -------------------------------------------------------------------

setUiFontFile(readFile(fonts / "SuharNoForms-Test.ttf"))
check face(fUser).glyphOf(0xFE91) == 0 and shapesOwnArabic(fUser),
      "a font with no presentation forms, GSUB's joining: its own Arabic"
let own = shape("بكم", fUser)
var fromIt = true
for g in own.glyphs:
  if g.face != fUser: fromIt = false
check not own.missing and fromIt, "Arabic drawn in it, not in the built-in font"
let f = face(fUser)
check int(own.glyphs[^1].gid) != f.glyphOf(0x0628), "joined: the ب at its start in its initial form"
let ownW = textWidth("بكم")
setUiFont(ufSans)
check ownW != textWidth("بكم"), "its width, not FreeSerif's"
setUiFont(ufSuhar)

# ---- tall lines --------------------------------------------------------------------------------------------

let plainH = FontH
setTallLines(true)
check FontH >= int(textSize() * 2.0) and FontH > plainH, "tall lines: room for vowelled Arabic (2 em)"
check lineHeight(style(size = 2)) > 2 * plainH, "... at every size"
setTallLines(false)
check FontH == plainH, "off: the font's own line again"

# ---- text taller by its own ink --------------------------------------------------------------------------

block byInk:
  let vowelled = "إِنَّ اَلْعِلْمَ نُورٌ"
  var tr: Rect   # (its place)
  for (txt, st) in [(vowelled, style(size = 4)), (vowelled, style(size = 4, read = true))]:
    view = proc () =
      styledText(txt, st)
      tr = ui.lastRect
    run(2)
    var inkTop = H
    var inkFoot = -1
    for y in 0 ..< H:
      for x in 0 ..< W:
        if (pixels[y * W + x] and 0xFF) < 160:
          inkTop = min(inkTop, y)
          inkFoot = max(inkFoot, y)
    # (a pixel of the letters' soft edge may be past it)
    check tr.h > lineHeight(st) and inkTop >= tr.y - 1 and inkFoot <= tr.y + tr.h,
          "vowelled Arabic, large" & (if st.read: " (Suhar App Read)" else: "") &
          ": its place as tall as its marks reach -- all its ink inside it"
  view = proc () =
    styledText("Sohar", style(size = 4))
    tr = ui.lastRect
  run(2)
  check tr.h == lineHeight(style(size = 4)), "... Latin: the line's own height"
  view = proc () =
    label "صحار مدينة على ساحل الباطنة"
    tr = ui.lastRect
  run(2)
  check tr.h == FontH, "an interface's Arabic at its size: the line's own height, not a pixel more"

# ---- the layout mirrored ------------------------------------------------------------------------------------

var capR, fieldR, okR, cancelR: Rect
var name = ""
view = proc () =
  row:
    label "Name:"
    capR = ui.lastRect
    edit(name, w = 160)
    fieldR = ui.lastRect
  row:
    discard button("OK")
    okR = ui.lastRect
    discard button("Cancel")
    cancelR = ui.lastRect
run(2)
check capR.x < fieldR.x and okR.x < cancelR.x, "left to right: the caption before its field"
setRtlInterface(true)
run(2)
check capR.x < fieldR.x, "setRtlInterface: the lines' direction only, the layout as it was"
proc inkIn(r: Rect): int =
  for y in max(0, r.y) ..< min(H, r.y + r.h):
    for x in max(0, r.x) ..< min(W, r.x + r.w):
      if (pixels[y * W + x] and 0xFF) < 100: inc result
proc mirrored(r: Rect): Rect = rect(W - r.x - r.w, r.y, r.w, r.h)
let capInk = inkIn(capR)
check capInk > 10 and inkIn(mirrored(capR)) < capInk div 4, "the caption's words where it is"
setRightToLeft(true)
run(3)
# (the frame is laid out as before and drawn mirrored: what was at the left is at the right)
check rightToLeft() and inkIn(mirrored(capR)) > capInk div 2 and inkIn(capR) < capInk div 2 and
      mirrored(capR).x > mirrored(fieldR).x and mirrored(okR).x > mirrored(cancelR).x,
      "setRightToLeft: mirrored -- the caption right of its field, the buttons from the right"
setRightToLeft(false)
run(2)
check capR.x < fieldR.x, "and back"

# ---- a right-to-left paragraph set from the right ---------------------------------------------------------

block rtlParagraphs:
  var pr: Rect
  proc inkSpan(r: Rect): tuple[lo, hi: int] =
    ## (the leftmost and rightmost columns with ink in `r`)
    result = (W, -1)
    for y in max(0, r.y) ..< min(H, r.y + r.h):
      for x in max(0, r.x) ..< min(W, r.x + r.w):
        if (pixels[y * W + x] and 0xFF) < 128:
          result.lo = min(result.lo, x)
          result.hi = max(result.hi, x)
  for (txt, rtl) in [("صحار مدينة على ساحل الباطنة في عمان، ومنها أبحر السندباد إلى البحار البعيدة.", true),
                     ("Sohar is a city on the Batinah coast of Oman, the harbour Sindbad sailed from.", false)]:
    view = proc () =
      paragraph(txt, w = 300)
      pr = ui.lastRect
    run(2)
    let lastLine = rect(pr.x, pr.y + pr.h - FontH, pr.w, FontH)
    let (lo, hi) = inkSpan(lastLine)
    doAssert pr.h > FontH, "wrapped: more than one line"
    if rtl:
      check hi >= pr.x + pr.w - 6 and lo > pr.x + 20,
            "an Arabic paragraph in an English interface: its lines from the right"
    else:
      check lo <= pr.x + 3 and hi < pr.x + pr.w - 20, "... an English one from the left"
  setRightToLeft(true)
  view = proc () =
    paragraph("Sohar is a city on the Batinah coast of Oman, the harbour Sindbad sailed from.", w = 300)
    pr = ui.lastRect
  run(3)
  let m = rect(W - pr.x - pr.w, pr.y + pr.h - FontH, pr.w, FontH)
  check inkSpan(m).hi >= m.x + m.w - 6, "a mirrored interface: every line from the right"
  setRightToLeft(false)
  run(2)

# ---- one variable font file -----------------------------------------------------------------------------------

setUiFontVariable(readFile(fonts / "VarTest.ttf"))
check uiFont() == ufFile and "wght" in userFontAxes(), "a variable font as the UI's font"
check face(fUserBold).varCoords.len > 0 and face(fUserBold) != face(fUser) and not fauxStyle(fUserBold).bold,
      "its bold: the font at wght 700, not made bolder"
proc inkStyled(s: string; st: TextStyle): int =
  view = proc () = styledText(s, st)
  run(2)
  for p in pixels:
    if (p and 0xFF) < 128: inc result
check inkStyled("AAAA", style(bold = true, size = 4)) > inkStyled("AAAA", style(size = 4)),
      "... drawn as the font draws it there: heavier"
setTextSize(24)
check face(fUserBold).varCoords.len > 0, "a size changed: its styles made again"
setTextSize(12)

# ---- Suhar's variable font: weights and optical sizes (SuharVar-Test.ttf, cut from Suhar 2.8's
# Suhar[opsz,wght].ttf: wght 400..700, opsz 8..72 points) ------------------------------------------------

setUiFontVariable(readFile(fonts / "SuharVar-Test.ttf"))
let vf = face(fUser)
check "wght" in userFontAxes() and "opsz" in userFontAxes(), "Suhar's variable font: its weights and optical sizes"
proc advOf(id: FaceId; c: char): int = face(id).advance(face(id).glyphOf(ord(c)))
let small = advOf(fUser, 'a')
let smallBold = advOf(fUserBold, 'a')
let smallCoords = face(fUser).varCoords
check smallCoords.len == 2 and smallBold != small, "at 12 pixels: regular and bold at their weights"
setTextSize(64)
let large = advOf(fUser, 'a')
check face(fUser).varCoords != smallCoords and large < small,
      "at 64 pixels: its optical size the text's -- the letters narrower, as drawn for large text"
check advOf(fUserBold, 'a') != large, "... its bold too"
check inkStyled("an", style(size = 1)) > 0, "drawn at the large size"
setTextSize(12)
check advOf(fUser, 'a') == small, "back at 12: the small size's letters again"
setUiFontVariable(readFile(fonts / "SuharVar-Test.ttf"), opticalSize = false)
setTextSize(64)
let fixedLarge = advOf(fUser, 'a')
setTextSize(12)
check advOf(fUser, 'a') == fixedLarge, "opticalSize = false: the font's own optical size at every text size"
discard vf
setUiFont(ufSuhar)

echo "suhar: ", passed, " ok"

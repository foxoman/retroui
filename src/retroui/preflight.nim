## Check Document (preflight): what would go wrong when a document or a
## book is printed or sent on -- text that does not fit its box and goes
## nowhere, pictures too coarse for print, fonts that are not here, frames
## with nothing in them, type too near the edge, hidden or empty layers --
## each with where it is, before the press finds it. And Arabic's own: Arabic
## in a font that has no Arabic letters, set left to right, slanted (Arabic
## has no italic), tracked apart (its joins break), typed in presentation
## forms (copied from a PDF), lengthened by tatweel typed by hand, its digits
## of two kinds.
##
## ```nim
## for p in preflight(d, ppi = 300): echo p.severity, " ", p.layer, ": ", p.message
## for p in b.preflight(): echo "page ", p.page + 1, ": ", p.message
## ```

import std/[strutils, math]
from std/unicode import runeLen, runes
import gfx, photo, photobook, textengine, ttf, typeset

type
  PreflightKind* = enum
    pkError = "Error", pkWarning = "Warning", pkInfo = "Note"
  PreflightItem* = object
    severity*: PreflightKind
    page*: int                ## a book's page (0-based; -1: a single document)
    layer*: string            ## the layer it is about ("" the document)
    uid*: int                 ## ... who it is (`uidOf`), to go to it
    message*: string

proc arabicChecks(t: TextData): seq[(PreflightKind, string)] =
  ## (what will print wrong in a text's Arabic)
  var noArabic: seq[string]
  var slanted, tracked, forms, tatweel, any = false
  var latinDigits, indicDigits = false
  for sp in t.spans:
    var ar = false
    for r in sp.text.runes:
      let c = int(r)
      if c in 0x0600 .. 0x06FF or c in 0x0750 .. 0x077F or c in 0x08A0 .. 0x08FF:
        if c notin 0x0660 .. 0x0669 and c notin 0x06F0 .. 0x06F9 and c != 0x060C and c != 0x061B and
           c != 0x061F: ar = true
      if c in 0xFB50 .. 0xFDFF or c in 0xFE70 .. 0xFEFC: forms = true
      if c == 0x0640: tatweel = true
      if c in 0x30 .. 0x39:
        if sp.style.digits == 0: latinDigits = true else: indicDigits = true
      if c in 0x0660 .. 0x0669 or c in 0x06F0 .. 0x06F9: indicDigits = true
    if not ar: continue
    any = true
    if sp.style.fauxItalic or "italic" in sp.style.style.toLowerAscii or "oblique" in sp.style.style.toLowerAscii:
      slanted = true
    if sp.style.tracking > 0 and sp.style.arabicFont.tracking >= 0: tracked = true
    # (a font picked for it that has no Arabic -- not the kit's own FreeSans, FreeSerif, FreeMono,
    # which hand their Arabic to its Arabic face, as they should)
    let fam = if sp.style.arabicFont.family.len > 0: sp.style.arabicFont.family else: sp.style.family
    if fam.len > 0 and fam notin ["FreeSans", "FreeSerif", "FreeMono"]:
      let f = fontFace(fam, if sp.style.arabicFont.style.len > 0: sp.style.arabicFont.style else: sp.style.style).face
      if f != nil and not f.hasGlyph(0x0628) and fam notin noArabic: noArabic.add fam
  for f in noArabic:
    result.add (pkWarning, "Arabic in a font with no Arabic letters (" & f & "): drawn in another font -- give " &
                           "it an Arabic font (Character: Arabic font)")
  if not any and not forms: return
  if any and t.para.rtl == 1 and strongDir(t.plainText) == 1:
    result.add (pkWarning, "Arabic set left to right: its lines start at the left and its punctuation goes to " &
                           "the wrong end -- Paragraph: Direction Right to left")
  if slanted:
    result.add (pkWarning, "Arabic slanted (italic): Arabic has no italic; the press shows it leaning -- " &
                           "a font of its own style instead")
  if tracked:
    result.add (pkWarning, "Arabic tracked apart: the joins between its letters break -- tracking 0, and " &
                           "Insert Kashida to lengthen a line")
  if forms:
    result.add (pkWarning, "Arabic typed as presentation forms (copied from a PDF?): it is not searched, " &
                           "spell-checked or lengthened with kashidas -- type it again, or paste it as text")
  if tatweel and t.boxW > 0 and t.para.align in {justifyLeft, justifyCenter, justifyRight, justifyAll}:
    result.add (pkInfo, "tatweel (\u0640) typed by hand in justified Arabic: it does not grow with the line -- " &
                        "Insert Kashida lengthens the joins as the line needs")
  if any and latinDigits and indicDigits:
    result.add (pkInfo, "digits of two kinds in the Arabic text (123 and \u0661\u0662\u0663): " &
                        "Character: Digits makes them one")

proc preflight*(d: Doc; ppi = 300; safe = 0; page = -1): seq[PreflightItem] =
  ## The document's problems: text that does not fit (and goes on nowhere),
  ## pictures under `ppi` as placed (Smart Objects: their own pixels over
  ## their size here), fonts not here, empty frames, type nearer than `safe`
  ## pixels to the edge, layers hidden or empty.
  let families = fontFamilies()
  let dpi = if d.dpi > 0: d.dpi else: 72.0
  for L in d.layers:
    if L.fromMaster != 0 or L.fromSpan != 0: continue
    template add(sev: PreflightKind; msg: string) =
      result.add PreflightItem(severity: sev, page: page, layer: L.name, uid: uidOf(L), message: msg)
    if not L.visible and not L.group and not L.background:
      add(pkInfo, "hidden: it will not print")
    if L.isText:
      let t = d.effectiveText(L)
      if t.boxW > 0 and t.boxH > 0 and not d.flowsOn(L):
        var u = t
        u.clipOverflow = true
        let l = layoutText(u)
        if l.overflow >= 0 and l.overflow < t.plainText.runeLen:
          add(pkError, "text does not fit its box (" & $(t.plainText.runeLen - l.overflow) &
                       " characters left over): make the box bigger or flow it on")
      var missing: seq[string]
      for sp in t.spans:
        let f = sp.style.family
        if f.len > 0 and f notin families and f notin missing: missing.add f
      for f in missing: add(pkError, "font not here: " & f & " (drawn in another)")
      for (sev, msg) in arabicChecks(t): add(sev, msg)
      if safe > 0:
        let b = d.layerBox(L)
        if b.w > 0 and (b.x < safe or b.y < safe or b.x + b.w > d.w - safe or b.y + b.h > d.h - safe):
          add(pkWarning, "type nearer than " & $safe & " px to the edge: it may be cut")
    elif L.isSmart and L.smart != nil:
      let s = L.smart
      let wPlaced = hypot(s.quad[1][0] - s.quad[0][0], s.quad[1][1] - s.quad[0][1])
      if wPlaced > 1 and s.w > 0:
        let eff = s.w.float / (wPlaced / dpi)
        if eff < ppi.float * 0.995:
          add((if eff < ppi.float * 0.5: pkError else: pkWarning),
              "picture at " & $int(round(eff)) & " ppi as placed (under " & $ppi & "): it will print soft")
    elif L.isShape:
      if L.name.startsWith("Frame ") or L.name.startsWith("Photo "):
        let i = d.layers.find(L)
        let filled = i + 1 < d.layers.len and d.layers[i + 1].clipped
        if not filled: add(pkWarning, "an empty frame (Layer > Place Into puts a picture in it)")
    elif not L.group and L.adjust.kind.len == 0 and not L.background and L.px.len > 0:
      if d.contentBounds(L).w <= 0: add(pkInfo, "empty: nothing on it")
  if dpi < ppi.float * 0.995 and page < 0:
    result.add PreflightItem(severity: pkWarning, page: page, message: "the document is " & $int(round(dpi)) &
                             " ppi (under " & $ppi & "): its pixels will print soft")

proc preflight*(b: Book; ppi = 300; keep: openArray[int] = []): seq[PreflightItem] =
  ## Every page's problems (as `preflight` of a document), the safe area its
  ## margins; and the book's own -- a resolution under `ppi`.
  if b.setup.dpi < ppi.float * 0.995:
    result.add PreflightItem(severity: pkWarning, page: -1, message: "the book is " & $int(round(b.setup.dpi)) &
                             " ppi (under " & $ppi & "): its pixels will print soft")
  for i in 0 ..< b.pages.len:
    let was = b.isOpen(i)
    let d = b.doc(i)
    let m = b.marginBox(i)
    result.add d.preflight(ppi, safe = max(1, min(m.x, m.y) div 3), page = i)
    if not was and i notin keep: b.park(keep)

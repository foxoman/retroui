## Check Document (preflight): what would go wrong when a document or a
## book is printed or sent on -- text that does not fit its box and goes
## nowhere, pictures too coarse for print, fonts that are not here, frames
## with nothing in them, type too near the edge, hidden or empty layers --
## each with where it is, before the press finds it.
##
## ```nim
## for p in preflight(d, ppi = 300): echo p.severity, " ", p.layer, ": ", p.message
## for p in b.preflight(): echo "page ", p.page + 1, ": ", p.message
## ```

import std/[strutils, math]
from std/unicode import runeLen
import gfx, photo, photobook, textengine

type
  PreflightKind* = enum
    pkError = "Error", pkWarning = "Warning", pkInfo = "Note"
  PreflightItem* = object
    severity*: PreflightKind
    page*: int                ## a book's page (0-based; -1: a single document)
    layer*: string            ## the layer it is about ("" the document)
    uid*: int                 ## ... who it is (`uidOf`), to go to it
    message*: string

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

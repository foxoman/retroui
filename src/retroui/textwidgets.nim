## Widgets for styled text (`retroui/textengine`): a font list that shows
## each family in its own letters, its styles, a sample of a style.
##
## ```nim
## var family = "FreeSans"
## var style = "Regular"
## if fontCombo(family, w = dp(160)): style = fontStyles(family)[0]
## fontStyleCombo(family, style, w = dp(100))
## ```

import std/[tables, math, os, strutils, unicode, algorithm]
import core, gfx, widgets, textengine, memwatch
from ttf import Face, bounds, render
from otshape import featureName

var samples: Table[string, Bitmap]

const SampleMaxFile = 8 * 1024 * 1024
  ## (a font file bigger than this -- a CJK collection -- is not read only to show a list's sample:
  ## its name is shown in the kit's letters; the family is read when the text uses it)

proc tooBigToSample(family, style: string): bool =
  let f = fontFileOf(family, style)
  if f.len == 0: return false
  try: getFileSize(f) > SampleMaxFile
  except OSError: false

proc fontSample*(family, style, text: string; h: int; color = 0xFF000000'u32): Bitmap =
  ## `text` in a font, `h` screen pixels tall (kept: drawn once). A font whose file is very big
  ## (a CJK collection: tens of megabytes to read and make ready) is not read for it: the text is
  ## in the kit's letters.
  let key = family & "/" & style & "/" & text & "/" & $h & "/" & $color
  if samples.hasKey(key): return samples[key]
  if samples.len > 600: samples.clear()
  var st = defaultStyle()
  if not tooBigToSample(family, style):
    st.family = family
    st.style = style
  st.size = float32(h) * 0.74
  st.color = color
  var t = newText(text, st)
  let l0 = layoutText(t)
  let asc = if l0.lines.len > 0: l0.lines[0].ascent else: st.size
  let desc = if l0.lines.len > 0: l0.lines[0].descent else: 0'f32
  # (the line's middle in the picture's middle)
  t.y = float32(h) / 2 + (asc - desc) / 2
  t.x = 1
  let l = layoutText(t)
  let w = clamp(int(ceil(l.x1 - l.x0)) + 3, 1, 2000)
  result = newBitmap(w, h)
  result.px = t.renderText(w, h, l)
  result.changed()
  samples[key] = result

proc drawSample(r: Rect; family, style, text: string; color: uint32) =
  ## A sample drawn at the left of `r`, its middle on `r`'s.
  let hp = max(4, r.h * pxScale)
  let b = fontSample(family, style, text, hp, color)
  let bw = (b.w + pxScale - 1) div pxScale
  drawBitmap(rect(r.x, r.y, bw, r.h), b)

var recentFonts*: seq[string]
  ## The families picked last in a font list (`fontCombo`), the latest first (up to 8): shown at
  ## the top of every list, before all of them from A to Z. An app keeps it between runs (Retro
  ## Atelier: in its preferences); `noteFontUsed` adds one.

proc noteFontUsed*(family: string) =
  ## `family` used now: the first of `recentFonts`.
  if family.len == 0: return
  let k = recentFonts.find(family)
  if k >= 0: recentFonts.delete(k)
  recentFonts.insert(family, 0)
  if recentFonts.len > 8: recentFonts.setLen(8)

proc fontListOrder*(): seq[string] =
  ## The font families as a font list shows them: those used last (`recentFonts`, the ones
  ## there are), then every family from A to Z.
  let all = fontFamilies()
  for f in recentFonts:
    if f in all: result.add f
  var az = all
  az.sort(proc (a, b: string): int = cmpIgnoreCase(a, b))
  result.add az

proc fontCombo*(family: var string; w = 0; enabled = true): bool {.discardable.} =
  ## A drop-down list of the font families (the system's and the built-in
  ## ones), each shown in its own letters: the ones used last first (`recentFonts`), then all
  ## of them from A to Z. A family picked becomes the first of the used ones.
  let fams = fontListOrder()
  var sel = max(0, fams.find(family))
  let preview: ItemPreview = proc (i: int; r: Rect; selected: bool) =
    let c = if selected: 0xFFFFFFFF'u32 else: 0xFF000000'u32
    drawSample(rect(r.x + 3, r.y, r.w - 3, r.h), fams[i], "Regular", fams[i], c)
  pushId("fontcombo" & $cast[uint](addr family))     # (one of its own for each variable)
  if combo(fams, sel, w = w, enabled = enabled, preview = preview) and sel in 0 .. fams.high:
    family = fams[sel]
    noteFontUsed(family)
    result = true
  popId()

proc fontStyleCombo*(family: string; style: var string; w = 0; enabled = true): bool {.discardable.} =
  ## The styles of `family` ("Regular", "Bold"...), each in its letters.
  let sts = fontStyles(family)
  var sel = max(0, sts.find(style))
  let preview: ItemPreview = proc (i: int; r: Rect; selected: bool) =
    let c = if selected: 0xFFFFFFFF'u32 else: 0xFF000000'u32
    drawSample(rect(r.x + 3, r.y, r.w - 3, r.h), family, sts[i], sts[i], c)
  if sts.find(style) < 0 and sts.len > 0 and style.len == 0: style = sts[0]
  pushId("stylecombo" & $cast[uint](addr style))
  if combo(sts, sel, w = w, enabled = enabled, preview = preview) and sel in 0 .. sts.high:
    style = sts[sel]
    result = true
  popId()

# ---- a font's glyphs ---------------------------------------------------------------------------

var glyphPics: Table[string, Bitmap]     ## (each glyph's picture, drawn once)

proc glyphPicture(face: Face; key: string; gid, cellDev: int; color: uint32): Bitmap =
  ## (glyph `gid` as big as fits a cell `cellDev` device pixels wide: a wide ligature smaller)
  let k = key & "\t" & $gid & "\t" & $cellDev & "\t" & $color
  if glyphPics.hasKey(k): return glyphPics[k]
  if glyphPics.len > 3000: glyphPics.clear()
  result = newBitmap(1, 1)
  if face != nil:
    let (x0, y0, x1, y1) = face.bounds(gid)
    let big = max(1, max(x1 - x0, y1 - y0))
    let ppem = min(float32(cellDev) * 0.62, float32(cellDev) * 0.78 * float32(face.unitsPerEm) / float32(big))
    let m = face.render(gid, ppem)
    if m.w > 0 and m.h > 0 and not m.lcd and m.a.len >= m.w * m.h:
      result = newBitmap(m.w, m.h)
      for i in 0 ..< m.w * m.h:
        let a = uint32(m.a[i])
        if a > 0: result.px[i] = (a shl 24) or (color and 0xFFFFFF'u32)
      result.changed()
  glyphPics[k] = result

proc glyphPicker*(family, style: string; picked: var FontGlyph; h = 0; cell = 0): bool {.discardable.} =
  ## Every glyph of a font's style (`fontGlyphs`), each drawn in it, in a grid that scrolls
  ## (`h` high; 0: down to the bottom; `cell`: each cell's side, 0 for 32): a click on one picks
  ## it (`picked`, true) -- type `picked.text` with `picked.feature` on (`withFeature`) and the
  ## text has it, whether a character has it (U+FDF2, a logo in the private area) or the font
  ## makes it (the Allah ligature from الله, "ffi", a stylistic set's form). One nothing types
  ## is gray and cannot be picked. The pointer on one tells its character or what makes it.
  let gl = fontGlyphs(family, style)
  let face = fontFace(family, style).face
  let key = family & "\t" & style
  let cs = if cell > 0: cell else: dp(32)
  beginScroll(h, key = "glyphpicker", framed = true)
  let cols = max(1, available() div cs)
  let rows = (gl.len + cols - 1) div cols
  let area = place(cols * cs, max(cs, rows * cs))
  let clip = clipRect()
  # (only the rows in view: a font may have tens of thousands of glyphs)
  let r0 = clamp((clip.y - area.y) div cs, 0, max(0, rows - 1))
  let r1 = clamp((clip.y + clip.h - area.y) div cs, 0, max(0, rows - 1))
  let dev = max(1, cs * max(1, pxScale))
  for row in r0 .. r1:
    for c in 0 ..< cols:
      let i = row * cols + c
      if i >= gl.len: break
      let g = gl[i]
      let cr = rect(area.x + c * cs, area.y + row * cs, cs, cs)
      let can = g.text.len > 0
      let hit = interact(idOf("glyph\t" & key & "\t" & $g.gid), cr, focusable = false)
      let sel = picked.gid == g.gid and picked.text == g.text
      let back = if sel or (hit.down and can): ui.theme.select elif hit.hover and can: hoverColor() else: ui.theme.field
      fill(cr, back)
      box(rect(cr.x + cr.w - 1, cr.y, 1, cr.h), mixColor(ui.theme.field, ui.theme.gray, 0.35))
      box(rect(cr.x, cr.y + cr.h - 1, cr.w, 1), mixColor(ui.theme.field, ui.theme.gray, 0.35))
      let ink = if sel or (hit.down and can): ui.theme.selectText elif can: ui.theme.fieldText else: ui.theme.gray
      let b = glyphPicture(face, key, g.gid, dev, (uint32(ink.r) shl 16) or (uint32(ink.g) shl 8) or uint32(ink.b))
      let s = max(1, pxScale)
      let (bw, bh) = ((b.w + s - 1) div s, (b.h + s - 1) div s)
      if b.w > 1: drawBitmap(rect(cr.x + (cr.w - bw) div 2, cr.y + (cr.h - bh) div 2, bw, bh), b)
      if hit.hover:
        var tip = ""
        if not can: tip = tr("Glyph") & " " & $g.gid & ": " & tr("no character or feature of the font makes it")
        elif g.text.runeLen == 1 and g.feature.len == 0:
          tip = "U+" & toHex(int(g.text.runeAt(0)), 4) & "  (" & tr("glyph") & " " & $g.gid & ")"
        else:
          tip = g.text & (if g.feature.len > 0: "  + " & face.featureName(g.feature) else: "") &
                "  (" & tr("glyph") & " " & $g.gid & ")"
        ui.tip = tip
      if hit.clicked and can:
        picked = g
        result = true
  endScroll()

# (the device short of memory -- or a soak's count: the fonts read for the lists' samples and for
# texts, the samples and the glyphs' pictures let go of, made again when they are shown)
onMemoryPressure(proc (level: MemoryPressure) =
  if level == mpCritical:
    letGoOfFonts()
    samples.clear()
    glyphPics.clear())

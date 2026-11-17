## Styles for a design in one click, as the quick-design programs have them: a palette and a
## pair of fonts -- one for headings, one for the words -- put on all of it at once (each
## color to the palette's of its lightness, big type in the heading font, the rest in the body
## font), and font pairs that go well together, of the fonts there are.
##
## .. code-block:: nim
##   let s = builtInStyles()[0]
##   discard doc.applyStyle(s)
##   for (heading, body) in fontPairs(fontFamilies()): echo heading, " + ", body
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[algorithm, math, strutils]
import photo, textengine

type
  DesignStyle* = object
    ## A palette and a font pair.
    name*: string
    colors*: seq[uint32]       ## its palette, any order (put on by lightness)
    heading*, body*: string    ## its fonts ("" the type keeps its own)

proc lum(c: uint32): int = int((c shr 16) and 255) * 3 + int((c shr 8) and 255) * 6 + int(c and 255)

proc builtInStyles*(): seq[DesignStyle] =
  ## The styles Retro Atelier comes with.
  template st(n: string; cs: openArray[uint32]; h, b: string) =
    result.add DesignStyle(name: n, colors: @cs, heading: h, body: b)
  st("Harbour", [0xFF0B2545'u32, 0xFF13315C'u32, 0xFF8DA9C4'u32, 0xFFEEF4ED'u32], "FreeSerif", "FreeSans")
  st("Desert Rose", [0xFF4A2C2A'u32, 0xFFB5651D'u32, 0xFFE8B4A0'u32, 0xFFFBF3EE'u32], "FreeSerif", "FreeSans")
  st("Frankincense", [0xFF2E2A24'u32, 0xFF7A6A53'u32, 0xFFD9C5A0'u32, 0xFFF7F1E5'u32], "FreeSerif", "FreeSerif")
  st("Muscat Night", [0xFF0D0D1A'u32, 0xFF2C2C54'u32, 0xFFE9B44C'u32, 0xFFF5F5F0'u32], "FreeSans", "FreeSans")
  st("Date Palm", [0xFF1B3A2F'u32, 0xFF3E6B48'u32, 0xFFC9A227'u32, 0xFFF4EFE1'u32], "FreeSerif", "FreeSans")
  st("Coral Reef", [0xFF073B4C'u32, 0xFF118AB2'u32, 0xFFEF476F'u32, 0xFFFFF6EC'u32], "FreeSans", "FreeSerif")
  st("Sunrise", [0xFF3D1E3E'u32, 0xFFD1495B'u32, 0xFFEDAE49'u32, 0xFFFFF8E8'u32], "FreeSans", "FreeSans")
  st("Mint Paper", [0xFF1F2933'u32, 0xFF3D9970'u32, 0xFFB8E0D2'u32, 0xFFFAFFFC'u32], "FreeSans", "FreeSerif")
  st("Ink and Paper", [0xFF111111'u32, 0xFF444444'u32, 0xFFBBBBBB'u32, 0xFFFAFAF7'u32], "FreeSerif", "FreeSerif")
  st("Pomegranate", [0xFF2B0A0F'u32, 0xFF8E1B2E'u32, 0xFFE57F84'u32, 0xFFFDF0EF'u32], "FreeSerif", "FreeSans")
  st("Sea Glass", [0xFF22333B'u32, 0xFF5E8C8A'u32, 0xFFA9D6CF'u32, 0xFFF2F7F5'u32], "FreeSans", "FreeSans")
  st("Saffron", [0xFF3A2E1F'u32, 0xFFC1440E'u32, 0xFFF3A712'u32, 0xFFFFF9EB'u32], "FreeSerif", "FreeSans")
  st("Lavender Field", [0xFF2D2342'u32, 0xFF6C5B9E'u32, 0xFFC7B8EA'u32, 0xFFF8F5FF'u32], "FreeSerif", "FreeSans")
  st("Slate and Lime", [0xFF1E252B'u32, 0xFF3A4750'u32, 0xFFB5E61D'u32, 0xFFF4F6F7'u32], "FreeSans", "FreeMono")
  st("Retro 1994", [0xFF000080'u32, 0xFF008080'u32, 0xFFC0C0C0'u32, 0xFFFFFFFF'u32], "FreeSans", "FreeSans")
  st("Wadi", [0xFF2F2A26'u32, 0xFF8C5B3F'u32, 0xFF7FA6A8'u32, 0xFFF3EDE4'u32], "FreeSerif", "FreeSans")

const Pairs = [
  # (heading, body): pairs that go well, the first of them that are there offered
  ("Playfair Display", "Source Sans Pro"), ("Playfair Display", "Lato"), ("Montserrat", "Merriweather"),
  ("Merriweather", "Open Sans"), ("Oswald", "Roboto"), ("Roboto Slab", "Roboto"), ("Lora", "Open Sans"),
  ("Raleway", "Libre Baskerville"), ("Poppins", "Noto Serif"), ("Bebas Neue", "Montserrat"),
  ("Abril Fatface", "Poppins"), ("Cormorant Garamond", "Proza Libre"), ("Libre Baskerville", "Source Sans Pro"),
  ("DejaVu Serif", "DejaVu Sans"), ("Liberation Serif", "Liberation Sans"), ("Noto Serif", "Noto Sans"),
  ("Georgia", "Verdana"), ("Times New Roman", "Arial"), ("Palatino Linotype", "Segoe UI"),
  ("Amiri", "Noto Naskh Arabic"), ("Cairo", "Tajawal"), ("Noto Kufi Arabic", "Noto Naskh Arabic"),
  ("FreeSerif", "FreeSans"), ("FreeSans", "FreeSerif"), ("FreeSans", "FreeSans"), ("FreeMono", "FreeSans")]

proc fontPairs*(available: openArray[string]): seq[tuple[heading, body: string]] =
  ## Font pairs that go well together -- a heading font and a body font -- of the families
  ## `available` (case aside), the good known pairs first.
  var low: seq[string]
  for a in available: low.add a.toLowerAscii
  for (h, b) in Pairs:
    let hi = low.find(h.toLowerAscii)
    let bi = low.find(b.toLowerAscii)
    if hi >= 0 and bi >= 0: result.add (available[hi], available[bi])
  if result.len == 0: result.add ("FreeSerif", "FreeSans")

proc typeSizes(d: Doc): seq[float32] =
  for L in d.layers:
    if not L.isText: continue
    for sp in L.text.spans:
      if sp.text.strip.len > 0: result.add sp.style.size

proc headingSize*(d: Doc): float32 =
  ## The size from which type is a heading: half again the size most of it is (24 at least
  ## below that).
  var s = d.typeSizes
  if s.len == 0: return 24
  s.sort()
  let median = s[s.len div 2]
  max(min(median * 1.5, 24), median * 1.3)

proc styleColors*(d: Doc): seq[uint32] =
  ## The colors of a design that a style changes: its shapes' fills and strokes, its type's (not
  ## a photo placeholder's: a photo goes there).
  for L in d.layers:
    if L.locked or L.attrs.placeholder != 0: continue
    if L.isShape:
      if L.shape.fill.kind == spColor:
        let c = L.shape.fill.color or 0xFF000000'u32
        if c notin result: result.add c
      if L.shape.stroke.kind == spColor:
        let c = L.shape.stroke.color or 0xFF000000'u32
        if c notin result: result.add c
    elif L.isText:
      for sp in L.text.spans:
        let c = sp.style.color or 0xFF000000'u32
        if c notin result: result.add c

proc paletteMap*(used, palette: openArray[uint32]): seq[uint32] =
  ## Each of `used` given the palette's color of its place in lightness (the darkest the
  ## darkest...): the colors to put in their places.
  if palette.len == 0: return @used
  var byLum = @used
  byLum.sort(proc (a, b: uint32): int = cmp(lum(a), lum(b)))
  var pl = @palette
  pl.sort(proc (a, b: uint32): int = cmp(lum(a), lum(b)))
  for c in used:
    let i = byLum.find(c)
    let j = if byLum.len == 1: pl.high div 2 else: int(round(i / byLum.high * pl.high.float))
    result.add (pl[clamp(j, 0, pl.high)] and 0x00FFFFFF'u32) or (c and 0xFF000000'u32)

proc applyStyle*(d: Doc; s: DesignStyle; colors = true; fonts = true): int =
  ## The style on the whole design (not its locked layers, nor its photo placeholders): its
  ## palette on the colors (by lightness), its heading font on big type, its body font on the
  ## rest; the background, a
  ## plain fill, the palette's lightest. How many layers changed. (In a step: the caller's.)
  let used = d.styleColors
  let mapped = if colors: paletteMap(used, s.colors) else: @used
  proc to(c: uint32): uint32 =
    let k = used.find(c or 0xFF000000'u32)
    if k < 0: c else: (mapped[k] and 0x00FFFFFF'u32) or (c and 0xFF000000'u32)
  let big = d.headingSize
  for L in d.layers:
    if L.locked or L.fromMaster != 0 or L.fromSpan != 0 or L.attrs.placeholder != 0: continue
    if L.isShape and colors:
      var sh = L.shape
      if sh.fill.kind == spColor: sh.fill.color = to(sh.fill.color)
      if sh.stroke.kind == spColor: sh.stroke.color = to(sh.stroke.color)
      if sh != L.shape:
        d.setShape(L, sh)
        inc result
    elif L.isText:
      var t = L.text
      for sp in t.spans.mitems:
        if colors: sp.style.color = to(sp.style.color)
        if fonts:
          let f = if sp.style.size >= big: s.heading else: s.body
          if f.len > 0:
            sp.style.family = f
            if fontStyles(f).find(sp.style.style) < 0: sp.style.style = "Regular"
      if t != L.text:
        d.setText(L, t)
        inc result
  # (a background of one color: the palette's lightest)
  if colors and s.colors.len > 0 and d.layers.len > 0 and d.layers[0].background and not d.layers[0].locked:
    let B = d.layers[0]
    if B.px.len > 0:
      let first = B.px[0]
      var one = true
      for p in B.px:
        if p != first:
          one = false
          break
      if one:
        var lightest = s.colors[0]
        for c in s.colors:
          if lum(c) > lum(lightest): lightest = c
        for p in B.px.mitems: p = lightest or 0xFF000000'u32
        inc B.ver
        inc result
  d.markAll()

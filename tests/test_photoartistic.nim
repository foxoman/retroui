## Tests of `retroui/photoartistic`: the Filter Gallery and the other new
## filters -- each gives a picture as big, keeps transparency where it
## should, changes the picture, stays the same run after run; the Sketch
## ones draw in the two colors given; the custom shapes' sets; HSB/HSL
## there and back.

import retroui/[gfx, photo, photofx, photoartistic, photoshapes]

proc picture(w, h: int): Img =
  result = newImg(w, h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let v = if (x div 8 + y div 8) mod 2 == 0: 40 else: 210
      result.px[y * w + x] = argb(255, (v + x) mod 256, (v + y * 2) mod 256, (x * 3 + y) mod 256)

let im = picture(96, 72)
let whole = rect(0, 0, im.w, im.h)
let all = [("Cutout", cutout()), ("Dry Brush", dryBrush()), ("Film Grain", filmGrain(8, 10)),
           ("Paint Daubs", paintDaubs()), ("Poster Edges", posterEdges()), ("Watercolor", watercolor()),
           ("Sponge", sponge()), ("Colored Pencil", coloredPencil()), ("Plastic Wrap", plasticWrap()),
           ("Accented Edges", accentedEdges()), ("Angled Strokes", angledStrokes()), ("Crosshatch", crosshatch()),
           ("Ink Outlines", inkOutlines()), ("Spatter", spatter()), ("Sumi-e", sumiE()), ("Charcoal", charcoal()),
           ("Graphic Pen", graphicPen()), ("Halftone Pattern", halftonePattern()), ("Photocopy", photocopy()),
           ("Stamp", stamp()), ("Bas Relief", basRelief()), ("Chrome", chrome()), ("Torn Edges", tornEdges()),
           ("Reticulation", reticulation()), ("Craquelure", craquelure()), ("Grain", grainTexture()),
           ("Mosaic Tiles", mosaicTiles()), ("Patchwork", patchwork()), ("Stained Glass", stainedGlass()),
           ("Texturizer", texturizer()), ("Oil Paint", oilPaint()), ("Fibers", fibers()),
           ("Lighting Effects", lightingEffects(height = 30)), ("Displace", displace()),
           ("Smart Sharpen", smartSharpen()), ("Fresco", fresco()), ("Neon Glow", neonGlow()),
           ("Palette Knife", paletteKnife()), ("Rough Pastels", roughPastels()), ("Smudge Stick", smudgeStick()),
           ("Underpainting", underpainting()), ("Dark Strokes", darkStrokes()), ("Sprayed Strokes", sprayedStrokes()),
           ("Glass", glass()), ("Ocean Ripple", oceanRipple()), ("Diffuse Glow", diffuseGlow()),
           ("Chalk & Charcoal", chalkCharcoal()), ("Conté Crayon", conteCrayon()), ("Note Paper", notePaper()),
           ("Plaster", plaster()), ("Water Paper", waterPaper()), ("Glowing Edges", glowingEdges()),
           ("HSB/HSL", hsbHsl())]

block everyFilter:
  for (name, f) in all:
    let o = f(im, whole)
    doAssert o.w == im.w and o.h == im.h and o.px.len == im.px.len, name
    doAssert o.px != im.px, name & " changed nothing"
    for p in o.px: doAssert aOf(p) == 255, name & ": the picture stays opaque"
    let again = f(im, whole)
    doAssert again.px == o.px, name & ": the same each time"

block sketchColors:
  # the Sketch filters: only the colors between the foreground and the background
  let fg = 0xFF800000'u32
  let bg = 0xFFFFFF00'u32
  for f in [stamp(25, 5, fg, bg), photocopy(7, 8, fg, bg), graphicPen(15, 50, 0, fg, bg),
            chalkCharcoal(6, 6, 1, fg, bg), conteCrayon(fg = fg, bg = bg), notePaper(fg = fg, bg = bg),
            plaster(fg = fg, bg = bg)]:
    let o = f(im, whole)
    for p in o.px:
      doAssert rOf(p) >= 128 and bOf(p) == 0, "between dark red and yellow"

block transparencyKept:
  var t = im
  for i in 0 ..< t.px.len:
    if i mod 3 == 0: t.px[i] = t.px[i] and 0x00FFFFFF'u32
  for f in [dryBrush(), chrome(), stainedGlass()]:
    let o = f(t, whole)
    var clear = 0
    for p in o.px:
      if aOf(p) == 0: inc clear
    doAssert clear > 0, "the transparent pixels stay transparent"

block kuwaharaFlattens:
  # a painterly filter makes noisy flat parts flat
  var noisy = newImg(64, 64)
  for i in 0 ..< noisy.px.len:
    let v = 120 + (i * 7919 mod 17) - 8
    noisy.px[i] = argb(255, v, v, v)
  proc spread(im: Img): int =
    var lo = 255
    var hi = 0
    for p in im.px:
      lo = min(lo, int(rOf(p)))
      hi = max(hi, int(rOf(p)))
    hi - lo
  let o = paintDaubs(8, 0)(noisy, rect(0, 0, 64, 64))
  doAssert spread(o) < spread(noisy) div 2, $spread(o) & " vs " & $spread(noisy)

block shapes:
  doAssert CustomShapes.len >= 100, $CustomShapes.len
  for c in ShapeCategories:
    var n = 0
    for s in CustomShapes:
      if s.category == c: inc n
    doAssert n >= 2, c
  for s in CustomShapes: doAssert s.category in ShapeCategories, s.name

block hsbThereAndBack:
  # RGB to HSB puts hue, saturation and brightness in the channels; HSB to RGB takes them back
  var px = newImg(4, 1)
  px.px = @[argb(255, 255, 0, 0), argb(255, 0, 255, 0), argb(255, 40, 80, 200), argb(255, 128, 128, 128)]
  let h = hsbHsl(0, 1)(px, rect(0, 0, 4, 1))
  doAssert rOf(h.px[0]) == 0 and gOf(h.px[0]) == 255 and bOf(h.px[0]) == 255, "red: hue 0, full"
  doAssert abs(int(rOf(h.px[1])) - 85) <= 1, "green: a third of the way round"
  doAssert gOf(h.px[3]) == 0 and bOf(h.px[3]) == 128, "gray: no saturation"
  for model in [1, 2]:
    let there = hsbHsl(0, model)(px, rect(0, 0, 4, 1))
    let back = hsbHsl(model, 0)(there, rect(0, 0, 4, 1))
    for k in 0 ..< 4:
      for sh in [16, 8, 0]:
        doAssert abs(int((back.px[k] shr sh) and 255) - int((px.px[k] shr sh) and 255)) <= 3, $model & " " & $k

block glowingEdgesOnBlack:
  # flat color has no edges: black; an edge glows
  var flat = newImg(32, 32)
  for i in 0 ..< flat.px.len: flat.px[i] = if i mod 32 < 16: 0xFF2040C0'u32 else: 0xFFE0E040'u32
  let o = glowingEdges()(flat, rect(0, 0, 32, 32))
  doAssert (o.px[16 * 32 + 2] and 0xFFFFFF'u32) == 0, "far from the edge: black"
  doAssert lumaOf(o.px[16 * 32 + 16]) > 60, "at the edge: it glows"

echo "test_photoartistic: ok"

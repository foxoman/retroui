## Image documents for a paint program: layers with blend modes, opacity
## and preserved transparency, a selection (a soft mask), alpha channels,
## paths, the composite kept up to date by region, and many undo steps
## that keep only the tiles a change touched. The painting tools are in
## `photopaint`, the filters and adjustments in `photofx`, the widgets
## (the canvas with its marching ants, the color picker, curves...) in
## `photowidgets`. Nothing here draws on the screen: it all runs headless.
##
## .. code-block:: nim
##   let d = newDoc(640, 480, contents = 0xFFFFFFFF'u32)
##   d.beginStep("Fill")
##   d.fillSelection(0xFF336699'u32)
##   d.endStep()
##   d.updateComposite()          # d.comp: what the document looks like
##   d.undo()

import std/[math, tables, strutils, json, os, base64, algorithm, locks, atomics, hashes]
when compileOption("threads"):
  import std/typedthreads
import gfx, imaging, zip, jpeg, parallel, textengine, busy, photoinks
from codec import unbase64
export photoinks

template pixPtr(s: seq[uint32]): ptr UncheckedArray[uint32] =
  ## The pixels, for the cores to share (each writes its own rows).
  cast[ptr UncheckedArray[uint32]](if s.len > 0: unsafeAddr s[0] else: nil)

export gfx.Rect, gfx.rect, gfx.Bitmap

# ---- pixels ---------------------------------------------------------------------------------------
#
# A pixel is 0xAARRGGBB with straight (not premultiplied) alpha, as in
# `Bitmap`.

template aOf*(p: uint32): int = int(p shr 24)
  ## The alpha of a pixel (0..255).
template rOf*(p: uint32): int = int((p shr 16) and 255)
  ## The red of a pixel (0..255).
template gOf*(p: uint32): int = int((p shr 8) and 255)
  ## The green of a pixel (0..255).
template bOf*(p: uint32): int = int(p and 255)
  ## The blue of a pixel (0..255).

proc argb*(a, r, g, b: int): uint32 {.inline.} =
  ## A pixel of alpha, red, green and blue (each clamped to 0..255).
  (uint32(clamp(a, 0, 255)) shl 24) or (uint32(clamp(r, 0, 255)) shl 16) or
    (uint32(clamp(g, 0, 255)) shl 8) or uint32(clamp(b, 0, 255))

proc rgbOf*(c: Color): uint32 =
  ## A screen `Color` as an opaque pixel.
  argb(255, int(c.r), int(c.g), int(c.b))

proc colorOf*(p: uint32): Color =
  ## A pixel as a screen `Color` (its alpha dropped).
  color(uint8(rOf(p)), uint8(gOf(p)), uint8(bOf(p)))

proc withAlpha*(p: uint32; a: int): uint32 {.inline.} =
  ## `p` with its alpha set to `a` (0..255).
  (p and 0xFFFFFF'u32) or (uint32(clamp(a, 0, 255)) shl 24)

proc luma*(r, g, b: int): int {.inline.} = (r * 77 + g * 151 + b * 28) shr 8
  ## Lightness as gray (0.30 R, 0.59 G, 0.11 B).

proc lumaOf*(p: uint32): int {.inline.} = luma(rOf(p), gOf(p), bOf(p))
  ## The lightness of a pixel as gray (see `luma`).

proc grayPx*(v: int; a = 255): uint32 {.inline.} = argb(a, v, v, v)
  ## A gray pixel of level `v` (0..255), alpha `a`.

proc mix*(a, b: uint32; t: float): uint32 =
  ## `a` to `b` by `t` (0..1), alpha too.
  let u = clamp(t, 0.0, 1.0)
  template m(x, y: int): int = int(round(float(x) + (float(y) - float(x)) * u))
  argb(m(aOf(a), aOf(b)), m(rOf(a), rOf(b)), m(gOf(a), gOf(b)), m(bOf(a), bOf(b)))

proc mixAlpha*(a, b: uint32; t: float): uint32 =
  ## Between two colors with their alpha (the colors weighed by it).
  let aa = aOf(a).float * (1 - t)
  let ba = aOf(b).float * t
  let al = aa + ba
  if al <= 0: return 0
  argb(int(round(al)), int(round((rOf(a).float * aa + rOf(b).float * ba) / al)),
       int(round((gOf(a).float * aa + gOf(b).float * ba) / al)),
       int(round((bOf(a).float * aa + bOf(b).float * ba) / al)))

proc toHsb*(p: uint32): tuple[h, s, b: float] =
  ## Hue (0..360), saturation and brightness (0..1).
  let r = rOf(p) / 255
  let g = gOf(p) / 255
  let b = bOf(p) / 255
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  let d = mx - mn
  result.b = mx
  result.s = if mx <= 0: 0.0 else: d / mx
  if d <= 0: result.h = 0
  elif mx == r: result.h = 60 * (((g - b) / d) mod 6)
  elif mx == g: result.h = 60 * ((b - r) / d + 2)
  else: result.h = 60 * ((r - g) / d + 4)
  if result.h < 0: result.h += 360

proc fromHsb*(h, s, v: float; a = 255): uint32 =
  ## A pixel of hue (0..360), saturation and brightness (0..1); see `toHsb`.
  let hh = ((h mod 360) + 360) mod 360 / 60
  let c = v * s
  let x = c * (1 - abs((hh mod 2) - 1))
  var (r, g, b) = (0.0, 0.0, 0.0)
  case int(hh)
  of 0: (r, g, b) = (c, x, 0.0)
  of 1: (r, g, b) = (x, c, 0.0)
  of 2: (r, g, b) = (0.0, c, x)
  of 3: (r, g, b) = (0.0, x, c)
  of 4: (r, g, b) = (x, 0.0, c)
  else: (r, g, b) = (c, 0.0, x)
  let m = v - c
  argb(a, int(round((r + m) * 255)), int(round((g + m) * 255)), int(round((b + m) * 255)))

proc toHsl*(p: uint32): tuple[h, s, l: float] =
  ## Hue (0..360), saturation and lightness (0..1).
  let r = rOf(p) / 255
  let g = gOf(p) / 255
  let b = bOf(p) / 255
  let mx = max(r, max(g, b))
  let mn = min(r, min(g, b))
  result.l = (mx + mn) / 2
  let d = mx - mn
  if d <= 0: return (0.0, 0.0, result.l)
  result.s = if result.l > 0.5: d / (2 - mx - mn) else: d / (mx + mn)
  if mx == r: result.h = 60 * (((g - b) / d) mod 6)
  elif mx == g: result.h = 60 * ((b - r) / d + 2)
  else: result.h = 60 * ((r - g) / d + 4)
  if result.h < 0: result.h += 360

proc fromHsl*(h, s, l: float; a = 255): uint32 =
  ## A pixel of hue (0..360), saturation and lightness (0..1); see `toHsl`.
  if s <= 0:
    let v = int(round(l * 255))
    return argb(a, v, v, v)
  proc hue2(p, q, t0: float): float =
    var t = t0
    if t < 0: t += 1
    if t > 1: t -= 1
    if t < 1/6: p + (q - p) * 6 * t
    elif t < 1/2: q
    elif t < 2/3: p + (q - p) * (2/3 - t) * 6
    else: p
  let q = if l < 0.5: l * (1 + s) else: l + s - l * s
  let p = 2 * l - q
  let hh = (((h mod 360) + 360) mod 360) / 360
  argb(a, int(round(hue2(p, q, hh + 1/3) * 255)), int(round(hue2(p, q, hh) * 255)),
       int(round(hue2(p, q, hh - 1/3) * 255)))

proc toCmyk*(p: uint32): tuple[c, m, y, k: int] =
  ## The printing inks of a color, in % (as the printing setup separates
  ## it: what the Info palette and the color picker show).
  let i = inkOf(p)
  (int(i[0]) * 100 div 255, int(i[1]) * 100 div 255, int(i[2]) * 100 div 255, int(i[3]) * 100 div 255)

proc toLab*(p: uint32): tuple[l, a, b: int] =
  ## CIE L*a*b* (D65) of an sRGB pixel.
  proc lin(c: int): float =
    let v = c / 255
    if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4)
  let r = lin(rOf(p))
  let g = lin(gOf(p))
  let b = lin(bOf(p))
  let x = (r * 0.4124 + g * 0.3576 + b * 0.1805) / 0.95047
  let y = r * 0.2126 + g * 0.7152 + b * 0.0722
  let z = (r * 0.0193 + g * 0.1192 + b * 0.9505) / 1.08883
  proc f(t: float): float = (if t > 0.008856: cbrt(t) else: 7.787 * t + 16 / 116)
  (int(round(116 * f(y) - 16)), int(round(500 * (f(x) - f(y)))), int(round(200 * (f(y) - f(z)))))

# ---- blend modes ------------------------------------------------------------------------------------

type
  BlendMode* = enum
    ## How a layer (or paint) mixes with what is under it.
    bmNormal = "Normal", bmDissolve = "Dissolve", bmBehind = "Behind", bmClear = "Clear",
    bmMultiply = "Multiply", bmScreen = "Screen", bmOverlay = "Overlay",
    bmSoftLight = "Soft Light", bmHardLight = "Hard Light", bmDarken = "Darken",
    bmLighten = "Lighten", bmDifference = "Difference", bmHue = "Hue",
    bmSaturation = "Saturation", bmColor = "Color", bmLuminosity = "Luminosity",
    bmColorBurn = "Color Burn", bmLinearBurn = "Linear Burn", bmDarkerColor = "Darker Color",
    bmColorDodge = "Color Dodge", bmLinearDodge = "Linear Dodge (Add)", bmLighterColor = "Lighter Color",
    bmVividLight = "Vivid Light", bmLinearLight = "Linear Light", bmPinLight = "Pin Light",
    bmHardMix = "Hard Mix", bmExclusion = "Exclusion", bmSubtract = "Subtract", bmDivide = "Divide"

const
  LayerModes* = [bmNormal, bmDissolve,
                 bmDarken, bmMultiply, bmColorBurn, bmLinearBurn, bmDarkerColor,
                 bmLighten, bmScreen, bmColorDodge, bmLinearDodge, bmLighterColor,
                 bmOverlay, bmSoftLight, bmHardLight, bmVividLight, bmLinearLight, bmPinLight, bmHardMix,
                 bmDifference, bmExclusion, bmSubtract, bmDivide,
                 bmHue, bmSaturation, bmColor, bmLuminosity]
    ## The modes a layer can have (Behind and Clear are for painting), in
    ## their families: darken, lighten, contrast, compare, color.
  PaintModes* = [bmNormal, bmDissolve, bmBehind, bmClear,
                 bmDarken, bmMultiply, bmColorBurn, bmLinearBurn, bmDarkerColor,
                 bmLighten, bmScreen, bmColorDodge, bmLinearDodge, bmLighterColor,
                 bmOverlay, bmSoftLight, bmHardLight, bmVividLight, bmLinearLight, bmPinLight, bmHardMix,
                 bmDifference, bmExclusion, bmSubtract, bmDivide,
                 bmHue, bmSaturation, bmColor, bmLuminosity]
    ## The modes of the painting tools.

proc hash2*(x, y: int): uint32 {.inline.} =
  ## A fixed pseudo-random number for a place (Dissolve, noise, dither).
  var h = uint32(x) * 374761393'u32 + uint32(y) * 668265263'u32
  h = (h xor (h shr 13)) * 1274126177'u32
  h xor (h shr 16)

proc sepBlend(m: BlendMode; cb, cs: int): int {.inline.} =
  ## The separable modes, per channel (0..255).
  case m
  of bmMultiply: cb * cs div 255
  of bmScreen: cb + cs - cb * cs div 255
  of bmOverlay:
    if cb < 128: 2 * cb * cs div 255 else: 255 - 2 * (255 - cb) * (255 - cs) div 255
  of bmHardLight:
    if cs < 128: 2 * cb * cs div 255 else: 255 - 2 * (255 - cb) * (255 - cs) div 255
  of bmSoftLight:
    let b = cb / 255
    let s = cs / 255
    let d = if b <= 0.25: ((16 * b - 12) * b + 4) * b else: sqrt(b)
    let r = if s <= 0.5: b - (1 - 2 * s) * b * (1 - b) else: b + (2 * s - 1) * (d - b)
    int(round(r * 255))
  of bmDarken: min(cb, cs)
  of bmLighten: max(cb, cs)
  of bmDifference: abs(cb - cs)
  of bmColorBurn:
    if cb >= 255: 255 elif cs <= 0: 0 else: 255 - min(255, (255 - cb) * 255 div cs)
  of bmColorDodge:
    if cb <= 0: 0 elif cs >= 255: 255 else: min(255, cb * 255 div (255 - cs))
  of bmLinearBurn: max(0, cb + cs - 255)
  of bmLinearDodge: min(255, cb + cs)
  of bmVividLight:
    if cs < 128:
      let s2 = 2 * cs
      if cb >= 255: 255 elif s2 <= 0: 0 else: 255 - min(255, (255 - cb) * 255 div s2)
    else:
      let s2 = 2 * (cs - 128)
      if cb <= 0: 0 elif s2 >= 255: 255 else: min(255, cb * 255 div (255 - s2))
  of bmLinearLight: clamp(cb + 2 * cs - 255, 0, 255)
  of bmPinLight:
    if cs < 128: min(cb, 2 * cs) else: max(cb, 2 * (cs - 128))
  of bmHardMix: (if cb + cs >= 255: 255 else: 0)
  of bmExclusion: cb + cs - 2 * cb * cs div 255
  of bmSubtract: max(0, cb - cs)
  of bmDivide:
    if cs <= 0: (if cb > 0: 255 else: 0) else: min(255, cb * 255 div cs)
  else: cs

proc lumF(r, g, b: float): float {.inline.} = 0.3 * r + 0.59 * g + 0.11 * b

proc clipColor(r, g, b: var float) =
  let l = lumF(r, g, b)
  let n = min(r, min(g, b))
  let x = max(r, max(g, b))
  if n < 0:
    r = l + (r - l) * l / (l - n); g = l + (g - l) * l / (l - n); b = l + (b - l) * l / (l - n)
  if x > 1:
    r = l + (r - l) * (1 - l) / (x - l); g = l + (g - l) * (1 - l) / (x - l)
    b = l + (b - l) * (1 - l) / (x - l)

proc setLum(r, g, b: var float; l: float) =
  let d = l - lumF(r, g, b)
  r += d; g += d; b += d
  clipColor(r, g, b)

proc satF(r, g, b: float): float = max(r, max(g, b)) - min(r, min(g, b))

proc setSat(r, g, b: var float; s: float) =
  var c = [r, g, b]
  var idx = [0, 1, 2]
  idx.sort(proc (i, j: int): int = cmp(c[i], c[j]))
  let (mn, md, mx) = (idx[0], idx[1], idx[2])
  if c[mx] > c[mn]:
    c[md] = (c[md] - c[mn]) * s / (c[mx] - c[mn])
    c[mx] = s
  else:
    c[md] = 0; c[mx] = 0
  c[mn] = 0
  r = c[0]; g = c[1]; b = c[2]

proc nonSepBlend(m: BlendMode; db, ds: uint32): tuple[r, g, b: int] =
  ## Hue, Saturation, Color, Luminosity.
  var (br, bg, bb) = (rOf(db) / 255, gOf(db) / 255, bOf(db) / 255)
  var (sr, sg, sb) = (rOf(ds) / 255, gOf(ds) / 255, bOf(ds) / 255)
  var (r, g, b) = (0.0, 0.0, 0.0)
  case m
  of bmHue:
    (r, g, b) = (sr, sg, sb)
    setSat(r, g, b, satF(br, bg, bb)); setLum(r, g, b, lumF(br, bg, bb))
  of bmSaturation:
    (r, g, b) = (br, bg, bb)
    setSat(r, g, b, satF(sr, sg, sb)); setLum(r, g, b, lumF(br, bg, bb))
  of bmColor:
    (r, g, b) = (sr, sg, sb)
    setLum(r, g, b, lumF(br, bg, bb))
  of bmDarkerColor:
    (r, g, b) = (if lumF(sr, sg, sb) < lumF(br, bg, bb): (sr, sg, sb) else: (br, bg, bb))
  of bmLighterColor:
    (r, g, b) = (if lumF(sr, sg, sb) > lumF(br, bg, bb): (sr, sg, sb) else: (br, bg, bb))
  else:
    (r, g, b) = (br, bg, bb)
    setLum(r, g, b, lumF(sr, sg, sb))
  (int(round(r * 255)), int(round(g * 255)), int(round(b * 255)))

proc blendPx*(dst, src: uint32; alpha: int; m: BlendMode; x = 0; y = 0): uint32 =
  ## `src` over `dst` in mode `m`, `src`'s alpha times `alpha` (0..255).
  ## (`x`, `y`: where, for Dissolve.)
  var sa = aOf(src) * alpha div 255
  if sa <= 0 and m != bmClear: return dst
  let da = aOf(dst)
  case m
  of bmClear:
    return withAlpha(dst, da * (255 - alpha * aOf(src) div 255) div 255)
  of bmBehind:
    # the paint goes under what is there
    if da >= 255: return dst
    return blendPx(src.withAlpha(sa), dst, 255, bmNormal)
  of bmDissolve:
    if int(hash2(x, y) and 255) >= sa: return dst
    sa = 255
  else: discard
  if sa >= 255 and (m in {bmNormal, bmDissolve} or da == 0):
    return src or 0xFF000000'u32
  if da == 0: return src.withAlpha(sa)
  var cr, cg, cb: int
  if m in {bmNormal, bmDissolve}:
    cr = rOf(src); cg = gOf(src); cb = bOf(src)
  elif m in {bmHue, bmSaturation, bmColor, bmLuminosity, bmDarkerColor, bmLighterColor}:
    let t = nonSepBlend(m, dst, src)
    # mixed by how opaque what is under it is
    cr = (rOf(src) * (255 - da) + t.r * da) div 255
    cg = (gOf(src) * (255 - da) + t.g * da) div 255
    cb = (bOf(src) * (255 - da) + t.b * da) div 255
  else:
    cr = (rOf(src) * (255 - da) + sepBlend(m, rOf(dst), rOf(src)) * da) div 255
    cg = (gOf(src) * (255 - da) + sepBlend(m, gOf(dst), gOf(src)) * da) div 255
    cb = (bOf(src) * (255 - da) + sepBlend(m, bOf(dst), bOf(src)) * da) div 255
  let oa = sa + da * (255 - sa) div 255
  if oa <= 0: return 0
  let wd = da * (255 - sa) div 255
  argb(oa, (cr * sa + rOf(dst) * wd) div oa, (cg * sa + gOf(dst) * wd) div oa,
       (cb * sa + bOf(dst) * wd) div oa)

const SepModes = {bmMultiply, bmScreen, bmOverlay, bmSoftLight, bmHardLight, bmDarken, bmLighten,
                  bmDifference, bmColorBurn, bmLinearBurn, bmColorDodge, bmLinearDodge, bmVividLight,
                  bmLinearLight, bmPinLight, bmHardMix, bmExclusion, bmSubtract, bmDivide}
  ## (the modes that mix each channel alone: a table each)

var sepLuts: array[BlendMode, ptr UncheckedArray[uint8]]
var sepLutLock: Lock
initLock(sepLutLock)

proc sepLut(m: BlendMode): ptr UncheckedArray[uint8] =
  ## Mode `m`'s mix of a channel as a table, `[under * 256 + over]` (made
  ## once, kept; nil: not a mode of channels alone).
  if m notin SepModes: return nil
  {.cast(gcsafe).}:
    withLock sepLutLock:
      if sepLuts[m] == nil:
        let t = cast[ptr UncheckedArray[uint8]](allocShared(65536))
        for cb in 0 .. 255:
          for cs in 0 .. 255: t[cb shl 8 or cs] = uint8(clamp(sepBlend(m, cb, cs), 0, 255))
        sepLuts[m] = t
      result = sepLuts[m]

proc overOpaque(d, s: uint32; ea: int; lut: ptr UncheckedArray[uint8]): uint32 {.inline.} =
  ## `s` over an opaque `d`, `ea` (1..255) of it, mixed by `lut` (nil:
  ## Normal) -- what `blendPx` gives there, without its divisions.
  let ia = 255 - ea
  let dr = int((d shr 16) and 255)
  let dg = int((d shr 8) and 255)
  let db = int(d and 255)
  var sr = int((s shr 16) and 255)
  var sg = int((s shr 8) and 255)
  var sb = int(s and 255)
  if lut != nil:
    sr = int(lut[dr shl 8 or sr]); sg = int(lut[dg shl 8 or sg]); sb = int(lut[db shl 8 or sb])
  0xFF000000'u32 or (uint32((sr * ea + dr * ia) div 255) shl 16) or
    (uint32((sg * ea + dg * ia) div 255) shl 8) or uint32((sb * ea + db * ia) div 255)

# ---- documents -------------------------------------------------------------------------------------

type
  ColorMode* = enum
    ## The mode of an image (Mode menu): it limits the colors it holds.
    cmBitmap = "Bitmap", cmGray = "Grayscale", cmIndexed = "Indexed Color", cmRGB = "RGB Color",
    cmCMYK = "CMYK Color", cmLab = "Lab Color", cmDuotone = "Duotone", cmMultichannel = "Multichannel"

  SpotChannel* = object
    ## A channel of a Multichannel image: an ink of its own, printed on its
    ## plate -- what was a channel of the mode it came from (`Doc.spotBase`).
    name*: string           ## "Cyan", "Magenta"...
    ch*: int                ## which channel of `spotBase` it is (0..3)

  Layer* = ref object
    ## A layer: as big as the document, pixels 0xAARRGGBB. An adjustment
    ## layer (`adjust`) changes what is under it; its pixels are its mask.
    name*: string           ## shown in the Layers palette
    px*: seq[uint32]        ## its pixels, `Doc.w` x `Doc.h`, row by row
    hi*: seq[uint16]        ## a 16-bit document's layer at 16 bits (R G B A for each pixel);
                            ## `px` is it at 8 bits. A channel a tool changed at 8 bits no
                            ## longer matches: it is taken at 8 bits there (see `hiPixels`)
    hiVer*: int             ## (kept for old code: not looked at)
    hdr*: seq[float32]      ## a 32-bit document's layer in light as it is (linear R G B A for each
                            ## pixel, 1 the white of the screen, more brighter); `px` is it shown
                            ## at the document's exposure, and a pixel a tool changed at 8 bits
                            ## no longer matches: its light is made from what is shown
    hdrVer*: int            ## (kept for old code: not looked at)
    opacity*: int           ## 0..100
    mode*: BlendMode        ## how it mixes with what is under it
    visible*: bool          ## shown (the eye in the Layers palette)
    lockAlpha*: bool        ## Preserve Transparency: painting keeps its alpha
    background*: bool       ## the Background: opaque, always at the bottom
    ver*: int               ## changes with its pixels (for thumbnails)
    boxVer*: int            ## (for an app: `ver` + 1 when `box` was measured --
    box*: Rect              ## where its pixels are, kept on the layer: a cache
                            ## by its address goes wrong when a new layer gets it)
    mask*: Layer            ## its layer mask (gray: white shows, black hides), or nil
    maskOff*: bool          ## the mask is there but not used
    gray*: bool             ## a mask: painted in grays
    adjust*: Adjustment     ## an adjustment layer: what it does (kind "" for pixels)
    text*: TextData         ## a type layer: its text (no spans: a layer of pixels); its
                            ## pixels are the text drawn (`renderText`)
    fx*: LayerFx            ## its layer style (effects)
    clearFill: int          # 100 - its Fill Opacity
    lut: seq[uint32]        # (the adjustment as a table of colors)
    lut1: seq[uint8]        # (... as a table for each channel, when each follows only itself)
    lutKey: string
    textBox: DrawnBox       # where its text was drawn (empty: anywhere)
    clipped*: bool          ## in a clipping mask: shows only where the layer under it does
    shape*: ShapeData       ## a shape layer: its outline and paint (no subpaths: not one);
                            ## its pixels are the shape drawn
    shapeBox: DrawnBox      # where the shape was drawn
    fxCache: FxRender
    fxKey: string
    group*: bool            ## a layer group (a folder): the layers under it that are deeper
                            ## (`depth`) are in it; its pixels are nothing
    depth*: int             ## how deep in groups it is (0: in none)
    collapsed*: bool        ## a group closed in the Layers palette
    passThrough*: bool      ## a group whose layers mix with what is under it (its mode unused)
    picked*: bool           ## picked with others in the Layers palette (Ctrl+click)
    blendIf*: BlendIf       ## Blending Options: shown only where it and what is under are in ranges
    maskClear: int          # 100 - its mask's Density
    maskFeather*: float     ## its mask softened by so many pixels (Properties)
    maskEff: seq[uint32]    # (its mask as used: feathered, less dense)
    maskEffKey: string
    smart*: SmartData       ## a Smart Object: the picture its pixels are made from (nil: not one)
    locked*: bool           ## Lock All: not painted, moved or changed
    lockPixels*: bool       ## Lock Image Pixels: not painted (it still moves)
    lockPosition*: bool     ## Lock Position: not moved (it is still painted)
    link*: int              ## linked layers share a number (0: not linked): they move together
    board*: Rect            ## (a group) an artboard's page: what is in it shown only there
    uid*: int               ## who it is, for what refers to it (layer comps; 0: not asked yet)
    flowFrom*: int          ## a type layer whose box shows what did not fit the box of the type layer
                            ## of this `uid` (threaded text frames); 0: its own text

  CompState* = object
    ## A layer as a layer comp keeps it.
    uid*: int                ## the layer (`Layer.uid`)
    visible*: bool           ## shown
    x*, y*: int              ## where its content was (its box's corner)
    opacity*, fill*: int     ## its opacity and fill opacity (0..100)
    mode*: BlendMode         ## its blend mode
    fx*: LayerFx             ## its layer style

  LayerComp* = object
    ## Window > Layer Comps: a look of the document kept by name -- which
    ## layers show, where they are, how they look -- to go back to.
    name*, comment*: string  ## its name in the palette, and a note
    visibility*, position*, appearance*: bool   ## what it brings back
    states*: seq[CompState]  ## each layer as it was

  BlendIf* = object
    ## Blending Options > Blend If: where a layer shows by how light its own
    ## pixels (`this`) and the ones under it (`under`) are -- each range
    ## black, the end of black's split, the start of white's split, white
    ## (0..255; all 0: the whole range).
    channel*: int           ## 0 Gray, 1 Red, 2 Green, 3 Blue
    this*, under*: array[4, int]  ## the ranges of its own pixels and of those under it

  Quad* = array[4, (float, float)]
    ## Four corners: top left, top right, bottom right, bottom left.

  SmartFilter* = object
    ## A filter on a Smart Object: done again whenever it changes.
    name*: string           ## the filter's name ("Gaussian Blur")
    args*: seq[float]       ## its settings, as numbers (as the filter reads them)
    text*: string           ## (settings that are not numbers)
    opacity*: int           ## 0..100 (0 taken as 100)
    mode*: BlendMode        ## how its result mixes with what it filtered
    off*: bool              ## turned off (kept, not done)

  SmartData* = ref object
    ## What a Smart Object holds: its picture as placed (never resampled:
    ## scaling and turning it again loses nothing), where its corners are in
    ## the document, its Smart Filters. Never changed once made: a change is
    ## a new one (so undo keeps the old).
    src*: seq[uint32]       ## its picture's pixels, as placed (`w` x `h`)
    w*, h*: int             ## its picture's size
    quad*: Quad             ## where the picture's corners are in the document
    filters*: seq[SmartFilter]  ## its Smart Filters, done in order
    name*: string           ## what it was made from (a file's name)
    file*: string           ## the document it holds, when it is one with layers (.rpd bytes)
    warp*: seq[(float, float)]  ## a warp's mesh (4 x 4 points of the picture, 0..1), empty none

  FxKind* = enum
    ## The effects of a layer style (Layer > Layer Style), bottom to top.
    fxDropShadow = "Drop Shadow", fxOuterGlow = "Outer Glow", fxGradientOverlay = "Gradient Overlay",
    fxColorOverlay = "Color Overlay", fxSatin = "Satin", fxInnerGlow = "Inner Glow",
    fxInnerShadow = "Inner Shadow", fxStroke = "Stroke", fxBevel = "Bevel and Emboss"

  Effect* = object
    ## One effect and its settings (which ones it reads: `retroui/photostyles`).
    on*: bool                  ## turned on
    mode*: BlendMode           ## how it mixes
    opacity*: int              ## 0..100
    color*: uint32             ## (Bevel: the highlight's; Gradient Overlay: its start)
    color2*: uint32            ## Bevel: the shadow's; Gradient Overlay: its end
    mode2*: BlendMode          ## Bevel: the shadow's mode
    opacity2*: int             ## Bevel: the shadow's opacity
    angle*: int                ## degrees: where the light comes from (or the gradient goes)
    altitude*: int             ## Bevel: degrees above
    distance*: int             ## pixels
    size*: int                 ## pixels
    spread*: int               ## 0..100 (Choke for the inner ones)
    depth*: int                ## Bevel: %
    soften*: int               ## Bevel: pixels
    style*: int                ## Bevel 0 Inner, 1 Outer, 2 Emboss, 3 Pillow Emboss; Stroke 0 Outside,
                               ## 1 Inside, 2 Center; Gradient 0 Linear, 1 Radial, 2 Angle,
                               ## 3 Reflected, 4 Diamond; Inner Glow 0 Edge, 1 Center
    down*: bool                ## Bevel: lit from below; Gradient: reversed; Satin: inverted
    scale*: int                ## Gradient Overlay: % (0: 100)

  LayerFx* = object
    ## A layer style: its effects.
    fx*: array[FxKind, Effect] ## each effect, by its kind
    hidden*: bool              ## all turned off (still there)

  FxPlane* = object
    ## An effect made: how much of it there is at each pixel (over the
    ## `FxRender`'s rectangle) in a color, a blend mode, an opacity.
    a*: seq[uint8]             ## how much of it at each pixel, 0..255
    color*: uint32             ## its color (ARGB)
    colors*: seq[uint32]       ## a color for each pixel (a gradient) when not empty
    mode*: BlendMode           ## how it mixes
    opacity*: int              ## 0..255

  FxRender* = ref object
    ## A layer's effects, made: drawn under its pixels (shadows, glows,
    ## the outside stroke) and over them.
    r*: Rect                   ## the rectangle the planes cover (document pixels)
    below*, above*: seq[FxPlane]  ## the planes under the layer's pixels and over them, in order

  Adjustment* = object
    ## What an adjustment layer does: "Levels", "Curves", "Hue/Saturation"...
    ## (Clarity and Grain look at the pixels around: `AreaAdjustKinds`)
    ## with its settings (as `adjustmentLut` reads them).
    kind*: string               ## its name ("" for a layer of pixels)
    args*: seq[float]           ## its settings, as numbers
    data*: string               ## settings that are not numbers (Color Lookup: the look's name
                                ## or a .cube file's text)

  AlphaChannel* = object
    ## A saved selection (an alpha channel): 0 not selected .. 255 selected.
    name*: string               ## shown in the Channels palette
    m*: seq[uint8]              ## a value for each pixel of the document
    ver*: int                   ## changes with `m` (for thumbnails)

  PathPoint* = object
    ## A point of a path with its two direction handles (equal to the point
    ## for a corner without curves).
    p*, inH*, outH*: (float, float)  ## the point, its handle toward the point before, toward the next

  PathOp* = enum
    ## How a subpath of a shape goes with the ones before it.
    poAdd = "Combine Shapes", poSubtract = "Subtract Front Shape",
    poIntersect = "Intersect Shape Areas", poExclude = "Exclude Overlapping Shapes"

  SubPath* = object
    ## A run of points of a path: open, or closed into an outline.
    pts*: seq[PathPoint]      ## its points, in order
    closed*: bool             ## its last point joins its first
    op*: PathOp               ## (a shape's) how it goes with the subpaths before it
    joined*: bool             ## filled together with the subpath before (one component)

  Path* = object
    ## A path drawn with the pen: shapes made of curves.
    name*: string             ## shown in the Paths palette ("Work Path")
    subs*: seq[SubPath]       ## its subpaths

  ShapePaintKind* = enum
    ## What a shape's fill or stroke paints with.
    spNone = "No Color", spColor = "Solid Color", spGradient = "Gradient", spPattern = "Pattern"

  GradientStop* = object
    ## A color of a gradient, and where it is.
    at*: float                  ## 0..1 along the gradient
    color*: uint32              ## with its opacity (alpha)
    mid*: float                 ## where between it and the next the colors are half and half
                                ## (0..1 of the way; 0 taken as 0.5)

  ShapePaint* = object
    ## What a shape is filled or stroked with.
    kind*: ShapePaintKind       ## what it paints with
    color*, color2*: uint32     ## (a gradient goes from `color` to `color2`...
    stops*: seq[GradientStop]   ## ... or through these colors, when there are any)
    scale*: int                 ## a gradient's scale, % (0: 100)
    angle*: int                 ## a gradient's direction, degrees
    style*: int                 ## 0 Linear, 1 Radial, 2 Angle, 3 Reflected, 4 Diamond
    reverse*: bool              ## the gradient's colors the other way
    opacity*: int               ## 0..100 (0 taken as 100)
    pattern*: seq[uint32]       ## a pattern's pixels (`pw` x `ph`), tiled (`scale` %)
    pw*, ph*: int               ## the pattern's size

  StrokeAlign* = enum
    ## Where a shape's stroke is: inside its outline, centered on it, outside.
    saInside = "Inside", saCenter = "Center", saOutside = "Outside"

  LineCap* = enum
    ## How the ends of an open stroke are drawn: cut off at the end, rounded,
    ## or squared half the stroke's width past it.
    lcButt = "Butt", lcRound = "Round", lcSquare = "Square"

  LineJoin* = enum
    ## How a stroke turns a corner: pointed, rounded, or cut off.
    ljMiter = "Miter", ljRound = "Round", ljBevel = "Bevel"

  LineEnd* = enum
    ## What an open line has at its start or its end (a shape's
    ## `startEnd`, `endEnd`): drawn in its stroke's color, turned as the
    ## line goes there.
    leNone = "None", leArrow = "Arrow", leOpenArrow = "Open Arrow", leStealth = "Stealth Arrow",
    leCircle = "Circle", leSquare = "Square", leDiamond = "Diamond", leBar = "Bar"

  ShapeData* = object
    ## A shape layer: its outline (a path) filled and stroked, drawn again
    ## sharp when it changes size or turns.
    path*: Path                 ## its outline
    fill*, stroke*: ShapePaint  ## what it is filled with, and stroked with
    strokeWidth*: float         ## pixels
    align*: StrokeAlign         ## where the stroke is on the outline
    cap*: LineCap               ## the stroke's ends
    join*: LineJoin             ## the stroke's corners
    dashes*: seq[float]         ## dash, gap, dash... in stroke widths (empty: a solid line)
    kind*: string               ## what drew it ("Rectangle", "Ellipse"...; "" a path)
    radius*: float              ## a rounded rectangle's corners
    startEnd*, endEnd*: LineEnd ## (its open subpaths -- a line) an arrowhead or another
                                ## shape at their start and end
    endW*, endL*: float         ## ... how wide and long, times the stroke's width (0: 4)

  FrameLayer* = object
    ## A layer in a frame of an animation: shown or not, how opaque, where.
    uid*: int                   ## the layer (`uidOf`)
    visible*: bool              ## shown in the frame
    opacity*: int               ## 0..100
    dx*, dy*: int               ## moved so far from where it is in the first frame

  AnimFrame* = object
    ## A frame of an animation (the Timeline): its layers' states, how long
    ## it is shown.
    delay*: int                 ## milliseconds
    layers*: seq[FrameLayer]    ## the layers' states in this frame

  TextStyleDef* = object
    ## A Character or Paragraph Style: a look kept by name, given to text
    ## (`applyCharStyle`, `applyParaStyle`) and changed everywhere it is
    ## when it is redefined (`redefineStyle`).
    name*: string               ## shown in the Styles palettes
    char*: CharStyle            ## the letters (a Paragraph Style's too, as Photoshop's)
    para*: ParaStyle            ## (a Paragraph Style's) its paragraphs

  ImageInfo* = object
    ## What File Info keeps with the image.
    caption*, author*, title*, keywords*, copyright*, url*: string
      ## its description, who made it, its title, its keywords, its
      ## copyright notice, and a web address for it

  TileSave = object
    layer: Layer
    tx, ty: int              # (-1, -1: the whole layer, `touchWhole`)
    px: seq[uint32]
    hi: seq[uint16]          # (its 16 bits, when it has them)
    hdr: seq[float32]        # (its light at 32 bits, when it has it)

  SpillJob = object
    ## (what the writer thread writes: shared memory, no references)
    path: array[1024, char]
    bufs: ptr UncheckedArray[tuple[p: pointer; len: int]]
    n: int
    done: Atomic[int]          # 1 written, 2 failed
    cancel: Atomic[int]        # 1: no longer wanted (stop writing)
    removeOnly: bool           # (a file to delete, nothing to write: the writer frees it)

  SpillObj = object
    ## A step's pixels written to the scratch disk.
    path: string
    job: ptr SpillJob
    lens: seq[int]             # the byte length of each buffer, in order
    freed: bool                # the memory given back (the pixels only in the file)

  Spill = ref SpillObj

  LayerSettings = object
    ## (all of a layer but its pixels)
    name: string
    opacity: int
    mode: BlendMode
    visible, lockAlpha, background, maskOff, gray: bool
    mask: Layer
    adjust: Adjustment
    text: TextData
    fx: LayerFx
    clearFill: int
    shape: ShapeData
    clipped: bool
    lockPixels, lockPosition: bool
    link: int
    board: Rect
    group, collapsed, passThrough, locked: bool
    depth: int
    blendIf: BlendIf
    maskClear: int
    maskFeather: float
    smart: SmartData

  LayerSnap = object
    layer: Layer
    px: seq[uint32]
    hi: seq[uint16]
    hdr: seq[float32]
    maskPx: seq[uint32]
    s: LayerSettings

  DocSnap = object
    w, h: int
    dpi: float
    mode: ColorMode
    palette: seq[uint32]
    duotone: seq[DuotoneInk]
    layers: seq[LayerSnap]
    cur: int
    sel: seq[uint8]
    alphas: seq[AlphaChannel]
    paths: seq[Path]

  Step* = object
    ## One undoable change.
    name*: string            ## shown in the History palette and Edit > Undo
    tiles: seq[TileSave]
    sel: seq[uint8]
    selSaved: bool
    snap: DocSnap
    hasSnap: bool
    bytes: int
    wasModified: bool        # (a cancelled step leaves the document as it was)
    paths: seq[Path]         # the paths before (`touchPaths`)
    curPath: int
    pathsSaved: bool
    layerList: LayerList     # the layers and their settings before (`touchLayers`)
    layersSaved: bool
    spill: Spill             # its pixels on the scratch disk (nil: in memory)

  LayerProps = object
    layer: Layer
    s: LayerSettings

  Snapshot* = object
    ## A snapshot (History palette): the whole image as it was.
    name*: string                ## shown in the History palette ("Snapshot 1")
    step: Step                   # (a step with all of it: written to the scratch disk)

  Guide* = object
    ## A guide: a line across (`vertical` false: at `pos` down) or down the
    ## image, in image pixels.
    vertical*: bool              ## a line down the image (at `pos` across)
    pos*: float                  ## where (image pixels)

  LayerList = object
    props: seq[LayerProps]
    cur: int
    editMask: bool

  LiveKind* = enum
    ## How a `LivePart` shows its layer changed.
    lkShift   ## `src` (as big as the image) moved by `dx`, `dy`, over `base`
    lkWarp    ## `src` (the pixels taken from `srcR`, its size) stretched into the corners `quad`,
              ## over `base`
    lkMap     ## the layer's own pixels, each changed by `map` (where selected)

  LivePart* = object
    ## A change being made with the mouse, shown before it is done: views
    ## draw the layer this way, straight from the layers at their own size
    ## (`compositeSampled`), and the full-size pixels are only changed when
    ## it is put down -- a big photo moves, turns and is adjusted as quickly
    ## as a small one. The pixels pointed at belong to the caller, who keeps
    ## them while the part is shown.
    layer*: Layer                     ## the layer (or a layer's mask) shown changed
    kind*: LiveKind                   ## how it is changed
    base*: ptr UncheckedArray[uint32] ## (shift, warp) what stays under, as big as the image;
                                      ## nil: `baseFill` everywhere
    baseFill*: uint32                 ## (shift, warp) the color under, without `base`
    src*: ptr UncheckedArray[uint32]  ## (shift, warp) the pixels that move
    srcR*: Rect                       ## (warp) where `src`'s pixels were taken from
    dx*, dy*: int                     ## (shift) how far they moved
    quad*: Quad                       ## (warp) where `srcR`'s corners go
    srcStride*: int                   ## (warp) `src`'s row length (0: `srcR.w`)
    hole*: bool                       ## (warp, no `base`) the layer's own pixels under it, but
                                      ## `baseFill` where the pixels were taken from (`srcR`)
    replace*: bool                    ## (a mask) what moves replaces what is under it
    keepAlpha*: bool                  ## (map) the alpha kept: the Background, Preserve Transparency
    map*: proc (px: var seq[uint32]; w, h: int) {.closure.}
      ## (map) changes `w` x `h` pixels of the layer, in place

  LivePlain = object
    ## (a live part as plain data for the cores)
    kind: LiveKind
    base, src, mapped: ptr UncheckedArray[uint32]
    baseFill: uint32
    srcR: Rect
    dx, dy: int
    inv: array[9, float]
    stride: int
    hole, replace, keepAlpha: bool
    sel: ptr UncheckedArray[uint8]

  Doc* = ref object
    ## An image: its layers, selection, channels, paths and history.
    w*, h*: int                    ## its size in pixels
    dpi*: float                    ## pixels per inch
    exposure*: float               ## a 32-bit document: the exposure it is shown at (stops; see photohdr)
    viewGamma*: float              ## ... and the gamma (0: 1)
    depth*: int                    ## bits a channel: 8, 16 or 32 (Image > Mode: kept and saved so;
                                   ## edits are made at 8 -- an edited layer is saved as 8 made 16)
    mode*: ColorMode               ## its color mode (Image > Mode)
    palette*: seq[uint32]          ## Indexed Color: its colors
    layers*: seq[Layer]            ## bottom first
    cur*: int                      ## the layer painted on
    sel*: seq[uint8]               ## the selection; empty: none (all of it)
    selVer*: int                   ## changes with the selection
    alphas*: seq[AlphaChannel]     ## saved selections
    paths*: seq[Path]              ## its paths (Paths palette)
    curPath*: int                  ## the path shown (-1 none)
    channelsOn*: array[4, bool]    ## R, G, B (C, M, Y, K; L, a, b): the color channels edited
    viewChannel*: int              ## -1 all, 0..3 one color channel (in gray)
    duotone*: seq[DuotoneInk]      ## Duotone: its inks
    spots*: seq[SpotChannel]       ## Multichannel: its channels, each an ink
    spotBase*: ColorMode           ## Multichannel: the mode its channels came from (RGB, CMYK, Grayscale)
    proof*: bool                   ## View > Proof Colors: shown as it prints
    icc*: string                   ## its color profile (ICC); "": sRGB, the working space
    gamutWarning*: bool            ## View > Gamut Warning: what cannot be printed in gray
    quickMask*: bool               ## the selection shown and painted as a red mask
    editMask*: bool                ## painting goes on the current layer's mask
    maskLayer*: Layer              ## the mask painted in Quick Mask mode
    comp*: seq[uint32]             ## what it looks like, all layers mixed
    dirty*: Rect                   ## where `comp` is out of date
    mips: seq[seq[uint32]]         # `comp` at 1/2, 1/4, 1/8... (zoomed-out views)
    mipSize: seq[(int, int)]
    mipDirty: seq[Rect]            # where each is out of date (in `comp`'s pixels)
    ver*: int                      ## changes with what it looks like
    changeLog: array[64, tuple[ver: int; r: Rect]]   ## the last changes (`changedSince`)
    name*: string                  ## "Untitled-1"
    path*: string                  ## its file ("" not saved yet)
    format*: string                ## the file's format ("rpd", "png", "jpg"...)
    modified*: bool                ## changed since saved
    info*: ImageInfo               ## its File Info
    undoSteps*, redoSteps*: seq[Step]  ## the steps to undo (the last made last) and to redo
    stepsMade*: int                ## how many steps have been made so far
                                   ## (an operation's own: those since it began)
    parkedRedo: seq[Step]      # the redo steps while a step is open
    stepOpen: bool
    stepIndex: Table[(pointer, int, int), int]
    stepWhole: seq[pointer]        # (the layers this step saved whole: `touchWhole`)
    maxUndoBytes*: int             ## the history's room (oldest steps go first)
    snapshots*: seq[Snapshot]      ## History palette: the image kept as it was (on the scratch disk)
    historyCut*: bool              ## the oldest steps were forgotten (the history is not all there)
    guides*: seq[Guide]            ## lines over the image things snap to
    comps*: seq[LayerComp]         ## its layer comps (Window > Layer Comps)
    frames*: seq[AnimFrame]        ## its animation's frames (Timeline; none: not animated)
    frameCur*: int                 ## ... the frame shown
    animLoop*: int                 ## ... played so many times (0: forever)
    charStyles*: seq[TextStyleDef] ## its Character Styles
    paraStyles*: seq[TextStyleDef] ## its Paragraph Styles
    live*: seq[LivePart]           ## what is being moved, turned, adjusted: shown, not done yet
                                   ## (see `LivePart`; `setLive`, `endLive`)
    liveVer*: int                  ## changes with `live`
    liveSel*: tuple[dx, dy: int; hidden: bool]   ## the selection's outline shown moved, or not
                                                 ## shown, while `live` is
    selBox: tuple[ver, w, h: int; r: Rect]   # (`selBounds`, kept while the selection stays)

when defined(linux) and not defined(android):
  proc mallocTrim(pad: csize_t): cint {.importc: "malloc_trim", header: "<malloc.h>".}

proc purgeCaches*(d: Doc) =
  ## Lets go of what is only kept to be quick (the zoomed-out copies, the
  ## softened masks): made again when needed.
  d.mips = @[]
  d.mipSize = @[]
  d.mipDirty = @[]
  for L in d.layers:
    L.maskEff = @[]
    L.maskEffKey = ""

proc trimMemory*() =
  ## Gives the memory let go back to the system (where it can).
  when defined(linux) and not defined(android):
    discard mallocTrim(0)

proc memoryUsed*(): int =
  ## The memory the program holds (its resident size), bytes; 0 when not
  ## known.
  when defined(linux) or defined(android):
    try:
      let f = readFile("/proc/self/statm").split(' ')
      if f.len > 1: return parseInt(f[1]) * 4096
    except CatchableError: discard
  0

proc waitJob(job: ptr SpillJob) {.raises: [].} =
  ## (also from a destructor: nothing may escape it)
  while job.done.load == 0:
    try: busyTick()
    except Exception: discard
    sleep(2)

proc queueRemove(path: string) {.raises: [].}

proc `=destroy`(x: var SpillObj) =
  if x.job != nil:
    # (still being written: stopped -- the writer looks between pieces)
    x.job.cancel.store(1)
    waitJob(x.job)
    deallocShared(x.job.bufs)
    freeShared(x.job)
  if x.path.len > 0: queueRemove(x.path)
  `=destroy`(x.path)
  `=destroy`(x.lens)

proc `=copy`(a: var SpillObj; b: SpillObj) {.error.}

const TileSize = 64

const LutN* = 33
  ## An adjustment layer's table of colors: 33 x 33 x 33 (read between).

const AreaAdjustKinds* = ["Clarity", "Grain"]
  ## The adjustment layers that look at the pixels around each (not a
  ## table of colors): done between the layers under and over them, at
  ## the top level (in a group they do nothing).

var adjustmentLut*: proc (a: Adjustment): seq[uint32] {.nimcall.}
  ## Makes an adjustment layer's table (`LutN`^3 colors, red slowest: what
  ## each grid color becomes). Set by `retroui/photodevelop`; without it
  ## adjustment layers change nothing.

var shapeRender*: proc (w, h: int; L: Layer): DrawnBox {.nimcall.}
  ## Draws a shape layer's shape into its pixels (cleared), saying where it
  ## drew. Set by `retroui/photoshapes`.

var layerFxRender*: proc (w, h: int; L: Layer): FxRender {.nimcall.}
  ## Makes a layer's effects (its layer style) from its pixels and mask.
  ## Set by `retroui/photostyles`; without it layer styles show nothing.

proc fill*(L: Layer): int {.inline.} = 100 - L.clearFill
  ## Its Fill Opacity: how much of its own pixels show (its effects all
  ## the same), 0..100.
proc `fill=`*(L: Layer; v: int) {.inline.} = L.clearFill = 100 - clamp(v, 0, 100)
  ## Sets its Fill Opacity, 0..100.

proc isText*(L: Layer): bool {.inline.} =
  ## A type layer (its text can still be edited).
  L != nil and L.text.spans.len > 0

proc isShape*(L: Layer): bool {.inline.} =
  ## A shape layer (its outline can still be edited).
  L != nil and L.shape.path.subs.len > 0

proc isVector*(L: Layer): bool {.inline.} =
  ## A type or shape layer: its pixels are made from what it holds.
  L.isText or L.isShape

proc hasFx*(L: Layer): bool =
  ## It has a layer style that shows.
  if L.fx.hidden: return false
  for e in L.fx.fx:
    if e.on: return true

proc hasStyle*(L: Layer): bool =
  ## It has a layer style (shown or not).
  for e in L.fx.fx:
    if e.on: return true

proc maskDensity*(L: Layer): int {.inline.} = 100 - L.maskClear
  ## How much its mask hides (Properties: Density), 0..100.
proc `maskDensity=`*(L: Layer; v: int) {.inline.} = L.maskClear = 100 - clamp(v, 0, 100)
  ## Sets how much its mask hides, 0..100.

proc isSmart*(L: Layer): bool {.inline.} =
  ## A Smart Object (its picture can be scaled again, its filters changed).
  L != nil and L.smart != nil and L.smart.src.len > 0

proc rangeOf*(a: array[4, int]): array[4, int] {.inline.} =
  ## A Blend If range as it works (all 0: the whole range).
  if a == [0, 0, 0, 0]: [0, 0, 255, 255] else: a

proc isOn*(b: BlendIf): bool =
  ## Whether Blend If leaves anything out.
  rangeOf(b.this) != [0, 0, 255, 255] or rangeOf(b.under) != [0, 0, 255, 255]

proc rangeAmt(r: array[4, int]; v: int): int {.inline.} =
  ## How much (0..255) a value `v` lets the layer show by the range `r`.
  if v < r[0] or v > r[3]: 0
  elif v < r[1]: (v - r[0]) * 255 div max(1, r[1] - r[0])
  elif v > r[2]: (r[3] - v) * 255 div max(1, r[3] - r[2])
  else: 255

proc chanOf(p: uint32; ch: int): int {.inline.} =
  case ch
  of 1: int((p shr 16) and 255)
  of 2: int((p shr 8) and 255)
  of 3: int(p and 255)
  else: (int((p shr 16) and 255) * 77 + int((p shr 8) and 255) * 151 + int(p and 255) * 28) shr 8

when defined(useMalloc) and not defined(js):
  proc cCalloc(n, size: csize_t): pointer {.importc: "calloc", header: "<stdlib.h>".}

proc zeroPixels*(n: int): seq[uint32] =
  ## `n` transparent pixels. A big buffer comes zeroed from the system
  ## (`calloc`): its memory is only really taken where it is written -- an
  ## empty layer, a group, costs (almost) nothing.
  when defined(useMalloc) and not defined(js):
    if n >= 65536:
      type Raw = object
        len: int
        p: pointer
      let p = cCalloc(csize_t(sizeof(int) + n * 4), 1)
      if p == nil: raise newException(OutOfMemDefect, "out of memory")
      cast[ptr int](p)[] = n               # (the payload: its capacity, then the pixels)
      cast[ptr Raw](addr result)[] = Raw(len: n, p: p)
      return
  newSeq[uint32](n)

proc newLayer*(d: Doc; name: string; fill = 0'u32): Layer =
  ## A layer as big as `d` (not added to it).
  result = Layer(name: name, opacity: 100, mode: bmNormal, visible: true)
  let n = d.w * d.h
  if fill == 0:
    result.px = zeroPixels(n)
  else:
    result.px = newSeqUninit[uint32](n)
    let p = pixPtr(result.px)
    parallelFor(n, proc (lo, hi: int) =
      for i in lo ..< hi: p[i] = fill, grain = 65536)

var maxHistoryStates* = 100
  ## The most undo steps a document keeps (the oldest go first).

var undoBudget* = 1536 * 1024 * 1024
  ## The room each new document's undo steps may take, in memory and on
  ## the scratch disk (the oldest go first); `Doc.maxUndoBytes` for one
  ## document. (Only `undoRamBudget` of it is kept in memory.)

const MaxSide* = 30000
  ## The longest side of an image.

when defined(posix):
  var scPhysPages {.importc: "_SC_PHYS_PAGES", header: "<unistd.h>".}: cint
  var scPageSize {.importc: "_SC_PAGESIZE", header: "<unistd.h>".}: cint
  proc sysconf(name: cint): clong {.importc, header: "<unistd.h>".}

proc physicalMemory*(): int64 =
  ## The device's memory in bytes (4 GB when it cannot be told).
  when defined(posix):
    let n = sysconf(scPhysPages)
    let p = sysconf(scPageSize)
    if n > 0 and p > 0: return int64(n) * int64(p)
  4'i64 shl 30

var maxPixels* = int(clamp(physicalMemory() div 48, 64_000_000'i64, 300_000_000'i64))
  ## The most pixels an image may have (each layer takes 4 bytes a pixel,
  ## and the undo steps more): Image Size, Canvas Size, New... ask within.
  ## From the device's memory (a 64 MP image at least).

proc sizeOk*(w, h: int): bool =
  ## Whether an image `w` x `h` may be made.
  w >= 1 and h >= 1 and w <= MaxSide and h <= MaxSide and w * h <= maxPixels

proc checkSize(w, h: int) =
  if not sizeOk(w, h):
    raise newException(ValueError, "an image of " & $w & " x " & $h & " pixels is too big")

proc blankDoc(w, h: int; dpi = 72.0; name = "Untitled-1"; mode = cmRGB): Doc =
  ## A document without layers yet.
  checkSize(max(1, w), max(1, h))
  result = Doc(w: max(1, w), h: max(1, h), dpi: dpi, mode: mode, name: name, curPath: -1,
               viewChannel: -1, maxUndoBytes: undoBudget, depth: 8)
  result.channelsOn = [true, true, true, true]
  result.dirty = rect(0, 0, result.w, result.h)     # (`comp` is made when first needed)

proc newDoc*(w, h: int; contents = 0xFFFFFFFF'u32; dpi = 72.0; name = "Untitled-1";
             mode = cmRGB): Doc =
  ## A new image, `w` x `h`: a Background of `contents`, or (when it is
  ## transparent: 0) "Layer 1". Raises `ValueError` when it is too big
  ## (`sizeOk`).
  result = blankDoc(w, h, dpi, name, mode)
  if aOf(contents) == 0:
    result.layers.add result.newLayer("Layer 1")
  else:
    let L = result.newLayer("Background", contents or 0xFF000000'u32)
    L.background = true
    result.layers.add L

proc bounds*(d: Doc): Rect = rect(0, 0, d.w, d.h)
  ## The whole image: 0, 0, `w` x `h`.

proc layer*(d: Doc): Layer =
  ## The layer painted on: the current layer, or its mask (`editMask`), or
  ## the Quick Mask while it is on.
  if d.quickMask and d.maskLayer != nil: return d.maskLayer
  let L = d.layers[clamp(d.cur, 0, d.layers.high)]
  if d.editMask and L.mask != nil and L.mask.px.len == L.px.len: L.mask else: L

proc current*(d: Doc): Layer =
  ## The current layer (itself, never its mask).
  d.layers[clamp(d.cur, 0, d.layers.high)]

iterator pixelLayers*(d: Doc): Layer =
  ## Every layer and every layer mask: what changes when the image changes
  ## size or turns. (Not the groups' pixels, which are nothing: `markAll`
  ## makes them the new size.)
  for L in d.layers:
    if not L.group: yield L
    if L.mask != nil: yield L.mask

proc clip*(d: Doc; r: Rect): Rect = intersect(r, d.bounds)
  ## The part of `r` inside the image.

proc markDirty*(d: Doc; r: Rect) =
  ## `r` of the image changed: the composite is made again there.
  let c = d.clip(r)
  if c.w <= 0 or c.h <= 0: return
  d.dirty = if d.dirty.w <= 0: c else: union(d.dirty, c)
  inc d.ver
  d.changeLog[d.ver and 63] = (d.ver, c)
  d.modified = true

proc changedSince*(d: Doc; ver: int): Rect =
  ## The part of the image that changed after version `ver` (all of it when
  ## that is not known: too long ago, or a change that did not say where).
  if ver == d.ver: return rect(0, 0, 0, 0)
  if ver > d.ver or d.ver - ver > d.changeLog.len: return d.bounds
  for v in ver + 1 .. d.ver:
    let e = d.changeLog[v and 63]
    if e.ver != v: return d.bounds
    result = union(result, e.r)

proc fitQuickMask(d: Doc) =
  ## The Quick Mask made again from the selection when the image changed
  ## size under it (Crop, Image Size, an undo of them).
  if not d.quickMask or d.maskLayer == nil or d.maskLayer.px.len == d.w * d.h: return
  d.maskLayer.px = newSeq[uint32](d.w * d.h)
  let whole = d.sel.len != d.w * d.h
  for i in 0 ..< d.maskLayer.px.len:
    let v = if whole: 255 else: int(d.sel[i])
    d.maskLayer.px[i] = 0xFF000000'u32 or uint32(v * 0x010101)
  inc d.maskLayer.ver

proc markAll*(d: Doc) =
  ## All of the image changed: the composite is made again everywhere.
  d.fitQuickMask()
  for L in d.layers:
    if L.group and L.px.len != d.w * d.h: L.px = zeroPixels(d.w * d.h)
  d.markDirty(d.bounds)

proc touchLayer*(L: Layer) = inc L.ver
  ## The layer's pixels changed (its `ver` goes up; thumbnails are made again).

# ---- type layers ----------------------------------------------------------------------------------------

proc textBounds*(L: Layer): Rect =
  ## Where a type layer's text was last drawn (empty: not known).
  let b = L.textBox
  if b.x1 > b.x0 and b.y1 > b.y0: rect(b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0) else: rect(0, 0, 0, 0)

proc layerOfUid*(d: Doc; uid: int): Layer
  ## The layer whose `uid` that is (nil: none).

proc flowsOn*(d: Doc; L: Layer): bool =
  ## Another type layer's box shows what does not fit this one's.
  if L.uid == 0: return false
  for M in d.layers:
    if M != L and M.flowFrom == L.uid: return true

proc effectiveText*(d: Doc; L: Layer; depth = 0): TextData =
  ## The text a type layer shows: its own; or, flowing on from another box
  ## (`flowFrom`), what did not fit that one, set in this one's box.
  if L.flowFrom == 0 or depth > 16: return L.text
  let S = d.layerOfUid(L.flowFrom)
  if S == nil or S == L or not S.isText: return L.text
  var st = d.effectiveText(S, depth + 1)
  st.clipOverflow = true
  let lay = layoutText(st)
  result = if lay.overflow >= 0: st.remainder(lay.overflow) else: st.remainder(int.high)
  result.x = L.text.x
  result.y = L.text.y
  result.boxW = L.text.boxW
  result.boxH = L.text.boxH
  result.columns = L.text.columns
  result.gutter = L.text.gutter
  result.warp = TextWarp()
  result.path = @[]
  result.fit = false
  result.clipOverflow = d.flowsOn(L)

var flowDepth = 0                  ## (boxes drawn again down a chain of them)

proc drawText*(d: Doc; L: Layer) =
  ## A type layer's pixels made again from its text (after it changed);
  ## the boxes its text flows on into, again too.
  if not L.isText or L.px.len != d.w * d.h: return
  let old = L.textBox
  if old.x1 > old.x0:
    for y in max(0, old.y0) ..< min(d.h, old.y1):
      let x0 = max(0, old.x0)
      let x1 = min(d.w, old.x1)
      if x1 > x0: zeroMem(addr L.px[y * d.w + x0], (x1 - x0) * 4)
  else:
    zeroMem(addr L.px[0], L.px.len * 4)
  var t = d.effectiveText(L)
  if d.flowsOn(L): t.clipOverflow = true
  let b = t.renderTextInto(L.px, d.w, d.h, layoutText(t))
  L.textBox = b
  inc L.ver
  if old.x1 > old.x0:
    d.markDirty(rect(old.x0, old.y0, old.x1 - old.x0, old.y1 - old.y0))
  else: d.markDirty(d.bounds)
  if b.x1 > b.x0: d.markDirty(rect(b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0))
  if L.uid != 0 and flowDepth < 16:
    inc flowDepth
    try:
      for M in d.layers:
        if M != L and M.flowFrom == L.uid: d.drawText(M)
    finally: dec flowDepth

proc textArea*(L: Layer): Rect =
  ## Where a type layer's pixels are (empty when not known: anywhere).
  let b = L.textBox
  if L.isText and b.x1 > b.x0 and b.y1 > b.y0: rect(b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0)
  else: rect(0, 0, 0, 0)

proc setText*(d: Doc; L: Layer; t: TextData) =
  ## A type layer's text changed (undoable in a step: `touchLayers`
  ## first).
  L.text = t
  d.drawText(L)

# ---- Character and Paragraph Styles -------------------------------------------------------------------------

proc styleIndex*(list: seq[TextStyleDef]; name: string): int =
  ## Where the style named `name` is in `list` (-1: none).
  for i, st in list:
    if st.name == name: return i
  -1

proc withLook(s: var CharStyle; look: CharStyle; name: string) =
  ## (a character style's look put on letters: their own text kept)
  s = look
  s.styleName = name

proc applyCharStyle*(d: Doc; L: Layer; a, b: int; name: string) =
  ## Character Styles: the style `name` given to characters `a` ..< `b`
  ## of a type layer (`a` = `b` = 0: all of it); "" takes the style away
  ## (the letters keep their look). Undoable in a step (`touchLayers`).
  if not L.isText: return
  var t = L.text
  let k = d.charStyles.styleIndex(name)
  if name.len > 0 and k < 0: return
  let look = if k >= 0: d.charStyles[k].char else: CharStyle()
  t.restyle(a, b, proc (s: var CharStyle) =
    if name.len == 0: s.styleName = ""
    else: s.withLook(look, name))
  d.setText(L, t)

proc applyParaStyle*(d: Doc; L: Layer; name: string) =
  ## Paragraph Styles: the style `name` given to a type layer's paragraphs
  ## -- and its letters to the text that has no Character Style; "" takes
  ## it away. Undoable in a step (`touchLayers`).
  if not L.isText: return
  var t = L.text
  if name.len == 0:
    t.para.styleName = ""
    d.setText(L, t)
    return
  let k = d.paraStyles.styleIndex(name)
  if k < 0: return
  let def = d.paraStyles[k]
  t.para = def.para
  t.para.styleName = name
  let look = def.char
  t.restyle(0, 0, proc (s: var CharStyle) =
    if s.styleName.len == 0:
      let keep = s.styleName
      s = look
      s.styleName = keep)
  d.setText(L, t)

proc redefineStyle*(d: Doc; paragraph: bool; name: string; char: CharStyle; para = ParaStyle()) =
  ## A style made as `char` (and `para`): every text that has it changes
  ## (undoable in a step: `touchLayers` first). Made when it is not there.
  var c = char
  c.styleName = ""
  var p = para
  p.styleName = ""
  if paragraph:
    let k = d.paraStyles.styleIndex(name)
    if k < 0: d.paraStyles.add TextStyleDef(name: name, char: c, para: p)
    else:
      d.paraStyles[k].char = c
      d.paraStyles[k].para = p
  else:
    let k = d.charStyles.styleIndex(name)
    if k < 0: d.charStyles.add TextStyleDef(name: name, char: c)
    else: d.charStyles[k].char = c
  for L in d.layers:
    if not L.isText: continue
    var used = false
    if paragraph and L.text.para.styleName == name: used = true
    for sp in L.text.spans:
      if (not paragraph and sp.style.styleName == name) or (paragraph and used and sp.style.styleName.len == 0):
        used = true
    if not used: continue
    if paragraph: d.applyParaStyle(L, name)
    else:
      var t = L.text
      for sp in t.spans.mitems:
        if sp.style.styleName == name: sp.style.withLook(c, name)
      d.setText(L, t)

proc renameStyle*(d: Doc; paragraph: bool; old, name: string) =
  ## A style called `name` now, in the list and in every text that has it.
  if name.len == 0 or old == name: return
  if paragraph:
    let k = d.paraStyles.styleIndex(old)
    if k < 0 or d.paraStyles.styleIndex(name) >= 0: return
    d.paraStyles[k].name = name
  else:
    let k = d.charStyles.styleIndex(old)
    if k < 0 or d.charStyles.styleIndex(name) >= 0: return
    d.charStyles[k].name = name
  for L in d.layers:
    if not L.isText: continue
    if paragraph and L.text.para.styleName == old: L.text.para.styleName = name
    elif not paragraph:
      for sp in L.text.spans.mitems:
        if sp.style.styleName == old: sp.style.styleName = name

proc deleteStyle*(d: Doc; paragraph: bool; name: string) =
  ## A style taken away: the texts that had it keep their look.
  if paragraph:
    let k = d.paraStyles.styleIndex(name)
    if k >= 0: d.paraStyles.delete(k)
  else:
    let k = d.charStyles.styleIndex(name)
    if k >= 0: d.charStyles.delete(k)
  for L in d.layers:
    if not L.isText: continue
    if paragraph and L.text.para.styleName == name: L.text.para.styleName = ""
    elif not paragraph:
      for sp in L.text.spans.mitems:
        if sp.style.styleName == name: sp.style.styleName = ""

proc styleOverridden*(d: Doc; L: Layer; paragraph: bool): bool =
  ## The text differs from the style it has (shown with a "+").
  if not L.isText: return false
  if paragraph:
    let k = d.paraStyles.styleIndex(L.text.para.styleName)
    if k < 0: return false
    var p = L.text.para
    p.styleName = ""
    return p != d.paraStyles[k].para
  for sp in L.text.spans:
    let k = d.charStyles.styleIndex(sp.style.styleName)
    if k < 0: continue
    var c = sp.style
    c.styleName = ""
    if c != d.charStyles[k].char: return true
  false

proc rasterizeText*(d: Doc; L: Layer) =
  ## Layer > Rasterize > Type: the text stays as pixels and can no longer
  ## be edited (undoable in a step: `touchLayers` first).
  L.text = TextData()
  L.textBox = (0, 0, 0, 0)
  inc L.ver

# ---- shape layers ----------------------------------------------------------------------------------------

proc canvasPath*(w, h: int): Path =
  ## A rectangle as big as the canvas (a fill layer's outline).
  var sp = SubPath(closed: true)
  for (x, y) in [(0.0, 0.0), (w.float, 0.0), (w.float, h.float), (0.0, h.float)]:
    sp.pts.add PathPoint(p: (x, y), inH: (x, y), outH: (x, y))
  Path(subs: @[sp])

proc gradientColor*(stops: openArray[GradientStop]; t: float): uint32 =
  ## The color (with its opacity) at `t` (0..1) of a gradient through
  ## `stops` (in order) -- each pair's midpoint kept.
  if stops.len == 0: return 0
  if t <= stops[0].at: return stops[0].color
  for k in 1 .. stops.high:
    if t <= stops[k].at:
      let a = stops[k - 1]
      let b = stops[k]
      let span = b.at - a.at
      if span <= 1e-9: return b.color
      var u = (t - a.at) / span
      let m = if a.mid <= 0.001 or a.mid >= 0.999: 0.5 else: a.mid
      if abs(m - 0.5) > 1e-6 and u > 0: u = pow(u, ln(0.5) / ln(m))
      return mix(a.color, b.color, u)
  stops[^1].color

proc isFill*(L: Layer): bool {.inline.} =
  ## A fill layer (Layer > New Fill Layer): a color, gradient or pattern
  ## filling all of it (its mask its shape).
  L != nil and L.shape.kind == "Fill" and L.shape.path.subs.len > 0

proc drawShape*(d: Doc; L: Layer) =
  ## A shape layer's pixels made again from its shape (after it changed).
  if not L.isShape or L.px.len != d.w * d.h or shapeRender == nil: return
  if L.isFill: L.shape.path = canvasPath(d.w, d.h)     # (a fill layer: all of the canvas)
  let old = L.shapeBox
  let b = shapeRender(d.w, d.h, L)
  L.shapeBox = b
  inc L.ver
  if old.x1 > old.x0 and old.y1 > old.y0:
    d.markDirty(rect(old.x0, old.y0, old.x1 - old.x0, old.y1 - old.y0))
  else: d.markDirty(d.bounds)
  if b.x1 > b.x0: d.markDirty(rect(b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0))

proc drawVector*(d: Doc; L: Layer) =
  ## A type or shape layer drawn again.
  if L.isText: d.drawText(L)
  elif L.isShape: d.drawShape(L)

proc shapeArea*(L: Layer): Rect =
  ## Where a shape layer's pixels are (empty when not known).
  let b = L.shapeBox
  if L.isShape and b.x1 > b.x0 and b.y1 > b.y0: rect(b.x0, b.y0, b.x1 - b.x0, b.y1 - b.y0)
  else: rect(0, 0, 0, 0)

proc setShape*(d: Doc; L: Layer; s: ShapeData) =
  ## A shape layer's shape changed (undoable in a step: `touchLayers`
  ## first).
  L.shape = s
  d.drawShape(L)

proc rasterizeShape*(d: Doc; L: Layer) =
  ## Layer > Rasterize > Shape: the shape stays as pixels.
  L.shape = ShapeData()
  L.shapeBox = (0, 0, 0, 0)
  inc L.ver

proc mapPoints*(p: var Path; f: proc (x, y: float): (float, float)) =
  ## Every point and handle of `p` moved by `f`.
  for s in p.subs.mitems:
    for q in s.pts.mitems:
      q.p = f(q.p[0], q.p[1])
      q.inH = f(q.inH[0], q.inH[1])
      q.outH = f(q.outH[0], q.outH[1])

proc mapShape*(d: Doc; L: Layer; f: proc (x, y: float): (float, float); scale = 1.0) =
  ## A shape layer's outline moved by `f` (its stroke `scale`d); drawn
  ## again.
  if not L.isShape: return
  L.shape.path.mapPoints(f)
  L.shape.strokeWidth *= scale
  L.shape.radius *= scale
  L.shapeBox = (0, 0, 0, 0)

# ---- the composite --------------------------------------------------------------------------------

{.push boundChecks: off, overflowChecks: off.}

proc channelTables(lut: seq[uint32]): seq[uint8] =
  ## An adjustment's table as three tables of 256, red green blue, when
  ## each channel it gives follows its own channel alone (Curves, Levels,
  ## Brightness/Contrast, ...): read as `lutAt` reads between the colors,
  ## to the same numbers. Empty when the channels mix.
  const n = LutN - 1
  if lut.len != LutN * LutN * LutN: return
  template at(i, j, k: int): uint32 = lut[(i * LutN + j) * LutN + k]
  for i in 0 ..< LutN:
    for j in 0 ..< LutN:
      for k in 0 ..< LutN:
        let v = at(i, j, k)
        if ((v xor at(i, 0, 0)) and 0xFF0000'u32) != 0 or ((v xor at(0, j, 0)) and 0xFF00'u32) != 0 or
           ((v xor at(0, 0, k)) and 0xFF'u32) != 0: return
  result = newSeq[uint8](768)
  for c in 0 .. 2:
    let sh = 16 - 8 * c
    template f(i: int): int =
      int((at((if c == 0: i else: 0), (if c == 1: i else: 0), (if c == 2: i else: 0)) shr sh) and 255)
    for x in 0 .. 255:
      let xi = x * n div 255
      let xf = x * n - xi * 255
      let x1 = min(xi + 1, n)
      # (in 64 bits: 255^4 is past what a 32-bit int holds)
      result[c * 256 + x] = uint8((int64(f(xi)) * (255 - xf) * 65025 + int64(f(x1)) * xf * 65025 +
                                   255 * 255 * 255 div 2) div (255 * 255 * 255))

proc ensureLut(L: Layer): bool =
  ## An adjustment layer's table, made when its settings changed.
  if L.adjust.kind.len == 0 or adjustmentLut == nil: return false
  let key = L.adjust.kind & $L.adjust.args & "/" & $L.adjust.data.len & "/" & $hash(L.adjust.data)
  if L.lut.len != LutN * LutN * LutN or L.lutKey != key:
    L.lut = adjustmentLut(L.adjust)
    L.lutKey = key
    L.lut1 = channelTables(L.lut)
  L.lut.len == LutN * LutN * LutN

proc lutOf*(L: Layer): ptr seq[uint32] =
  ## An adjustment layer's table of colors (`LutN`^3, red slowest), made
  ## when its settings changed; nil when it has none.
  if not ensureLut(L): return nil
  addr L.lut

proc lutAt(lut: ptr UncheckedArray[uint32]; p: uint32): uint32 {.inline.} =
  ## The color `p` becomes by the table (read between its colors).
  const n = LutN - 1
  let r = int((p shr 16) and 255) * n
  let g = int((p shr 8) and 255) * n
  let b = int(p and 255) * n
  let ri = r div 255
  let gi = g div 255
  let bi = b div 255
  let rf = r - ri * 255
  let gf = g - gi * 255
  let bf = b - bi * 255
  let r1 = min(ri + 1, n)
  let g1 = min(gi + 1, n)
  let b1 = min(bi + 1, n)
  template at(i, j, k: int): uint32 = lut[(i * LutN + j) * LutN + k]
  var o: array[3, int]
  for c in 0 .. 2:
    let sh = 16 - 8 * c
    template v(i, j, k: int): int = int((at(i, j, k) shr sh) and 255)
    let c00 = v(ri, gi, bi) * (255 - bf) + v(ri, gi, b1) * bf
    let c01 = v(ri, g1, bi) * (255 - bf) + v(ri, g1, b1) * bf
    let c10 = v(r1, gi, bi) * (255 - bf) + v(r1, gi, b1) * bf
    let c11 = v(r1, g1, bi) * (255 - bf) + v(r1, g1, b1) * bf
    let c0 = c00 * (255 - gf) + c01 * gf
    let c1 = c10 * (255 - gf) + c11 * gf
    o[c] = int((int64(c0) * (255 - rf) + int64(c1) * rf + 255 * 255 * 255 div 2) div (255 * 255 * 255))
  (p and 0xFF000000'u32) or (uint32(o[0]) shl 16) or (uint32(o[1]) shl 8) or uint32(o[2])

type PlanePtr = object
  a: ptr UncheckedArray[uint8]
  colors: ptr UncheckedArray[uint32]
  color: uint32
  mode: BlendMode
  opacity: int
  quick: bool                        # (Normal or a mode of channels alone: `overOpaque` on opaque pixels)
  lut: ptr UncheckedArray[uint8]     # (that mode's table)

proc planePtr(p: FxPlane): PlanePtr =
  PlanePtr(a: (if p.a.len > 0: cast[ptr UncheckedArray[uint8]](unsafeAddr p.a[0]) else: nil),
           colors: (if p.colors.len > 0: cast[ptr UncheckedArray[uint32]](unsafeAddr p.colors[0]) else: nil),
           color: p.color, mode: p.mode, opacity: p.opacity,
           quick: p.mode == bmNormal or p.mode in SepModes, lut: sepLut(p.mode))

proc drawPlane(tp: ptr UncheckedArray[uint32]; y: int; c, fr: Rect; pl: PlanePtr; op: int;
               bp: ptr UncheckedArray[uint32] = nil; bm: ptr UncheckedArray[uint32] = nil;
               baseLut = false; brow: ptr UncheckedArray[uint32] = nil) {.inline.} =
  ## One effect blended into row `y` (`tp[x]`, in `c`); a clipped layer's
  ## only where its base (`bp`, its mask `bm`: that row's, `[x]`) is.
  if pl.a == nil: return
  let x0 = max(c.x, fr.x)
  let x1 = min(c.x + c.w, fr.x + fr.w)
  let prow = (y - fr.y) * fr.w - fr.x
  let k = pl.opacity * op
  for x in x0 ..< x1:
    let v = int(pl.a[prow + x])
    if v == 0: continue
    var a = v * k div (255 * 255)
    if brow != nil: a = a * int(brow[x]) div 255
    elif bp != nil:
      var ba = int(bp[x] shr 24)
      if baseLut: ba = int((bp[x] shr 16) and 255) * ba div 255
      if bm != nil: ba = ba * int((bm[x] shr 16) and 255) div 255
      a = a * ba div 255
    if a <= 0: continue
    let col = if pl.colors != nil: pl.colors[prow + x] else: pl.color
    let d0 = tp[x]
    if pl.quick and (d0 shr 24) == 255: tp[x] = overOpaque(d0, col, a, pl.lut)
    else: tp[x] = blendPx(d0, col or 0xFF000000'u32, a, pl.mode, x, y)

proc drawPlaneAt(tp: ptr UncheckedArray[uint32]; xs: ptr UncheckedArray[int32]; ow, iy: int; fr: Rect;
                 pl: PlanePtr; op: int; bp, bm: ptr UncheckedArray[uint32]; baseLut: bool;
                 brow: ptr UncheckedArray[uint32]; dx, dy: int) {.inline.} =
  ## `drawPlane` for a row of points (`xs`: their image columns, `iy` their
  ## image row), the effect moved by `dx`, `dy`.
  if pl.a == nil: return
  let py = iy - dy - fr.y
  if py < 0 or py >= fr.h: return
  let prow = py * fr.w
  let k = pl.opacity * op
  for x in 0 ..< ow:
    let ix = int(xs[x])
    if ix < 0: continue
    let px = ix - dx - fr.x
    if px < 0 or px >= fr.w: continue
    let v = int(pl.a[prow + px])
    if v == 0: continue
    var a = v * k div (255 * 255)
    if brow != nil: a = a * int(brow[x]) div 255
    elif bp != nil:
      var ba = int(bp[x] shr 24)
      if baseLut: ba = int((bp[x] shr 16) and 255) * ba div 255
      if bm != nil: ba = ba * int((bm[x] shr 16) and 255) div 255
      a = a * ba div 255
    if a <= 0: continue
    let col = if pl.colors != nil: pl.colors[prow + px] else: pl.color
    let d0 = tp[x]
    if pl.quick and (d0 shr 24) == 255: tp[x] = overOpaque(d0, col, a, pl.lut)
    else: tp[x] = blendPx(d0, col or 0xFF000000'u32, a, pl.mode, ix, iy)

proc fxKeyOf(d: Doc; L: Layer): string =
  result = $L.fx & "/" & $L.ver & "/" & $d.w & "x" & $d.h
  if L.mask != nil and not L.maskOff: result.add "/m" & $L.mask.ver & "/" & $cast[int](L.mask)

proc ensureFx(d: Doc; L: Layer): FxRender =
  ## A layer's effects, made again when it or they changed.
  if layerFxRender == nil: return nil
  let key = d.fxKeyOf(L)
  if L.fxCache == nil or L.fxKey != key:
    L.fxCache = layerFxRender(d.w, d.h, L)
    L.fxKey = key
  L.fxCache

proc blurMask*(m: var seq[uint8]; w, h: int; radius: float)
  ## A gaussian blur of a mask (feathering): three box blurs, on all the
  ## cores.

proc maskOf(L: Layer; w, h: int): ptr UncheckedArray[uint32] =
  ## A layer's mask as it is used -- feathered, less dense (made again when
  ## it changed) -- or nil.
  let m = L.mask
  if m == nil or L.maskOff or m.px.len != L.px.len: return nil
  if L.maskClear == 0 and L.maskFeather <= 0.05:
    if L.maskEff.len > 0:
      L.maskEff = @[]
      L.maskEffKey = ""
    return pixPtr(m.px)
  let key = $m.ver & "/" & $cast[int](m) & "/" & $L.maskClear & "/" & $L.maskFeather & "/" & $m.px.len
  if L.maskEffKey != key or L.maskEff.len != m.px.len:
    L.maskEff = m.px
    if L.maskFeather > 0.05 and w * h == m.px.len:
      var g = newSeqUninit[uint8](m.px.len)
      let ep = pixPtr(L.maskEff)
      let gp = cast[ptr UncheckedArray[uint8]](addr g[0])
      parallelFor(g.len, proc (a, b: int) =
        for i in a ..< b: gp[i] = uint8((ep[i] shr 16) and 255), grain = 65536)
      blurMask(g, w, h, L.maskFeather)
      parallelFor(g.len, proc (a, b: int) =
        for i in a ..< b:
          let v = uint32(gp[i])
          ep[i] = 0xFF000000'u32 or (v shl 16) or (v shl 8) or v, grain = 65536)
    if L.maskClear > 0:
      let lo = L.maskClear * 255 div 100
      let ep = pixPtr(L.maskEff)
      parallelFor(L.maskEff.len, proc (a, b: int) =
        for i in a ..< b:
          let v = int((ep[i] shr 16) and 255)
          let o = lo + v * (255 - lo) div 255
          ep[i] = 0xFF000000'u32 or (uint32(o) shl 16) or (uint32(o) shl 8) or uint32(o), grain = 65536)
    L.maskEffKey = key
  pixPtr(L.maskEff)

proc lerpPx(a, b: uint32; t: int): uint32 {.inline.} =
  ## Between two pixels (`t` 0: `a` .. 255: `b`), their colors weighed by
  ## their alpha.
  if t >= 255: return b
  if t <= 0: return a
  let aa = int(a shr 24) * (255 - t)
  let ba = int(b shr 24) * t
  let al = aa + ba
  if al == 0: return 0
  var o = uint32((al + 127) div 255) shl 24
  for sh in [16, 8, 0]:
    let v = (int((a shr sh) and 255) * aa + int((b shr sh) and 255) * ba + al div 2) div al
    o = o or (uint32(v) shl sh)
  o

type
  CKind = enum ckLayer, ckPush, ckPop
  CItem = object
    ## (one step of the composite: a layer, or a group begun or ended)
    kind: CKind
    src, mask, lut: ptr UncheckedArray[uint32]
    lut1: ptr UncheckedArray[uint8]   # (the table by channels, when it has one)
    filt: bool                  # an adjustment layer that looks at the pixels around (Clarity,
                                # Grain): done between the steps (`compositeInto`)
    fl: pointer                 # (... its layer)
    op, fill: int
    mode: BlendMode
    fxr: Rect
    below, above: seq[PlanePtr]
    base: int                   # a clipped layer's base (an item), -1 none
    bif: bool
    ch: int
    this, under: array[4, int]
    isolated: bool              # a group mixed on its own, then onto what is under it
    level: int                  # (a group's) the level of its layers
    cov: bool                   # (a group's) how much it covers is kept: layers are clipped to it
    pair: int                   # (a group's end) its beginning
    live, maskLive: int         # (a sampled composite) the live part it and its mask are shown by, -1 none
    fxDx, fxDy: int             # (... ) its effects moved along with it

proc parentsOf*(layers: seq[Layer]): seq[int] =
  ## For each layer the group it is in (an index; -1 none) -- by their
  ## depths, the top first.
  result = newSeq[int](layers.len)
  var stack: seq[int]
  for i in countdown(layers.high, 0):
    let dd = layers[i].depth
    while stack.len > 0 and layers[stack[^1]].depth >= dd: stack.setLen(stack.len - 1)
    result[i] = if stack.len > 0: stack[^1] else: -1
    if layers[i].group: stack.add i

proc liveIndex(d: Doc; L: Layer): int =
  ## (the live part `L` is shown by, -1 none)
  if L != nil:
    for i in 0 ..< d.live.len:
      if d.live[i].layer == L: return i
  -1

proc compositeItems(d: Doc; layers: seq[Layer]; sampled: bool): tuple[items: seq[CItem]; maxDepth: int] =
  ## (the visible `layers` as the steps of the composite: plain data for the
  ## cores -- no references are touched while they work; `sampled`: the
  ## live parts shown)
  var items: seq[CItem]
  let parents = parentsOf(layers)
  type Level = object
    g: int                    # the group (index in `layers`)
    shown: bool               # (a hidden group: nothing in it is mixed)
    base: int
    baseShown, first: bool
    push: int                 # (its beginning: an item)
  var open: seq[Level]
  var base = -1
  var baseShown = false
  var first = true
  var hidden = 0
  var maxDepth = 0
  proc isShown(L: Layer): bool = L.visible and L.opacity > 0
  template beginGroup(gi: int) =
    let G = layers[gi]
    let sh = hidden == 0 and isShown(G)
    open.add Level(g: gi, shown: sh, base: base, baseShown: baseShown, first: first)
    if sh:
      items.add CItem(kind: ckPush, isolated: not G.passThrough, level: open.len, base: -1, live: -1,
                      maskLive: -1)
      open[^1].push = items.high
      maxDepth = max(maxDepth, open.len)
    else: inc hidden
    base = -1
    baseShown = false
    first = true
  template endGroup() =
    let lv = open.pop()
    let G = layers[lv.g]
    base = -1
    if lv.shown:
      items.add CItem(kind: ckPop, isolated: not G.passThrough, op: G.opacity * 255 div 100,
                      mode: G.mode, mask: maskOf(G, d.w, d.h), base: -1, level: open.len + 1,
                      pair: lv.push, live: -1,
                      maskLive: (if sampled and not G.maskOff: d.liveIndex(G.mask) else: -1))
      base = items.high                 # (the layers clipped to it: by what it covers)
    else: dec hidden
    baseShown = lv.shown
    first = false
  for i, L in layers:
    # the groups it is in, begun
    var chain: seq[int]
    var par = parents[i]
    while par >= 0:
      chain.add par
      par = parents[par]
    chain.reverse()
    if L.group: chain.add i              # (its own: begun with its first layer, or now when empty)
    var k = 0
    while k < open.len and k < chain.len and open[k].g == chain[k]: inc k
    while open.len > k: endGroup()       # (not in them: their headers missing from `layers`)
    for j in k ..< chain.len: beginGroup(chain[j])
    if L.group:
      endGroup()
      continue
    if hidden > 0: continue
    let shown = isShown(L) and L.px.len == d.w * d.h
    if L.clipped and not first:
      if not baseShown: continue        # (its base is hidden: so is it)
    else:
      baseShown = shown
      base = -1
    first = false
    if not shown: continue
    var lut: ptr UncheckedArray[uint32] = nil
    let filt = L.adjust.kind in AreaAdjustKinds
    if L.adjust.kind.len > 0 and not filt:
      if not ensureLut(L): continue
      lut = pixPtr(L.lut)
    var it = CItem(kind: ckLayer, src: pixPtr(L.px), mask: maskOf(L, d.w, d.h), lut: lut, filt: filt,
                   fl: (if filt: cast[pointer](L) else: nil),
                   lut1: (if lut != nil and L.lut1.len == 768: cast[ptr UncheckedArray[uint8]](addr L.lut1[0])
                          else: nil),
                   op: L.opacity * 255 div 100, fill: L.fill * 255 div 100, mode: L.mode,
                   live: (if sampled: d.liveIndex(L) else: -1),
                   maskLive: (if sampled and not L.maskOff: d.liveIndex(L.mask) else: -1))
    if L.clipped and base >= 0:
      it.base = base
      if items[base].kind == ckPop:
        items[base].cov = true
        items[items[base].pair].cov = true
    else:
      it.base = -1
      base = items.len
    if L.blendIf.isOn:
      it.bif = true
      it.ch = L.blendIf.channel
      it.this = rangeOf(L.blendIf.this)
      it.under = rangeOf(L.blendIf.under)
    if lut == nil and not filt and L.hasFx and not (it.live >= 0 and d.live[it.live].kind == lkWarp):
      if it.live >= 0 and d.live[it.live].kind == lkShift:
        it.fxDx = d.live[it.live].dx      # (its effects go with it)
        it.fxDy = d.live[it.live].dy
      let fr = d.ensureFx(L)
      if fr != nil:
        it.fxr = fr.r
        for p in fr.below: it.below.add planePtr(p)
        for p in fr.above: it.above.add planePtr(p)
    items.add it
  while open.len > 0: endGroup()
  (items, maxDepth)

proc gatherRow(src: ptr UncheckedArray[uint32]; w, iy: int; xs: ptr UncheckedArray[int32]; n: int;
               o: ptr UncheckedArray[uint32]) {.inline.} =
  ## (the pixels of `src` at `xs` along image row `iy`; 0 off the image)
  let row = iy * w
  for x in 0 ..< n:
    let ix = int(xs[x])
    o[x] = if ix < 0: 0'u32 else: src[row + ix]

proc bilinearAt(src: ptr UncheckedArray[uint32]; sw, sh: int; sx, sy: float; stride = 0): uint32 {.inline.} =
  ## `src` (`sw` x `sh`, rows `stride` apart: 0 `sw`) read between its
  ## pixels at `sx`, `sy` (their colors weighed by their alpha; nothing
  ## outside it).
  let st = if stride > 0: stride else: sw
  let fx = floor(sx)
  let fy = floor(sy)
  let x0 = int(fx)
  let y0 = int(fy)
  let tx = int((sx - fx) * 256)
  let ty = int((sy - fy) * 256)
  template at(px, py: int): uint32 =
    (if px < 0 or py < 0 or px >= sw or py >= sh: 0'u32 else: src[py * st + px])
  # (64-bit sums: a color times its weight passes 2^31)
  var a, r, g, b = 0'i64
  for (ddx, ddy, wt) in [(0, 0, (256 - tx) * (256 - ty)), (1, 0, tx * (256 - ty)),
                         (0, 1, (256 - tx) * ty), (1, 1, tx * ty)]:
    if wt == 0: continue
    let p = at(x0 + ddx, y0 + ddy)
    let pa = int64(p shr 24) * int64(wt)
    if pa == 0: continue
    a += pa
    r += int64((p shr 16) and 255) * pa
    g += int64((p shr 8) and 255) * pa
    b += int64(p and 255) * pa
  if a < 32768: return 0
  (uint32((a + 32768) shr 16) shl 24) or (uint32(r div a) shl 16) or (uint32(g div a) shl 8) or uint32(b div a)

proc bilinearFix(src: ptr UncheckedArray[uint32]; sw, sh, st: int; sxF, syF: int64): uint32 {.inline.} =
  ## `bilinearAt` at 32.32 fixed-point `sxF`, `syF` (rows `st` apart): four
  ## opaque pixels mixed side by side in integers -- a photo turned or
  ## scaled quickly. (64 bits on every system: 32-bit ones too)
  let x0 = int(ashr(sxF, 32))
  let y0 = int(ashr(syF, 32))
  let tx = int((sxF shr 24) and 255)
  let ty = int((syF shr 24) and 255)
  if x0 >= 0 and y0 >= 0 and x0 + 1 < sw and y0 + 1 < sh:
    let i = y0 * st + x0
    let p00 = src[i]
    let p10 = src[i + 1]
    let p01 = src[i + st]
    let p11 = src[i + st + 1]
    if (p00 and p10 and p01 and p11) >= 0xFF000000'u32:
      let w00 = uint64((256 - tx) * (256 - ty))
      let w10 = uint64(tx * (256 - ty))
      let w01 = uint64((256 - tx) * ty)
      let w11 = uint64(tx * ty)
      template rb(p: uint32): uint64 = uint64(p and 0xFF'u32) or (uint64(p and 0xFF0000'u32) shl 16)
      template gg(p: uint32): uint64 = uint64((p shr 8) and 0xFF'u32)
      let srb = rb(p00) * w00 + rb(p10) * w10 + rb(p01) * w01 + rb(p11) * w11
      let sg = gg(p00) * w00 + gg(p10) * w10 + gg(p01) * w01 + gg(p11) * w11
      return 0xFF000000'u32 or (uint32((srb shr 48) and 255) shl 16) or (uint32((sg shr 16) and 255) shl 8) or
             uint32((srb shr 16) and 255)
  # (at the edges, or with transparency: weighed by alpha)
  var a, r, g, b = 0'i64
  for (ddx, ddy, wt) in [(0, 0, (256 - tx) * (256 - ty)), (1, 0, tx * (256 - ty)),
                         (0, 1, (256 - tx) * ty), (1, 1, tx * ty)]:
    if wt == 0: continue
    let px = x0 + ddx
    let py = y0 + ddy
    if px < 0 or py < 0 or px >= sw or py >= sh: continue
    let p = src[py * st + px]
    let pa = int64(p shr 24) * int64(wt)
    if pa == 0: continue
    a += pa
    r += int64((p shr 16) and 255) * pa
    g += int64((p shr 8) and 255) * pa
    b += int64(p and 255) * pa
  if a < 32768: return 0
  (uint32((a + 32768) shr 16) shl 24) or (uint32(r div a) shl 16) or (uint32(g div a) shl 8) or uint32(b div a)

proc liveRow(lp: ptr LivePlain; w, h, iy, oy, ow: int; xs: ptr UncheckedArray[int32];
             own: ptr UncheckedArray[uint32]; o: ptr UncheckedArray[uint32]) =
  ## (a live part's pixels along output row `oy`, image row `iy`: `o[x]`;
  ## `own` the layer's own pixels)
  case lp.kind
  of lkShift:
    let sy = iy - lp.dy
    let inRow = sy >= 0 and sy < h
    for x in 0 ..< ow:
      let ix = int(xs[x])
      if ix < 0:
        o[x] = 0
        continue
      let b = if lp.base != nil: lp.base[iy * w + ix] else: lp.baseFill
      let sx = ix - lp.dx
      if inRow and sx >= 0 and sx < w:
        let p = lp.src[sy * w + sx]
        o[x] = if lp.replace: p or 0xFF000000'u32
               elif (p shr 24) == 0: b
               elif (p shr 24) == 255: p
               else: blendPx(b, p, 255, bmNormal)
      else: o[x] = b
  of lkWarp:
    let fy = iy.float + 0.5
    let sw = lp.srcR.w
    let sh = lp.srcR.h
    let m = lp.inv
    for x in 0 ..< ow:
      let ix = int(xs[x])
      if ix < 0:
        o[x] = 0
        continue
      var b = if lp.base != nil: lp.base[iy * w + ix]
              elif lp.hole and not (ix >= lp.srcR.x and iy >= lp.srcR.y and ix < lp.srcR.x + lp.srcR.w and
                                    iy < lp.srcR.y + lp.srcR.h): own[iy * w + ix]
              else: lp.baseFill
      let fx = ix.float + 0.5
      let ww = m[6] * fx + m[7] * fy + m[8]
      if abs(ww) > 1e-12:
        let u = (m[0] * fx + m[1] * fy + m[2]) / ww
        let v = (m[3] * fx + m[4] * fy + m[5]) / ww
        if u >= -0.01 and v >= -0.01 and u <= 1.01 and v <= 1.01:
          let c = bilinearAt(lp.src, sw, sh, u * sw.float - 0.5, v * sh.float - 0.5, lp.stride)
          if (c shr 24) > 0: b = if lp.replace: c else: blendPx(b, c, 255, bmNormal)
      o[x] = b
  of lkMap:
    for x in 0 ..< ow:
      let ix = int(xs[x])
      if ix < 0:
        o[x] = 0
        continue
      let before = own[iy * w + ix]
      var after = lp.mapped[oy * ow + x]
      if lp.keepAlpha: after = (after and 0xFFFFFF'u32) or (before and 0xFF000000'u32)
      if lp.sel != nil:
        let k = int(lp.sel[iy * w + ix])
        o[x] = if k == 0: before elif k >= 255: after else: lerpPx(before, after, k)
      else: o[x] = after

proc mixLayers[S: static bool](items: var seq[CItem]; maxDepth: int; c: Rect; w, h: int;
                               dst: ptr UncheckedArray[uint32]; xs, ys: ptr UncheckedArray[int32];
                               lives: ptr UncheckedArray[LivePlain]; first = 0; last = -1; keep = false) =
  ## The composite's steps (`items`) mixed, rows `c` shared out among the
  ## cores: into the image's rows (`dst` as big as the image; `S` false), or
  ## (`S` true) into `dst` of `c.w` x `c.h` points, at image columns `xs`
  ## and rows `ys` (-1: off the image), the live parts as they are shown.
  let n = items.len
  let ip = cast[ptr UncheckedArray[CItem]](if n > 0: addr items[0] else: nil)
  let depthN = maxDepth
  # (the steps mixed: `first` ..< `last`; `keep`: over what `dst` has, not
  # from nothing)
  let k0 = clamp(first, 0, n)
  let k1 = if last < 0: n else: clamp(last, k0, n)
  # (each step's table of its mode, made here before the cores start)
  var luts = newSeq[ptr UncheckedArray[uint8]](max(1, n))
  for k in 0 ..< n:
    if items[k].kind != ckPush: luts[k] = sepLut(items[k].mode)
  let lutp = cast[ptr UncheckedArray[ptr UncheckedArray[uint8]]](addr luts[0])
  proc work(lo, hi: int) {.closure.} =
    # (a row for each group level, and a copy of what was under a group
    # mixing through, and how much a group covers -- for the layers clipped
    # to it)
    var bufs = newSeq[seq[uint32]](depthN + 1)
    var saved = newSeq[seq[uint32]](depthN + 1)
    var covs = newSeq[seq[uint32]](depthN + 1)
    var covOn = newSeq[bool](depthN + 1)
    for b in 1 .. depthN:
      bufs[b] = newSeqUninit[uint32](c.w)
      saved[b] = newSeqUninit[uint32](c.w)
      covs[b] = newSeqUninit[uint32](c.w)
    var tps = newSeq[ptr UncheckedArray[uint32]](depthN + 1)
    when S:
      # (each step's pixels along the row, and its mask's: gathered first)
      var gs = newSeqUninit[uint32](max(1, n * c.w))
      var gm = newSeqUninit[uint32](max(1, n * c.w))
      let gsp = cast[ptr UncheckedArray[uint32]](addr gs[0])
      let gmp = cast[ptr UncheckedArray[uint32]](addr gm[0])
    template rowOf(sq: seq[uint32]): ptr UncheckedArray[uint32] =
      ## (indexed by x, as the document's rows)
      cast[ptr UncheckedArray[uint32]](cast[uint](unsafeAddr sq[0]) - uint(c.x * 4))
    template at(p: ptr UncheckedArray[uint32]; i: int): ptr UncheckedArray[uint32] =
      cast[ptr UncheckedArray[uint32]](addr p[i])
    for yy in lo ..< hi:
      let y = c.y + yy
      when S:
        let iy = int(ys[y])
        let orow = y * c.w
        if not keep: zeroMem(addr dst[orow], c.w * 4)
        if iy < 0: continue
        tps[0] = at(dst, orow)
        for k in k0 ..< k1:
          let it = addr ip[k]
          if it.kind == ckPush: continue
          if it.kind == ckLayer:
            if it.live >= 0: liveRow(addr lives[it.live], w, h, iy, y, c.w, xs, it.src, at(gsp, k * c.w))
            else: gatherRow(it.src, w, iy, xs, c.w, at(gsp, k * c.w))
          if it.mask != nil:
            if it.maskLive >= 0: liveRow(addr lives[it.maskLive], w, h, iy, y, c.w, xs, it.mask, at(gmp, k * c.w))
            else: gatherRow(it.mask, w, iy, xs, c.w, at(gmp, k * c.w))
        template IX(x: int): int = int(xs[x])
        let IY = iy
      else:
        let row = y * w
        if not keep: zeroMem(addr dst[row + c.x], c.w * 4)
        tps[0] = at(dst, row)
        template IX(x: int): int = x
        let IY = y
      var lvl = 0
      var covers = 0                       # (the levels whose cover is kept)
      var bare = not keep                  # (nothing mixed into the row yet)
      template cover(x: int; a: int) =
        ## (`a` more covered at `x`, in the groups that keep it)
        if covers > 0 and a > 0:
          for l in 1 .. lvl:
            if covOn[l]:
              let cp = rowOf(covs[l])
              let cv = int(cp[x])
              cp[x] = uint32(cv + a * (255 - cv) div 255)
      for k in k0 ..< k1:
        template it: untyped = ip[k]
        # (its pixels and its mask's, indexed by x along this row)
        when S:
          let spr = at(gsp, k * c.w)
          let mpr = if it.mask != nil: at(gmp, k * c.w) else: nil
        else:
          let spr = if it.src != nil: at(it.src, row) else: nil
          let mpr = if it.mask != nil: at(it.mask, row) else: nil
        case it.kind
        of ckPush:
          let outer = tps[lvl]
          inc lvl
          if it.isolated:
            zeroMem(addr bufs[lvl][0], c.w * 4)
            tps[lvl] = rowOf(bufs[lvl])
            covOn[lvl] = false
          else:
            copyMem(addr saved[lvl][0], addr outer[c.x], c.w * 4)
            tps[lvl] = outer
            covOn[lvl] = it.cov
            if it.cov:
              zeroMem(addr covs[lvl][0], c.w * 4)
              inc covers
          continue
        of ckPop:
          let inner = tps[lvl]
          let sv = rowOf(saved[lvl])
          let gl = lvl
          if covOn[gl]:
            covOn[gl] = false
            dec covers
          dec lvl
          if lvl == 0: bare = false
          let outer = tps[lvl]
          let cp = rowOf(covs[gl])
          if it.isolated:
            let quickG = it.mode == bmNormal or it.mode in SepModes
            for x in c.x ..< c.x + c.w:
              let s = inner[x]
              var a = it.op
              if mpr != nil: a = a * int((mpr[x] shr 16) and 255) div 255
              let ea = a * int(s shr 24) div 255
              if it.cov: cp[x] = uint32(ea)
              if ea <= 0: continue
              let o0 = outer[x]
              if quickG and (o0 shr 24) == 255: outer[x] = overOpaque(o0, s, ea, lutp[k])
              else: outer[x] = blendPx(o0, s, a, it.mode, IX(x), IY)
              cover(x, ea)
          else:
            if it.op < 255 or mpr != nil:
              for x in c.x ..< c.x + c.w:
                var a = it.op
                if mpr != nil: a = a * int((mpr[x] shr 16) and 255) div 255
                outer[x] = lerpPx(sv[x], outer[x], a)
                if it.cov: cp[x] = uint32(int(cp[x]) * a div 255)
          continue
        of ckLayer:
          if it.filt: continue             # (in a group, or a preview: not done)
        let tp = tps[lvl]
        let lp = it.lut
        let l1 = it.lut1
        let op0 = it.op
        let m = it.mode
        let fxr = it.fxr
        when S:
          let styled = fxr.w > 0 and IY - it.fxDy >= fxr.y and IY - it.fxDy < fxr.y + fxr.h
        else:
          let styled = fxr.w > 0 and y >= fxr.y and y < fxr.y + fxr.h
        let op = op0 * it.fill div 255
        let bk = it.base
        let groupBase = bk >= 0 and ip[bk].kind == ckPop
        when S:
          let bp = if bk >= 0 and not groupBase: at(gsp, bk * c.w) else: nil
          let bm = if bk >= 0 and not groupBase and ip[bk].mask != nil: at(gmp, bk * c.w) else: nil
        else:
          let bp = if bk >= 0 and not groupBase: at(ip[bk].src, row) else: nil
          let bm = if bk >= 0 and not groupBase and ip[bk].mask != nil: at(ip[bk].mask, row) else: nil
        let brow = if groupBase: rowOf(covs[ip[bk].level]) else: nil
        let blut = bk >= 0 and not groupBase and ip[bk].lut != nil
        let bif = it.bif
        template clipAmt(a: int; x: int): int =
          ## (how much the base shows there)
          if brow != nil: a * int(brow[x]) div 255
          elif bp == nil: a
          else:
            var ba = int(bp[x] shr 24)
            if blut: ba = int((bp[x] shr 16) and 255) * ba div 255
            if bm != nil: ba = ba * int((bm[x] shr 16) and 255) div 255
            a * ba div 255
        template planes(list: untyped) =
          when S:
            for pl in list: drawPlaneAt(tp, xs, c.w, IY, fxr, pl, op0, bp, bm, blut, brow, it.fxDx, it.fxDy)
          else:
            for pl in list: drawPlane(tp, y, c, fxr, pl, op0, bp, bm, blut, brow)
        if styled: planes(it.below)
        if lp != nil:
          # an adjustment layer: what is under it, changed (where its mask lets)
          for x in c.x ..< c.x + c.w:
            let under = tp[x]
            if (under shr 24) == 0: continue
            let mk = spr[x]
            var amt = clipAmt(int((mk shr 16) and 255) * int(mk shr 24) div 255 * op div 255, x)
            if mpr != nil: amt = amt * int((mpr[x] shr 16) and 255) div 255
            if amt <= 0: continue
            let v = if l1 != nil: (under and 0xFF000000'u32) or (uint32(l1[int((under shr 16) and 255)]) shl 16) or
                                  (uint32(l1[256 + int((under shr 8) and 255)]) shl 8) or
                                  uint32(l1[512 + int(under and 255)])
                    else: lutAt(lp, under)
            if bif:
              amt = amt * rangeAmt(it.this, chanOf(v, it.ch)) div 255 *
                    rangeAmt(it.under, chanOf(under, it.ch)) div 255
              if amt <= 0: continue
            if m == bmNormal:
              if amt >= 255:
                tp[x] = v
              else:
                var o = under and 0xFF000000'u32
                for sh in [16, 8, 0]:
                  let a0 = int((under shr sh) and 255)
                  let b0 = int((v shr sh) and 255)
                  o = o or (uint32(a0 + ((b0 - a0) * amt + 127) div 255) shl sh)
                tp[x] = o
            elif m in SepModes:
              let res = overOpaque(under or 0xFF000000'u32, v, min(amt, 255), lutp[k])
              tp[x] = (under and 0xFF000000'u32) or (res and 0xFFFFFF'u32)
            else:
              let res = blendPx(under or 0xFF000000'u32, v or 0xFF000000'u32, amt, m, IX(x), IY)
              tp[x] = (under and 0xFF000000'u32) or (res and 0xFFFFFF'u32)
          continue
        let fast = m == bmNormal and op == 255 and mpr == nil and bp == nil and brow == nil and not bif
        if fast and bare and lvl == 0 and not styled:
          # (the first layer of the row, as it is: copied -- over nothing it
          # is itself)
          copyMem(addr tp[c.x], addr spr[c.x], c.w * 4)
          bare = false
          continue
        if lvl == 0: bare = false
        let quick = m == bmNormal or m in SepModes
        let sl = lutp[k]
        for x in c.x ..< c.x + c.w:
          let s = spr[x]
          if (s shr 24) == 0: continue
          if fast and (s shr 24) == 255:
            tp[x] = s
            cover(x, 255)
          else:
            var a = op
            if mpr != nil:
              let mk = mpr[x]
              a = a * int((mk shr 16) and 255) div 255
              if a <= 0: continue
            if bp != nil or brow != nil:
              a = clipAmt(a, x)
              if a <= 0: continue
            if bif:
              a = a * rangeAmt(it.this, chanOf(s, it.ch)) div 255 *
                  rangeAmt(it.under, chanOf(tp[x], it.ch)) div 255
              if a <= 0: continue
            let d0 = tp[x]
            if quick and (d0 shr 24) == 255:
              let ea = a * int(s shr 24) div 255
              if ea > 0: tp[x] = overOpaque(d0, s, ea, sl)
            else:
              tp[x] = blendPx(d0, s, a, m, IX(x), IY)
            cover(x, a * int(s shr 24) div 255)
        if styled: planes(it.above)
  parallelFor(c.h, work, keepAlive = not S)

# ---- adjustment layers that look around: Clarity, Grain ----------------------------------------------------

proc areaReach(d: Doc; L: Layer): int =
  ## (how far around a pixel the adjustment looks)
  if L.adjust.kind == "Clarity": clamp(min(d.w, d.h) div 80, 3, 60) * 3 else: 0

proc boxBlurPlane(p: ptr UncheckedArray[float32]; w, h, r: int) =
  ## (a box blur of a plane, `r` each side, in place: along the rows, then
  ## down the columns a band at a time; the edges repeated)
  if r <= 0 or w <= 0 or h <= 0: return
  let inv = 1'f32 / float32(2 * r + 1)
  parallelFor(h, proc (lo, hi: int) =
    var line = newSeqUninit[float32](w + 2 * r + 2)
    for y in lo ..< hi:
      let row = cast[ptr UncheckedArray[float32]](addr p[y * w])
      for i in 0 ..< w + 2 * r + 2: line[i] = row[clamp(i - r - 1, 0, w - 1)]
      var acc = 0'f32
      for i in 1 .. 2 * r + 1: acc += line[i]
      for i in 0 ..< w:
        row[i] = acc * inv
        acc += line[i + 2 * r + 2] - line[i + 1]
  , grain = 8)
  const Band = 64
  parallelFor((w + Band - 1) div Band, proc (lo, hi: int) =
    var col = newSeqUninit[float32]((h + 2 * r + 2) * Band)
    var acc = newSeqUninit[float32](Band)
    for band in lo ..< hi:
      let x0 = band * Band
      let bw = min(Band, w - x0)
      for j in 0 ..< h + 2 * r + 2:
        let sy = clamp(j - r - 1, 0, h - 1)
        for x in 0 ..< bw: col[j * bw + x] = p[sy * w + x0 + x]
      for x in 0 ..< bw: acc[x] = 0
      for k in 1 .. 2 * r + 1:
        for x in 0 ..< bw: acc[x] += col[k * bw + x]
      for y in 0 ..< h:
        for x in 0 ..< bw:
          p[y * w + x0 + x] = acc[x] * inv
          acc[x] += col[(y + 2 * r + 2) * bw + x] - col[(y + 1) * bw + x]
  )

var grainTiles {.threadvar.}: seq[tuple[key: string; t: seq[float32]]]

proc grainTile(size, rough, seed: int): seq[float32] =
  ## (256 x 256 of film grain that tiles: about -1..1; bigger with `size`,
  ## coarser with less `rough`ness)
  let key = $size & "/" & $rough & "/" & $seed
  for (k, t) in grainTiles:
    if k == key: return t
  const N = 256
  var a = newSeq[float32](N * N)
  for y in 0 ..< N:
    for x in 0 ..< N:
      a[y * N + x] = float32(int(hash2(x + seed * 7919, y) and 1023)) / 511.5'f32 - 1
  let r = size div 25
  if r > 0:
    # (smoothed with its own other side: it still tiles)
    var b = a
    for pass in 0 .. 1:
      for y in 0 ..< N:
        for x in 0 ..< N:
          var acc = 0'f32
          for k in -r .. r:
            acc += (if pass == 0: a[y * N + ((x + k + N) mod N)] else: a[((y + k + N) mod N) * N + x])
          b[y * N + x] = acc / float32(2 * r + 1)
      a = b
  # (roughness: the fine noise mixed back in)
  if r > 0 and rough > 0:
    for i in 0 ..< N * N:
      let fine = float32(int(hash2(i mod N + 31, i div N + seed) and 1023)) / 511.5'f32 - 1
      a[i] = a[i] * float32(100 - rough) / 100 + fine * float32(rough) / 100 * 0.6'f32
  var sum2 = 0.0
  for v in a: sum2 += float(v * v)
  let sd = sqrt(sum2 / float(N * N))
  if sd > 1e-6:
    for v in a.mitems: v = v / float32(sd) * 0.5'f32
  grainTiles.add (key, a)
  if grainTiles.len > 8: grainTiles.delete(0)
  a

proc applyAreaAdjust(d: Doc; L: Layer; op: int; dst: var seq[uint32]; c: Rect) =
  ## Clarity or Grain over what is under it in `c` (`dst`: the image's
  ## pixels so far), where its mask (its pixels) lets, `op` (0..255) of it.
  if op <= 0 or c.w <= 0 or c.h <= 0: return
  let w = d.w
  let dp = pixPtr(dst)
  let mp = pixPtr(L.px)
  let mk = if L.mask != nil and not L.maskOff and L.mask.px.len == L.px.len: pixPtr(L.mask.px) else: nil
  let args = L.adjust.args
  template arg(i: int; dflt: float): float = (if i < args.len: args[i] else: dflt)
  case L.adjust.kind
  of "Clarity":
    let amount = clamp(arg(0, 30), -100, 100) / 100 * 1.6
    if amount == 0: return
    let r = clamp(min(d.w, d.h) div 80, 3, 60)
    var y = newSeqUninit[float32](c.w * c.h)
    let yp = cast[ptr UncheckedArray[float32]](addr y[0])
    let cw = c.w
    let cx = c.x
    let cy = c.y
    parallelFor(c.h, proc (lo, hi: int) =
      for j in lo ..< hi:
        for i in 0 ..< cw:
          let p = dp[(cy + j) * w + cx + i]
          yp[j * cw + i] = float32(int((p shr 16) and 255) * 77 + int((p shr 8) and 255) * 150 +
                                   int(p and 255) * 29) / 256'f32
    , grain = 8)
    # (a copy of its own: `var b = y` would take `y`'s buffer -- `yp` still points there)
    var b = newSeqUninit[float32](y.len)
    copyMem(addr b[0], addr y[0], y.len * 4)
    let bp = cast[ptr UncheckedArray[float32]](addr b[0])
    for pass in 0 .. 2: boxBlurPlane(bp, c.w, c.h, r)
    let k = float32(amount)
    parallelFor(c.h, proc (lo, hi: int) =
      for j in lo ..< hi:
        for i in 0 ..< cw:
          let at = (cy + j) * w + cx + i
          var a = int((mp[at] shr 16) and 255) * int(mp[at] shr 24) div 255 * op div 255
          if mk != nil: a = a * int((mk[at] shr 16) and 255) div 255
          if a <= 0: continue
          let p = dp[at]
          if (p shr 24) == 0: continue
          let lum = yp[j * cw + i]
          let t = lum / 127.5'f32 - 1
          let wt = max(0'f32, 1 - t * t)            # (the midtones most)
          let nl = clamp(lum + k * (lum - bp[j * cw + i]) * wt, 0, 255)
          let f = if lum > 0.5: nl / lum else: 1'f32
          let add = if lum <= 0.5: nl else: 0'f32
          var o = p and 0xFF000000'u32
          for sh in [16, 8, 0]:
            let c0 = float32((p shr sh) and 255)
            let c1 = clamp(c0 * f + add, 0, 255)
            let v = int(c0 + (c1 - c0) * float32(a) / 255 + 0.5)
            o = o or (uint32(clamp(v, 0, 255)) shl sh)
          dp[at] = o
    , grain = 8)
  of "Grain":
    let amount = clamp(arg(0, 25), 0, 100)
    if amount <= 0: return
    let tile = grainTile(int(clamp(arg(1, 25), 0, 100)), int(clamp(arg(2, 50), 0, 100)), int(arg(3, 1)))
    let tp = cast[ptr UncheckedArray[float32]](unsafeAddr tile[0])
    let strength = float32(amount) / 100 * 70
    let cw = c.w
    let cx = c.x
    let cy = c.y
    parallelFor(c.h, proc (lo, hi: int) =
      for j in lo ..< hi:
        let yy = cy + j
        for i in 0 ..< cw:
          let xx = cx + i
          let at = yy * w + xx
          var a = int((mp[at] shr 16) and 255) * int(mp[at] shr 24) div 255 * op div 255
          if mk != nil: a = a * int((mk[at] shr 16) and 255) div 255
          if a <= 0: continue
          let p = dp[at]
          if (p shr 24) == 0: continue
          let lum = float32(int((p shr 16) and 255) * 77 + int((p shr 8) and 255) * 150 + int(p and 255) * 29) / 65280'f32
          let wt = 1 - 0.6'f32 * abs(lum * 2 - 1)       # (less in the deepest shadows and brightest lights)
          let n = tp[(yy and 255) * 256 + (xx and 255)] * strength * wt * float32(a) / 255
          var o = p and 0xFF000000'u32
          for sh in [16, 8, 0]:
            o = o or (uint32(clamp(int(float32((p shr sh) and 255) + n + 0.5), 0, 255)) shl sh)
          dp[at] = o
    , grain = 8)
  else: discard

proc compositeInto*(d: Doc; dst: var seq[uint32]; r: Rect; layers: seq[Layer]) =
  ## The visible `layers` mixed into `dst` (as big as the document) in `r`
  ## -- their masks, the adjustment layers, the groups -- the rows shared
  ## out among the cores.
  let c = d.clip(r)
  if c.w <= 0 or c.h <= 0: return
  var (items, maxDepth) = d.compositeItems(layers, false)
  # (Clarity, Grain: what is under them mixed first, then they look at it --
  # the room around too, as far as they reach -- then the rest over it)
  var cuts: seq[int]
  var lvl = 0
  var reach = 0
  for k, it in items:
    case it.kind
    of ckPush: inc lvl
    of ckPop: dec lvl
    of ckLayer:
      if it.filt and lvl == 0:
        cuts.add k
        reach += areaReach(d, cast[Layer](it.fl))
  if cuts.len == 0:
    mixLayers[false](items, maxDepth, c, d.w, d.h, pixPtr(dst), nil, nil, nil)
    return
  let c2 = d.clip(rect(c.x - reach, c.y - reach, c.w + 2 * reach, c.h + 2 * reach))
  var at = 0
  for i, k in cuts:
    mixLayers[false](items, maxDepth, c2, d.w, d.h, pixPtr(dst), nil, nil, nil, at, k, keep = i > 0)
    applyAreaAdjust(d, cast[Layer](items[k].fl), items[k].op * items[k].fill div 255, dst, c2)
    at = k + 1
  mixLayers[false](items, maxDepth, c2, d.w, d.h, pixPtr(dst), nil, nil, nil, at, -1, keep = true)

proc squareToQuad*(q: Quad): array[9, float]
  ## The projective map of the unit square onto `q` (Heckbert's).
proc inverse3*(m: array[9, float]): array[9, float]
  ## The inverse of a 3x3 matrix (row by row; identity when it has none).

proc compositeSampled*(d: Doc; xs, ys: seq[int32]; o: var seq[uint32]) =
  ## What the image looks like -- its `live` parts as they are being moved,
  ## turned or adjusted -- at the points `xs` x `ys` (image columns and
  ## rows; -1: off the image, transparent): a view's pixels made straight
  ## from the layers, nothing done to the whole image. How a big photo is
  ## shown while something on it is dragged.
  let ow = xs.len
  let oh = ys.len
  o.setLen(ow * oh)
  if ow == 0 or oh == 0: return
  var (items, maxDepth) = d.compositeItems(d.layers, true)
  var lives = newSeq[LivePlain](max(1, d.live.len))
  var mapped = newSeq[seq[uint32]](d.live.len)
  let xp = cast[ptr UncheckedArray[int32]](unsafeAddr xs[0])
  let yp = cast[ptr UncheckedArray[int32]](unsafeAddr ys[0])
  for i, p in d.live:
    var lp = LivePlain(kind: p.kind, base: p.base, baseFill: p.baseFill, src: p.src, srcR: p.srcR,
                       dx: p.dx, dy: p.dy, replace: p.replace, keepAlpha: p.keepAlpha,
                       stride: p.srcStride, hole: p.hole)
    if p.kind == lkWarp: lp.inv = inverse3(squareToQuad(p.quad))
    if p.kind == lkMap and p.layer != nil and p.layer.px.len == d.w * d.h:
      # (the layer at the points, changed as one small picture: a change of
      # each pixel by itself looks the same at any size)
      mapped[i] = newSeqUninit[uint32](ow * oh)
      let mp = pixPtr(mapped[i])
      let lpx = pixPtr(p.layer.px)
      let w = d.w
      parallelFor(oh, proc (a, b: int) =
        for y in a ..< b:
          let iy = int(yp[y])
          if iy < 0:
            zeroMem(addr mp[y * ow], ow * 4)
          else:
            gatherRow(lpx, w, iy, xp, ow, cast[ptr UncheckedArray[uint32]](addr mp[y * ow])), keepAlive = false)
      if p.map != nil: p.map(mapped[i], ow, oh)
      lp.mapped = pixPtr(mapped[i])
      if d.sel.len == d.w * d.h: lp.sel = cast[ptr UncheckedArray[uint8]](addr d.sel[0])
    lives[i] = lp
  mixLayers[true](items, maxDepth, rect(0, 0, ow, oh), d.w, d.h, pixPtr(o), xp, yp,
                  cast[ptr UncheckedArray[LivePlain]](addr lives[0]))

{.pop.}

proc simpleLayer*(d: Doc): Layer =
  ## The layer the image is when it shows just that one as it is (one
  ## visible layer: Normal, 100 %, no mask, style or adjustment): its pixels
  ## are what the image looks like, and no copy of them is kept (`comp` is
  ## then empty: read `compPtr`). nil when the image is a mix of layers.
  for L in d.layers:
    if L.group: return nil
  # (the layer found is kept in a local, not in `result`: Nim 2.2's `return
  # nil` over a `result` already set leaves that layer counted once more,
  # and it was never freed)
  var one: Layer = nil
  for L in d.layers:
    if not L.visible: continue
    if one != nil: return nil
    if L.blendIf.isOn: return nil
    if L.opacity != 100 or L.clearFill != 0 or L.mode != bmNormal or L.adjust.kind.len > 0 or
       (L.mask != nil and not L.maskOff) or L.px.len != d.w * d.h or L.hasFx or L.clipped:
      return nil
    one = L
  one

proc compPtr*(d: Doc): ptr UncheckedArray[uint32] =
  ## What the image looks like (after `updateComposite`): `comp`, or the
  ## pixels of its one plain layer.
  let s = d.simpleLayer
  if s != nil: pixPtr(s.px)
  elif d.comp.len == d.w * d.h: pixPtr(d.comp)
  else: nil

var gpuCompositeHook*: proc (d: Doc; r: Rect): bool {.nimcall.}
  ## Makes `comp` in `r` some other way -- the layers mixed on the GPU (set
  ## by `retroui/photogpu`); false: not done there, the CPU does it.

proc updateComposite*(d: Doc) =
  ## Makes what the image looks like again where it is out of date (`comp`;
  ## nothing for an image of one plain layer: see `simpleLayer`).
  if d.simpleLayer != nil:
    # (one plain layer: it is the composite; only the smaller copies follow)
    if d.comp.len > 0: d.comp = @[]
    if d.dirty.w > 0 and d.dirty.h > 0:
      for r in d.mipDirty.mitems:
        r = if r.w <= 0: d.dirty else: union(r, d.dirty)
      d.dirty = rect(0, 0, 0, 0)
    for L in d.layers:
      if L.fxCache != nil and not L.hasFx:
        L.fxCache = nil
        L.fxKey = ""
    return
  if d.comp.len != d.w * d.h:
    d.comp = newSeq[uint32](d.w * d.h)
    d.dirty = d.bounds
    for r in d.mipDirty.mitems: r = d.bounds
  # (a layer style made again: where it was and where it is now are out of
  # date -- its shadow reaches past the pixels that changed; the views are
  # told too, or they keep the old shadow where the letters were)
  let wasModified = d.modified          # (drawing a style is not a change to save)
  for L in d.layers:
    let before = L.fxCache
    let shown = L.visible and L.hasFx and L.adjust.kind.len == 0 and L.px.len == d.w * d.h
    if shown:
      let now = d.ensureFx(L)
      if now != before:
        if before != nil and before.r.w > 0: d.markDirty(before.r)
        if now != nil and now.r.w > 0: d.markDirty(now.r)
    elif before != nil:
      if before.r.w > 0: d.markDirty(before.r)
      L.fxCache = nil
      L.fxKey = ""
  d.modified = wasModified
  if d.dirty.w <= 0 or d.dirty.h <= 0: return
  if gpuCompositeHook == nil or not gpuCompositeHook(d, d.dirty):
    d.compositeInto(d.comp, d.dirty, d.layers)
  for r in d.mipDirty.mitems:
    r = if r.w <= 0: d.dirty else: union(r, d.dirty)
  d.dirty = rect(0, 0, 0, 0)

proc compCopy*(d: Doc): seq[uint32] =
  ## A copy of what the image looks like.
  d.updateComposite()
  let s = d.simpleLayer
  if s != nil: s.px else: d.comp

{.push boundChecks: off, overflowChecks: off.}

proc mipLevel*(d: Doc; level: int): tuple[px: ptr UncheckedArray[uint32]; w, h: int] =
  ## The image as it looks at 1 / 2^`level` of its size (each pixel the
  ## average of the ones under it), kept and brought up to date where it
  ## changed: what a zoomed-out view draws from. Level 0 is `comp`.
  d.updateComposite()
  let base = d.compPtr
  if level <= 0: return (base, d.w, d.h)
  # (made again when the image changed size)
  var w = d.w
  var h = d.h
  for k in 1 .. level:
    w = max(1, (w + 1) div 2)
    h = max(1, (h + 1) div 2)
    if d.mips.len < k:
      d.mips.add newSeq[uint32](w * h)
      d.mipSize.add (w, h)
      d.mipDirty.add d.bounds
    elif d.mipSize[k - 1] != (w, h):
      d.mips[k - 1] = newSeq[uint32](w * h)
      d.mipSize[k - 1] = (w, h)
      d.mipDirty[k - 1] = d.bounds
  var sw = d.w
  var sh = d.h
  var sp = base
  for k in 1 .. level:
    let (mw, mh) = d.mipSize[k - 1]
    let dp = pixPtr(d.mips[k - 1])
    let r = d.mipDirty[k - 1]
    if r.w > 0 and r.h > 0:
      let x0 = max(0, r.x shr k)
      let x1 = min(mw, ((r.x + r.w - 1) shr k) + 1)
      let y0 = max(0, r.y shr k)
      let y1 = min(mh, ((r.y + r.h - 1) shr k) + 1)
      let src = sp
      let srcW = sw
      let srcH = sh
      parallelRows(y1 - y0, yy):
        let y = y0 + yy
        let ya = min(2 * y, srcH - 1) * srcW
        let yb = min(2 * y + 1, srcH - 1) * srcW
        for x in x0 ..< x1:
          let xa = min(2 * x, srcW - 1)
          let xb = min(2 * x + 1, srcW - 1)
          let q0 = src[ya + xa]
          let q1 = src[ya + xb]
          let q2 = src[yb + xa]
          let q3 = src[yb + xb]
          if (q0 and q1 and q2 and q3) >= 0xFF000000'u32:
            # (all four opaque -- a photo: the channels summed side by side)
            let rb = ((q0 and 0xFF00FF'u32) + (q1 and 0xFF00FF'u32) + (q2 and 0xFF00FF'u32) +
                      (q3 and 0xFF00FF'u32)) shr 2
            let gg = ((q0 and 0xFF00'u32) + (q1 and 0xFF00'u32) + (q2 and 0xFF00'u32) + (q3 and 0xFF00'u32)) shr 2
            dp[y * mw + x] = 0xFF000000'u32 or (rb and 0xFF00FF'u32) or (gg and 0xFF00'u32)
            continue
          var a, rr, g, b = 0'u32
          for p in [q0, q1, q2, q3]:
            let pa = p shr 24
            a += pa
            rr += ((p shr 16) and 255) * pa
            g += ((p shr 8) and 255) * pa
            b += (p and 255) * pa
          dp[y * mw + x] = if a == 0: 0'u32
                           else: ((a + 2) div 4 shl 24) or (rr div a shl 16) or (g div a shl 8) or (b div a)
      d.mipDirty[k - 1] = rect(0, 0, 0, 0)
    sp = dp
    sw = mw
    sh = mh
  (sp, sw, sh)

{.pop.}

proc flattened*(d: Doc; bg = 0'u32): seq[uint32] =
  ## All visible layers mixed (over `bg` when it is not transparent).
  result = newSeq[uint32](d.w * d.h)
  d.compositeInto(result, d.bounds, d.layers)
  if aOf(bg) > 0:
    let rp = pixPtr(result)
    parallelFor(result.len, proc (lo, hi: int) =
      for i in lo ..< hi:
        let p = rp[i]
        if (p shr 24) != 255: rp[i] = blendPx(bg, p, 255, bmNormal), grain = 4096)

proc toBitmap*(d: Doc; bg = 0'u32): Bitmap =
  ## The image as a picture (layers mixed).
  result = newBitmap(d.w, d.h)
  result.px = d.flattened(bg)

proc layerBitmap*(d: Doc; L: Layer): Bitmap =
  ## The pixels of layer `L` alone as a picture.
  result = newBitmap(d.w, d.h)
  result.px = L.px

proc thumbnailOf*(px: seq[uint32]; w, h, tw, th: int; checker = true): Bitmap =
  ## A small picture of `px` fitted into `tw` x `th` (transparency on a
  ## checkerboard), averaged.
  let k = min(tw / w, th / h)
  let ow = max(1, int(round(w.float * k)))
  let oh = max(1, int(round(h.float * k)))
  result = newBitmap(ow, oh)
  for ty in 0 ..< oh:
    let y0 = ty * h div oh
    let y1 = max(y0 + 1, (ty + 1) * h div oh)
    for tx in 0 ..< ow:
      let x0 = tx * w div ow
      let x1 = max(x0 + 1, (tx + 1) * w div ow)
      var sa, sr, sg, sb, n = 0
      let step = max(1, (x1 - x0) div 4)
      let stepY = max(1, (y1 - y0) div 4)
      var y = y0
      while y < y1:
        var x = x0
        while x < x1:
          let p = px[y * w + x]
          let a = aOf(p)
          sa += a; sr += rOf(p) * a; sg += gOf(p) * a; sb += bOf(p) * a
          inc n
          x += step
        y += stepY
      let a = if n > 0: sa div n else: 0
      var c = if sa > 0: argb(a, sr div sa, sg div sa, sb div sa) else: 0'u32
      if checker:
        let bg = if ((tx div 4) + (ty div 4)) mod 2 == 0: 0xFFFFFFFF'u32 else: 0xFFCCCCCC'u32
        c = blendPx(bg, c, 255, bmNormal)
      result.px[ty * ow + tx] = c

# ---- the selection ------------------------------------------------------------------------------------

proc hasSelection*(d: Doc): bool = d.sel.len == d.w * d.h
  ## A selection is made (without one, the whole image counts as selected).

proc selAt*(d: Doc; i: int): int {.inline.} =
  ## How selected pixel `i` is (0..255; all of it when nothing is).
  if d.sel.len == 0: 255 else: int(d.sel[i])

proc selBounds*(d: Doc): Rect =
  ## The rectangle around the selection (the whole image when there is
  ## none). Kept while the selection does not change (`selVer`).
  if not d.hasSelection: return d.bounds
  if d.selBox.ver == d.selVer and d.selBox.w == d.w and d.selBox.h == d.h and d.selBox.ver != 0:
    return d.selBox.r
  # (the rows on all the cores: the first and last selected column of each)
  let w = d.w
  let sp = cast[ptr UncheckedArray[uint8]](addr d.sel[0])
  var firsts = newSeq[int32](d.h)
  var lasts = newSeq[int32](d.h)
  let fp = cast[ptr UncheckedArray[int32]](addr firsts[0])
  let lp = cast[ptr UncheckedArray[int32]](addr lasts[0])
  parallelFor(d.h, proc (a, b: int) =
    for y in a ..< b:
      let row = y * w
      var f = -1
      var l = -1
      # (eight bytes at a time over what is not selected)
      var x = 0
      while x < w:
        # (copied, not read through a uint64 pointer: unaligned there)
        var word {.noinit.}: uint64
        if x + 8 <= w: copyMem(addr word, addr sp[row + x], 8)
        if x + 8 <= w and word == 0:
          x += 8
          continue
        if sp[row + x] != 0:
          if f < 0: f = x
          l = x
        inc x
      fp[y] = int32(f)
      lp[y] = int32(l), grain = 16)
  var x0 = d.w
  var y0 = d.h
  var x1 = -1
  var y1 = -1
  for y in 0 ..< d.h:
    if firsts[y] < 0: continue
    x0 = min(x0, int(firsts[y]))
    x1 = max(x1, int(lasts[y]))
    if y < y0: y0 = y
    y1 = y
  result = if x1 < 0: rect(0, 0, 0, 0) else: rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
  d.selBox = (d.selVer, d.w, d.h, result)

proc selectionEmpty*(d: Doc): bool =
  ## A selection that holds nothing.
  if not d.hasSelection: return false
  for v in d.sel:
    if v != 0: return false
  true

# ---- undo -------------------------------------------------------------------------------------------

proc settingsOf(L: Layer): LayerSettings =
  LayerSettings(name: L.name, opacity: L.opacity, mode: L.mode, visible: L.visible, lockAlpha: L.lockAlpha,
                background: L.background, maskOff: L.maskOff, gray: L.gray, mask: L.mask, adjust: L.adjust,
                text: L.text, fx: L.fx, clearFill: L.clearFill, shape: L.shape, clipped: L.clipped,
                group: L.group, collapsed: L.collapsed, passThrough: L.passThrough, locked: L.locked,
                lockPixels: L.lockPixels, lockPosition: L.lockPosition, link: L.link, board: L.board,
                depth: L.depth, blendIf: L.blendIf, maskClear: L.maskClear, maskFeather: L.maskFeather,
                smart: L.smart)

proc setSettings(L: Layer; s: LayerSettings) =
  ## (not its text or shape: they are drawn again when changed)
  L.name = s.name; L.opacity = s.opacity; L.mode = s.mode; L.visible = s.visible
  L.lockAlpha = s.lockAlpha; L.background = s.background; L.maskOff = s.maskOff
  L.gray = s.gray; L.mask = s.mask; L.adjust = s.adjust
  L.fx = s.fx; L.clearFill = s.clearFill; L.clipped = s.clipped
  L.group = s.group; L.collapsed = s.collapsed; L.passThrough = s.passThrough; L.locked = s.locked
  L.lockPixels = s.lockPixels; L.lockPosition = s.lockPosition; L.link = s.link; L.board = s.board
  L.depth = s.depth; L.blendIf = s.blendIf; L.maskClear = s.maskClear; L.maskFeather = s.maskFeather
  L.smart = s.smart

proc snapOf(d: Doc): DocSnap =
  result = DocSnap(w: d.w, h: d.h, dpi: d.dpi, mode: d.mode, palette: d.palette, duotone: d.duotone, cur: d.cur,
                   sel: d.sel, alphas: d.alphas, paths: d.paths)
  for L in d.layers:
    # (a group's pixels are nothing: not copied)
    result.layers.add LayerSnap(layer: L, px: (if L.group: @[] else: L.px), s: settingsOf(L),
                                maskPx: (if L.mask != nil: L.mask.px else: @[]), hi: L.hi, hdr: L.hdr)
    result.layers[^1].s.text = L.text
    result.layers[^1].s.shape = L.shape

proc restore(d: Doc; s: DocSnap) =
  d.w = s.w; d.h = s.h; d.dpi = s.dpi; d.mode = s.mode; d.palette = s.palette; d.duotone = s.duotone
  d.sel = s.sel; d.alphas = s.alphas; d.paths = s.paths
  d.layers.setLen(0)
  for ls in s.layers:
    let L = ls.layer
    L.px = if ls.s.group: zeroPixels(d.w * d.h) else: ls.px
    L.hi = ls.hi
    L.hdr = ls.hdr
    L.setSettings(ls.s)
    if L.mask != nil:
      L.mask.px = ls.maskPx
      inc L.mask.ver
    L.text = ls.s.text
    L.textBox = (0, 0, 0, 0)
    L.shape = ls.s.shape
    L.shapeBox = (0, 0, 0, 0)
    inc L.ver
    d.layers.add L
  d.cur = clamp(s.cur, 0, d.layers.high)
  inc d.selVer
  if d.curPath >= d.paths.len: d.curPath = -1
  d.comp = @[]
  d.dirty = d.bounds
  d.fitQuickMask()
  inc d.ver

proc snapBytes(s: DocSnap): int =
  result = s.sel.len
  for L in s.layers: result += L.px.len * 4 + L.maskPx.len * 4 + L.hi.len * 2 + L.hdr.len * 4
  for a in s.alphas: result += a.m.len

# ---- the scratch disk: old undo steps kept in a file, not in memory -------------------------------

var
  scratchDir* = ""
    ## Where old undo steps go (a scratch disk); "" a folder in the system's
    ## temporary one.
  undoRamBudget* = int(clamp(physicalMemory() div 16, 128'i64 shl 20, 512'i64 shl 20))
    ## How much memory the undo steps may take before the older ones go to
    ## the scratch disk (the newest stays in memory).
  spillLock: Lock
  spillCond: Cond
  spillQueue: array[256, ptr SpillJob]
  spillHead, spillTail: int
  spillStarted = false
  spillFinished: Atomic[int]    # the jobs the writer is done with
  spillCount = 0
  scratchBroken = false         # the scratch disk failed: the history in memory only

when compileOption("threads"):
  var spillThread: Thread[void]

proc spillWriter() {.thread.} =
  ## Writes the queued steps to their files, one after the other.
  while true:
    acquire(spillLock)
    while spillHead == spillTail: wait(spillCond, spillLock)
    let job = spillQueue[spillHead mod spillQueue.len]
    inc spillHead
    release(spillLock)
    if job.removeOnly:
      # (an old step's file: deleted here, not where the user waits)
      try: removeFile($cast[cstring](addr job.path[0]))
      except CatchableError: discard
      freeShared(job)
      spillFinished.atomicInc
      continue
    var ok = false
    try:
      let path = $cast[cstring](addr job.path[0])
      var f: File
      if open(f, path, fmWrite):
        ok = true
        block writing:
          for k in 0 ..< job.n:
            let b = job.bufs[k]
            var at = 0
            while at < b.len:
              # (in pieces: a step no longer wanted stops soon)
              if job.cancel.load != 0:
                ok = false
                break writing
              let n = min(b.len - at, 8 shl 20)
              if f.writeBuffer(cast[pointer](cast[uint](b.p) + uint(at)), n) != n:
                ok = false
                break writing
              at += n
        close(f)
    except CatchableError: ok = false
    job.done.store(if ok: 1 else: 2)
    spillFinished.atomicInc

proc waitScratch*() =
  ## Until the scratch disk's writer has done all it was given (its files
  ## written, the old ones deleted).
  if not spillStarted: return
  while true:
    acquire(spillLock)
    let all = spillTail
    release(spillLock)
    if spillFinished.load >= all: return
    sleep(1)

proc queueRemove(path: string) {.raises: [].} =
  ## (a scratch file deleted by the writer thread, after what it is writing)
  if spillStarted:
    let job = createShared(SpillJob)
    let n = min(path.len, job.path.len - 1)
    if n > 0: copyMem(addr job.path[0], unsafeAddr path[0], n)
    job.path[n] = '\0'
    job.removeOnly = true
    acquire(spillLock)
    if spillTail - spillHead < spillQueue.len - 1:
      spillQueue[spillTail mod spillQueue.len] = job
      inc spillTail
      signal(spillCond)
      release(spillLock)
      return
    release(spillLock)
    freeShared(job)
  try: removeFile(path)
  except CatchableError: discard

template eachBuffer(s: var Step; body: untyped) =
  ## `body` with `buf` (a seq of pixels or of mask bytes) for each big
  ## buffer of the step, always in the same order.
  for t in s.tiles.mitems:
    block:
      template buf: untyped {.inject.} = t.px
      body
    block:
      template buf: untyped {.inject.} = t.hi
      body
    block:
      template buf: untyped {.inject.} = t.hdr
      body
  if s.selSaved:
    template buf: untyped {.inject.} = s.sel
    body
  if s.hasSnap:
    for l in s.snap.layers.mitems:
      block:
        template buf: untyped {.inject.} = l.px
        body
      block:
        template buf: untyped {.inject.} = l.maskPx
        body
      block:
        template buf: untyped {.inject.} = l.hi
        body
      block:
        template buf: untyped {.inject.} = l.hdr
        body
    block:
      template buf: untyped {.inject.} = s.snap.sel
      body
    for a in s.snap.alphas.mitems:
      template buf: untyped {.inject.} = a.m
      body

proc scratchFolder(): string =
  result = if scratchDir.len > 0: scratchDir else: getTempDir() / "retro-photo-scratch"
  try: createDir(result)
  except CatchableError: discard

proc spillStep(s: var Step) =
  ## Starts writing the step's pixels to the scratch disk (in the
  ## background); `collectSpills` gives their memory back once written.
  if s.spill != nil: return
  when not compileOption("threads"):
    # (a web page without threads: the history stays in memory)
    return
  else:
    if not spillStarted:
      initLock(spillLock)
      initCond(spillCond)
      createThread(spillThread, spillWriter)
      spillStarted = true
    if spillTail - spillHead >= spillQueue.len - 1: return
    inc spillCount
    let path = scratchFolder() / ("undo-" & $getCurrentProcessId() & "-" & $spillCount & ".raw")
    let sp = Spill(path: path)
    var bufs: seq[tuple[p: pointer; len: int]]
    s.eachBuffer:
      let bytes = buf.len * sizeof(buf[0])
      sp.lens.add bytes
      bufs.add ((if buf.len > 0: pointer(addr buf[0]) else: nil), bytes)
    let job = createShared(SpillJob)
    let n = min(path.len, job.path.len - 1)
    if n > 0: copyMem(addr job.path[0], unsafeAddr path[0], n)
    job.path[n] = '\0'
    job.n = bufs.len
    job.bufs = cast[ptr UncheckedArray[tuple[p: pointer; len: int]]](allocShared0(max(1, bufs.len) * sizeof(bufs[0])))
    for k, b in bufs: job.bufs[k] = b
    sp.job = job
    s.spill = sp
    acquire(spillLock)
    spillQueue[spillTail mod spillQueue.len] = job
    inc spillTail
    signal(spillCond)
    release(spillLock)

proc collectStep(s: var Step) =
  ## The step's memory given back once its pixels are on the disk.
  let sp = s.spill
  if sp == nil or sp.freed or sp.job == nil or sp.job.done.load == 0: return
  if sp.job.done.load == 2:
    # (the disk failed: kept in memory, the history made shorter)
    s.spill = nil
    scratchBroken = true
    return
  s.eachBuffer:
    buf = @[]
  sp.freed = true

proc loadStep(s: var Step) =
  ## The step's pixels back in memory (from the scratch disk), before it is
  ## undone or redone.
  let sp = s.spill
  if sp == nil: return
  if sp.job != nil: waitJob(sp.job)
  if sp.freed:
    var f: File
    if not open(f, sp.path, fmRead):
      raise newException(IOError, "the scratch disk lost an undo step")
    defer: close(f)
    var k = 0
    s.eachBuffer:
      let bytes = sp.lens[k]
      buf.setLen(bytes div sizeof(buf[0]))
      if bytes > 0:
        if f.readBuffer(addr buf[0], bytes) != bytes:
          raise newException(IOError, "the scratch disk lost an undo step")
      inc k
      busyTick()
  s.spill = nil          # (the file goes: the step changes when it is swapped)

proc ramBytes(s: Step): int =
  if s.spill != nil and s.spill.freed: 0 else: s.bytes

proc collectSpills*(d: Doc) =
  ## Gives back the memory of the steps written to the scratch disk, and
  ## sends older steps there when the history takes more memory than
  ## `undoRamBudget` (the newest step stays).
  for st in d.undoSteps.mitems: collectStep(st)
  for st in d.redoSteps.mitems: collectStep(st)
  for sn in d.snapshots.mitems: collectStep(sn.step)
  var used = 0
  var keepFirst = true
  for k in countdown(d.undoSteps.high, 0):
    if d.stepOpen and k == d.undoSteps.high: continue
    let b = d.undoSteps[k].ramBytes
    if b == 0: continue
    if keepFirst:
      keepFirst = false
      used += b
      continue
    if used + b > undoRamBudget and b >= (1 shl 20): spillStep(d.undoSteps[k])
    else: used += b
  for k in countdown(d.redoSteps.high, 0):
    let b = d.redoSteps[k].ramBytes
    if b == 0: continue
    if used + b > undoRamBudget and b >= (1 shl 20): spillStep(d.redoSteps[k])
    else: used += b

proc to8*(v: uint16): uint32 {.inline.} =
  ## A 16-bit value at 8 bits (rounded).
  (uint32(v) + 128) div 257

proc hiOf8*(px: openArray[uint32]): seq[uint16] =
  ## 8-bit pixels at 16 bits (R G B A each).
  result = newSeqUninit[uint16](px.len * 4)
  if px.len == 0: return
  let s = cast[ptr UncheckedArray[uint32]](unsafeAddr px[0])
  let o = cast[ptr UncheckedArray[uint16]](addr result[0])
  parallelFor(px.len, proc (lo, hi: int) =
    for i in lo ..< hi:
      let p = s[i]
      o[4 * i] = uint16((p shr 16) and 255) * 257
      o[4 * i + 1] = uint16((p shr 8) and 255) * 257
      o[4 * i + 2] = uint16(p and 255) * 257
      o[4 * i + 3] = uint16(p shr 24) * 257, grain = 8192)

proc hiValid*(d: Doc; L: Layer): bool {.inline.} =
  ## The layer has 16-bit pixels (where a tool changed it at 8 bits since,
  ## they are taken at 8 bits: `hiPixels`).
  L.hi.len == d.w * d.h * 4 and L.px.len == d.w * d.h

proc syncHi*(d: Doc; L: Layer) =
  ## The layer's 16 bits made to agree with its 8: each channel a tool
  ## changed at 8 bits (its 8 bits no longer its 16 rounded) is that value
  ## at 16; the others keep their 16 bits.
  if not d.hiValid(L): return
  let s = cast[ptr UncheckedArray[uint32]](addr L.px[0])
  let o = cast[ptr UncheckedArray[uint16]](addr L.hi[0])
  parallelFor(L.px.len, proc (lo, hi: int) =
    for i in lo ..< hi:
      let p = s[i]
      for c in 0 .. 3:
        let v8 = (if c == 3: p shr 24 else: (p shr (16 - 8 * c)) and 255)
        if to8(o[4 * i + c]) != v8: o[4 * i + c] = uint16(v8 * 257), grain = 8192)

proc setHi*(d: Doc; L: Layer; hi: sink seq[uint16]) =
  ## The layer's pixels at 16 bits (R G B A each, as big as the document);
  ## its 8 bits made from them.
  L.hi = hi
  L.hiVer = L.ver
  if L.hi.len != d.w * d.h * 4: return
  if L.px.len != d.w * d.h: L.px = newSeq[uint32](d.w * d.h)
  let o = cast[ptr UncheckedArray[uint32]](addr L.px[0])
  let s = cast[ptr UncheckedArray[uint16]](addr L.hi[0])
  parallelFor(L.px.len, proc (lo, hi: int) =
    for i in lo ..< hi:
      o[i] = (to8(s[4 * i + 3]) shl 24) or (to8(s[4 * i]) shl 16) or (to8(s[4 * i + 1]) shl 8) or
             to8(s[4 * i + 2]), grain = 8192)
  inc L.ver

proc ensureHi*(d: Doc; L: Layer) =
  ## The layer's 16 bits there and agreeing with its 8 (made from them when
  ## it had none): for working on it at 16 bits.
  if L.px.len != d.w * d.h: return
  if d.hiValid(L): d.syncHi(L)
  else: L.hi = hiOf8(L.px)

proc hiPixels*(d: Doc; L: Layer): seq[uint16] =
  ## The layer at 16 bits: its 16 bits, where a tool changed it since at 8
  ## bits those 8.
  if d.hiValid(L):
    d.syncHi(L)
    return L.hi
  hiOf8(L.px)

proc hiToPx*(d: Doc; L: Layer; r: Rect) =
  ## After the 16 bits of `r` were worked on: its 8 bits made from them.
  let c = d.clip(r)
  if c.w <= 0 or c.h <= 0 or not d.hiValid(L): return
  let o = cast[ptr UncheckedArray[uint32]](addr L.px[0])
  let s = cast[ptr UncheckedArray[uint16]](addr L.hi[0])
  let w = d.w
  parallelRows(c.h, y):
    for x in c.x ..< c.x + c.w:
      let i = (c.y + y) * w + x
      o[i] = (to8(s[4 * i + 3]) shl 24) or (to8(s[4 * i]) shl 16) or (to8(s[4 * i + 1]) shl 8) or
             to8(s[4 * i + 2])
  inc L.ver
  d.markDirty(c)

proc hdrValid*(d: Doc; L: Layer): bool {.inline.} =
  ## The layer has its light at 32 bits (where a tool changed it at 8 bits
  ## since, it is made from what is shown: `hdrPixels` in `photohdr`).
  L.hdr.len == d.w * d.h * 4 and L.px.len == d.w * d.h

proc setDepth*(d: Doc; bits: int) =
  ## Image > Mode > 8 or 16 Bits/Channel (8: the 16-bit pixels let go; the
  ## 32-bit light let go too -- `photohdr` makes 32 and tone maps from it).
  d.depth = if bits >= 32: 32 elif bits >= 16: 16 else: 8
  if d.depth == 8:
    for L in d.layers:
      L.hi = @[]
      L.hiVer = 0
  if d.depth != 32:
    for L in d.layers:
      L.hdr = @[]
      L.hdrVer = 0

var flatten16Hook*: proc (d: Doc): seq[uint16] {.nimcall.}
  ## The image composited at 16 bits (set by `retroui/photodeep`; empty when
  ## something in it is only done at 8 bits).

proc flattened16*(d: Doc): seq[uint16] =
  ## The image at 16 bits: its layers composited at 16 bits (`photodeep`),
  ## else the composite made 16.
  var only: Layer
  var n = 0
  for L in d.layers:
    if L.visible and not L.group:
      inc n
      only = L
  if n == 1 and only.opacity == 100 and only.mode == bmNormal and only.mask == nil and not only.hasFx and
     only.adjust.kind.len == 0 and d.hiValid(only):
    return d.hiPixels(only)
  if flatten16Hook != nil:
    result = flatten16Hook(d)
    if result.len == d.w * d.h * 4: return
  d.updateComposite()
  let m = d.w * d.h
  result = newSeq[uint16](m * 4)
  for i in 0 ..< m:
    let p = d.compPtr[i]
    result[4 * i] = uint16((p shr 16) and 255) * 257
    result[4 * i + 1] = uint16((p shr 8) and 255) * 257
    result[4 * i + 2] = uint16(p and 255) * 257
    result[4 * i + 3] = uint16(p shr 24) * 257

proc historyInMemory*(d: Doc): float =
  ## How much of the undo history is in memory (0..1; the rest is on the
  ## scratch disk): the status bar's Efficiency.
  var total, ram = 0
  for st in d.undoSteps:
    total += st.bytes
    ram += st.ramBytes
  for st in d.redoSteps:
    total += st.bytes
    ram += st.ramBytes
  if total <= 0: 1.0 else: clamp(ram / total, 0.0, 1.0)

proc trimHistory(d: Doc) =
  var total = 0
  for s in d.undoSteps: total += s.bytes
  let room = if scratchBroken: min(d.maxUndoBytes, undoRamBudget * 2) else: d.maxUndoBytes
  while d.undoSteps.len > 1 and (total > room or d.undoSteps.len > max(1, maxHistoryStates)):
    total -= d.undoSteps[0].bytes
    d.undoSteps.delete(0)
    d.historyCut = true

proc beginStep*(d: Doc; name: string) =
  ## Starts an undoable change named `name` ("Paintbrush", "Fill"): what it
  ## changes is saved first with `touch`, `touchSel` (or the whole image
  ## with `snapStep`); `endStep` ends it.
  if d.stepOpen: return
  if busyDepth > 0 and busyLabel.len == 0: busyLabel = name    # (what the busy box says)
  d.parkedRedo = move(d.redoSteps)   # (back if the step changes nothing or is cancelled)
  d.redoSteps = @[]
  d.undoSteps.add Step(name: name, wasModified: d.modified)
  d.stepOpen = true
  d.stepIndex.clear()
  d.stepWhole.setLen(0)

proc stepOpen*(d: Doc): bool = d.stepOpen
  ## A step begun with `beginStep` has not ended yet.

proc touch*(d: Doc; L: Layer; r: Rect) =
  ## Saves the tiles of `L` in `r` that this step has not saved yet.
  if not d.stepOpen or L == nil: return
  let c = d.clip(r)
  if c.w <= 0 or c.h <= 0: return
  let lk = cast[pointer](L)
  if lk in d.stepWhole:
    inc L.ver
    return
  # the tiles not saved yet, then their pixels copied on all the cores
  let first = d.undoSteps[^1].tiles.len
  let hasHi = L.hi.len == d.w * d.h * 4 and L.px.len == d.w * d.h
  let hasHdr = L.hdr.len == d.w * d.h * 4 and L.px.len == d.w * d.h
  for ty in c.y div TileSize .. (c.y + c.h - 1) div TileSize:
    for tx in c.x div TileSize .. (c.x + c.w - 1) div TileSize:
      if d.stepIndex.hasKey((lk, tx, ty)): continue
      let x0 = tx * TileSize
      let y0 = ty * TileSize
      let tw = min(TileSize, d.w - x0)
      let th = min(TileSize, d.h - y0)
      d.undoSteps[^1].bytes += tw * th * 4
      d.stepIndex[(lk, tx, ty)] = d.undoSteps[^1].tiles.len
      d.undoSteps[^1].tiles.add TileSave(layer: L, tx: tx, ty: ty, px: newSeqUninit[uint32](tw * th))
      if hasHi:
        d.undoSteps[^1].tiles[^1].hi = newSeqUninit[uint16](tw * th * 4)
        d.undoSteps[^1].bytes += tw * th * 8
      if hasHdr:
        d.undoSteps[^1].tiles[^1].hdr = newSeqUninit[float32](tw * th * 4)
        d.undoSteps[^1].bytes += tw * th * 16
  let count = d.undoSteps[^1].tiles.len - first
  if count > 0:
    let tp = cast[ptr UncheckedArray[TileSave]](addr d.undoSteps[^1].tiles[first])
    let lp = pixPtr(L.px)
    let hp = if hasHi: cast[ptr UncheckedArray[uint16]](addr L.hi[0]) else: nil
    let fp = if hasHdr: cast[ptr UncheckedArray[float32]](addr L.hdr[0]) else: nil
    let w = d.w
    let h = d.h
    parallelFor(count, proc (lo, hi: int) =
      for k in lo ..< hi:
        let x0 = tp[k].tx * TileSize
        let y0 = tp[k].ty * TileSize
        let tw = min(TileSize, w - x0)
        let th = min(TileSize, h - y0)
        let dst = cast[ptr UncheckedArray[uint32]](addr tp[k].px[0])
        for y in 0 ..< th:
          copyMem(addr dst[y * tw], addr lp[(y0 + y) * w + x0], tw * 4)
        if hp != nil:
          let dh = cast[ptr UncheckedArray[uint16]](addr tp[k].hi[0])
          for y in 0 ..< th:
            copyMem(addr dh[y * tw * 4], addr hp[((y0 + y) * w + x0) * 4], tw * 8)
        if fp != nil:
          let df = cast[ptr UncheckedArray[float32]](addr tp[k].hdr[0])
          for y in 0 ..< th:
            copyMem(addr df[y * tw * 4], addr fp[((y0 + y) * w + x0) * 4], tw * 16), grain = 16)
  inc L.ver

proc touchWhole*(d: Doc; L: Layer): bool =
  ## Before `L`'s pixels are replaced as a whole (a filter on all of it, a
  ## layer moved, transformed): they go to this step as they are -- moved,
  ## not copied: a big photo's change saved at once, its undo a swap. True
  ## when they were taken (`L.px` is then empty: the caller puts the new
  ## pixels there); false when part of it was saved before in this step
  ## (then it was saved as tiles, and `L.px` is as it was).
  if not d.stepOpen or L == nil or d.undoSteps.len == 0: return false
  let lk = cast[pointer](L)
  if lk in d.stepWhole: return false
  if L.px.len != d.w * d.h: return false
  for t in d.undoSteps[^1].tiles:
    if t.layer == L:
      d.touch(L, d.bounds)
      return false
  d.undoSteps[^1].bytes += L.px.len * 4 + L.hi.len * 2 + L.hdr.len * 4
  d.undoSteps[^1].tiles.add TileSave(layer: L, tx: -1, ty: -1, px: move(L.px), hi: L.hi, hdr: L.hdr)
  d.stepWhole.add lk
  L.px = @[]
  inc L.ver
  true

proc wholeSaved(d: Doc; L: Layer): ptr seq[uint32] =
  ## (this step's whole save of `L`, nil none)
  if d.stepOpen and d.undoSteps.len > 0 and cast[pointer](L) in d.stepWhole:
    for t in d.undoSteps[^1].tiles.mitems:
      if t.layer == L and t.tx == -1: return addr t.px
  nil

proc original*(d: Doc; L: Layer; x, y: int): uint32 =
  ## What pixel `x`, `y` of `L` was when this step began (it must have
  ## been saved with `touch`; else what it is now).
  let wp = d.wholeSaved(L)
  if wp != nil: return wp[][y * d.w + x]
  let k = (cast[pointer](L), x div TileSize, y div TileSize)
  let i = d.stepIndex.getOrDefault(k, -1)
  if i < 0 or not d.stepOpen: return L.px[y * d.w + x]
  let t = addr d.undoSteps[^1].tiles[i]
  let tw = min(TileSize, d.w - t.tx * TileSize)
  t.px[(y - t.ty * TileSize) * tw + (x - t.tx * TileSize)]

type OrigReader* = object
  ## Reads what pixels were when the step began (as `original`), a tile at
  ## a time: the look-up is made once for 64 pixels, not for each. One for
  ## each thread; it holds no references (worker threads may use it while
  ## the document is the drawing thread's).
  idx: ptr Table[(pointer, int, int), int]
  tiles: ptr seq[TileSave]
  lkey: pointer
  lpx: ptr UncheckedArray[uint32]
  w: int
  tx, ty: int
  p: ptr UncheckedArray[uint32]
  tw: int

proc origReader*(d: Doc; L: Layer): OrigReader =
  ## A reader of what `L`'s pixels were when the step began.
  result = OrigReader(idx: addr d.stepIndex, lkey: cast[pointer](L), w: d.w, tx: -1, ty: -1,
                      lpx: if L.px.len > 0: cast[ptr UncheckedArray[uint32]](addr L.px[0]) else: nil)
  let wp = d.wholeSaved(L)
  if wp != nil and wp[].len > 0:
    result.lpx = cast[ptr UncheckedArray[uint32]](addr wp[][0])     # (saved whole: read from there)
  elif d.stepOpen and d.undoSteps.len > 0: result.tiles = addr d.undoSteps[^1].tiles

proc at*(r: var OrigReader; x, y: int): uint32 {.inline.} =
  ## Pixel `x`, `y` as it was (see `original`).
  let tx = x shr 6
  let ty = y shr 6
  if tx != r.tx or ty != r.ty:
    r.tx = tx
    r.ty = ty
    r.p = nil
    if r.tiles != nil:
      let i = r.idx[].getOrDefault((r.lkey, tx, ty), -1)
      if i >= 0:
        let t = addr r.tiles[][i]
        r.tw = min(TileSize, r.w - t.tx * TileSize)
        r.p = cast[ptr UncheckedArray[uint32]](addr t.px[0])
  if r.p == nil: r.lpx[y * r.w + x]
  else: r.p[(y - ty * TileSize) * r.tw + (x - tx * TileSize)]

proc touchPaths*(d: Doc) =
  ## Saves the paths for this step (the pen, the path tools).
  if not d.stepOpen or d.undoSteps.len == 0 or d.undoSteps[^1].pathsSaved: return
  d.undoSteps[^1].paths = d.paths
  d.undoSteps[^1].curPath = d.curPath
  d.undoSteps[^1].pathsSaved = true
  for p in d.paths:
    for sp in p.subs: d.undoSteps[^1].bytes += sp.pts.len * sizeof(PathPoint)

proc layerListOf(d: Doc): LayerList =
  result.cur = d.cur
  result.editMask = d.editMask
  for L in d.layers:
    result.props.add LayerProps(layer: L, s: settingsOf(L))

proc restoreLayers(d: Doc; l: LayerList) =
  d.layers.setLen(0)
  for p in l.props:
    let L = p.layer
    L.setSettings(p.s)
    if L.group and L.px.len != d.w * d.h: L.px = zeroPixels(d.w * d.h)
    if L.text != p.s.text:
      L.text = p.s.text
      if L.isText and L.px.len == d.w * d.h: d.drawText(L)
    if L.shape != p.s.shape:
      L.shape = p.s.shape
      if L.isShape and L.px.len == d.w * d.h: d.drawShape(L)
    inc L.ver
    d.layers.add L
  d.cur = clamp(l.cur, 0, d.layers.high)
  d.editMask = l.editMask
  d.markAll()

proc touchLayers*(d: Doc) =
  ## Saves the layers -- which there are, in which order, and their
  ## settings, masks, adjustments, texts and styles, not their pixels --
  ## for this step: adding, removing, moving layers, masks and adjustment
  ## layers, editing type, is undone without copying the image.
  if not d.stepOpen or d.undoSteps[^1].layersSaved: return
  d.undoSteps[^1].layerList = d.layerListOf()
  d.undoSteps[^1].layersSaved = true
  d.undoSteps[^1].bytes += 64 * d.layers.len

proc touchSel*(d: Doc) =
  ## Saves the selection for this step.
  if not d.stepOpen or d.undoSteps[^1].selSaved: return
  d.undoSteps[^1].sel = d.sel
  d.undoSteps[^1].selSaved = true
  d.undoSteps[^1].bytes += d.sel.len

proc snapStep*(d: Doc; name: string) =
  ## An undoable change of the whole image (its size, its layers...):
  ## everything is saved. Ended by `endStep`.
  d.beginStep(name)
  if not d.undoSteps[^1].hasSnap:
    d.undoSteps[^1].snap = d.snapOf()
    d.undoSteps[^1].hasSnap = true
    d.undoSteps[^1].bytes += snapBytes(d.undoSteps[^1].snap)

proc endStep*(d: Doc) =
  ## Ends the change begun with `beginStep` (or `snapStep`).
  if not d.stepOpen: return
  d.stepOpen = false
  d.stepIndex.clear()
  d.stepWhole.setLen(0)
  if d.undoSteps.len == 0: return
  template s: untyped = d.undoSteps[^1]    # (not a copy: it may be big)
  if s.tiles.len == 0 and not s.selSaved and not s.hasSnap and not s.pathsSaved and not s.layersSaved:
    d.undoSteps.setLen(d.undoSteps.len - 1)
    d.redoSteps = move(d.parkedRedo)
    return
  d.parkedRedo = @[]
  inc d.stepsMade
  if s.tiles.len > 0 or s.hasSnap or s.pathsSaved or s.layersSaved: d.modified = true   # (a new selection alone is no change to save)
  d.trimHistory()
  d.collectSpills()

proc cancelStep*(d: Doc) =
  ## Undoes the change begun (its tiles go back), as if it never happened:
  ## the redo steps and the document's "modified" are as they were.
  if not d.stepOpen: return
  d.stepOpen = false
  d.stepIndex.clear()
  d.stepWhole.setLen(0)
  if d.undoSteps.len == 0: return
  var s = d.undoSteps.pop()
  for i in countdown(s.tiles.high, 0):
    let t = s.tiles[i]
    if t.tx == -1:
      # (saved whole: put back)
      if t.px.len == d.w * d.h:
        t.layer.px = move(s.tiles[i].px)
        t.layer.hi = move(s.tiles[i].hi)
        t.layer.hdr = move(s.tiles[i].hdr)
        d.markDirty(d.bounds)
      inc t.layer.ver
      continue
    let x0 = t.tx * TileSize
    let y0 = t.ty * TileSize
    let tw = min(TileSize, d.w - x0)
    let th = t.px.len div max(1, tw)
    if t.layer.px.len == d.w * d.h:
      for y in 0 ..< th:
        copyMem(addr t.layer.px[(y0 + y) * d.w + x0], unsafeAddr t.px[y * tw], tw * 4)
      if t.hi.len == tw * th * 4 and t.layer.hi.len == d.w * d.h * 4:
        for y in 0 ..< th:
          copyMem(addr t.layer.hi[((y0 + y) * d.w + x0) * 4], unsafeAddr t.hi[y * tw * 4], tw * 8)
      if t.hdr.len == tw * th * 4 and t.layer.hdr.len == d.w * d.h * 4:
        for y in 0 ..< th:
          copyMem(addr t.layer.hdr[((y0 + y) * d.w + x0) * 4], unsafeAddr t.hdr[y * tw * 4], tw * 16)
      d.markDirty(rect(x0, y0, tw, th))
    inc t.layer.ver
  if s.selSaved:
    d.sel = s.sel
    inc d.selVer
  if s.layersSaved: d.restoreLayers(s.layerList)
  if s.hasSnap: d.restore(s.snap)
  if s.pathsSaved:
    d.paths = s.paths
    d.curPath = if s.curPath < d.paths.len: s.curPath else: -1
  d.modified = s.wasModified
  d.redoSteps = move(d.parkedRedo)

proc swapStep(d: Doc; s: var Step; undoing: bool) =
  template doTiles() =
    for i in countdown(s.tiles.high, 0):
      let t = addr s.tiles[i]
      if t.tx == -1:
        # (saved whole: swapped, nothing copied)
        if t.px.len == d.w * d.h and t.layer.px.len == d.w * d.h:
          swap(t.layer.px, t.px)
          swap(t.layer.hi, t.hi)
          swap(t.layer.hdr, t.hdr)
          inc t.layer.ver
          d.markDirty(d.bounds)
        continue
      let x0 = t.tx * TileSize
      let y0 = t.ty * TileSize
      let tw = min(TileSize, d.w - x0)
      if tw <= 0 or t.layer.px.len != d.w * d.h: continue
      let th = t.px.len div tw
      if y0 + th > d.h: continue
      var now = newSeq[uint32](tw * th)
      for y in 0 ..< th:
        copyMem(addr now[y * tw], addr t.layer.px[(y0 + y) * d.w + x0], tw * 4)
        copyMem(addr t.layer.px[(y0 + y) * d.w + x0], addr t.px[y * tw], tw * 4)
      t.px = now
      if t.hi.len == tw * th * 4:
        if t.layer.hi.len != d.w * d.h * 4: t.layer.hi = hiOf8(t.layer.px)
        var nh = newSeqUninit[uint16](tw * th * 4)
        for y in 0 ..< th:
          copyMem(addr nh[y * tw * 4], addr t.layer.hi[((y0 + y) * d.w + x0) * 4], tw * 8)
          copyMem(addr t.layer.hi[((y0 + y) * d.w + x0) * 4], addr t.hi[y * tw * 4], tw * 8)
        t.hi = nh
      if t.hdr.len == tw * th * 4 and t.layer.hdr.len == d.w * d.h * 4:
        var nf = newSeqUninit[float32](tw * th * 4)
        for y in 0 ..< th:
          copyMem(addr nf[y * tw * 4], addr t.layer.hdr[((y0 + y) * d.w + x0) * 4], tw * 16)
          copyMem(addr t.layer.hdr[((y0 + y) * d.w + x0) * 4], addr t.hdr[y * tw * 4], tw * 16)
        t.hdr = nf
      inc t.layer.ver
      d.markDirty(rect(x0, y0, tw, th))
  template doSel() =
    if s.selSaved:
      swap(d.sel, s.sel)
      if d.sel.len != 0 and d.sel.len != d.w * d.h: d.sel.setLen(0)
      inc d.selVer
    if s.pathsSaved:
      swap(d.paths, s.paths)
      swap(d.curPath, s.curPath)
      if d.curPath >= d.paths.len: d.curPath = -1
  template doSnap() =
    if s.hasSnap:
      let now = d.snapOf()
      d.restore(s.snap)
      s.snap = now
  template doLayers() =
    if s.layersSaved:
      let now = d.layerListOf()
      d.restoreLayers(s.layerList)
      s.layerList = now
  if undoing:
    doSel(); doTiles(); doLayers(); doSnap()
  else:
    doSnap(); doLayers(); doTiles(); doSel()
  d.modified = true
  inc d.ver

proc canUndo*(d: Doc): bool = d.undoSteps.len > 0 and not d.stepOpen
  ## There is a step to undo (and none is being made).
proc canRedo*(d: Doc): bool = d.redoSteps.len > 0 and not d.stepOpen
  ## There is a step to redo (and none is being made).
proc undoName*(d: Doc): string = (if d.undoSteps.len > 0: d.undoSteps[^1].name else: "")
  ## The name of the step `undo` takes back ("" when there is none).
proc redoName*(d: Doc): string = (if d.redoSteps.len > 0: d.redoSteps[^1].name else: "")
  ## The name of the step `redo` does again ("" when there is none).

proc undo*(d: Doc) =
  ## Takes back the last change.
  if not d.canUndo: return
  var s = d.undoSteps.pop()
  s.loadStep()
  d.swapStep(s, true)
  d.redoSteps.add s
  d.collectSpills()

proc redo*(d: Doc) =
  ## Does again the last change undone.
  if not d.canRedo: return
  var s = d.redoSteps.pop()
  s.loadStep()
  d.swapStep(s, false)
  d.undoSteps.add s
  d.collectSpills()

proc clearHistory*(d: Doc) =
  ## Forgets the undo and redo steps (a step being made stays).
  if d.undoSteps.len > (if d.stepOpen: 1 else: 0): d.historyCut = true
  if d.stepOpen and d.undoSteps.len > 0:
    d.undoSteps = @[d.undoSteps[^1]]
  else:
    d.undoSteps.setLen(0)
    d.stepOpen = false
  d.redoSteps.setLen(0)
  d.parkedRedo.setLen(0)

# ---- the History palette: its states, snapshots ---------------------------------------------------------------

proc historyStates*(d: Doc): seq[string] =
  ## The states of the History palette, the oldest first: the image as it
  ## was opened (or the oldest kept), then after each step -- those undone
  ## last (they can be redone).
  result.add(if d.historyCut: "(older steps)" else: "Open")
  for s in d.undoSteps: result.add s.name
  for k in countdown(d.redoSteps.high, 0): result.add d.redoSteps[k].name

proc historyAt*(d: Doc): int =
  ## The state the image is in (an index of `historyStates`).
  d.undoSteps.len

proc goToHistory*(d: Doc; k: int) =
  ## The image as it was at state `k` (undoing or redoing the steps between).
  if d.stepOpen: return
  let want = clamp(k, 0, d.undoSteps.len + d.redoSteps.len)
  while d.undoSteps.len > want and d.canUndo: d.undo()
  while d.undoSteps.len < want and d.canRedo: d.redo()

proc takeSnapshot*(d: Doc; name = ""): int {.discardable.} =
  ## History > New Snapshot: the image as it is now, kept (written to the
  ## scratch disk: it takes no memory once there). Its index.
  var n = name
  if n.len == 0: n = "Snapshot " & $(d.snapshots.len + 1)
  var st = Step(name: n, snap: d.snapOf(), hasSnap: true)
  st.bytes = snapBytes(st.snap)
  if st.bytes >= (1 shl 20): spillStep(st)
  d.snapshots.add Snapshot(name: n, step: st)
  d.collectSpills()
  d.snapshots.high

proc snapCoord*(d: Doc; v: float; vertical: bool; tol: float; grid = 0.0; guides = true;
                edges = true): float =
  ## `v` (an x when `vertical`, else a y) snapped to the nearest guide, grid
  ## line or edge of the image within `tol` image pixels.
  result = v
  var best = tol
  template tryAt(c: float) =
    if abs(v - c) <= best:
      best = abs(v - c)
      result = c
  if guides:
    for g in d.guides:
      if g.vertical == vertical: tryAt(g.pos)
  if grid > 0: tryAt(round(v / grid) * grid)
  if edges:
    tryAt(0.0)
    tryAt(float(if vertical: d.w else: d.h))

proc clearGuides*(d: Doc) =
  ## Removes every guide.
  d.guides.setLen(0)
  inc d.ver

proc deleteSnapshot*(d: Doc; k: int) =
  ## Forgets snapshot `k`.
  if k >= 0 and k < d.snapshots.len: d.snapshots.delete(k)

proc revertToSnapshot*(d: Doc; k: int) =
  ## The image made as the snapshot was (an undoable step).
  if k < 0 or k >= d.snapshots.len or d.stepOpen: return
  loadStep(d.snapshots[k].step)
  d.snapStep(d.snapshots[k].name)
  d.restore(d.snapshots[k].step.snap)
  d.endStep()
  if d.snapshots[k].step.bytes >= (1 shl 20): spillStep(d.snapshots[k].step)
  d.collectSpills()

proc tileInto(px: var seq[uint32]; w, h: int; t: TileSave): bool =
  if t.tx == -1:
    if t.px.len != w * h: return false
    px = t.px
    return true
  let x0 = t.tx * TileSize
  let y0 = t.ty * TileSize
  let tw = min(TileSize, w - x0)
  if tw <= 0 or px.len != w * h: return false
  let th = t.px.len div tw
  if y0 + th > h: return false
  for y in 0 ..< th:
    copyMem(addr px[(y0 + y) * w + x0], unsafeAddr t.px[y * tw], tw * 4)
  true

proc snapPixels(s: DocSnap; L: Layer; w, h: int): seq[uint32] =
  ## (a layer's -- or a layer mask's -- pixels in a snap, when it is there and as big)
  if s.w != w or s.h != h: return
  for ls in s.layers:
    if ls.layer == L and not ls.s.group: return ls.px
    if ls.s.mask == L and ls.s.mask != nil: return ls.maskPx

proc statePixels*(d: Doc; L: Layer; k: int): seq[uint32] =
  ## What layer `L` (or a layer mask) was at history state `k` -- for the
  ## History Brush. Empty when it was not there, or not as big.
  if L == nil or L.px.len != d.w * d.h: return
  let cur = d.undoSteps.len
  let total = cur + d.redoSteps.len
  let k = clamp(k, 0, total)
  result = L.px
  if k < cur:
    # back: each step keeps what was before it
    for si in countdown(cur - 1, k):
      if d.stepOpen and si == d.undoSteps.high: continue
      loadStep(d.undoSteps[si])
      template st: untyped = d.undoSteps[si]
      for t in st.tiles:
        if t.layer == L: discard tileInto(result, d.w, d.h, t)
      if st.layersSaved:
        # (not there before this step: no pixels then)
        var there = false
        for pr in st.layerList.props:
          if pr.layer == L or pr.s.mask == L: there = true
        if not there and L != d.maskLayer: result = @[]; return
      if st.hasSnap:
        let sp = snapPixels(st.snap, L, d.w, d.h)
        if sp.len == 0: result = @[]; return
        result = sp
  elif k > cur:
    # forward: an undone step keeps what was after it
    for n in 1 .. k - cur:
      let si = d.redoSteps.len - n
      loadStep(d.redoSteps[si])
      template st: untyped = d.redoSteps[si]
      if st.hasSnap:
        let sp = snapPixels(st.snap, L, d.w, d.h)
        if sp.len == 0: result = @[]; return
        result = sp
      for t in st.tiles:
        if t.layer == L: discard tileInto(result, d.w, d.h, t)
  d.collectSpills()

proc snapshotPixels*(d: Doc; L: Layer; k: int): seq[uint32] =
  ## What layer `L` (or a mask) was in snapshot `k` (empty: not there).
  if k < 0 or k >= d.snapshots.len or L == nil: return
  loadStep(d.snapshots[k].step)
  result = snapPixels(d.snapshots[k].step.snap, L, d.w, d.h)
  if d.snapshots[k].step.bytes >= (1 shl 20): spillStep(d.snapshots[k].step)

# ---- selecting ------------------------------------------------------------------------------------------

type SelOp* = enum
  ## How a new selection meets the one there is.
  soReplace, soAdd, soSubtract, soIntersect

proc setSelection*(d: Doc; m: seq[uint8]; op = soReplace) =
  ## Puts mask `m` (as big as the image) into the selection by `op`.
  ## (Undoable within a step: call `touchSel` first.)
  if m.len != d.w * d.h: return
  if op == soReplace or not d.hasSelection:
    if op == soSubtract:
      d.sel = newSeq[uint8](d.w * d.h)
      for i in 0 ..< m.len: d.sel[i] = uint8(255 - int(m[i]))
    elif op == soIntersect and not d.hasSelection:
      d.sel = m
    else:
      d.sel = m
  else:
    for i in 0 ..< m.len:
      let a = int(d.sel[i])
      let b = int(m[i])
      d.sel[i] = uint8(case op
        of soAdd: max(a, b)
        of soSubtract: a * (255 - b) div 255
        of soIntersect: min(a, b)
        else: b)
  inc d.selVer

proc shiftedMask*(m: openArray[uint8]; w, h, dx, dy: int): seq[uint8] =
  ## Mask `m` (`w` x `h`) moved by `dx`, `dy` pixels: what goes off the
  ## edge is lost, what comes in is empty.
  result = newSeq[uint8](w * h)
  if m.len != w * h: return
  let x0 = max(0, dx)
  let x1 = min(w, w + dx)
  if x1 <= x0: return
  for y in max(0, dy) ..< min(h, h + dy):
    copyMem(addr result[y * w + x0], unsafeAddr m[(y - dy) * w + x0 - dx], x1 - x0)

proc moveSelection*(d: Doc; src: openArray[uint8]; dx, dy: int) =
  ## The selection: outline `src` moved by `dx`, `dy` -- the pixels stay
  ## (a selection tool dragged inside the selection, the arrow keys).
  ## (Undoable within a step: call `touchSel` first.)
  if src.len != d.w * d.h: return
  d.sel = shiftedMask(src, d.w, d.h, dx, dy)
  inc d.selVer

proc selectAll*(d: Doc) =
  ## Select > All: the whole image.
  d.sel = newSeq[uint8](d.w * d.h)
  for v in d.sel.mitems: v = 255
  inc d.selVer

proc selectNone*(d: Doc) =
  ## Select > Deselect: nothing selected.
  d.sel.setLen(0)
  inc d.selVer

proc invertSelection*(d: Doc) =
  ## Select > Inverse: what was not selected is, and the other way round.
  if not d.hasSelection:
    d.sel = newSeq[uint8](d.w * d.h)   # all selected -> nothing
  else:
    for v in d.sel.mitems: v = 255 - v
  inc d.selVer

proc rectMask*(d: Doc; r: Rect): seq[uint8] =
  ## A mask as big as the image with `r` (clipped to it) selected.
  result = newSeq[uint8](d.w * d.h)
  let c = d.clip(r)
  for y in c.y ..< c.y + c.h:
    for x in c.x ..< c.x + c.w: result[y * d.w + x] = 255

proc ellipseMask*(d: Doc; x0, y0, x1, y1: float; antialias = true): seq[uint8] =
  ## The ellipse inside the box (`x0`, `y0`)-(`x1`, `y1`), soft-edged
  ## with `antialias`.
  result = newSeq[uint8](d.w * d.h)
  let cx = (x0 + x1) / 2
  let cy = (y0 + y1) / 2
  let rx = abs(x1 - x0) / 2
  let ry = abs(y1 - y0) / 2
  if rx < 0.5 or ry < 0.5: return
  let ya = max(0, int(floor(cy - ry)) - 1)
  let yb = min(d.h - 1, int(ceil(cy + ry)) + 1)
  let xa = max(0, int(floor(cx - rx)) - 1)
  let xb = min(d.w - 1, int(ceil(cx + rx)) + 1)
  const n = 4
  for y in ya .. yb:
    for x in xa .. xb:
      if antialias:
        var hits = 0
        for sy in 0 ..< n:
          for sx in 0 ..< n:
            let px = (x.float + (sx.float + 0.5) / n - cx) / rx
            let py = (y.float + (sy.float + 0.5) / n - cy) / ry
            if px * px + py * py <= 1: inc hits
        result[y * d.w + x] = uint8(hits * 255 div (n * n))
      else:
        let px = (x.float + 0.5 - cx) / rx
        let py = (y.float + 0.5 - cy) / ry
        if px * px + py * py <= 1: result[y * d.w + x] = 255

proc polygonMask*(d: Doc; pts: openArray[(float, float)]; antialias = true): seq[uint8] =
  ## The inside of the polygon `pts` (even-odd), soft-edged with `antialias`.
  result = newSeq[uint8](d.w * d.h)
  if pts.len < 3: return
  var ya = d.h.float
  var yb = 0.0
  for p in pts:
    ya = min(ya, p[1]); yb = max(yb, p[1])
  let n = if antialias: 4 else: 1
  var cover = newSeq[int](d.w)
  for y in max(0, int(floor(ya))) .. min(d.h - 1, int(ceil(yb))):
    for i in 0 ..< d.w: cover[i] = 0
    for sy in 0 ..< n:
      let yc = y.float + (sy.float + 0.5) / n.float
      var xs: seq[float]
      for i in 0 ..< pts.len:
        let (x0, y0) = pts[i]
        let (x1, y1) = pts[(i + 1) mod pts.len]
        if (y0 <= yc and yc < y1) or (y1 <= yc and yc < y0):
          xs.add x0 + (yc - y0) * (x1 - x0) / (y1 - y0)
      xs.sort()
      var k = 0
      while k + 1 < xs.len:
        # sub-pixel columns covered
        let a = xs[k] * n.float
        let b = xs[k + 1] * n.float
        var sx = max(0, int(ceil(a - 0.5)))
        let ex = min(d.w * n - 1, int(floor(b - 0.5)))
        while sx <= ex:
          inc cover[sx div n]
          inc sx
        k += 2
    for x in 0 ..< d.w:
      if cover[x] > 0:
        result[y * d.w + x] = uint8(min(255, cover[x] * 255 div (n * n)))

proc boxSizes(sigma: float; n: int): seq[int] =
  ## The radii of `n` box blurs that together are a gaussian blur of `sigma`.
  let wIdeal = sqrt(12 * sigma * sigma / n.float + 1)
  var wl = int(floor(wIdeal))
  if wl mod 2 == 0: dec wl
  let wu = wl + 2
  let mIdeal = (12 * sigma * sigma - n.float * (wl * wl).float - 4 * n.float * wl.float - 3 * n.float) /
               (-4 * wl.float - 4)
  let m = int(round(mIdeal))
  for i in 0 ..< n: result.add (if i < m: wl else: wu) div 2

{.push boundChecks: off, overflowChecks: off.}

proc blurMask*(m: var seq[uint8]; w, h: int; radius: float) =
  ## A gaussian blur of a mask (feathering): three box blurs, on all the
  ## cores.
  if radius <= 0.05 or m.len != w * h or w <= 0 or h <= 0: return
  let sigma = radius / 2 + 0.01
  if sigma < 0.8:
    # (small: an exact kernel)
    let r = int(ceil(sigma * 3))
    var k = newSeq[int](2 * r + 1)
    var tot = 0
    for i in -r .. r:
      k[i + r] = int(round(exp(-(i * i).float / (2 * sigma * sigma)) * 4096))
      tot += k[i + r]
    var tmp = newSeq[uint8](w * h)
    let mp = cast[ptr UncheckedArray[uint8]](addr m[0])
    let tp = cast[ptr UncheckedArray[uint8]](addr tmp[0])
    let kp = cast[ptr UncheckedArray[int]](addr k[0])
    parallelRows(h, y):
      for x in 0 ..< w:
        var acc = 0
        for i in -r .. r: acc += int(mp[y * w + clamp(x + i, 0, w - 1)]) * kp[i + r]
        tp[y * w + x] = uint8((acc + tot div 2) div tot)
    parallelRows(h, y):
      for x in 0 ..< w:
        var acc = 0
        for i in -r .. r: acc += int(tp[clamp(y + i, 0, h - 1) * w + x]) * kp[i + r]
        mp[y * w + x] = uint8((acc + tot div 2) div tot)
    return
  let mp = cast[ptr UncheckedArray[uint8]](addr m[0])
  for br0 in boxSizes(sigma, 3):
    let br = br0
    if br <= 0: continue
    let n = 2 * br + 1
    # across: each row with a running sum
    parallelRows(h, y):
      var line = newSeq[uint8](w)
      let row = y * w
      copyMem(addr line[0], addr mp[row], w)
      var acc = 0
      for i in -br .. br: acc += int(line[clamp(i, 0, w - 1)])
      for x in 0 ..< w:
        mp[row + x] = uint8((acc + n div 2) div n)
        acc += int(line[min(x + br + 1, w - 1)]) - int(line[max(x - br, 0)])
    # down: columns in pieces, a running sum for each
    parallelChunks(w, lo, hi):
      let cw = hi - lo
      var acc = newSeq[int](cw)
      var col = newSeq[uint8](h * cw)
      for y in 0 ..< h: copyMem(addr col[y * cw], addr mp[y * w + lo], cw)
      for i in -br .. br:
        let yy = clamp(i, 0, h - 1)
        for c in 0 ..< cw: acc[c] += int(col[yy * cw + c])
      for y in 0 ..< h:
        let ya = min(y + br + 1, h - 1) * cw
        let yb = max(y - br, 0) * cw
        for c in 0 ..< cw:
          mp[y * w + lo + c] = uint8((acc[c] + n div 2) div n)
          acc[c] += int(col[ya + c]) - int(col[yb + c])

{.pop.}

proc feather*(d: Doc; radius: float) =
  ## Select > Feather: softens the selection's edge by `radius` pixels.
  if not d.hasSelection: return
  blurMask(d.sel, d.w, d.h, radius)
  inc d.selVer

proc morph(m: seq[uint8]; w, h, r: int; grow: bool): seq[uint8] =
  ## Max (grow) or min (shrink) over a disc of radius `r`.
  result = m
  if r <= 0: return
  var offs: seq[(int, int)]
  for dy in -r .. r:
    for dx in -r .. r:
      if dx * dx + dy * dy <= r * r: offs.add (dx, dy)
  # by rows of the disc: a run-length max is enough at these sizes
  for y in 0 ..< h:
    for x in 0 ..< w:
      var v = if grow: 0 else: 255
      for (dx, dy) in offs:
        let xx = x + dx
        let yy = y + dy
        let s = if xx < 0 or yy < 0 or xx >= w or yy >= h: (if grow: 0 else: 255)
                else: int(m[yy * w + xx])
        if grow: (if s > v: v = s) else: (if s < v: v = s)
        if (grow and v == 255) or (not grow and v == 0): break
      result[y * w + x] = uint8(v)

proc expandSelection*(d: Doc; px: int) =
  ## Select > Modify > Expand: the selection grown by `px` pixels.
  if not d.hasSelection: return
  d.sel = morph(d.sel, d.w, d.h, px, true)
  inc d.selVer

proc contractSelection*(d: Doc; px: int) =
  ## Select > Modify > Contract: the selection shrunk by `px` pixels.
  if not d.hasSelection: return
  d.sel = morph(d.sel, d.w, d.h, px, false)
  inc d.selVer

proc borderSelection*(d: Doc; px: int) =
  ## A band `px` wide along the edge of the selection.
  if not d.hasSelection: return
  let a = morph(d.sel, d.w, d.h, max(1, px div 2), true)
  let b = morph(d.sel, d.w, d.h, max(1, px - px div 2), false)
  for i in 0 ..< d.sel.len: d.sel[i] = uint8(max(0, int(a[i]) - int(b[i])))
  blurMask(d.sel, d.w, d.h, 1.0)
  inc d.selVer

proc smoothSelection*(d: Doc; px: int) =
  ## Rounds the corners and closes the holes smaller than `px`.
  if not d.hasSelection: return
  blurMask(d.sel, d.w, d.h, px.float)
  for v in d.sel.mitems: v = (if v >= 128: 255'u8 else: 0'u8)
  inc d.selVer

# ---- channels -------------------------------------------------------------------------------------------

proc saveSelection*(d: Doc; name = ""): int =
  ## The selection into a new alpha channel; its index.
  var m = if d.hasSelection: d.sel else: newSeq[uint8](d.w * d.h)
  if not d.hasSelection:
    for v in m.mitems: v = 255
  d.alphas.add AlphaChannel(name: (if name.len > 0: name else: "#" & $(d.alphas.len + 4)), m: m)
  d.alphas.high

proc loadSelection*(d: Doc; i: int; op = soReplace; invert = false) =
  ## The alpha channel `i` as the selection, put in by `op` (inverted
  ## first with `invert`).
  if i < 0 or i >= d.alphas.len: return
  var m = d.alphas[i].m
  if invert:
    for v in m.mitems: v = 255 - v
  d.setSelection(m, op)

const
  colorModes* = {cmRGB, cmCMYK, cmLab}
    ## The modes of full color.
  editModes* = {cmRGB, cmCMYK, cmLab, cmGray, cmDuotone, cmMultichannel}
    ## The modes the filters and adjustments work in.

proc channelCount*(d: Doc): int =
  ## How many color channels the image's mode has.
  case d.mode
  of cmGray, cmBitmap, cmDuotone: 1
  of cmCMYK: 4
  of cmMultichannel: max(1, d.spots.len)
  else: 3

proc hasComposite*(d: Doc): bool =
  ## Channels lists the channels mixed first ("RGB", "CMYK"): a mode of
  ## several channels, but not Multichannel (its inks are on their own).
  d.mode != cmMultichannel and d.channelCount > 1

proc channelNames*(d: Doc): seq[string] =
  ## The color channels (the composite first when there are several, but
  ## a Multichannel image's inks alone: `hasComposite`).
  case d.mode
  of cmMultichannel:
    var names: seq[string]
    for s in d.spots: names.add s.name
    if names.len == 0: names.add "Black"
    names
  of cmGray, cmBitmap: @["Black"]
  of cmDuotone: @[(if d.duotone.len <= 1: "Monotone" elif d.duotone.len == 2: "Duotone"
                   elif d.duotone.len == 3: "Tritone" else: "Quadtone")]
  of cmCMYK: @["CMYK", "Cyan", "Magenta", "Yellow", "Black"]
  of cmLab: @["Lab", "Lightness", "a", "b"]
  of cmIndexed: @["Index", "Red", "Green", "Blue"]
  of cmRGB: @["RGB", "Red", "Green", "Blue"]

proc colorChannelsAll*(d: Doc): bool =
  ## Every color channel of the mode is on (none left out).
  for c in 0 ..< max(1, d.channelCount):
    if not d.channelsOn[c]: return false
  true

proc showAllChannels*(d: Doc) =
  ## Every color channel edited and shown again (in color).
  d.channelsOn = [true, true, true, true]
  d.viewChannel = -1

proc showChannel*(d: Doc; ch: int) =
  ## One color channel edited and shown (in gray).
  d.channelsOn = [false, false, false, false]
  d.channelsOn[clamp(ch, 0, 3)] = true
  d.viewChannel = ch

proc channelGray*(mode: ColorMode; p: uint32; ch: int): int =
  ## A color channel of a pixel as a gray (how Channels shows it): ink as
  ## black for CMYK, Lightness, a, b for Lab. (Multichannel: `channelGrayOf`.)
  case mode
  of cmCMYK: 255 - int(inkOf(p)[clamp(ch, 0, 3)])
  of cmLab: labBytes(p)[clamp(ch, 0, 2)]
  else: int((p shr (16 - 8 * clamp(ch, 0, 2))) and 255)

proc channelGrayOf*(d: Doc; p: uint32; ch: int): int =
  ## Channel `ch` of a pixel of `d` as a gray: a Multichannel image's ink
  ## as its plate shows it (black: all of the ink).
  if d.mode == cmMultichannel and d.spots.len > 0:
    let s = d.spots[clamp(ch, 0, d.spots.high)]
    channelGray(d.spotBase, p, s.ch)
  else: channelGray(d.mode, p, ch)

proc keepIn(mode: ColorMode; on: array[4, bool]; before, after: uint32): uint32 =
  case mode
  of cmCMYK:
    var a = inkOf(after)
    let b = inkOf(before)
    for c in 0 .. 3:
      if not on[c]: a[c] = b[c]
    fromInk(a, aOf(after))
  of cmLab:
    var a = labBytes(after)
    let b = labBytes(before)
    for c in 0 .. 2:
      if not on[c]: a[c] = b[c]
    fromLabBytes(a, aOf(after))
  else:
    var r = rOf(after)
    var g = gOf(after)
    var b = bOf(after)
    if not on[0]: r = rOf(before)
    if not on[1]: g = gOf(before)
    if not on[2]: b = bOf(before)
    argb(aOf(after), r, g, b)

proc keepChannels*(d: Doc; before, after: uint32): uint32 =
  ## `after` with the color channels not being edited taken from `before`
  ## (a Multichannel image: its inks not being edited, and the ones it no
  ## longer has).
  if d.mode == cmMultichannel:
    if d.spotBase in {cmGray, cmBitmap, cmDuotone}:
      return (if d.channelsOn[0]: after else: before)
    var on: array[4, bool]
    for i, s in d.spots:
      if i < 4 and s.ch in 0 .. 3: on[s.ch] = d.channelsOn[i]
    return keepIn(d.spotBase, on, before, after)
  if d.colorChannelsAll: return after
  keepIn(d.mode, d.channelsOn, before, after)

# ---- Quick Mask -----------------------------------------------------------------------------------------

proc enterQuickMask*(d: Doc) =
  ## Shows the selection as a mask to paint on: white selected, black not.
  if d.quickMask: return
  d.maskLayer = d.newLayer("Quick Mask")
  d.maskLayer.gray = true
  for i in 0 ..< d.maskLayer.px.len:
    d.maskLayer.px[i] = grayPx(d.selAt(i))
  d.maskLayer.background = true
  d.quickMask = true
  inc d.ver

proc syncQuickMask*(d: Doc) =
  ## The painted mask back into the selection (while in Quick Mask).
  if not d.quickMask or d.maskLayer == nil: return
  d.sel = newSeq[uint8](d.w * d.h)
  var all = true
  for i in 0 ..< d.sel.len:
    let v = uint8(lumaOf(d.maskLayer.px[i]))
    d.sel[i] = v
    if v != 255: all = false
  if all: d.sel.setLen(0)
  inc d.selVer

proc leaveQuickMask*(d: Doc) =
  ## Back from Quick Mask: the painted mask becomes the selection.
  if not d.quickMask: return
  d.syncQuickMask()
  d.quickMask = false
  d.maskLayer = nil
  inc d.ver

# ---- layers -----------------------------------------------------------------------------------------------

# ---- layer groups ----------------------------------------------------------------------------------

proc blockStart*(d: Doc; i: int): int =
  ## The lowest layer of layer `i` with all that is in it (a group's
  ## layers are under it): the block `blockStart(i) .. i`.
  result = i
  if i < 0 or i >= d.layers.len or not d.layers[i].group: return
  let dd = d.layers[i].depth
  while result > 0 and d.layers[result - 1].depth > dd: dec result

proc parentOf*(d: Doc; i: int): int =
  ## The group layer `i` is in (-1: none).
  if i < 0 or i >= d.layers.len: return -1
  let dd = d.layers[i].depth
  if dd == 0: return -1
  for j in i + 1 .. d.layers.high:
    if d.layers[j].depth < dd: return (if d.layers[j].group: j else: -1)
  -1

proc shownInTree*(d: Doc; i: int): bool =
  ## Visible, and in no hidden group.
  var j = i
  var n = 0
  while j >= 0 and n < 1000:
    if not d.layers[j].visible: return false
    j = d.parentOf(j)
    inc n
  true

proc hasGroups*(d: Doc): bool =
  ## The image has a layer group.
  for L in d.layers:
    if L.group: return true

proc fixDepths*(d: Doc) =
  ## The depths made right: none deeper than one under a group header (and
  ## the Background in no group).
  var open = 0
  for i in countdown(d.layers.high, 0):
    let L = d.layers[i]
    L.depth = clamp(L.depth, 0, open)
    if L.background: L.depth = 0
    open = if L.group: L.depth + 1 else: L.depth

proc newGroupLayer*(d: Doc; name = ""): Layer =
  ## A group (not added): Pass Through, as big as `d`, its pixels nothing.
  var n = 1
  for L in d.layers:
    if L.group and L.name.startsWith("Group "):
      try: n = max(n, parseInt(L.name[6 .. ^1]) + 1)
      except ValueError: discard
  Layer(name: (if name.len > 0: name else: "Group " & $n), opacity: 100, mode: bmNormal, visible: true,
        group: true, passThrough: true, px: zeroPixels(d.w * d.h))

proc insertLayer*(d: Doc; L: Layer; above = -1) =
  ## `L` put above layer `above` (-1: the current one) -- into the top of
  ## that one when it is an open group -- as deep; it becomes the current
  ## layer.
  if d.layers.len == 0:
    L.depth = 0
    d.layers.add L
    d.cur = 0
    d.markAll()
    return
  let k = clamp(if above < 0: d.cur else: above, -1, d.layers.high)
  if k < 0:
    let at = if d.layers[0].background: 1 else: 0
    L.depth = 0
    d.layers.insert(L, at)
    d.cur = at
  else:
    let ref0 = d.layers[k]
    L.depth = if ref0.group and not ref0.collapsed: ref0.depth + 1 else: ref0.depth
    let at = if ref0.group and not ref0.collapsed: k else: k + 1
    d.layers.insert(L, at)
    d.cur = at
  d.fixDepths()
  d.markAll()

proc addLayer*(d: Doc; name = ""; above = -1): Layer =
  ## A new empty layer above layer `above` (-1: the current one); it
  ## becomes the current layer. (An undoable change: `snapStep` first.)
  var n = 1
  for L in d.layers:
    if L.name.startsWith("Layer "):
      try: n = max(n, parseInt(L.name[6 .. ^1]) + 1)
      except ValueError: discard
  result = d.newLayer(if name.len > 0: name else: "Layer " & $n)
  d.insertLayer(result, above)

proc addGroup*(d: Doc; name = ""): Layer =
  ## Layer > New > Group: an empty group above the current layer.
  result = d.newGroupLayer(name)
  d.insertLayer(result)

proc blocksOf(d: Doc; idxs: seq[int]): seq[(int, int)] =
  ## The blocks (`lo .. hi`) of the layers `idxs`, the top first, none in
  ## another.
  var hs = idxs
  hs.sort(Descending)
  for i in hs:
    if i < 0 or i >= d.layers.len: continue
    var inside = false
    for (lo, hi) in result:
      if i >= lo and i <= hi: inside = true
    if inside: continue
    result.add (d.blockStart(i), i)

proc pickedLayers*(d: Doc): seq[int] =
  ## The layers picked in the Layers palette (with the current one), the
  ## top first.
  for i in countdown(d.layers.high, 0):
    if d.layers[i].picked or i == d.cur: result.add i

proc clearPicks*(d: Doc) =
  ## No layer picked in the Layers palette.
  for L in d.layers: L.picked = false

proc groupLayers*(d: Doc; idxs: seq[int]; name = ""): Layer =
  ## Layer > Group Layers: the layers `idxs` (each with what is in it) in a
  ## new group where the topmost of them is. nil when none can be (the
  ## Background cannot).
  var bl: seq[(int, int)]
  for b in d.blocksOf(idxs):
    if not d.layers[b[0]].background: bl.add b
  if bl.len == 0: return nil
  let top = bl[0][1]
  let depth0 = d.layers[top].depth
  let aboveRef = if top + 1 < d.layers.len: d.layers[top + 1] else: nil
  var moved: seq[Layer]
  for k in countdown(bl.high, 0):
    let (lo, hi) = bl[k]
    let rel = d.layers[hi].depth
    for j in lo .. hi:
      let L = d.layers[j]
      L.depth = depth0 + 1 + (L.depth - rel)
      moved.add L
  for (lo, hi) in bl:
    for j in countdown(hi, lo): d.layers.delete(j)
  var at = if aboveRef != nil: d.layers.find(aboveRef) else: d.layers.len
  if at < 0: at = d.layers.len
  result = d.newGroupLayer(name)
  result.depth = depth0
  d.layers.insert(result, at)
  for k in countdown(moved.high, 0): d.layers.insert(moved[k], at)
  d.cur = d.layers.find(result)
  d.clearPicks()
  d.fixDepths()
  d.markAll()

proc ungroup*(d: Doc; i = -1) =
  ## Layer > Ungroup Layers: the group's layers out of it, the group gone.
  let k = if i < 0: d.cur else: i
  if k < 0 or k >= d.layers.len or not d.layers[k].group: return
  let lo = d.blockStart(k)
  for j in lo ..< k: dec d.layers[j].depth
  d.layers.delete(k)
  d.cur = clamp(if k > lo: k - 1 else: k, 0, d.layers.high)
  d.fixDepths()
  d.markAll()

proc copyLayer(L: Layer; name: string): Layer =
  result = Layer(name: name, px: L.px, ver: L.ver)
  result.setSettings(settingsOf(L))
  result.name = name
  result.text = L.text
  result.textBox = L.textBox
  result.shape = L.shape
  result.shapeBox = L.shapeBox
  result.picked = false
  result.background = false
  if L.mask != nil:
    result.mask = Layer(name: "Layer Mask", px: L.mask.px, opacity: 100, visible: true, gray: true)

proc duplicateLayer*(d: Doc; i = -1): Layer =
  ## A copy of the layer (a group: with all in it) above it; the copy
  ## becomes the current layer.
  let k = if i < 0: d.cur else: i
  let lo = d.blockStart(k)
  var copies: seq[Layer]
  for j in lo .. k:
    let L = d.layers[j]
    copies.add copyLayer(L, if j == k: L.name & " copy" else: L.name)
  copies[^1].visible = true
  for c in countdown(copies.high, 0): d.layers.insert(copies[c], k + 1)
  d.cur = k + copies.len
  result = d.layers[d.cur]
  d.markAll()

proc deleteLayer*(d: Doc; i = -1) =
  ## The layer (a group: with all in it) thrown away -- not the last
  ## layer of pixels.
  let k = if i < 0: d.cur else: i
  if k < 0 or k >= d.layers.len: return
  let lo = d.blockStart(k)
  var others = 0
  for j, L in d.layers:
    if (j < lo or j > k) and not L.group: inc others
  if others == 0: return
  for j in countdown(k, lo): d.layers.delete(j)
  if d.cur > k: d.cur -= k - lo + 1
  elif d.cur >= lo: d.cur = lo
  d.cur = clamp(d.cur, 0, d.layers.high)
  d.fixDepths()
  d.markAll()

proc moveBlock*(d: Doc; i, gap: int; depth = -1): bool {.discardable.} =
  ## Layer `i` (a group: with all in it) to the gap `gap` (put before the
  ## layer that is `gap` now: 0 the bottom, `layers.len` the top), as deep
  ## as `depth` allows there (-1: in the open group over the gap, else as
  ## deep as the layer over it). Not the Background, nor into itself.
  if i < 0 or i >= d.layers.len or d.layers[i].background: return false
  let lo = d.blockStart(i)
  var g = clamp(gap, 0, d.layers.len)
  if g > lo and g <= i: return false                 # (into itself)
  let curL = d.layers[clamp(d.cur, 0, d.layers.high)]
  let blk = d.layers[lo .. i]
  let rel = d.layers[i].depth
  if g > i: g -= blk.len
  for j in countdown(i, lo): d.layers.delete(j)
  if g == 0 and d.layers.len > 0 and d.layers[0].background: g = 1
  # the depths it may have there: from the layer under the gap's to one
  # deeper than the group over it
  var hiD, loD, want: int
  if g >= d.layers.len:
    hiD = 0
  else:
    let u = d.layers[g]
    hiD = if u.group: u.depth + 1 else: u.depth
  loD = if g > 0: min(d.layers[g - 1].depth, hiD) else: 0
  if depth >= 0: want = depth
  elif g < d.layers.len and d.layers[g].group:
    want = if d.layers[g].collapsed: d.layers[g].depth else: hiD
  else: want = hiD
  want = clamp(want, loD, hiD)
  for L in blk: L.depth = want + (L.depth - rel)
  for k in countdown(blk.high, 0): d.layers.insert(blk[k], g)
  d.cur = max(0, d.layers.find(curL))
  d.fixDepths()
  d.markAll()
  true

proc moveLayer*(d: Doc; i, to: int) =
  ## Layer `i` (with all in it) to place `to` (the Background stays at the
  ## bottom).
  if i < 0 or i >= d.layers.len: return
  let gap = if to > i: to + 1 else: to
  discard d.moveBlock(i, gap)

type Arrange* = enum
  ## Where Layer > Arrange moves a layer (`arrange`).
  arFront = "Bring to Front", arForward = "Bring Forward", arBackward = "Send Backward",
  arBack = "Send to Back"

proc arrange*(d: Doc; how: Arrange; i = -1): bool {.discardable.} =
  ## Layer > Arrange: the layer (with all in it) among the others in its
  ## group -- into an open group it meets, out of its group at an end.
  let k = if i < 0: d.cur else: i
  if k < 0 or k >= d.layers.len or d.layers[k].background: return false
  let L = d.layers[k]
  let lo = d.blockStart(k)
  let par = d.parentOf(k)
  let top = if par >= 0: par else: d.layers.len           # (the gap at the top of its group)
  var bottom = if par >= 0: d.blockStart(par) else: 0
  if bottom == 0 and d.layers[0].background: bottom = 1
  case how
  of arFront:
    if k + 1 >= top: return false
    d.moveBlock(k, top, L.depth)
  of arBack:
    if lo <= bottom: return false
    d.moveBlock(k, bottom, L.depth)
  of arForward:
    if k + 1 >= top:
      if par < 0: return false
      return d.moveBlock(k, par + 1, L.depth - 1)        # (out of its group: over it)
    var hb = k + 1                                       # (the block over it: its top)
    while hb < d.layers.high and d.layers[hb].depth > L.depth: inc hb
    let over = d.layers[hb]
    if over.group and not over.collapsed:
      # into it, at its bottom (where it is, one deeper)
      for j in lo .. k: inc d.layers[j].depth
      d.fixDepths()
      d.markAll()
      true
    else:
      d.moveBlock(k, hb + 1, L.depth)
  of arBackward:
    if lo <= bottom:
      if par < 0: return false
      return d.moveBlock(k, d.blockStart(par), L.depth - 1)   # (out of its group: under it)
    let under = d.layers[lo - 1]
    if under.group and not under.collapsed:
      d.moveBlock(k, lo - 1, under.depth + 1)            # (into it, at its top)
    else:
      d.moveBlock(k, d.blockStart(lo - 1), L.depth)

proc addTextLayer*(d: Doc; t: TextData; above = -1): Layer =
  ## A new type layer showing `t` (named after what it says), the current
  ## one. (Undoable in a step: `touchLayers` first.)
  result = d.addLayer(t.layerName, above)
  result.text = t
  if result.text.spans.len == 0: result.text.spans.add TextSpan(text: "", style: defaultStyle())
  d.drawText(result)

proc layerFromBackground*(d: Doc; i = 0) =
  ## The Background as an ordinary layer ("Layer 0") that can be
  ## transparent and moved.
  if i < 0 or i >= d.layers.len or not d.layers[i].background: return
  d.layers[i].background = false
  d.layers[i].name = "Layer 0"

proc mergeGroup*(d: Doc; i = -1) =
  ## Layer > Merge Group: a group made one layer of its layers mixed (with
  ## its opacity, mode and mask).
  let k = if i < 0: d.cur else: i
  if k < 0 or k >= d.layers.len or not d.layers[k].group: return
  let G = d.layers[k]
  let lo = d.blockStart(k)
  var kids: seq[Layer]
  for j in lo ..< k: kids.add d.layers[j]
  let base = d.blockStart(k)
  discard base
  var px = zeroPixels(d.w * d.h)
  # (its layers alone: as if it were not mixing through)
  for L in kids: L.depth -= G.depth + 1
  d.compositeInto(px, d.bounds, kids)
  for L in kids: L.depth += G.depth + 1
  let L = Layer(name: G.name, px: px, opacity: G.opacity, mode: (if G.passThrough: bmNormal else: G.mode),
                visible: G.visible, mask: G.mask, maskOff: G.maskOff, depth: G.depth)
  L.maskClear = G.maskClear
  L.maskFeather = G.maskFeather
  for j in countdown(k, lo): d.layers.delete(j)
  d.layers.insert(L, lo)
  d.cur = lo
  d.fixDepths()
  d.markAll()

proc canMergeDown*(d: Doc): bool =
  ## Whether Merge Down (Merge Group for a group) can be done.
  if d.cur < 0 or d.cur >= d.layers.len: return false
  let L = d.layers[d.cur]
  if L.group: return true
  if d.cur == 0: return false
  let u = d.layers[d.cur - 1]
  u.adjust.kind.len == 0 and not u.group and u.depth == L.depth

proc mergeDown*(d: Doc) =
  ## The current layer (its mask, or its adjustment) into the one under
  ## it -- not into an adjustment layer or a group (a group: Merge Group).
  if d.cur < 0 or d.cur >= d.layers.len: return
  if d.layers[d.cur].group:
    d.mergeGroup()
    return
  if d.cur <= 0: return
  let top = d.layers[d.cur]
  let under = d.layers[d.cur - 1]
  if under.adjust.kind.len > 0 or under.group or under.depth != top.depth: return
  var px = zeroPixels(d.w * d.h)
  let base = Layer(px: under.px, opacity: 100, mode: bmNormal, visible: true, mask: under.mask,
                   maskOff: under.maskOff, fx: under.fx, clearFill: under.clearFill, ver: under.ver)
  base.maskClear = under.maskClear
  base.maskFeather = under.maskFeather
  let topC = copyLayer(top, top.name)
  topC.ver = top.ver
  topC.depth = 0
  topC.visible = true
  d.compositeInto(px, d.bounds, @[base, topC])
  under.px = px
  if under.mask != nil and not under.maskOff:
    under.mask = nil                  # (its mask is in the pixels now)
  under.fx = LayerFx()                # (and its style)
  under.clearFill = 0
  under.text = TextData()             # (type: pixels now)
  under.shape = ShapeData()
  under.smart = nil
  under.blendIf = BlendIf()
  inc under.ver
  d.layers.delete(d.cur)
  dec d.cur
  d.markAll()

proc mergeVisible*(d: Doc) =
  ## The visible layers into one (where the lowest visible one is); hidden
  ## ones stay, out of their groups.
  var vis: seq[int]
  for i, L in d.layers:
    if not L.group and d.shownInTree(i): vis.add i
  if vis.len < 2 and not d.hasGroups: return
  if vis.len == 0: return
  var px = zeroPixels(d.w * d.h)
  d.compositeInto(px, d.bounds, d.layers)
  let keep = d.layers[vis[0]]
  keep.px = px
  keep.opacity = 100
  keep.mode = bmNormal
  keep.mask = nil
  keep.gray = false
  keep.adjust = Adjustment()
  keep.text = TextData()
  keep.shape = ShapeData()
  keep.fx = LayerFx()
  keep.clearFill = 0
  keep.smart = nil
  keep.blendIf = BlendIf()
  keep.clipped = false
  keep.depth = 0
  inc keep.ver
  var gone: seq[int]
  for k in 1 .. vis.high: gone.add vis[k]
  for i, L in d.layers:
    if L.group and d.shownInTree(i): gone.add i
  gone.sort(Descending)
  for i in gone: d.layers.delete(i)
  for L in d.layers:
    if L != keep and not L.group and L.depth > 0 and d.parentOf(d.layers.find(L)) < 0: L.depth = 0
  d.cur = max(0, d.layers.find(keep))
  d.fixDepths()
  d.markAll()

proc flatten*(d: Doc; bg = 0xFFFFFFFF'u32) =
  ## All layers into the Background (hidden ones are dropped).
  let L = Layer(name: "Background", opacity: 100, mode: bmNormal, visible: true)
  L.px = d.flattened(bg)
  L.background = true
  d.layers = @[L]
  d.cur = 0
  d.markAll()

# ---- layer masks, adjustment layers --------------------------------------------------------------------

type MaskFill* = enum
  ## What a new layer mask shows.
  mfRevealAll = "Reveal All", mfHideAll = "Hide All", mfRevealSelection = "Reveal Selection",
  mfHideSelection = "Hide Selection"

proc grayLayer(d: Doc; name: string; f: proc (i: int): int): Layer =
  result = Layer(name: name, opacity: 100, mode: bmNormal, visible: true, gray: true,
                 px: newSeqUninit[uint32](d.w * d.h))
  for i in 0 ..< d.w * d.h: result.px[i] = grayPx(f(i))

proc addLayerMask*(d: Doc; how = mfRevealAll; i = -1) =
  ## Layer > Add Layer Mask: white shows the layer, black hides it (not on
  ## the Background or an adjustment layer, whose pixels are its mask).
  ## Undoable (in a step: `touchLayers`).
  let L = d.layers[clamp(if i < 0: d.cur else: i, 0, d.layers.high)]
  if L.background or L.mask != nil or L.adjust.kind.len > 0: return
  d.touchLayers()
  L.mask = d.grayLayer("Layer Mask", proc (k: int): int =
    case how
    of mfRevealAll: 255
    of mfHideAll: 0
    of mfRevealSelection: d.selAt(k)
    of mfHideSelection: 255 - d.selAt(k))
  L.maskOff = false
  inc L.ver
  d.markAll()

proc removeLayerMask*(d: Doc; apply = false; i = -1) =
  ## Layer > Remove Layer Mask: thrown away, or applied (the layer's
  ## transparency made by it). Undoable (in a step).
  let L = d.layers[clamp(if i < 0: d.cur else: i, 0, d.layers.high)]
  if L.mask == nil: return
  d.touchLayers()
  if apply and not L.maskOff and L.mask.px.len == L.px.len:
    d.touch(L, d.bounds)
    for k in 0 ..< L.px.len:
      L.px[k] = withAlpha(L.px[k], aOf(L.px[k]) * rOf(L.mask.px[k]) div 255)
  L.mask = nil
  L.maskOff = false
  d.editMask = false
  inc L.ver
  d.markAll()

proc newAdjustmentLayer*(d: Doc; a: Adjustment; name = ""): Layer =
  ## Layer > New Adjustment Layer above the current one: it changes the
  ## layers under it where its mask (its pixels: the selection, or all)
  ## lets. Undoable (in a step).
  d.touchLayers()
  result = d.grayLayer(if name.len > 0: name else: a.kind, proc (k: int): int = d.selAt(k))
  result.adjust = a
  d.insertLayer(result)
  d.editMask = false

proc setAdjustment*(d: Doc; L: Layer; a: Adjustment) =
  ## An adjustment layer's settings changed (undoable in a step).
  d.touchLayers()
  L.adjust = a
  inc L.ver
  d.markAll()

# ---- reading and changing pixels -----------------------------------------------------------------------

proc pixelAt*(d: Doc; x, y: int; merged = true): uint32 =
  ## The pixel at `x`, `y`: of the image as it looks, or of the current layer.
  if x < 0 or y < 0 or x >= d.w or y >= d.h: return 0
  if merged:
    d.updateComposite()
    d.compPtr[y * d.w + x]
  else: d.layer.px[y * d.w + x]

proc sampleAt*(d: Doc; x, y, size: int; merged = true): uint32 =
  ## The average of a `size` x `size` square around `x`, `y` (1, 3, 5).
  if size <= 1: return d.pixelAt(x, y, merged)
  var sa, sr, sg, sb, n = 0
  let h = size div 2
  for yy in y - h .. y + h:
    for xx in x - h .. x + h:
      if xx < 0 or yy < 0 or xx >= d.w or yy >= d.h: continue
      let p = d.pixelAt(xx, yy, merged)
      let a = aOf(p)
      sa += a; sr += rOf(p) * a; sg += gOf(p) * a; sb += bOf(p) * a
      inc n
  if sa == 0: return 0
  argb(sa div max(1, n), sr div sa, sg div sa, sb div sa)

proc paintTarget*(d: Doc): Layer = d.layer
  ## Where painting goes now (the Quick Mask while it is on).

proc applyAt*(d: Doc; L: Layer; i: int; before, after: uint32; amount: int): uint32 {.inline.} =
  ## `after` put on pixel `i` of `L` over `before` by `amount` (0..255)
  ## times the selection, keeping the channels not edited and (Preserve
  ## Transparency, the Background) the alpha.
  let s = if L == d.maskLayer: amount else: d.selAt(i) * amount div 255
  if s <= 0: return before
  var a = after
  if L.gray:
    a = grayPx(lumaOf(a))            # (a mask: gray, opaque)
  else:
    a = d.keepChannels(before, a)
    if L.lockAlpha or L.background: a = a.withAlpha(aOf(before))
  if s >= 255: return a
  mix(before, a, s / 255)

proc mapPixels*(d: Doc; L: Layer; r: Rect; f: proc (p: uint32; x, y: int): uint32) =
  ## Changes the pixels of `L` in `r` (and in the selection) with `f`.
  ## Saves them for undo when a step is open.
  let c = d.clip(intersect(r, d.selBounds))
  if c.w <= 0 or c.h <= 0: return
  d.touch(L, c)
  for y in c.y ..< c.y + c.h:
    for x in c.x ..< c.x + c.w:
      let i = y * d.w + x
      if d.selAt(i) == 0: continue
      let p = L.px[i]
      L.px[i] = d.applyAt(L, i, p, f(p, x, y), 255)
  inc L.ver
  if L == d.maskLayer: d.syncQuickMask()
  d.markDirty(c)

proc fillSelection*(d: Doc; c: uint32; opacity = 100; mode = bmNormal; L: Layer = nil) =
  ## Fills the selection (all of the layer when there is none).
  let t = if L == nil: d.layer else: L
  let op = opacity * 255 div 100
  let c2 = if t == d.maskLayer: grayPx(lumaOf(c)) else: c
  d.mapPixels(t, d.bounds, proc (p: uint32; x, y: int): uint32 =
    blendPx(p, c2, op, mode, x, y))

proc clearSelection*(d: Doc; bg: uint32) =
  ## Delete: the selection becomes transparent (the background color on
  ## the Background or with Preserve Transparency).
  let L = d.layer
  if L.background or L.lockAlpha or L == d.maskLayer:
    d.fillSelection(if L == d.maskLayer: 0xFF000000'u32 else: bg, L = L)
  else:
    let c = d.clip(d.selBounds)
    d.touch(L, c)
    for y in c.y ..< c.y + c.h:
      for x in c.x ..< c.x + c.w:
        let i = y * d.w + x
        let s = d.selAt(i)
        if s > 0:
          L.px[i] = withAlpha(L.px[i], aOf(L.px[i]) * (255 - s) div 255)
    inc L.ver
    d.markDirty(c)

proc strokeSelection*(d: Doc; c: uint32; width: int; location = 1; opacity = 100;
                      mode = bmNormal) =
  ## Edit > Stroke: a band `width` wide along the selection's edge, inside
  ## (0), centered (1) or outside (2) it.
  if not d.hasSelection: return
  let hard = block:
    var m = d.sel
    for v in m.mitems: v = (if v >= 128: 255'u8 else: 0'u8)
    m
  let outer = case location
              of 0: hard
              of 1: morph(hard, d.w, d.h, max(1, width div 2), true)
              else: morph(hard, d.w, d.h, width, true)
  let inner = case location
              of 0: morph(hard, d.w, d.h, width, false)
              of 1: morph(hard, d.w, d.h, max(1, width - width div 2), false)
              else: hard
  var band = newSeq[uint8](d.w * d.h)
  for i in 0 ..< band.len: band[i] = uint8(max(0, int(outer[i]) - int(inner[i])))
  let saved = d.sel
  d.sel = band
  inc d.selVer
  d.fillSelection(c, opacity, mode)
  d.sel = saved
  inc d.selVer

# ---- Apply Image, Calculations -----------------------------------------------------------------------------

proc sourcePixels*(d: Doc; layer: int): seq[uint32] =
  ## A source of Apply Image or Calculations: one layer's pixels, or (-1)
  ## the image as it looks.
  if layer < 0 or layer >= d.layers.len: d.flattened() else: d.layers[layer].px

proc channelOf*(px: seq[uint32]; ch: int; invert = false): seq[uint8] =
  ## One channel of pixels as gray: 0 their lightness, 1 red, 2 green, 3 blue.
  result = newSeq[uint8](px.len)
  for i, p in px:
    let v = case ch
            of 1: rOf(p)
            of 2: gOf(p)
            of 3: bOf(p)
            else: lumaOf(p)
    result[i] = uint8(if invert: 255 - v else: v)

proc applyImage*(d: Doc; src: seq[uint32]; mode = bmNormal; opacity = 100) =
  ## Image > Apply Image: `src` (as big as the image) mixed into the current
  ## layer by `mode`, in the selection.
  if src.len != d.w * d.h: return
  let op = clamp(opacity, 0, 100) * 255 div 100
  let w = d.w
  d.mapPixels(d.layer, d.bounds, proc (p: uint32; x, y: int): uint32 =
    blendPx(p, src[y * w + x], op, mode, x, y))

proc calculate*(a, b: seq[uint8]; mode = bmNormal; opacity = 100): seq[uint8] =
  ## Image > Calculations: channel `b` mixed onto channel `a` by `mode`.
  result = newSeq[uint8](min(a.len, b.len))
  let op = clamp(opacity, 0, 100) * 255 div 100
  for i in 0 ..< result.len:
    let o = blendPx(grayPx(int(a[i])), grayPx(int(b[i])), op, mode, i, 0)
    result[i] = uint8(lumaOf(o))

# ---- copy and paste ------------------------------------------------------------------------------------------

type Clip* = object
  ## What Copy keeps: pixels with their place, and the mask they had.
  w*, h*: int              ## its size
  px*: seq[uint32]         ## its pixels (the selection in their alpha)
  x*, y*: int              ## where they were copied from (document pixels)

proc copySelection*(d: Doc; merged = false): Clip =
  ## The selected pixels of the current layer (or of the image as it looks)
  ## within the selection's rectangle, with the selection as their alpha.
  let r = d.clip(d.selBounds)
  result = Clip(w: r.w, h: r.h, x: r.x, y: r.y, px: newSeq[uint32](r.w * r.h))
  if merged: d.updateComposite()
  let src = if merged: d.compPtr else: pixPtr(d.layer.px)
  for y in 0 ..< r.h:
    for x in 0 ..< r.w:
      let i = (r.y + y) * d.w + r.x + x
      let p = src[i]
      result.px[y * r.w + x] = withAlpha(p, aOf(p) * d.selAt(i) div 255)

proc pasteAsLayer*(d: Doc; c: Clip; centered = false; name = ""): Layer =
  ## The clipboard in a new layer, where it was copied from (or centered).
  ## (An undoable change: `snapStep` first.)
  result = d.addLayer(name)
  let x0 = if centered or c.x + c.w > d.w or c.y + c.h > d.h: (d.w - c.w) div 2 else: c.x
  let y0 = if centered or c.x + c.w > d.w or c.y + c.h > d.h: (d.h - c.h) div 2 else: c.y
  for y in 0 ..< c.h:
    for x in 0 ..< c.w:
      let tx = x0 + x
      let ty = y0 + y
      if tx >= 0 and ty >= 0 and tx < d.w and ty < d.h:
        result.px[ty * d.w + tx] = c.px[y * c.w + x]
  d.markAll()

# ---- moving pixels ---------------------------------------------------------------------------------------------

type
  LiftPart = object
    layer: Layer
    px: seq[uint32]          # what was lifted (the layer's size); empty: the layer's own pixels
    base: seq[uint32]        # the layer without it; empty: `baseFill` (or the layer as it is: `keep`)
    baseFill: uint32
    keep: bool               # (a copy lifted) the layer stays as it is under it
    vector: bool             # a type or shape layer: what it holds moves, drawn again
    text: TextData
    shape: ShapeData
  Lift* = object
    ## Pixels being moved (with the Move tool): taken out of the layers at
    ## the start, shown at the offset each time it changes (live, see
    ## `LivePart`), put down by `endMove`. The whole layer moves with its
    ## mask; a group, all in it.
    active*: bool            ## a move is under way (`beginMove` .. `endMove`)
    parts: seq[LiftPart]
    mask: seq[uint8]
    dx*, dy*: int            ## how far the pixels are moved
    pending: bool            # moved, not put down yet (`endMove`)

proc movedLayers*(d: Doc): seq[int] =
  ## The layers the Move tool moves (not their groups' insides): the
  ## current one, those picked with it, and those linked to any of them.
  let k = clamp(d.cur, 0, d.layers.high)
  var links: seq[int]
  for i, L in d.layers:
    if (i == k or L.picked) and L.link != 0 and L.link notin links: links.add L.link
  for i, L in d.layers:
    if i == k or L.picked or (L.link != 0 and L.link in links): result.add i

proc liftedLayers(d: Doc): seq[Layer] =
  ## (what the Move tool moves without a selection: the layers and their
  ## masks, or a group's layers and masks -- not those locked)
  if d.quickMask or d.editMask: return @[d.layer]
  for k in d.movedLayers:
    for j in d.blockStart(k) .. k:
      let L = d.layers[j]
      if L.locked or L.lockPosition or L in result: continue
      if not L.group: result.add L
      if L.mask != nil and L.mask.px.len == d.w * d.h and L.mask notin result: result.add L.mask

proc linkLayers*(d: Doc; idxs: seq[int]) =
  ## Links the layers (Link Layers): they move together. Layers linked
  ## already among them: all linked as one.
  if idxs.len < 2: return
  var n = 1
  for L in d.layers: n = max(n, L.link + 1)
  for i in idxs:
    if i >= 0 and i < d.layers.len: d.layers[i].link = n
  inc d.ver

proc unlinkLayers*(d: Doc; idxs: seq[int]) =
  ## Unlinks the layers (a link left with one layer goes too).
  for i in idxs:
    if i >= 0 and i < d.layers.len: d.layers[i].link = 0
  var counts: Table[int, int]
  for L in d.layers:
    if L.link != 0: counts.mgetOrPut(L.link, 0) += 1
  for L in d.layers:
    if L.link != 0 and counts.getOrDefault(L.link) < 2: L.link = 0
  inc d.ver

proc srcOf(part: LiftPart): ptr UncheckedArray[uint32] =
  if part.px.len > 0: pixPtr(part.px) else: pixPtr(part.layer.px)

proc baseOf(part: LiftPart): ptr UncheckedArray[uint32] =
  if part.base.len > 0: pixPtr(part.base) elif part.keep: pixPtr(part.layer.px) else: nil

proc beginMove*(d: Doc; fill: uint32; copy = false): Lift =
  ## Lifts the selection (or the whole layer: with its mask; a group: all
  ## in it) of the current layer; `fill` is left behind on the Background.
  ## `copy`: a copy of the selection is lifted, nothing left behind. (The
  ## layers are not changed -- nor copied for undo -- until it is put down
  ## by `endMove`: until then it is shown moved.)
  result = Lift(active: true)
  if d.hasSelection or d.quickMask or d.editMask:
    let L = d.layer
    if d.hasSelection:
      result.mask = d.sel
      var part = LiftPart(layer: L, px: newSeqUninit[uint32](L.px.len), keep: copy)
      if not copy: part.base = newSeqUninit[uint32](L.px.len)
      let lp = pixPtr(L.px)
      let pp = pixPtr(part.px)
      let bp = if copy: nil else: pixPtr(part.base)
      let sp = cast[ptr UncheckedArray[uint8]](addr d.sel[0])
      let solid = L.background or L.lockAlpha
      parallelFor(L.px.len, proc (a, b: int) =
        for i in a ..< b:
          let s = int(sp[i])
          let p = lp[i]
          if s == 0:
            pp[i] = 0
            if bp != nil: bp[i] = p
          else:
            pp[i] = withAlpha(p, int(p shr 24) * s div 255)
            if bp != nil:
              bp[i] = if solid: mix(p, fill, s / 255)
                      else: withAlpha(p, int(p shr 24) * (255 - s) div 255), grain = 65536)
      result.parts.add part
    else:
      result.parts.add LiftPart(layer: L, baseFill: (if L.background: fill else: 0'u32))
    return
  for L in d.liftedLayers:
    if L.isVector:
      d.touchLayers()
      result.parts.add LiftPart(layer: L, vector: true, text: L.text, shape: L.shape)
      continue
    # (left behind: the Background's color, a mask's white, else nothing)
    let left = if L.background: fill elif L.gray: 0xFFFFFFFF'u32 else: 0'u32
    result.parts.add LiftPart(layer: L, baseFill: left)

proc setLive*(d: Doc; parts: seq[LivePart]) =
  ## Shows `parts` (see `LivePart`) until `endLive`: the views draw them
  ## from the layers at their own size; the image is not changed.
  d.live = parts
  inc d.liveVer

proc liveChanged*(d: Doc) =
  ## After `live` was changed in place (a corner moved): shown again.
  ## (Only views follow `liveVer`: what the image is -- `ver` -- has not
  ## changed, so thumbnails and palettes are not made again.)
  inc d.liveVer

proc endLive*(d: Doc) =
  ## Back to showing the image as it is.
  if d.live.len == 0 and d.liveSel == (0, 0, false): return
  d.live.setLen(0)
  d.liveSel = (0, 0, false)
  inc d.liveVer

proc shiftedOnto(d: Doc; part: LiftPart; dx, dy: int) =
  ## (a lifted part put down moved by `dx`, `dy`: the layer's pixels made
  ## again from what stays and what moved, on all the cores; the old ones
  ## go to the step, not copied)
  let L = part.layer
  let w = d.w
  let h = d.h
  var res = newSeqUninit[uint32](w * h)
  let lp = pixPtr(res)
  let bp = baseOf(part)
  let fill = part.baseFill
  let sp = srcOf(part)
  let mask = L.gray
  parallelRows(h, y):
    if bp != nil: copyMem(addr lp[y * w], addr bp[y * w], w * 4)
    else:
      for x in 0 ..< w: lp[y * w + x] = fill
    let sy = y - dy
    if sy >= 0 and sy < h:
      for x in max(0, dx) ..< min(w, w + dx):
        let p = sp[sy * w + x - dx]
        if mask: lp[y * w + x] = p or 0xFF000000'u32
        elif (p shr 24) == 255: lp[y * w + x] = p
        elif (p shr 24) > 0: lp[y * w + x] = blendPx(lp[y * w + x], p, 255, bmNormal)
  discard d.touchWhole(L)
  L.px = move(res)
  inc L.ver

proc shiftedMask(m: seq[uint8]; w, h, dx, dy: int): seq[uint8] =
  ## (a selection moved by `dx`, `dy`: nothing comes in)
  result = newSeq[uint8](w * h)
  let sp = cast[ptr UncheckedArray[uint8]](unsafeAddr m[0])
  let op = cast[ptr UncheckedArray[uint8]](addr result[0])
  let x0 = max(0, dx)
  let x1 = min(w, w + dx)
  if x1 <= x0: return
  parallelRows(h, y):
    let sy = y - dy
    if sy >= 0 and sy < h:
      copyMem(addr op[y * w + x0], unsafeAddr sp[sy * w + x0 - dx], x1 - x0)

proc moveTo*(d: Doc; m: var Lift; dx, dy: int) =
  ## Shows the lifted pixels moved by `dx`, `dy` (the selection moves too):
  ## live (see `LivePart`) -- nothing is done to the image until `endMove`,
  ## which puts them down where they were moved last.
  if not m.active: return
  m.dx = dx
  m.dy = dy
  var parts: seq[LivePart]
  for part in m.parts.mitems:
    let L = part.layer
    if part.vector:
      # (type and shapes: drawn again where they go, as they are small)
      if L.isText: d.setText(L, part.text.moved(dx.float32, dy.float32))
      elif L.isShape:
        var s = part.shape
        s.path.mapPoints(proc (x, y: float): (float, float) = (x + dx.float, y + dy.float))
        d.setShape(L, s)
      continue
    parts.add LivePart(layer: L, kind: lkShift, base: baseOf(part), baseFill: part.baseFill,
                       src: srcOf(part), dx: dx, dy: dy, replace: L.gray)
  m.pending = parts.len > 0 or m.mask.len > 0
  if parts.len > 0 or m.mask.len > 0:
    d.setLive(parts)
    d.liveSel = (dx, dy, false)

proc endMove*(d: Doc; m: var Lift) =
  ## Puts the lifted pixels down where `moveTo` showed them last.
  if m.active and m.pending:
    d.endLive()
    for part in m.parts:
      if m.dx == 0 and m.dy == 0: break     # (put back where it was: nothing changes)
      if not part.vector: d.shiftedOnto(part, m.dx, m.dy)
    if m.mask.len == d.w * d.h and (m.dx != 0 or m.dy != 0):
      d.sel = shiftedMask(m.mask, d.w, d.h, m.dx, m.dy)
      inc d.selVer
    d.markAll()
  m.pending = false
  m.active = false
  m.parts.setLen(0)

proc shiftLayers*(d: Doc; layers: seq[Layer]; dx, dy: int) =
  ## The layers moved by `dx`, `dy` (what goes past the edges is lost; type
  ## and shapes stay what they are). Undoable in a step (their pixels are
  ## saved here).
  if dx == 0 and dy == 0: return
  let w = d.w
  let h = d.h
  for L in layers:
    if L.group: continue
    if L.isText:
      d.touchLayers()
      d.setText(L, L.text.moved(dx.float32, dy.float32))
      continue
    if L.isShape:
      d.touchLayers()
      var s = L.shape
      s.path.mapPoints(proc (x, y: float): (float, float) = (x + dx.float, y + dy.float))
      d.setShape(L, s)
      continue
    for P in [L, L.mask]:
      if P == nil or P.px.len != w * h: continue
      d.touch(P, d.bounds)
      let src = P.px
      let left = if P.gray: 0xFFFFFFFF'u32 elif L.background: src[0] else: 0'u32
      let sp = pixPtr(src)
      let lp = pixPtr(P.px)
      parallelRows(h, y):
        let sy = y - dy
        for x in 0 ..< w:
          let sx = x - dx
          lp[y * w + x] = if sy >= 0 and sy < h and sx >= 0 and sx < w: sp[sy * w + sx] else: left
      inc P.ver
    if L.smart != nil:
      var q = L.smart.quad
      for c in q.mitems: c = (c[0] + dx.float, c[1] + dy.float)
      L.smart = SmartData(src: L.smart.src, w: L.smart.w, h: L.smart.h, quad: q, filters: L.smart.filters,
                          name: L.smart.name, file: L.smart.file, warp: L.smart.warp)
  d.markAll()

proc contentBounds*(d: Doc; L: Layer): Rect =
  ## Where a layer has something (its alpha), a group's layers together; an
  ## adjustment layer: all of it. Empty when it has nothing.
  if L.group:
    let k = d.layers.find(L)
    if k < 0: return
    for j in d.blockStart(k) ..< k:
      let c = d.contentBounds(d.layers[j])
      if c.w > 0: result = if result.w > 0: union(result, c) else: c
    return
  if L.adjust.kind.len > 0: return d.bounds
  if L.px.len != d.w * d.h: return
  let w = d.w
  let h = d.h
  var ys = newSeq[(int, int)](h)          # (the first and last x with something, each row)
  let lp = pixPtr(L.px)
  let yp = cast[ptr UncheckedArray[(int, int)]](addr ys[0])
  parallelRows(h, y):
    var a = -1
    var b = -1
    for x in 0 ..< w:
      if (lp[y * w + x] shr 24) != 0:
        a = x
        break
    if a >= 0:
      for x in countdown(w - 1, a):
        if (lp[y * w + x] shr 24) != 0:
          b = x
          break
    yp[y] = (a, b)
  var x0 = w
  var x1 = -1
  var y0 = -1
  var y1 = -1
  for y in 0 ..< h:
    if ys[y][0] < 0: continue
    if y0 < 0: y0 = y
    y1 = y
    x0 = min(x0, ys[y][0])
    x1 = max(x1, ys[y][1])
  if y0 < 0: return
  rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)

type
  AlignHow* = enum
    ## What Layer > Align lines layers up by (`alignLayers`).
    alTop = "Top Edges", alVCenter = "Vertical Centers", alBottom = "Bottom Edges",
    alLeft = "Left Edges", alHCenter = "Horizontal Centers", alRight = "Right Edges"
  DistributeHow* = enum
    ## What Layer > Distribute spaces layers evenly by (`distributeLayers`).
    dsTop = "Top Edges", dsVCenter = "Vertical Centers", dsBottom = "Bottom Edges",
    dsLeft = "Left Edges", dsHCenter = "Horizontal Centers", dsRight = "Right Edges",
    dsHSpace = "Horizontal Spacing", dsVSpace = "Vertical Spacing"


var nextLayerUid = 0

proc uidOf*(L: Layer): int =
  ## The layer's `uid` (given the first time it is asked for).
  if L.uid == 0:
    inc nextLayerUid
    L.uid = nextLayerUid
  L.uid

proc layerOfUid*(d: Doc; uid: int): Layer =
  ## The layer whose `uid` that is (nil: none).
  if uid == 0: return nil
  for L in d.layers:
    if L.uid == uid: return L

proc compBox(d: Doc; L: Layer): Rect =
  if L.isText:
    let b = L.textBounds
    if b.w > 0: return b
  d.contentBounds(L)

proc layerBox*(d: Doc; L: Layer): Rect =
  ## Where a layer's content is (its text's box for type), as layer comps
  ## and frames keep its place.
  d.compBox(L)

proc captureComp*(d: Doc; name: string; visibility = true; position = true; appearance = true;
                  comment = ""): LayerComp =
  ## The document's look now, as a layer comp.
  result = LayerComp(name: name, comment: comment, visibility: visibility, position: position,
                     appearance: appearance)
  for L in d.layers:
    let b = if L.group or L.adjust.kind.len > 0: rect(0, 0, 0, 0) else: d.compBox(L)
    result.states.add CompState(uid: L.uidOf, visible: L.visible, x: b.x, y: b.y, opacity: L.opacity,
                                fill: L.fill, mode: L.mode, fx: L.fx)

proc applyComp*(d: Doc; c: LayerComp) =
  ## The document as the comp `c` kept it (what it keeps of it: which
  ## layers show, where they are, how they look). Layers made since are
  ## left as they are. Undoable in a step (`snapStep` first).
  for s in c.states:
    let L = d.layerOfUid(s.uid)
    if L == nil: continue
    if c.visibility: L.visible = s.visible
    if c.appearance:
      L.opacity = s.opacity
      L.fill = s.fill
      L.mode = s.mode
      L.fx = s.fx
    if c.position and not L.group and L.adjust.kind.len == 0:
      let b = d.compBox(L)
      if b.w > 0 and (b.x != s.x or b.y != s.y): d.shiftLayers(@[L], s.x - b.x, s.y - b.y)
  d.markAll()

proc alignLayers*(d: Doc; idxs: seq[int]; how: AlignHow; to: Rect) =
  ## Layer > Align: each of the layers (a group: all in it) moved so its
  ## edge or center is the one of `to` (the selection; the layers together).
  ## Undoable in a step.
  for b in d.blocksOf(idxs):
    let L = d.layers[b[1]]
    if L.background or L.locked: continue
    let c = d.contentBounds(L)
    if c.w <= 0: continue
    var dx, dy = 0
    case how
    of alTop: dy = to.y - c.y
    of alVCenter: dy = (to.y + to.h div 2) - (c.y + c.h div 2)
    of alBottom: dy = (to.y + to.h) - (c.y + c.h)
    of alLeft: dx = to.x - c.x
    of alHCenter: dx = (to.x + to.w div 2) - (c.x + c.w div 2)
    of alRight: dx = (to.x + to.w) - (c.x + c.w)
    d.shiftLayers(d.layers[b[0] .. b[1]], dx, dy)

proc alignTarget*(d: Doc; idxs: seq[int]): Rect =
  ## What Align lines the layers up with: the selection, else the layers
  ## together (one layer alone: the canvas).
  if d.hasSelection: return d.selBounds
  let bl = d.blocksOf(idxs)
  if bl.len <= 1: return d.bounds
  for b in bl:
    let c = d.contentBounds(d.layers[b[1]])
    if c.w > 0: result = if result.w > 0: union(result, c) else: c

proc distributeLayers*(d: Doc; idxs: seq[int]; how: DistributeHow) =
  ## Layer > Distribute: three or more layers spaced evenly between the two
  ## outermost (by their edges, centers, or the gaps between them). Undoable
  ## in a step.
  var items: seq[(int, int, Rect)]
  for b in d.blocksOf(idxs):
    let L = d.layers[b[1]]
    if L.background or L.locked: continue
    let c = d.contentBounds(L)
    if c.w > 0: items.add (b[0], b[1], c)
  if items.len < 3: return
  proc key(r: Rect): float =
    case how
    of dsTop, dsVSpace: r.y.float
    of dsVCenter: r.y.float + r.h / 2
    of dsBottom: float(r.y + r.h)
    of dsLeft, dsHSpace: r.x.float
    of dsHCenter: r.x.float + r.w / 2
    of dsRight: float(r.x + r.w)
  items.sort(proc (a, b: (int, int, Rect)): int = cmp(key(a[2]), key(b[2])))
  let n = items.len
  if how in {dsHSpace, dsVSpace}:
    let horiz = how == dsHSpace
    let first = items[0][2]
    let last = items[^1][2]
    var total = 0
    for it in items: total += (if horiz: it[2].w else: it[2].h)
    let span = if horiz: last.x + last.w - first.x else: last.y + last.h - first.y
    let gap = float(span - total) / float(n - 1)
    var at = if horiz: float(first.x + first.w) + gap else: float(first.y + first.h) + gap
    for k in 1 ..< n - 1:
      let r = items[k][2]
      let target = int(round(at))
      let dx = if horiz: target - r.x else: 0
      let dy = if horiz: 0 else: target - r.y
      d.shiftLayers(d.layers[items[k][0] .. items[k][1]], dx, dy)
      at += float(if horiz: r.w else: r.h) + gap
    return
  let a = key(items[0][2])
  let b = key(items[^1][2])
  for k in 1 ..< n - 1:
    let want = a + (b - a) * k.float / float(n - 1)
    let delta = int(round(want - key(items[k][2])))
    if how in {dsTop, dsVCenter, dsBottom}:
      d.shiftLayers(d.layers[items[k][0] .. items[k][1]], 0, delta)
    else:
      d.shiftLayers(d.layers[items[k][0] .. items[k][1]], delta, 0)

# ---- the whole image: size, canvas, rotation, crop ----------------------------------------------------------------

type Resample* = enum
  ## How pixels are worked out when the image changes size.
  rsNearest = "Nearest Neighbor", rsBilinear = "Bilinear", rsBicubic = "Bicubic",
    rsLanczos = "Lanczos"     ## (sharper than bicubic: 6 taps)

proc cubicW(t: float): float =
  let a = -0.5
  let x = abs(t)
  if x < 1: (a + 2) * x * x * x - (a + 3) * x * x + 1
  elif x < 2: a * x * x * x - 5 * a * x * x + 8 * a * x - 4 * a
  else: 0.0

proc lanczos3(t: float): float =
  let x = abs(t)
  if x < 1e-9: 1.0
  elif x >= 3: 0.0
  else: 3 * sin(PI * x) * sin(PI * x / 3) / (PI * PI * x * x)

{.push boundChecks: off, overflowChecks: off.}

proc resample*(px: seq[uint32]; w, h, nw, nh: int; how = rsBicubic): seq[uint32] =
  ## `px` (`w` x `h`) at `nw` x `nh`. Shrinking averages (area) for the
  ## smooth methods. On all the cores, the weights of each column worked
  ## out once.
  if w <= 0 or h <= 0 or nw <= 0 or nh <= 0 or px.len < w * h: return newSeq[uint32](max(0, nw) * max(0, nh))
  var res = newSeqUninit[uint32](nw * nh)       # (every pixel is written)
  let fx = w / nw
  let fy = h / nh
  let sp = pixPtr(px)
  let dp = pixPtr(res)
  if how == rsNearest:
    parallelRows(nh, y):
      let sy = min(h - 1, int((y.float + 0.5) * fy))
      for x in 0 ..< nw:
        dp[y * nw + x] = sp[sy * w + min(w - 1, int((x.float + 0.5) * fx))]
    return res
  if fx > 1.5 or fy > 1.5:
    # shrinking a lot: the average of the pixels under each new one
    parallelRows(nh, y):
      let y0 = int(y.float * fy)
      let y1 = max(y0 + 1, int((y + 1).float * fy))
      for x in 0 ..< nw:
        let x0 = int(x.float * fx)
        let x1 = max(x0 + 1, int((x + 1).float * fx))
        var sa, sr, sg, sb, n = 0
        for yy in y0 ..< min(h, y1):
          for xx in x0 ..< min(w, x1):
            let p = sp[yy * w + xx]
            let a = aOf(p)
            sa += a; sr += rOf(p) * a; sg += gOf(p) * a; sb += bOf(p) * a
            inc n
        dp[y * nw + x] = if sa == 0: 0'u32
                         else: argb(sa div max(1, n), sr div sa, sg div sa, sb div sa)
    return res
  # the taps: 2 (bilinear), 4 (bicubic) or 6 (Lanczos) of them, for each column and row
  let taps = case how
             of rsBilinear: 2
             of rsLanczos: 6
             else: 4
  proc weights(n, size: int; f: float): (seq[int32], seq[float32]) =
    var idx = newSeq[int32](n * taps)
    var wts = newSeq[float32](n * taps)
    for o in 0 ..< n:
      let s = (o.float + 0.5) * f - 0.5
      let i0 = int(floor(s))
      var tot = 0.0
      for t in 0 ..< taps:
        let i = i0 - (taps div 2 - 1) + t
        let wt = case taps
                 of 2: max(0.0, 1 - abs(s - i.float))
                 of 6: lanczos3(s - i.float)
                 else: cubicW(s - i.float)
        idx[o * taps + t] = int32(clamp(i, 0, size - 1))
        wts[o * taps + t] = float32(wt)
        tot += wt
      if tot != 0:
        for t in 0 ..< taps: wts[o * taps + t] = float32(wts[o * taps + t] / tot)
    (idx, wts)
  let (xi, xw) = weights(nw, w, fx)
  let (yi, yw) = weights(nh, h, fy)
  let xip = cast[ptr UncheckedArray[int32]](unsafeAddr xi[0])
  let xwp = cast[ptr UncheckedArray[float32]](unsafeAddr xw[0])
  let yip = cast[ptr UncheckedArray[int32]](unsafeAddr yi[0])
  let ywp = cast[ptr UncheckedArray[float32]](unsafeAddr yw[0])
  # (the number of taps fixed for each, so the loops are laid out flat)
  template run(T: static int) =
    parallelRows(nh, y):
      var rows: array[T, int]
      var wys: array[T, float32]
      for j in 0 ..< T:
        rows[j] = int(yip[y * T + j]) * w
        wys[j] = ywp[y * T + j]
      for x in 0 ..< nw:
        var a, r, g, b: float32
        for j in 0 ..< T:
          let wy = wys[j]
          let row = rows[j]
          for i in 0 ..< T:
            let wt = xwp[x * T + i] * wy
            let p = sp[row + int(xip[x * T + i])]
            let pa = float32(p shr 24) * wt
            a += pa
            r += float32((p shr 16) and 255) * pa
            g += float32((p shr 8) and 255) * pa
            b += float32(p and 255) * pa
        if a <= 0.001: dp[y * nw + x] = 0'u32
        else:
          let ia = 1'f32 / a
          dp[y * nw + x] = argb(int(a + 0.5), int(r * ia + 0.5), int(g * ia + 0.5), int(b * ia + 0.5))
  case taps
  of 2: run(2)
  of 6: run(6)
  else: run(4)
  res

{.pop.}

proc resampleMask(m: seq[uint8]; w, h, nw, nh: int): seq[uint8] =
  if m.len == 0: return
  var px = newSeq[uint32](m.len)
  for i, v in m: px[i] = argb(255, int(v), int(v), int(v))
  let r = resample(px, w, h, nw, nh, rsBilinear)
  result = newSeq[uint8](nw * nh)
  for i, p in r: result[i] = uint8(rOf(p))

# ---- the 16 and 32 bits moved along with the pixels ---------------------------------------------------------

var syncHdrHook*: proc (d: Doc; L: Layer) {.nimcall.}
  ## Makes a layer's light agree with what is shown (set by `photohdr`).
var showHdrHook*: proc (d: Doc; L: Layer) {.nimcall.}
  ## Makes what a layer shows from its light (set by `photohdr`).

proc deepCut[T](src: seq[T]; ow: int; c: Rect): seq[T] =
  result = newSeq[T](c.w * c.h * 4)
  for y in 0 ..< c.h:
    copyMem(addr result[y * c.w * 4], unsafeAddr src[((c.y + y) * ow + c.x) * 4], c.w * 4 * sizeof(T))

proc deepMove[T](src: seq[T]; ow, oh, nw, nh, ox, oy: int; fill: array[4, T]): seq[T] =
  result = newSeq[T](nw * nh * 4)
  if fill != [T(0), T(0), T(0), T(0)]:
    for i in 0 ..< nw * nh:
      for c in 0 .. 3: result[4 * i + c] = fill[c]
  for y in 0 ..< oh:
    let ty = y + oy
    if ty < 0 or ty >= nh: continue
    for x in 0 ..< ow:
      let tx = x + ox
      if tx >= 0 and tx < nw:
        for c in 0 .. 3: result[(ty * nw + tx) * 4 + c] = src[(y * ow + x) * 4 + c]

proc deepFlip[T](px: var seq[T]; w, h: int; horizontal: bool) =
  if horizontal:
    for y in 0 ..< h:
      var a = 0
      var b = w - 1
      while a < b:
        for c in 0 .. 3: swap(px[(y * w + a) * 4 + c], px[(y * w + b) * 4 + c])
        inc a; dec b
  else:
    var a = 0
    var b = h - 1
    while a < b:
      for t in 0 ..< w * 4: swap(px[a * w * 4 + t], px[b * w * 4 + t])
      inc a; dec b

proc deepRot[T](src: seq[T]; ow, oh, q: int): seq[T] =
  let nw = if q == 2: ow else: oh
  let nh = if q == 2: oh else: ow
  result = newSeq[T](nw * nh * 4)
  for y in 0 ..< oh:
    for x in 0 ..< ow:
      let (tx, ty) = case q
                     of 1: (oh - 1 - y, x)
                     of 2: (ow - 1 - x, oh - 1 - y)
                     else: (y, ow - 1 - x)
      for c in 0 .. 3: result[(ty * nw + tx) * 4 + c] = src[(y * ow + x) * 4 + c]

proc deepResample1(src: seq[float32]; w, h, nw: int): seq[float32] =
  ## (across: `w` pixels a row to `nw`; colors weighed by alpha)
  result = newSeq[float32](nw * h * 4)
  let scale = nw / w
  let support = if scale < 1: 2 / scale else: 2.0
  let f = if scale < 1: scale else: 1.0
  let sp = cast[ptr UncheckedArray[float32]](unsafeAddr src[0])
  let dp = cast[ptr UncheckedArray[float32]](addr result[0])
  parallelRows(h, y):
    for x in 0 ..< nw:
      let center = (x.float + 0.5) / scale - 0.5
      let lo = int(floor(center - support)) + 1
      let hi = int(floor(center + support))
      var acc = [0.0, 0.0, 0.0, 0.0]
      var tot = 0.0
      for i in lo .. hi:
        let wt = cubicW(abs(i.float - center) * f)
        if wt == 0: continue
        let q = (y * w + clamp(i, 0, w - 1)) * 4
        let al = sp[q + 3].float
        acc[0] += sp[q].float * al * wt; acc[1] += sp[q + 1].float * al * wt
        acc[2] += sp[q + 2].float * al * wt; acc[3] += al * wt
        tot += wt
      let o = (y * nw + x) * 4
      let a = if tot != 0: acc[3] / tot else: 0.0
      dp[o + 3] = float32(max(0.0, a))
      for c in 0 .. 2:
        dp[o + c] = if acc[3] > 1e-9: float32(max(0.0, acc[c] / acc[3])) else: 0'f32

proc deepTranspose(src: seq[float32]; w, h: int): seq[float32] =
  result = newSeq[float32](w * h * 4)
  for y in 0 ..< h:
    for x in 0 ..< w:
      for c in 0 .. 3: result[(x * h + y) * 4 + c] = src[(y * w + x) * 4 + c]

proc deepResample*(src: seq[float32]; w, h, nw, nh: int): seq[float32] =
  ## R G B A floats resampled to `nw` x `nh` (bicubic; smaller: every
  ## pixel under each counted).
  let a = deepResample1(src, w, h, nw)                        # nw x h
  let b = deepResample1(deepTranspose(a, nw, h), h, nw, nh)   # (turned) nh x nw
  deepTranspose(b, nh, nw)

proc floatsOf(hi: seq[uint16]): seq[float32] =
  result = newSeq[float32](hi.len)
  for i, v in hi: result[i] = float32(v) / 65535

proc hiOfFloats(f: seq[float32]): seq[uint16] =
  result = newSeq[uint16](f.len)
  for i, v in f: result[i] = uint16(clamp(int(v * 65535 + 0.5), 0, 65535))

proc deepRotate(src: seq[float32]; w, h: int; deg: float; nw, nh: int; fill: array[4, float32]): seq[float32] =
  ## (as `rotatedPx`, on floats)
  result = newSeq[float32](nw * nh * 4)
  let sp = cast[ptr UncheckedArray[float32]](unsafeAddr src[0])
  let dp = cast[ptr UncheckedArray[float32]](addr result[0])
  let a = degToRad(deg)
  let ca = cos(a)
  let sa = sin(a)
  let cx = w.float / 2
  let cy = h.float / 2
  let ncx = nw.float / 2
  let ncy = nh.float / 2
  parallelRows(nh, y):
    for x in 0 ..< nw:
      let dx = x.float + 0.5 - ncx
      let dy = y.float + 0.5 - ncy
      let sx = dx * ca + dy * sa + cx - 0.5
      let sy = -dx * sa + dy * ca + cy - 0.5
      let o = (y * nw + x) * 4
      if sx < -1 or sy < -1 or sx > w.float or sy > h.float:
        for c in 0 .. 3: dp[o + c] = fill[c]
        continue
      let x0 = int(floor(sx))
      let y0 = int(floor(sy))
      var acc = [0.0, 0.0, 0.0, 0.0]
      for j in 0 .. 1:
        for i in 0 .. 1:
          let wt = (1 - abs(sx - (x0 + i).float)) * (1 - abs(sy - (y0 + j).float))
          let xx = x0 + i
          let yy = y0 + j
          var p: array[4, float]
          if xx < 0 or yy < 0 or xx >= w or yy >= h:
            for c in 0 .. 3: p[c] = fill[c].float
          else:
            for c in 0 .. 3: p[c] = sp[(yy * w + xx) * 4 + c].float
          let al = p[3] * wt
          acc[0] += al; acc[1] += p[0] * al; acc[2] += p[1] * al; acc[3] += p[2] * al
      dp[o + 3] = float32(acc[0])
      for c in 0 .. 2: dp[o + c] = if acc[0] <= 1e-6: 0'f32 else: float32(acc[c + 1] / acc[0])

proc imageSize*(d: Doc; nw, nh: int; how = rsBicubic; dpi = 0.0) =
  ## Image > Image Size: every layer, channel and the selection resampled.
  ## (Undoable: `snapStep` first.) Raises `ValueError` when too big.
  if nw < 1 or nh < 1: return
  checkSize(nw, nh)
  let kx = nw / d.w
  let ky = nh / d.h
  for L in d.pixelLayers:
    let hadHdr = d.hdrValid(L) and not L.isVector
    if hadHdr and syncHdrHook != nil: syncHdrHook(d, L)
    if L.isText:
      # (type is set again at its new size: sharp)
      L.px = newSeq[uint32](nw * nh)
      L.text = L.text.scaled(float32(ky))
      if abs(kx - ky) > 1e-6:
        let r = float32(kx / ky)
        L.text.x *= r
        L.text.boxW *= r
        for p in L.text.path.mitems: p[0] *= r
        for sp in L.text.spans.mitems: sp.style.hScale = (if sp.style.hScale <= 0: 1'f32 else: sp.style.hScale) * r
      L.textBox = (0, 0, 0, 0)
    elif L.isShape:
      L.px = newSeq[uint32](nw * nh)
      d.mapShape(L, proc (x, y: float): (float, float) = (x * kx, y * ky), sqrt(kx * ky))
    elif d.hiValid(L):
      # (at 16 bits: resampled at 16, its 8 bits from them)
      d.syncHi(L)
      let f = deepResample(floatsOf(L.hi), d.w, d.h, nw, nh)
      L.hi = hiOfFloats(f)
      L.px = newSeq[uint32](nw * nh)
      for i in 0 ..< nw * nh:
        L.px[i] = (to8(L.hi[4 * i + 3]) shl 24) or (to8(L.hi[4 * i]) shl 16) or (to8(L.hi[4 * i + 1]) shl 8) or
                  to8(L.hi[4 * i + 2])
    else:
      L.px = resample(L.px, d.w, d.h, nw, nh, how)
    if hadHdr:
      # (at 32 bits: the light resampled; what is shown made from it below)
      L.hdr = deepResample(L.hdr, d.w, d.h, nw, nh)
    elif L.hdr.len > 0: L.hdr = @[]
    if L.hi.len > 0 and L.hi.len != nw * nh * 4: L.hi = @[]
    # (Scale Styles: its effects keep their look)
    let k = sqrt(kx * ky)
    for e in L.fx.fx.mitems:
      e.size = int(round(e.size.float * k))
      e.distance = int(round(e.distance.float * k))
      e.soften = int(round(e.soften.float * k))
    inc L.ver
  for a in d.alphas.mitems: a.m = resampleMask(a.m, d.w, d.h, nw, nh)
  d.sel = resampleMask(d.sel, d.w, d.h, nw, nh)
  for p in d.paths.mitems:
    for s in p.subs.mitems:
      for q in s.pts.mitems:
        q.p = (q.p[0] * kx, q.p[1] * ky); q.inH = (q.inH[0] * kx, q.inH[1] * ky)
        q.outH = (q.outH[0] * kx, q.outH[1] * ky)
  d.w = nw
  d.h = nh
  if dpi > 0: d.dpi = dpi
  for L in d.layers:
    if L.hdr.len == nw * nh * 4 and showHdrHook != nil: showHdrHook(d, L)
  for L in d.layers:
    d.drawVector(L)
  inc d.selVer
  d.comp = @[]
  d.markAll()

proc canvasSizeAt*(d: Doc; nw, nh: int; ox, oy: int; bg: uint32)
  ## The canvas made `nw` x `nh`, what was at 0, 0 now at `ox`, `oy` (room
  ## added -- `bg` on the Background -- or cut off). Raises `ValueError`
  ## when too big.

proc canvasSize*(d: Doc; nw, nh: int; anchorX, anchorY: int; bg: uint32) =
  ## Image > Canvas Size: room added (in `bg` on the Background) or cut
  ## off; `anchorX`/`anchorY` 0 left/top, 1 middle, 2 right/bottom.
  ## Raises `ValueError` when too big.
  let ox = case anchorX
           of 0: 0
           of 1: (nw - d.w) div 2
           else: nw - d.w
  let oy = case anchorY
           of 0: 0
           of 1: (nh - d.h) div 2
           else: nh - d.h
  d.canvasSizeAt(nw, nh, ox, oy, bg)

proc canvasSizeAt*(d: Doc; nw, nh: int; ox, oy: int; bg: uint32) =
  ## The canvas made `nw` x `nh`, what was at 0, 0 now at `ox`, `oy` (room
  ## added -- `bg` on the Background -- or cut off). Raises `ValueError`
  ## when too big.
  if nw < 1 or nh < 1: return
  checkSize(nw, nh)
  proc move32(src: seq[uint32]; fill: uint32): seq[uint32] =
    result = newSeq[uint32](nw * nh)
    if fill != 0:
      for p in result.mitems: p = fill
    for y in 0 ..< d.h:
      let ty = y + oy
      if ty < 0 or ty >= nh: continue
      for x in 0 ..< d.w:
        let tx = x + ox
        if tx >= 0 and tx < nw: result[ty * nw + tx] = src[y * d.w + x]
  proc move8(src: seq[uint8]): seq[uint8] =
    if src.len == 0: return
    result = newSeq[uint8](nw * nh)
    for y in 0 ..< d.h:
      let ty = y + oy
      if ty < 0 or ty >= nh: continue
      for x in 0 ..< d.w:
        let tx = x + ox
        if tx >= 0 and tx < nw: result[ty * nw + tx] = src[y * d.w + x]
  for L in d.pixelLayers:
    let fill = if L.gray: 0xFFFFFFFF'u32 elif L.background: bg or 0xFF000000'u32 else: 0'u32
    if d.hiValid(L):
      let f16 = [uint16((fill shr 16) and 255) * 257, uint16((fill shr 8) and 255) * 257,
                 uint16(fill and 255) * 257, uint16(fill shr 24) * 257]
      L.hi = deepMove(L.hi, d.w, d.h, nw, nh, ox, oy, f16)
    else: L.hi = @[]
    if d.hdrValid(L):
      let lin = proc (v: uint32): float32 =
        let c = float(v and 255) / 255
        float32(if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4))
      let k = float32(pow(2.0, -d.exposure))
      let ff = [lin(fill shr 16) * k, lin(fill shr 8) * k, lin(fill) * k, float32(fill shr 24) / 255]
      L.hdr = deepMove(L.hdr, d.w, d.h, nw, nh, ox, oy, ff)
    else: L.hdr = @[]
    L.px = move32(L.px, fill)
    if L.isText:
      L.text = L.text.moved(ox.float32, oy.float32)
      L.textBox = (0, 0, 0, 0)
    d.mapShape(L, proc (x, y: float): (float, float) = (x + ox.float, y + oy.float))
    inc L.ver
  for a in d.alphas.mitems: a.m = move8(a.m)
  d.sel = move8(d.sel)
  for p in d.paths.mitems:
    for s in p.subs.mitems:
      for q in s.pts.mitems:
        q.p = (q.p[0] + ox.float, q.p[1] + oy.float)
        q.inH = (q.inH[0] + ox.float, q.inH[1] + oy.float)
        q.outH = (q.outH[0] + ox.float, q.outH[1] + oy.float)
  d.w = nw
  d.h = nh
  for L in d.layers:
    if L.isShape: d.drawShape(L)
  inc d.selVer
  d.comp = @[]
  d.markAll()

proc crop*(d: Doc; r: Rect) =
  ## The image cut down to `r`.
  let c = d.clip(r)
  if c.w <= 0 or c.h <= 0: return
  let ow = d.w
  proc cut32(src: seq[uint32]): seq[uint32] =
    result = newSeq[uint32](c.w * c.h)
    for y in 0 ..< c.h:
      copyMem(addr result[y * c.w], unsafeAddr src[(c.y + y) * ow + c.x], c.w * 4)
  proc cut8(src: seq[uint8]): seq[uint8] =
    if src.len == 0: return
    result = newSeq[uint8](c.w * c.h)
    for y in 0 ..< c.h:
      for x in 0 ..< c.w: result[y * c.w + x] = src[(c.y + y) * ow + c.x + x]
  for L in d.pixelLayers:
    L.hi = if d.hiValid(L): deepCut(L.hi, ow, c) else: @[]
    L.hdr = if d.hdrValid(L): deepCut(L.hdr, ow, c) else: @[]
    L.px = cut32(L.px)
    if L.isText:
      L.text = L.text.moved(-c.x.float32, -c.y.float32)
      L.textBox = (0, 0, 0, 0)
    d.mapShape(L, proc (x, y: float): (float, float) = (x - c.x.float, y - c.y.float))
    inc L.ver
  for a in d.alphas.mitems: a.m = cut8(a.m)
  d.sel.setLen(0)
  for p in d.paths.mitems:
    for s in p.subs.mitems:
      for q in s.pts.mitems:
        q.p = (q.p[0] - c.x.float, q.p[1] - c.y.float)
        q.inH = (q.inH[0] - c.x.float, q.inH[1] - c.y.float)
        q.outH = (q.outH[0] - c.x.float, q.outH[1] - c.y.float)
  d.w = c.w
  d.h = c.h
  for L in d.layers:
    if L.isShape: d.drawShape(L)
  inc d.selVer
  d.comp = @[]
  d.markAll()

proc flipPx(px: var seq[uint32]; w, h: int; r: Rect; horizontal: bool) =
  if horizontal:
    for y in r.y ..< r.y + r.h:
      var a = r.x
      var b = r.x + r.w - 1
      while a < b:
        swap(px[y * w + a], px[y * w + b])
        inc a; dec b
  else:
    var a = r.y
    var b = r.y + r.h - 1
    while a < b:
      for x in r.x ..< r.x + r.w: swap(px[a * w + x], px[b * w + x])
      inc a; dec b

proc rasterizeAllText*(d: Doc) =
  ## Every type layer as pixels (before the image is turned, flipped,
  ## bent: what text cannot follow).
  for L in d.layers:
    if L.isText: d.rasterizeText(L)

proc flipImage*(d: Doc; horizontal: bool) =
  ## Image > Flip: every layer, channel and the selection.
  d.rasterizeAllText()
  let (w, h) = (d.w.float, d.h.float)
  for L in d.pixelLayers:
    if L.isShape:
      d.mapShape(L, proc (x, y: float): (float, float) = (if horizontal: (w - x, y) else: (x, h - y)))
      d.drawShape(L)
    else:
      if d.hiValid(L): deepFlip(L.hi, d.w, d.h, horizontal)
      if d.hdrValid(L): deepFlip(L.hdr, d.w, d.h, horizontal)
      flipPx(L.px, d.w, d.h, d.bounds, horizontal)
    inc L.ver
  if d.hasSelection:
    var m = newSeq[uint32](d.sel.len)
    for i, v in d.sel: m[i] = uint32(v)
    flipPx(m, d.w, d.h, d.bounds, horizontal)
    for i, v in m: d.sel[i] = uint8(v)
    inc d.selVer
  d.markAll()

proc flipSelection*(d: Doc; horizontal: bool) =
  ## Flips what is selected in the current layer, in its rectangle.
  let L = d.layer
  let r = d.clip(d.selBounds)
  d.touch(L, r)
  if not d.hasSelection:
    flipPx(L.px, d.w, d.h, r, horizontal)
  else:
    let before = L.px
    var moved = L.px
    flipPx(moved, d.w, d.h, r, horizontal)
    var m = newSeq[uint32](d.sel.len)
    for i, v in d.sel: m[i] = uint32(v)
    flipPx(m, d.w, d.h, r, horizontal)
    for y in r.y ..< r.y + r.h:
      for x in r.x ..< r.x + r.w:
        let i = y * d.w + x
        let s = int(m[i])
        let gone = int(d.sel[i])
        var p = before[i]
        if gone > 0 and not (L.background or L.lockAlpha):
          p = withAlpha(p, aOf(p) * (255 - gone) div 255)
        if s > 0: p = blendPx(p, withAlpha(moved[i], aOf(moved[i]) * s div 255), 255, bmNormal)
        L.px[i] = p
    for i in 0 ..< d.sel.len: d.sel[i] = uint8(m[i])
    inc d.selVer
  inc L.ver
  d.markDirty(r)

proc rotateImage*(d: Doc; quarter: int) =
  ## Image > Rotate by 90 degrees `quarter` times clockwise (1, 2, 3).
  let q = ((quarter mod 4) + 4) mod 4
  if q == 0: return
  d.rasterizeAllText()
  let ow = d.w
  let oh = d.h
  let nw = if q == 2: ow else: oh
  let nh = if q == 2: oh else: ow
  proc rot[T](src: seq[T]): seq[T] =
    if src.len == 0: return
    result = newSeq[T](nw * nh)
    for y in 0 ..< oh:
      for x in 0 ..< ow:
        let (tx, ty) = case q
                       of 1: (oh - 1 - y, x)
                       of 2: (ow - 1 - x, oh - 1 - y)
                       else: (y, ow - 1 - x)
        result[ty * nw + tx] = src[y * ow + x]
  let (fw, fh) = (ow.float, oh.float)
  for L in d.pixelLayers:
    L.hi = if d.hiValid(L): deepRot(L.hi, ow, oh, q) else: @[]
    L.hdr = if d.hdrValid(L): deepRot(L.hdr, ow, oh, q) else: @[]
    L.px = rot(L.px)
    d.mapShape(L, proc (x, y: float): (float, float) =
      case q
      of 1: (fh - y, x)
      of 2: (fw - x, fh - y)
      else: (y, fw - x))
    inc L.ver
  for a in d.alphas.mitems: a.m = rot(a.m)
  d.sel = rot(d.sel)
  d.w = nw
  d.h = nh
  for L in d.layers:
    if L.isShape: d.drawShape(L)
  inc d.selVer
  d.comp = @[]
  d.markAll()

proc rotatedPx(px: seq[uint32]; w, h: int; deg: float; nw, nh: int; fill: uint32): seq[uint32] =
  ## `px` turned by `deg` (clockwise) around its center into `nw` x `nh`
  ## (bilinear).
  var res = newSeq[uint32](nw * nh)
  let sp = pixPtr(px)
  let dp = pixPtr(res)
  let a = degToRad(deg)
  let ca = cos(a)
  let sa = sin(a)
  let cx = w.float / 2
  let cy = h.float / 2
  let ncx = nw.float / 2
  let ncy = nh.float / 2
  parallelRows(nh, y):
    for x in 0 ..< nw:
      let dx = x.float + 0.5 - ncx
      let dy = y.float + 0.5 - ncy
      let sx = dx * ca + dy * sa + cx - 0.5
      let sy = -dx * sa + dy * ca + cy - 0.5
      if sx < -1 or sy < -1 or sx > w.float or sy > h.float:
        dp[y * nw + x] = fill
        continue
      let x0 = int(floor(sx))
      let y0 = int(floor(sy))
      var acc = [0.0, 0.0, 0.0, 0.0]
      for j in 0 .. 1:
        for i in 0 .. 1:
          let wt = (1 - abs(sx - (x0 + i).float)) * (1 - abs(sy - (y0 + j).float))
          let xx = x0 + i
          let yy = y0 + j
          let p = if xx < 0 or yy < 0 or xx >= w or yy >= h: fill else: sp[yy * w + xx]
          let al = aOf(p).float * wt
          acc[0] += al; acc[1] += rOf(p).float * al; acc[2] += gOf(p).float * al
          acc[3] += bOf(p).float * al
      dp[y * nw + x] = if acc[0] <= 0.001: 0'u32
                           else: argb(int(round(acc[0])), int(round(acc[1] / acc[0])),
                                      int(round(acc[2] / acc[0])), int(round(acc[3] / acc[0])))
  res

proc rotateArbitrary*(d: Doc; deg: float; bg: uint32) =
  ## Image > Rotate > Arbitrary: the canvas grows to hold the turned image.
  let a = degToRad(deg)
  let nw = int(ceil(abs(d.w.float * cos(a)) + abs(d.h.float * sin(a)) - 0.001))
  let nh = int(ceil(abs(d.w.float * sin(a)) + abs(d.h.float * cos(a)) - 0.001))
  checkSize(nw, nh)
  d.rasterizeAllText()
  let ca = cos(a)
  let sa = sin(a)
  let (cx, cy, ncx, ncy) = (d.w / 2, d.h / 2, nw / 2, nh / 2)
  for L in d.pixelLayers:
    if L.isShape:
      L.px = newSeq[uint32](nw * nh)
      d.mapShape(L, proc (x, y: float): (float, float) =
        let dx = x - cx
        let dy = y - cy
        (dx * ca - dy * sa + ncx, dx * sa + dy * ca + ncy))
    else:
      let fill = if L.gray: 0xFFFFFFFF'u32 elif L.background: bg or 0xFF000000'u32 else: 0'u32
      if d.hiValid(L):
        d.syncHi(L)
        let f = [float32((fill shr 16) and 255) / 255, float32((fill shr 8) and 255) / 255,
                 float32(fill and 255) / 255, float32(fill shr 24) / 255]
        L.hi = hiOfFloats(deepRotate(floatsOf(L.hi), d.w, d.h, deg, nw, nh, f))
        L.px = newSeq[uint32](nw * nh)
        for i in 0 ..< nw * nh:
          L.px[i] = (to8(L.hi[4 * i + 3]) shl 24) or (to8(L.hi[4 * i]) shl 16) or
                    (to8(L.hi[4 * i + 1]) shl 8) or to8(L.hi[4 * i + 2])
      else:
        L.hi = @[]
        L.px = rotatedPx(L.px, d.w, d.h, deg, nw, nh, fill)
      if d.hdrValid(L) or L.hdr.len == d.w * d.h * 4:
        if syncHdrHook != nil: syncHdrHook(d, L)
        let lin = proc (v: uint32): float32 =
          let c = float(v and 255) / 255
          float32(if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4))
        let k = float32(pow(2.0, -d.exposure))
        let ff = [lin(fill shr 16) * k, lin(fill shr 8) * k, lin(fill) * k, float32(fill shr 24) / 255]
        L.hdr = deepRotate(L.hdr, d.w, d.h, deg, nw, nh, ff)
      else: L.hdr = @[]
    inc L.ver
  d.sel.setLen(0)
  for a in d.alphas.mitems:
    var px = newSeq[uint32](a.m.len)
    for i, v in a.m: px[i] = grayPx(int(v))
    let r = rotatedPx(px, d.w, d.h, deg, nw, nh, 0xFF000000'u32)
    a.m = newSeq[uint8](nw * nh)
    for i, p in r: a.m[i] = uint8(rOf(p))
  d.w = nw
  d.h = nh
  for L in d.layers:
    if L.hdr.len == nw * nh * 4 and showHdrHook != nil: showHdrHook(d, L)
  for L in d.layers:
    if L.isShape: d.drawShape(L)
  inc d.selVer
  d.comp = @[]
  d.markAll()


proc quadOf*(r: Rect): Quad =
  ## The corners of a rectangle.
  [(r.x.float, r.y.float), ((r.x + r.w).float, r.y.float),
   ((r.x + r.w).float, (r.y + r.h).float), (r.x.float, (r.y + r.h).float)]

proc squareToQuad*(q: Quad): array[9, float] =
  ## The projective map of the unit square onto `q` (Heckbert's).
  let (x0, y0) = q[0]
  let (x1, y1) = q[1]
  let (x2, y2) = q[2]
  let (x3, y3) = q[3]
  let dx3 = x0 - x1 + x2 - x3
  let dy3 = y0 - y1 + y2 - y3
  if abs(dx3) < 1e-9 and abs(dy3) < 1e-9:
    return [x1 - x0, x2 - x1, x0, y1 - y0, y2 - y1, y0, 0.0, 0.0, 1.0]
  let dx1 = x1 - x2
  let dx2 = x3 - x2
  let dy1 = y1 - y2
  let dy2 = y3 - y2
  let den = dx1 * dy2 - dx2 * dy1
  if abs(den) < 1e-12: return [x1 - x0, x3 - x0, x0, y1 - y0, y3 - y0, y0, 0.0, 0.0, 1.0]
  let g = (dx3 * dy2 - dx2 * dy3) / den
  let h = (dx1 * dy3 - dx3 * dy1) / den
  [x1 - x0 + g * x1, x3 - x0 + h * x3, x0, y1 - y0 + g * y1, y3 - y0 + h * y3, y0, g, h, 1.0]

proc inverse3*(m: array[9, float]): array[9, float] =
  ## The inverse of a 3x3 matrix (row by row; identity when it has none).
  let (a, b, c, d, e, f, g, h, i) = (m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8])
  let A = e * i - f * h
  let B = -(d * i - f * g)
  let C = d * h - e * g
  let det = a * A + b * B + c * C
  if abs(det) < 1e-12: return [0.0, 0, 0, 0, 0, 0, 0, 0, 1]
  let k = 1 / det
  [A * k, -(b * i - c * h) * k, (b * f - c * e) * k,
   B * k, (a * i - c * g) * k, -(a * f - c * d) * k,
   C * k, -(a * h - b * g) * k, (a * e - b * d) * k]

proc quadIsFine*(q: Quad): bool =
  ## Whether `q` can take a picture: not folded over itself, not flat.
  var sign = 0.0
  for k in 0 .. 3:
    let (ax, ay) = q[k]
    let (bx, by) = q[(k + 1) mod 4]
    let (cx, cy) = q[(k + 2) mod 4]
    let cr = (bx - ax) * (cy - by) - (by - ay) * (cx - bx)
    if abs(cr) < 1e-6: return false
    if sign == 0: sign = cr
    elif (cr > 0) != (sign > 0): return false
  true

proc quadMap*(r: Rect; q: Quad): proc (x, y: float): (float, float) =
  ## What carries a place in `r` to where it goes when `r` is stretched
  ## into the corners `q` (for outlines: shape layers, paths).
  let m = squareToQuad(q)
  let rx = r.x.float
  let ry = r.y.float
  let rw = max(1e-9, r.w.float)
  let rh = max(1e-9, r.h.float)
  result = proc (x, y: float): (float, float) =
    let u = (x - rx) / rw
    let v = (y - ry) / rh
    let w = m[6] * u + m[7] * v + m[8]
    let k = if abs(w) < 1e-12: 1e12 else: 1 / w
    ((m[0] * u + m[1] * v + m[2]) * k, (m[3] * u + m[4] * v + m[5]) * k)

proc homApply(m: array[9, float]; x, y: float): (float, float) {.inline.} =
  let w = m[6] * x + m[7] * y + m[8]
  let k = if abs(w) < 1e-12: 1e12 else: 1 / w
  ((m[0] * x + m[1] * y + m[2]) * k, (m[3] * x + m[4] * y + m[5]) * k)

proc perspectiveSize*(q: Quad): (int, int) =
  ## The size a perspective crop of `q` makes: its sides' average lengths.
  template len(a, b: (float, float)): float = hypot(a[0] - b[0], a[1] - b[1])
  (max(1, int(round((len(q[0], q[1]) + len(q[3], q[2])) / 2))),
   max(1, int(round((len(q[0], q[3]) + len(q[1], q[2])) / 2))))

proc perspectiveCrop*(d: Doc; q: Quad; bg: uint32; size = (0, 0)) =
  ## The Perspective Crop tool: what is inside the four corners `q` made a
  ## rectangle (`size`, or the sides' average lengths) -- a document photographed
  ## at an angle made straight, a building's lines made upright. Every
  ## layer, the masks, the channels; type becomes pixels first.
  let (aw, ah) = perspectiveSize(q)
  let nw = if size[0] > 0: size[0] else: aw
  let nh = if size[1] > 0: size[1] else: ah
  checkSize(nw, nh)
  d.rasterizeAllText()
  let m = squareToQuad(q)           # (unit square -> the image)
  let back = inverse3(m)            # (the image -> unit square)
  let (ow, oh) = (d.w, d.h)
  proc warpPx(px: seq[uint32]; fill: uint32): seq[uint32] =
    result = newSeq[uint32](nw * nh)
    if px.len != ow * oh: return
    let src = pixPtr(px)
    let dst = pixPtr(result)
    parallelRows(nh, j):
      let v = (j.float + 0.5) / nh.float
      for i in 0 ..< nw:
        let u = (i.float + 0.5) / nw.float
        let (sx, sy) = homApply(m, u, v)
        var c = bilinearAt(src, ow, oh, sx - 0.5, sy - 0.5)
        if fill != 0 and aOf(c) < 255:
          c = blendPx(fill, c, 255, bmNormal)
        dst[j * nw + i] = c
  for L in d.pixelLayers:
    if L.isShape:
      L.px = newSeq[uint32](nw * nh)
      d.mapShape(L, proc (x, y: float): (float, float) =
        let (u, v) = homApply(back, x, y)
        (u * nw.float, v * nh.float))
    else:
      L.px = warpPx(L.px, if L.gray: 0xFFFFFFFF'u32 elif L.background: bg or 0xFF000000'u32 else: 0)
    inc L.ver
  d.sel.setLen(0)
  for a in d.alphas.mitems:
    var px = newSeq[uint32](a.m.len)
    for i, v in a.m: px[i] = grayPx(int(v))
    let r = warpPx(px, 0xFF000000'u32)
    a.m = newSeq[uint8](nw * nh)
    for i, p in r: a.m[i] = uint8(rOf(p))
  d.w = nw
  d.h = nh
  for L in d.layers:
    if L.isShape: d.drawShape(L)
  inc d.selVer
  d.comp = @[]
  d.markAll()

proc liftForWarp*(d: Doc; original: seq[uint32]; r: Rect; mask: seq[uint8];
                  vacated: uint32): tuple[part, base: seq[uint32]] =
  ## The pixels of `original` (a layer's) in `r` where `mask` selects them
  ## (all when it is empty) taken up: `part` (`r`'s size), and the layer
  ## without them (`vacated` left where they were). On all the cores.
  result.base = original
  if r.w <= 0 or r.h <= 0 or original.len != d.w * d.h: return
  result.part = newSeq[uint32](r.w * r.h)
  let sel = mask.len == d.w * d.h
  let mp = if sel: cast[ptr UncheckedArray[uint8]](unsafeAddr mask[0]) else: nil
  let op = pixPtr(original)
  let pp = pixPtr(result.part)
  let bp = pixPtr(result.base)
  let w = d.w
  let h = d.h
  parallelRows(r.h, y):
    let yy = r.y + y
    if yy >= 0 and yy < h:
      for x in 0 ..< r.w:
        let xx = r.x + x
        if xx < 0 or xx >= w: continue
        let i = yy * w + xx
        let p = op[i]
        let s = if mp != nil: int(mp[i]) else: 255
        if s == 0: continue
        pp[y * r.w + x] = withAlpha(p, aOf(p) * s div 255)
        bp[i] = if s >= 255: vacated else: mix(p, vacated, s / 255)

proc warpOnto*(d: Doc; base: var seq[uint32]; src: ptr UncheckedArray[uint32]; stride: int; r: Rect;
               q: Quad) =
  ## The pixels at `src` (`r`'s size, rows `stride` apart) put down on
  ## `base` (as big as the image) stretched into the corners `q` -- read
  ## between their pixels, the colors weighed by their alpha; from a copy
  ## halved as often as it shrinks, so detail does not turn to noise. On all
  ## the cores; a turn or a stretch without perspective a row at a time.
  if r.w <= 0 or r.h <= 0 or src == nil or base.len != d.w * d.h or not quadIsFine(q): return
  let inv = inverse3(squareToQuad(q))
  var x0 = 1e18
  var y0 = 1e18
  var x1 = -1e18
  var y1 = -1e18
  for (x, y) in q:
    x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
  let bx0 = clamp(int(floor(x0)), 0, d.w)
  let by0 = clamp(int(floor(y0)), 0, d.h)
  let bx1 = clamp(int(ceil(x1)), 0, d.w)
  let by1 = clamp(int(ceil(y1)), 0, d.h)
  if bx1 <= bx0 or by1 <= by0: return
  var sp = src
  var sst = stride
  var sw = r.w
  var sh = r.h
  var halfBuf: seq[uint32]
  block:
    # (by the side shrunk least: a perspective keeps its near side sharp)
    let ax = max(hypot(q[1][0] - q[0][0], q[1][1] - q[0][1]), hypot(q[2][0] - q[3][0], q[2][1] - q[3][1]))
    let ay = max(hypot(q[3][0] - q[0][0], q[3][1] - q[0][1]), hypot(q[2][0] - q[1][0], q[2][1] - q[1][1]))
    var k = min(ax / max(1.0, r.w.float), ay / max(1.0, r.h.float))
    while k < 0.5 and sw > 2 and sh > 2:
      let nw = (sw + 1) div 2
      let nh = (sh + 1) div 2
      var half = newSeq[uint32](nw * nh)
      let hp = pixPtr(half)
      let op = sp
      let ow = sw
      let oh = sh
      let ost = sst
      parallelRows(nh, y):
        for x in 0 ..< nw:
          var a, rr, g, b = 0
          for (ddx, ddy) in [(0, 0), (1, 0), (0, 1), (1, 1)]:
            let p = op[min(oh - 1, 2 * y + ddy) * ost + min(ow - 1, 2 * x + ddx)]
            let pa = int(p shr 24)
            a += pa
            rr += int((p shr 16) and 255) * pa
            g += int((p shr 8) and 255) * pa
            b += int(p and 255) * pa
          hp[y * nw + x] = if a == 0: 0'u32
                           else: (uint32((a + 2) div 4) shl 24) or (uint32(rr div a) shl 16) or
                                 (uint32(g div a) shl 8) or uint32(b div a)
      halfBuf = move(half)
      sp = pixPtr(halfBuf)
      sst = nw
      sw = nw
      sh = nh
      k *= 2
  let bp = pixPtr(base)
  let w = d.w
  let affine = abs(inv[6]) < 1e-12 and abs(inv[7]) < 1e-12 and abs(inv[8]) > 1e-12
  let swf = sw.float
  let shf = sh.float
  let fsp = sp
  let fst = sst
  let fsw = sw
  let fsh = sh
  parallelRows(by1 - by0, yy):
    let y = by0 + yy
    let fy = y.float + 0.5
    if affine:
      # (u and v step evenly along the row: only where they are in it)
      let k8 = 1 / inv[8]
      let du = inv[0] * k8
      let dv = inv[3] * k8
      let u0 = (inv[1] * fy + inv[2]) * k8
      let v0 = (inv[4] * fy + inv[5]) * k8
      var lo = bx0.float
      var hi = bx1.float
      for (c0, dc) in [(u0, du), (v0, dv)]:
        # c0 + dc * (x + 0.5) within -0.01 .. 1.01
        if abs(dc) < 1e-15:
          if c0 < -0.01 or c0 > 1.01:
            lo = 1
            hi = 0
        else:
          let a = (-0.01 - c0) / dc - 0.5
          let b = (1.01 - c0) / dc - 0.5
          lo = max(lo, min(a, b))
          hi = min(hi, max(a, b) + 1)
      let xa = max(bx0, int(floor(lo)))
      let xb = min(bx1, int(ceil(hi)))
      if xb > xa:
        # (the source point steps evenly: in 32.32 fixed point)
        const one = 4294967296.0
        let fx0 = xa.float + 0.5
        var sxF = int64((( u0 + du * fx0) * swf - 0.5) * one)
        var syF = int64(((v0 + dv * fx0) * shf - 0.5) * one)
        let dsx = int64(du * swf * one)
        let dsy = int64(dv * shf * one)
        let loX = int64((-0.01 * swf - 0.5) * one)
        let hiX = int64((1.01 * swf - 0.5) * one)
        let loY = int64((-0.01 * shf - 0.5) * one)
        let hiY = int64((1.01 * shf - 0.5) * one)
        for x in xa ..< xb:
          if sxF >= loX and sxF <= hiX and syF >= loY and syF <= hiY:
            let c = bilinearFix(fsp, fsw, fsh, fst, sxF, syF)
            if (c shr 24) != 0:
              let i = y * w + x
              bp[i] = if (c shr 24) == 255: c else: blendPx(bp[i], c, 255, bmNormal)
          sxF += dsx
          syF += dsy
    else:
      for x in bx0 ..< bx1:
        let fx = x.float + 0.5
        let ww = inv[6] * fx + inv[7] * fy + inv[8]
        if abs(ww) < 1e-12: continue
        let u = (inv[0] * fx + inv[1] * fy + inv[2]) / ww
        let v = (inv[3] * fx + inv[4] * fy + inv[5]) / ww
        if u < -0.01 or v < -0.01 or u > 1.01 or v > 1.01: continue
        let c = bilinearAt(fsp, fsw, fsh, u * swf - 0.5, v * shf - 0.5, fst)
        if (c shr 24) == 0: continue
        let i = y * w + x
        bp[i] = if (c shr 24) == 255: c else: blendPx(bp[i], c, 255, bmNormal)

proc warpOnto*(d: Doc; base: var seq[uint32]; part: seq[uint32]; r: Rect; q: Quad) =
  ## `part` (taken up from `r`, its size) put down on `base` stretched into
  ## the corners `q` (see the other `warpOnto`).
  if part.len != r.w * r.h or part.len == 0: return
  d.warpOnto(base, pixPtr(part), r.w, r, q)

proc vacatedCopy*(d: Doc; px: seq[uint32]; r: Rect; vacated: uint32): seq[uint32] =
  ## A copy of a layer's pixels with `vacated` in `r` (what a transform of
  ## all of it without a selection leaves). On all the cores.
  result = newSeqUninit[uint32](px.len)
  let sp = pixPtr(px)
  let op = pixPtr(result)
  let w = d.w
  let c = d.clip(r)
  parallelRows(d.h, y):
    copyMem(addr op[y * w], addr sp[y * w], w * 4)
    if y >= c.y and y < c.y + c.h:
      for x in c.x ..< c.x + c.w: op[y * w + x] = vacated

proc warpedPixels*(d: Doc; original: seq[uint32]; r: Rect; mask: seq[uint8]; q: Quad;
                   vacated: uint32): seq[uint32] =
  ## A layer as `original`, with its pixels in `r` (where `mask` selects
  ## them; all of them when it is empty) taken up -- `vacated` left where
  ## they were -- and put down stretched into the corners `q` (Effects:
  ## Scale, Skew, Perspective, Distort, Rotate).
  var (part, base) = d.liftForWarp(original, r, mask, vacated)
  if part.len > 0 and quadIsFine(q): d.warpOnto(base, part, r, q)
  base

proc warpedMask*(d: Doc; mask: seq[uint8]; r: Rect; q: Quad): seq[uint8] =
  ## The selection carried along by `warpedPixels` (all of `r` when `mask`
  ## is empty).
  var px = newSeq[uint32](d.w * d.h)
  let sel = mask.len == d.w * d.h
  let pp = pixPtr(px)
  let mp = if sel: cast[ptr UncheckedArray[uint8]](unsafeAddr mask[0]) else: nil
  let w = d.w
  let x0 = max(0, r.x)
  let x1 = min(d.w, r.x + r.w)
  parallelRows(max(0, min(d.h, r.y + r.h) - max(0, r.y)), yy):
    let y = max(0, r.y) + yy
    for x in x0 ..< x1:
      let i = y * w + x
      pp[i] = withAlpha(0xFFFFFF'u32, if mp != nil: int(mp[i]) else: 255)
  let o = d.warpedPixels(px, r, @[], q, 0)
  result = newSeq[uint8](d.w * d.h)
  let op = pixPtr(o)
  let rp = cast[ptr UncheckedArray[uint8]](addr result[0])
  parallelFor(result.len, proc (a, b: int) =
    for i in a ..< b: rp[i] = uint8(op[i] shr 24), grain = 65536)

proc transformLayer*(d: Doc; L: Layer; r: Rect; nr: Rect; deg = 0.0) =
  ## The pixels of `L` in `r` scaled into `nr` and turned by `deg` around
  ## its center (Effects: Scale, Rotate). The place they leave is cleared.
  let sw = max(1, r.w)
  let sh = max(1, r.h)
  var part = newSeq[uint32](sw * sh)
  for y in 0 ..< sh:
    for x in 0 ..< sw:
      let xx = r.x + x
      let yy = r.y + y
      if xx >= 0 and yy >= 0 and xx < d.w and yy < d.h: part[y * sw + x] = L.px[yy * d.w + xx]
  var scaled = resample(part, sw, sh, max(1, nr.w), max(1, nr.h), rsBicubic)
  var tw = max(1, nr.w)
  var th = max(1, nr.h)
  var ox = nr.x
  var oy = nr.y
  if abs(deg) > 0.001:
    let a = degToRad(deg)
    let rw = int(ceil(abs(tw.float * cos(a)) + abs(th.float * sin(a))))
    let rh = int(ceil(abs(tw.float * sin(a)) + abs(th.float * cos(a))))
    scaled = rotatedPx(scaled, tw, th, deg, rw, rh, 0)
    ox -= (rw - tw) div 2
    oy -= (rh - th) div 2
    tw = rw
    th = rh
  let all = d.clip(union(r, rect(ox, oy, tw, th)))
  d.touch(L, all)
  let clearTo = 0'u32
  for y in max(0, r.y) ..< min(d.h, r.y + r.h):
    for x in max(0, r.x) ..< min(d.w, r.x + r.w):
      L.px[y * d.w + x] = clearTo
  for y in 0 ..< th:
    for x in 0 ..< tw:
      let xx = ox + x
      let yy = oy + y
      if xx >= 0 and yy >= 0 and xx < d.w and yy < d.h:
        let p = scaled[y * tw + x]
        if aOf(p) > 0: L.px[yy * d.w + xx] = blendPx(L.px[yy * d.w + xx], p, 255, bmNormal)
  inc L.ver
  d.markDirty(all)

# ---- modes -------------------------------------------------------------------------------------------------

proc mapAllPixels(d: Doc; f: proc (p: uint32): uint32 {.closure.}) =
  ## Every layer's pixels (not masks) changed by `f`, on all the cores.
  for L in d.layers:
    if L.adjust.kind.len > 0 or L.gray: continue
    let lp = pixPtr(L.px)
    parallelFor(L.px.len, proc (lo, hi: int) =
      for i in lo ..< hi:
        let p = lp[i]
        if (p shr 24) != 0: lp[i] = f(p), grain = 16384)
    inc L.ver

proc duotoneRendered*(d: Doc): seq[uint32] =
  ## A Duotone's look: each gray as its inks print it (256 colors).
  let t = duotoneTable(d.duotone)
  result = @t

proc toGrayscale*(d: Doc) =
  ## Mode > Grayscale.
  if d.mode == cmDuotone:
    d.mode = cmGray
    d.duotone.setLen(0)
    d.markAll()
    return
  for L in d.layers:
    for p in L.px.mitems: p = grayPx(lumaOf(p), aOf(p))
    inc L.ver
  d.mode = cmGray
  d.showAllChannels()
  d.markAll()

proc toRGB*(d: Doc)
  ## Mode > RGB Color (a Duotone: its inks' colors).

proc toCMYK*(d: Doc) =
  ## Mode > CMYK Color: every color made one the inks can print (as the
  ## printing setup says); the channels are cyan, magenta, yellow, black.
  if d.mode == cmDuotone: d.toRGB()
  discard proofOf(0)                            # (the tables, made once)
  let t = proofTablePtr()
  d.mapAllPixels(proc (p: uint32): uint32 = lookupProof(t, p))
  d.mode = cmCMYK
  d.palette.setLen(0)
  d.showAllChannels()
  d.markAll()

proc toLab*(d: Doc) =
  ## Mode > Lab Color: the channels are lightness, a (green to red), b (blue
  ## to yellow); the colors stay.
  if d.mode == cmDuotone:
    let t = duotoneTable(d.duotone)
    d.mapAllPixels(proc (p: uint32): uint32 = (t[(p shr 16) and 255] and 0xFFFFFF'u32) or (p and 0xFF000000'u32))
    d.duotone.setLen(0)
  d.mode = cmLab
  d.palette.setLen(0)
  d.showAllChannels()
  d.markAll()

proc toMultichannel*(d: Doc) =
  ## Mode > Multichannel: each color channel an ink of its own, on its own
  ## plate -- RGB's red, green and blue become cyan, magenta and yellow,
  ## CMYK's four inks stay, a gray image is one black (Lab is made RGB
  ## first). The layers are flattened: the inks are the picture. The
  ## picture looks as it did; deleting a channel (`deleteSpot`) takes its
  ## ink out.
  if d.mode == cmMultichannel: return
  if d.mode in {cmIndexed, cmLab}: d.toRGB()
  if d.mode == cmBitmap: d.mode = cmGray
  if d.mode == cmDuotone: d.toGrayscale()
  if d.layers.len > 1 or (d.layers.len == 1 and not d.layers[0].background): d.flatten()
  d.spots.setLen(0)
  case d.mode
  of cmCMYK:
    d.spotBase = cmCMYK
    for i, n in ["Cyan", "Magenta", "Yellow", "Black"]: d.spots.add SpotChannel(name: n, ch: i)
  of cmGray:
    d.spotBase = cmGray
    d.spots.add SpotChannel(name: "Black", ch: 0)
  else:
    d.spotBase = cmRGB
    for i, n in ["Cyan", "Magenta", "Yellow"]: d.spots.add SpotChannel(name: n, ch: i)
  d.palette.setLen(0)
  d.mode = cmMultichannel
  d.showAllChannels()
  d.markAll()

proc canDeleteSpot*(d: Doc): bool =
  ## A channel of the image can be deleted, its ink taken out: one of RGB's
  ## (or of a Multichannel image made from RGB) while another stays. (A
  ## CMYK image's inks are kept as the picture they print -- separated
  ## again from it, a black taken out would come back -- so they stay.)
  d.channelCount > 1 and (d.mode == cmRGB or (d.mode == cmMultichannel and d.spotBase == cmRGB))

proc deleteSpot*(d: Doc; i: int) =
  ## Channel `i` of a Multichannel image made from RGB deleted: its ink
  ## taken out of the picture (the others print as they did). The last one
  ## stays (`canDeleteSpot`).
  if d.mode != cmMultichannel or d.spotBase != cmRGB or i < 0 or i >= d.spots.len or
     d.spots.len <= 1: return
  let sh = 16 - 8 * d.spots[i].ch
  d.mapAllPixels(proc (p: uint32): uint32 = p or (0xFF'u32 shl sh))
  d.spots.delete(i)
  d.showAllChannels()
  d.markAll()

proc toDuotone*(d: Doc; inks: seq[DuotoneInk]) =
  ## Mode > Duotone: a gray image printed in one to four inks (from
  ## Grayscale).
  if d.mode notin {cmGray, cmDuotone}: d.toGrayscale()
  d.duotone = inks
  d.mode = cmDuotone
  d.showAllChannels()
  d.markAll()

proc toBitmapMode*(d: Doc; dither = true; threshold = 128) =
  ## Mode > Bitmap: black and white only (diffusion dither or 50 % threshold).
  if d.layers.len > 1: d.flatten()
  let L = d.layers[0]
  var err = newSeq[float](d.w * d.h)
  for i, p in L.px: err[i] = lumaOf(p).float
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      let i = y * d.w + x
      let v = err[i]
      let o = if v >= threshold.float: 255.0 else: 0.0
      L.px[i] = grayPx(int(o))
      if dither:
        let e = v - o
        if x + 1 < d.w: err[i + 1] += e * 7 / 16
        if y + 1 < d.h:
          if x > 0: err[i + d.w - 1] += e * 3 / 16
          err[i + d.w] += e * 5 / 16
          if x + 1 < d.w: err[i + d.w + 1] += e * 1 / 16
  inc L.ver
  d.mode = cmBitmap
  d.markAll()

proc nearestIn*(pal: seq[uint32]; p: uint32): uint32 =
  ## The color of `pal` nearest to `p` (with `p`'s alpha).
  var best = 1 shl 30
  for c in pal:
    let dr = rOf(c) - rOf(p)
    let dg = gOf(c) - gOf(p)
    let db = bOf(c) - bOf(p)
    let dd = dr * dr * 3 + dg * dg * 4 + db * db * 2
    if dd < best:
      best = dd
      result = c
  result = withAlpha(result, aOf(p))

proc medianCut*(px: seq[uint32]; n: int): seq[uint32] =
  ## `n` colors that stand for `px` well (median cut).
  var boxes: seq[seq[uint32]] = @[@[]]
  let step = max(1, px.len div 60000)
  var i = 0
  while i < px.len:
    if aOf(px[i]) > 0: boxes[0].add px[i] or 0xFF000000'u32
    i += step
  if boxes[0].len == 0: return @[0xFF000000'u32]
  while boxes.len < n:
    # the box with the widest channel goes in two
    var bi = -1
    var bw = -1
    var bch = 0
    for k, b in boxes:
      if b.len < 2: continue
      for ch in 0 .. 2:
        var lo = 255
        var hi = 0
        for p in b:
          let v = int((p shr (16 - ch * 8)) and 255)
          lo = min(lo, v); hi = max(hi, v)
        if hi - lo > bw:
          bw = hi - lo; bi = k; bch = ch
    if bi < 0 or bw <= 0: break
    var b = boxes[bi]
    let sh = 16 - bch * 8
    b.sort(proc (x, y: uint32): int = cmp((x shr sh) and 255, (y shr sh) and 255))
    let half = b.len div 2
    boxes[bi] = b[0 ..< half]
    boxes.add b[half .. ^1]
  for b in boxes:
    if b.len == 0: continue
    var sr, sg, sb = 0
    for p in b:
      sr += rOf(p); sg += gOf(p); sb += bOf(p)
    result.add argb(255, sr div b.len, sg div b.len, sb div b.len)

proc systemPalette*(): seq[uint32] =
  ## The 16 colors of the 3.1 desktop.
  for c in [0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xC0C0C0,
            0x808080, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF]:
    result.add 0xFF000000'u32 or uint32(c)

proc uniformPalette*(): seq[uint32] =
  ## 216 colors: 6 levels of red, green and blue.
  for r in 0 .. 5:
    for g in 0 .. 5:
      for b in 0 .. 5: result.add argb(255, r * 51, g * 51, b * 51)

proc toIndexed*(d: Doc; pal: seq[uint32]; dither = true) =
  ## Mode > Indexed Color with the colors `pal` (diffusion dither or
  ## nearest).
  if d.layers.len > 1: d.flatten()
  let L = d.layers[0]
  var er = newSeq[array[3, float]](d.w * d.h)
  for i, p in L.px: er[i] = [rOf(p).float, gOf(p).float, bOf(p).float]
  for y in 0 ..< d.h:
    for x in 0 ..< d.w:
      let i = y * d.w + x
      let want = argb(255, int(round(er[i][0])), int(round(er[i][1])), int(round(er[i][2])))
      let got = nearestIn(pal, want)
      L.px[i] = got or 0xFF000000'u32
      if dither:
        let e = [er[i][0] - rOf(got).float, er[i][1] - gOf(got).float, er[i][2] - bOf(got).float]
        for c in 0 .. 2:
          if x + 1 < d.w: er[i + 1][c] += e[c] * 7 / 16
          if y + 1 < d.h:
            if x > 0: er[i + d.w - 1][c] += e[c] * 3 / 16
            er[i + d.w][c] += e[c] * 5 / 16
            if x + 1 < d.w: er[i + d.w + 1][c] += e[c] / 16
  inc L.ver
  d.palette = pal
  d.mode = cmIndexed
  d.markAll()

proc toRGB*(d: Doc) =
  ## Mode > RGB Color (a Duotone: its inks' colors).
  if d.mode == cmDuotone:
    let t = duotoneTable(d.duotone)
    d.mapAllPixels(proc (p: uint32): uint32 = (t[(p shr 16) and 255] and 0xFFFFFF'u32) or (p and 0xFF000000'u32))
    d.duotone.setLen(0)
  d.mode = cmRGB
  d.palette.setLen(0)
  d.showAllChannels()
  d.markAll()

proc fitColor*(d: Doc; c: uint32): uint32 =
  ## A color as the image's mode allows it (gray, black or white, nearest
  ## in the color table).
  case d.mode
  of cmGray: grayPx(lumaOf(c), aOf(c))
  of cmBitmap: grayPx(if lumaOf(c) >= 128: 255 else: 0, aOf(c))
  of cmIndexed: (if d.palette.len > 0: nearestIn(d.palette, c) else: c)
  of cmRGB, cmLab: c
  of cmCMYK: proofOf(c)
  of cmDuotone: grayPx(lumaOf(c), aOf(c))
  of cmMultichannel:
    case d.spotBase
    of cmCMYK: proofOf(c)
    of cmGray: grayPx(lumaOf(c), aOf(c))
    else: c

# ---- histogram ----------------------------------------------------------------------------------------------

type Histogram* = object
  ## How many pixels have each level, per channel (0 lightness, 1 red, 2
  ## green, 3 blue).
  counts*: array[4, array[256, int]]  ## for each channel, the pixels at each level
  total*: int                         ## the pixels counted (those selected and not transparent)

proc histogram*(d: Doc; merged = true): Histogram =
  ## Of the selection (or all) of the image as it looks, or of the layer.
  if merged: d.updateComposite()
  let src = if merged: d.compPtr else: pixPtr(d.layer.px)
  let r = d.clip(d.selBounds)
  if r.w <= 0 or r.h <= 0: return
  let w = d.w
  let selp = if d.sel.len == d.w * d.h: cast[ptr UncheckedArray[uint8]](addr d.sel[0]) else: nil
  # each piece of rows counts on its own; the counts are added up after
  let pieces = max(1, min(r.h, threadCount() * 2))
  var parts = newSeq[Histogram](pieces)
  let pp = cast[ptr UncheckedArray[Histogram]](addr parts[0])
  parallelFor(pieces, proc (lo, hi: int) =
    for k in lo ..< hi:
      let y0 = r.y + r.h * k div pieces
      let y1 = r.y + r.h * (k + 1) div pieces
      for y in y0 ..< y1:
        for x in r.x ..< r.x + r.w:
          let i = y * w + x
          if selp != nil and selp[i] < 128: continue
          let p = src[i]
          if (p shr 24) == 0: continue
          inc pp[k].counts[0][lumaOf(p)]
          inc pp[k].counts[1][rOf(p)]
          inc pp[k].counts[2][gOf(p)]
          inc pp[k].counts[3][bOf(p)]
          inc pp[k].total)
  for part in parts:
    for c in 0 .. 3:
      for v in 0 .. 255: result.counts[c][v] += part.counts[c][v]
    result.total += part.total

proc stats*(h: Histogram; ch: int): tuple[mean, sd: float; median: int] =
  ## The mean, standard deviation and median level of channel `ch`.
  var s = 0.0
  for v in 0 .. 255: s += float(v * h.counts[ch][v])
  let n = max(1, h.total)
  result.mean = s / n.float
  var q = 0.0
  for v in 0 .. 255: q += float(h.counts[ch][v]) * (v.float - result.mean) ^ 2
  result.sd = sqrt(q / n.float)
  var c = 0
  for v in 0 .. 255:
    c += h.counts[ch][v]
    if c * 2 >= n:
      result.median = v
      break

# ---- files ----------------------------------------------------------------------------------------------------

proc fromBitmap*(b: Bitmap; name = "Untitled"; take = false): Doc =
  ## A document of one picture (the Background when it is opaque). With
  ## `take`, the picture's pixels are moved into it (no copy; `b` is left
  ## empty) -- for a big photo just opened.
  var opaque = true
  let bp = pixPtr(b.px)
  var seen: array[64, bool]                  # (each piece's answer)
  let pieces = min(64, max(1, b.px.len div 65536))
  let sp = cast[ptr UncheckedArray[bool]](addr seen[0])
  let n = b.px.len
  parallelFor(pieces, proc (lo, hi: int) =
    for k in lo ..< hi:
      for i in n * k div pieces ..< n * (k + 1) div pieces:
        if (bp[i] shr 24) != 255:
          sp[k] = true
          break)
  for k in 0 ..< pieces:
    if seen[k]: opaque = false
  result = blankDoc(b.w, b.h, name = name)
  let L = Layer(name: if opaque: "Background" else: "Layer 1", opacity: 100, mode: bmNormal,
                visible: true, background: opaque)
  if take: L.px = move b.px
  else: L.px = b.px
  result.layers.add L
  result.markAll()
  result.modified = false

proc encodeBmp32*(px: seq[uint32]; w, h: int): string =
  ## A 32-bit BMP of `px`, its transparency kept (BGRA, a V4 header).
  let size = 122 + w * h * 4
  result = newString(size)
  proc put32(s: var string; at: int; v: int) =
    for k in 0 .. 3: s[at + k] = char((v shr (8 * k)) and 255)
  result[0] = 'B'
  result[1] = 'M'
  put32(result, 2, size)
  put32(result, 10, 122)
  put32(result, 14, 108)                  # (BITMAPV4HEADER)
  put32(result, 18, w)
  put32(result, 22, h)
  result[26] = char(1)
  result[28] = char(32)
  put32(result, 30, 3)                    # (BI_BITFIELDS: the masks say where each color is)
  put32(result, 34, w * h * 4)
  put32(result, 38, 2835)
  put32(result, 42, 2835)
  put32(result, 54, 0x00FF0000)
  put32(result, 58, 0x0000FF00)
  put32(result, 62, 0x000000FF)
  put32(result, 66, int(cast[int32](0xFF000000'u32)))   # (put32 writes the low 32 bits)
  put32(result, 70, 0x73524742)           # ("sRGB")
  var at = 122
  for y in countdown(h - 1, 0):
    for x in 0 ..< w:
      let p = px[y * w + x]
      result[at] = char(p and 255)
      result[at + 1] = char((p shr 8) and 255)
      result[at + 2] = char((p shr 16) and 255)
      result[at + 3] = char(p shr 24)
      at += 4

proc encodeBmp*(px: seq[uint32]; w, h: int): string =
  ## A 24-bit BMP of `px` (transparent parts white).
  let rowLen = (w * 3 + 3) and not 3
  let size = 54 + rowLen * h
  var s = newString(size)
  proc put32(at: int; v: int) =
    for k in 0 .. 3: s[at + k] = char((v shr (8 * k)) and 255)
  proc put16(at: int; v: int) =
    s[at] = char(v and 255); s[at + 1] = char((v shr 8) and 255)
  s[0] = 'B'; s[1] = 'M'
  put32(2, size); put32(10, 54); put32(14, 40); put32(18, w); put32(22, h)
  put16(26, 1); put16(28, 24); put32(34, rowLen * h); put32(38, 2835); put32(42, 2835)
  for y in 0 ..< h:
    let row = 54 + (h - 1 - y) * rowLen
    for x in 0 ..< w:
      let p = blendPx(0xFFFFFFFF'u32, px[y * w + x], 255, bmNormal)
      s[row + x * 3] = char(bOf(p)); s[row + x * 3 + 1] = char(gOf(p)); s[row + x * 3 + 2] = char(rOf(p))
  s

proc maskPng(m: seq[uint8]; w, h: int): string =
  let b = newBitmap(w, h)
  for i, v in m: b.px[i] = grayPx(int(v))
  encodePng(b)

proc toJson*(fx: LayerFx): JsonNode =
  ## A layer style as JSON (the effects that are on).
  result = newJObject()
  if fx.hidden: result["hidden"] = %true
  for k, e in fx.fx:
    if not e.on: continue
    result[$k] = %*{"mode": $e.mode, "opacity": e.opacity, "color": int64(e.color), "color2": int64(e.color2),
                    "mode2": $e.mode2, "opacity2": e.opacity2, "angle": e.angle, "altitude": e.altitude,
                    "distance": e.distance, "size": e.size, "spread": e.spread, "depth": e.depth,
                    "soften": e.soften, "style": e.style, "down": e.down, "scale": e.scale}

proc layerFxFrom*(j: JsonNode): LayerFx =
  ## A layer style saved with `toJson`.
  if j == nil or j.kind != JObject: return
  result.hidden = j{"hidden"}.getBool
  for k in FxKind:
    let ej = j{$k}
    if ej == nil or ej.kind != JObject: continue
    var e = Effect(on: true)
    for m in BlendMode:
      if $m == ej{"mode"}.getStr: e.mode = m
      if $m == ej{"mode2"}.getStr: e.mode2 = m
    e.opacity = clamp(ej{"opacity"}.getInt(75), 0, 100)
    e.opacity2 = clamp(ej{"opacity2"}.getInt(75), 0, 100)
    e.color = uint32(ej{"color"}.getBiggestInt(0xFF000000) and 0xFFFFFFFF)
    e.color2 = uint32(ej{"color2"}.getBiggestInt(0xFF000000) and 0xFFFFFFFF)
    e.angle = ej{"angle"}.getInt(120)
    e.altitude = clamp(ej{"altitude"}.getInt(30), 0, 90)
    e.distance = clamp(ej{"distance"}.getInt(0), 0, 30000)
    e.size = clamp(ej{"size"}.getInt(0), 0, 250)
    e.spread = clamp(ej{"spread"}.getInt(0), 0, 100)
    e.depth = clamp(ej{"depth"}.getInt(100), 0, 1000)
    e.soften = clamp(ej{"soften"}.getInt(0), 0, 16)
    e.style = clamp(ej{"style"}.getInt(0), 0, 4)
    e.down = ej{"down"}.getBool
    e.scale = clamp(ej{"scale"}.getInt(100), 0, 150)
    result.fx[k] = e

proc toJson*(p: Path): JsonNode =
  ## A path as JSON.
  var subs = newJArray()
  for s in p.subs:
    var pts = newJArray()
    for q in s.pts: pts.add %*[q.p[0], q.p[1], q.inH[0], q.inH[1], q.outH[0], q.outH[1]]
    var sj = %*{"closed": s.closed, "points": pts}
    if s.op != poAdd: sj["op"] = %($s.op)
    if s.joined: sj["joined"] = %true
    subs.add sj
  %*{"name": p.name, "subpaths": subs}

proc pathFrom*(pj: JsonNode): Path =
  ## A path saved with `toJson`.
  result = Path(name: pj{"name"}.getStr("Path"))
  for sj in pj{"subpaths"}.getElems:
    var sp = SubPath(closed: sj{"closed"}.getBool, joined: sj{"joined"}.getBool)
    for o in PathOp:
      if $o == sj{"op"}.getStr: sp.op = o
    for q in sj{"points"}.getElems:
      let a = q.getElems
      if a.len == 6:
        sp.pts.add PathPoint(p: (a[0].getFloat, a[1].getFloat), inH: (a[2].getFloat, a[3].getFloat),
                             outH: (a[4].getFloat, a[5].getFloat))
    if sp.pts.len > 0: result.subs.add sp

proc toJson*(p: ShapePaint): JsonNode =
  ## A shape's fill or stroke as JSON.
  result = %*{"kind": $p.kind, "color": int64(p.color), "color2": int64(p.color2), "angle": p.angle,
              "style": p.style, "reverse": p.reverse, "opacity": p.opacity}
  if p.scale != 0 and p.scale != 100: result["scale"] = %p.scale
  if p.stops.len > 0:
    var a = newJArray()
    for st in p.stops:
      if st.mid > 0 and abs(st.mid - 0.5) > 1e-6: a.add %*[st.at, int64(st.color), st.mid]
      else: a.add %*[st.at, int64(st.color)]
    result["stops"] = a
  if p.pattern.len > 0 and p.pattern.len == p.pw * p.ph:
    let b = newBitmap(p.pw, p.ph)
    b.px = p.pattern
    result["pattern"] = %encode(encodePng(b))

proc paintFrom(j: JsonNode): ShapePaint =
  if j == nil or j.kind != JObject: return
  for k in ShapePaintKind:
    if $k == j{"kind"}.getStr: result.kind = k
  result.color = uint32(j{"color"}.getBiggestInt(0xFF000000) and 0xFFFFFFFF)
  result.color2 = uint32(j{"color2"}.getBiggestInt(0xFFFFFFFF) and 0xFFFFFFFF)
  result.angle = j{"angle"}.getInt(90)
  result.style = clamp(j{"style"}.getInt(0), 0, 4)
  result.reverse = j{"reverse"}.getBool
  result.opacity = clamp(j{"opacity"}.getInt(100), 0, 100)
  result.scale = clamp(j{"scale"}.getInt(100), 10, 1000)
  for st in j{"stops"}.getElems:
    let e = st.getElems
    if e.len in 2 .. 3 and result.stops.len < 64:
      result.stops.add GradientStop(at: clamp(e[0].getFloat, 0.0, 1.0),
                                    color: uint32(e[1].getBiggestInt(0) and 0xFFFFFFFF),
                                    mid: (if e.len == 3: clamp(e[2].getFloat, 0.0, 1.0) else: 0.0))
  if j.hasKey("pattern"):
    try:
      let b = decodePng(unbase64(j["pattern"].getStr))
      if b != nil and b.w > 0 and b.w * b.h <= 4096 * 4096:
        result.pattern = b.px
        result.pw = b.w
        result.ph = b.h
    except CatchableError: discard

proc toJson*(s: ShapeData): JsonNode =
  ## A shape layer's shape as JSON.
  result = %*{"path": s.path.toJson, "fill": s.fill.toJson, "stroke": s.stroke.toJson,
              "strokeWidth": s.strokeWidth, "align": $s.align, "cap": $s.cap, "join": $s.join,
              "dashes": s.dashes, "kind": s.kind, "radius": s.radius}
  if s.startEnd != leNone or s.endEnd != leNone:
    result["startEnd"] = %($s.startEnd)
    result["endEnd"] = %($s.endEnd)
    result["endW"] = %s.endW
    result["endL"] = %s.endL

proc shapeFrom*(j: JsonNode): ShapeData =
  ## A shape saved with `toJson`.
  if j == nil or j.kind != JObject: return
  result.path = pathFrom(j{"path"})
  result.fill = paintFrom(j{"fill"})
  result.stroke = paintFrom(j{"stroke"})
  result.strokeWidth = clamp(j{"strokeWidth"}.getFloat(1), 0.0, 1000.0)
  for a in StrokeAlign:
    if $a == j{"align"}.getStr: result.align = a
  for c in LineCap:
    if $c == j{"cap"}.getStr: result.cap = c
  for c in LineJoin:
    if $c == j{"join"}.getStr: result.join = c
  for v in j{"dashes"}.getElems:
    if result.dashes.len < 16: result.dashes.add clamp(v.getFloat, 0.0, 1000.0)
  result.kind = j{"kind"}.getStr
  result.radius = clamp(j{"radius"}.getFloat(0), 0.0, 1e6)
  for e in LineEnd:
    if $e == j{"startEnd"}.getStr: result.startEnd = e
    if $e == j{"endEnd"}.getStr: result.endEnd = e
  result.endW = clamp(j{"endW"}.getFloat(0), 0.0, 100.0)
  result.endL = clamp(j{"endL"}.getFloat(0), 0.0, 100.0)

type RpdPart* = object
  ## A file of a ".rpd" document, before it is written: bytes as they are,
  ## or pixels (or a gray mask) to make a PNG of.
  name*: string            ## its name in the .rpd (a zip)
  data*: string            ## its bytes, when it is written as it is
  px*: seq[uint32]         ## ... or its pixels, made a PNG
  gray*: seq[uint8]        ## ... or a gray mask, made a PNG
  w*, h*: int              ## the size of `px` or `gray`

proc compToJson(c: LayerComp): JsonNode =
  result = %*{"name": c.name, "comment": c.comment, "visibility": c.visibility, "position": c.position,
              "appearance": c.appearance}
  var a = newJArray()
  for s in c.states:
    a.add %*{"uid": s.uid, "visible": s.visible, "x": s.x, "y": s.y, "opacity": s.opacity, "fill": s.fill,
             "mode": $s.mode, "style": s.fx.toJson}
  result["layers"] = a

proc compFrom(j: JsonNode): LayerComp =
  result = LayerComp(name: j{"name"}.getStr("Layer Comp"), comment: j{"comment"}.getStr,
                     visibility: j{"visibility"}.getBool(true), position: j{"position"}.getBool(true),
                     appearance: j{"appearance"}.getBool(true))
  for sj in j{"layers"}.getElems:
    var st = CompState(uid: sj{"uid"}.getInt, visible: sj{"visible"}.getBool(true), x: sj{"x"}.getInt,
                       y: sj{"y"}.getInt, opacity: sj{"opacity"}.getInt(100), fill: sj{"fill"}.getInt(100))
    for m in BlendMode:
      if $m == sj{"mode"}.getStr: st.mode = m
    if sj.hasKey("style"): st.fx = layerFxFrom(sj["style"])
    result.states.add st

proc rpdParts*(d: Doc): seq[RpdPart] =
  ## What a ".rpd" of the document holds (its pixels copied, not yet
  ## compressed: `writeRpd` does that, on any thread).
  var parts: seq[RpdPart]
  proc addPx(name: string; px: seq[uint32]; w, h: int) = parts.add RpdPart(name: name, px: px, w: w, h: h)
  proc addGray(name: string; m: seq[uint8]; w, h: int) = parts.add RpdPart(name: name, gray: m, w: w, h: h)
  proc addRaw(name, data: string) = parts.add RpdPart(name: name, data: data)
  var j = %*{"format": "Retro Photo", "version": 3, "width": d.w, "height": d.h, "dpi": d.dpi,
             "mode": $d.mode, "current": d.cur,
             "info": {"caption": d.info.caption, "author": d.info.author, "title": d.info.title,
                      "keywords": d.info.keywords, "copyright": d.info.copyright, "url": d.info.url}}
  # (the picture as it looks, small: what file lists and Open dialogs show)
  if d.live.len == 0: d.updateComposite()
  if d.comp.len == d.w * d.h:
    let t = thumbnailOf(d.comp, d.w, d.h, min(d.w, 512), min(d.h, 512), checker = false)
    addPx("preview.png", t.px, t.w, t.h)
    j["preview"] = %"preview.png"
  var ls = newJArray()
  for i, L in d.layers:
    let file = "layer" & $i & ".png"
    var lj = %*{"name": L.name, "opacity": L.opacity, "mode": $L.mode, "visible": L.visible,
                "preserve": L.lockAlpha, "background": L.background, "file": file}
    if L.uid != 0: lj["uid"] = %L.uid
    if L.flowFrom != 0: lj["flowFrom"] = %L.flowFrom
    if L.gray: lj["gray"] = %true
    if L.adjust.kind.len > 0:
      lj["adjust"] = %*{"kind": L.adjust.kind, "args": L.adjust.args}
      if L.adjust.data.len > 0: lj["adjust"]["data"] = %L.adjust.data
    if L.isText: lj["text"] = L.text.toJson
    if L.isShape: lj["shape"] = L.shape.toJson
    if L.clipped: lj["clipped"] = %true
    if L.hasStyle: lj["style"] = L.fx.toJson
    if L.fill != 100: lj["fill"] = %L.fill
    if L.depth > 0: lj["depth"] = %L.depth
    if L.locked: lj["locked"] = %true
    if L.lockPixels: lj["lockPixels"] = %true
    if L.lockPosition: lj["lockPosition"] = %true
    if L.link != 0: lj["link"] = %L.link
    if L.board.w > 0: lj["artboard"] = %[L.board.x, L.board.y, L.board.w, L.board.h]
    if L.blendIf.isOn:
      lj["blendIf"] = %*{"channel": L.blendIf.channel, "this": rangeOf(L.blendIf.this),
                         "under": rangeOf(L.blendIf.under)}
    if L.maskDensity != 100: lj["maskDensity"] = %L.maskDensity
    if L.maskFeather > 0: lj["maskFeather"] = %L.maskFeather
    if L.group:
      lj["group"] = %true
      lj["passThrough"] = %L.passThrough
      if L.collapsed: lj["collapsed"] = %true
      lj.delete("file")
    else:
      addPx(file, L.px, d.w, d.h)
    if L.smart != nil and L.smart.src.len == L.smart.w * L.smart.h and L.smart.w > 0:
      # a Smart Object: its picture, corners, warp and filters
      let sf = "smart" & $i & ".png"
      addPx(sf, L.smart.src, L.smart.w, L.smart.h)
      var q = newJArray()
      for c in L.smart.quad: q.add %*[c[0], c[1]]
      var fs = newJArray()
      for f in L.smart.filters:
        fs.add %*{"name": f.name, "args": f.args, "text": f.text, "opacity": f.opacity, "mode": $f.mode,
                  "off": f.off}
      var sj = %*{"file": sf, "width": L.smart.w, "height": L.smart.h, "quad": q, "filters": fs,
                  "name": L.smart.name}
      if L.smart.warp.len > 0:
        var wa = newJArray()
        for c in L.smart.warp: wa.add %*[c[0], c[1]]
        sj["warp"] = wa
      if L.smart.file.len > 0:
        let df = "smart" & $i & ".rpd"
        addRaw(df, L.smart.file)
        sj["document"] = %df
      lj["smart"] = sj
    if d.depth == 16 and d.hiValid(L) and not L.group:
      # (its 16 bits: as they are, zipped)
      d.syncHi(L)
      let hf = "hi" & $i & ".u16"
      var raw = newString(L.hi.len * 2)
      if raw.len > 0: copyMem(addr raw[0], unsafeAddr L.hi[0], raw.len)
      addRaw(hf, raw)
      lj["hi"] = %hf
    if d.depth == 32 and d.hdrValid(L):
      # (its light at 32 bits: the floats as they are, zipped)
      let hf = "hdr" & $i & ".f32"
      var raw = newString(L.hdr.len * 4)
      if raw.len > 0: copyMem(addr raw[0], unsafeAddr L.hdr[0], raw.len)
      addRaw(hf, raw)
      lj["hdr"] = %hf
    if L.mask != nil and L.mask.px.len == L.px.len:
      let mf = "mask" & $i & ".png"
      var m = newSeq[uint8](d.w * d.h)
      for k, p in L.mask.px: m[k] = uint8(rOf(p))
      addGray(mf, m, d.w, d.h)
      lj["mask"] = %mf
      lj["maskOff"] = %L.maskOff
    ls.add lj
  j["layers"] = ls
  if d.depth > 8: j["bits"] = %d.depth
  if d.depth == 32:
    j["exposure"] = %d.exposure
    j["viewGamma"] = %d.viewGamma
  if d.comps.len > 0:
    var cs = newJArray()
    for c in d.comps: cs.add c.compToJson
    j["comps"] = cs
  if d.frames.len > 0:
    var fa = newJArray()
    for f in d.frames:
      var ls = newJArray()
      for fl in f.layers: ls.add %*[fl.uid, fl.visible, fl.opacity, fl.dx, fl.dy]
      fa.add %*{"delay": f.delay, "layers": ls}
    j["frames"] = fa
    j["frameCur"] = %d.frameCur
    j["animLoop"] = %d.animLoop
  for (key, list) in [("charStyles", d.charStyles), ("paraStyles", d.paraStyles)]:
    if list.len > 0:
      var a = newJArray()
      for st in list: a.add %*{"name": st.name, "char": st.char.toJson, "para": st.para.paraToJson}
      j[key] = a
  var cs = newJArray()
  for i, a in d.alphas:
    let file = "channel" & $i & ".png"
    cs.add %*{"name": a.name, "file": file}
    addGray(file, a.m, d.w, d.h)
  j["channels"] = cs
  if d.hasSelection: addGray("selection.png", d.sel, d.w, d.h)
  if d.icc.len > 0: addRaw("profile.icc", d.icc)
  var ps = newJArray()
  for p in d.paths: ps.add p.toJson
  j["paths"] = ps
  if d.palette.len > 0:
    var pal = newJArray()
    for c in d.palette: pal.add %int(c and 0xFFFFFF'u32)
    j["palette"] = pal
  if d.duotone.len > 0:
    var inks = newJArray()
    for ink in d.duotone: inks.add %*{"name": ink.name, "color": int(ink.color and 0xFFFFFF'u32), "gamma": ink.gamma}
    j["duotone"] = inks
  if d.mode == cmMultichannel:
    var sp = newJArray()
    for s in d.spots: sp.add %*{"name": s.name, "channel": s.ch}
    j["spots"] = sp
    j["spotBase"] = %($d.spotBase)
  addRaw("document.json", pretty(j))
  parts

proc writeRpd*(parts: sink seq[RpdPart]; path: string) =
  ## Writes a ".rpd" from its parts (`rpdParts`): the pictures made PNGs,
  ## zipped, written to a file beside it and moved into place.
  var parts = parts
  var z = newZipWriter()
  for p in parts.mitems:
    # (each PNG packed on all the cores, at the quick level: a little
    # bigger, twice as fast)
    if p.px.len > 0:
      let b = Bitmap(w: p.w, h: p.h, px: move p.px)
      z.addFile(p.name, encodePng(b, level = 3))
    elif p.gray.len > 0: z.addFile(p.name, maskPng(p.gray, p.w, p.h))
    else: z.addFile(p.name, p.data)
  let tmp = path & ".part"
  writeFile(tmp, z.finish())
  moveFile(tmp, path)

proc saveRpd*(d: Doc; path: string) =
  ## Saves the document with its layers, channels, paths and file info
  ## (a zip of PNG pictures and a description: ".rpd").
  writeRpd(d.rpdParts, path)

proc rpdPreview*(path: string; maxW = 512; maxH = 512): Bitmap =
  ## The small picture of a ".rpd" document (as it looks, merged), read
  ## without opening it; older files without one: their bottom layer.
  ## Nil when it is not one.
  try:
    var files: Table[string, ZipEntry]
    for e in zipEntries(path): files[e.name] = e
    for name in ["preview.png", "layer0.png"]:
      if files.hasKey(name):
        let b = decodePng(readEntry(path, files[name]))
        if b != nil and b.w > 0: return b
  except CatchableError: discard

proc loadRpd*(path: string): Doc =
  ## Opens a ".rpd" document. Raises `IOError` when it cannot be read.
  var files: Table[string, ZipEntry]
  for e in zipEntries(path): files[e.name] = e
  if not files.hasKey("document.json"): raise newException(IOError, "not a Retro Photo document")
  let j = try: parseJson(readEntry(path, files["document.json"]))
          except JsonParsingError, ValueError: raise newException(IOError, "damaged document")
  let w = j{"width"}.getInt(0)
  let h = j{"height"}.getInt(0)
  if not sizeOk(w, h): raise newException(IOError, "bad image size")
  result = newDoc(w, h, 0, dpi = j{"dpi"}.getFloat(72), name = path.splitFile.name)
  result.layers.setLen(0)
  # (the layers' and masks' pictures read first, then unpacked at once on
  # all the cores)
  var wanted: seq[string]
  for lj in j{"layers"}.getElems:
    for key in ["file", "mask"]:
      let f = lj{key}.getStr
      if f.len > 0 and files.hasKey(f) and f notin wanted: wanted.add f
  var packed = newSeq[string](wanted.len)
  for i, f in wanted: packed[i] = readEntry(path, files[f])
  var unpacked = newSeq[Bitmap](wanted.len)
  if wanted.len > 0:
    let pp = cast[ptr UncheckedArray[string]](addr packed[0])
    let up = cast[ptr UncheckedArray[Bitmap]](addr unpacked[0])
    parallelFor(wanted.len, proc (lo, hi: int) =
      for i in lo ..< hi:
        let b = try: decodePng(pp[i]) except CatchableError: nil
        if b != nil and b.w == w and b.h == h: up[i] = b
        pp[i] = ""
    )
  proc pic(file: string): Bitmap =
    let at = wanted.find(file)
    if at >= 0:
      result = move unpacked[at]
      return
    if not files.hasKey(file): result = nil; return
    let b = decodePng(readEntry(path, files[file]))
    if b == nil or b.w != w or b.h != h: result = nil; return
    b
  for lj in j{"layers"}.getElems:
    let b = pic(lj{"file"}.getStr)
    let L = Layer(name: lj{"name"}.getStr("Layer"), opacity: clamp(lj{"opacity"}.getInt(100), 0, 100),
                  visible: lj{"visible"}.getBool(true), lockAlpha: lj{"preserve"}.getBool,
                  background: lj{"background"}.getBool)
    L.px = if b != nil: b.px else: zeroPixels(w * h)
    L.group = lj{"group"}.getBool
    L.passThrough = lj{"passThrough"}.getBool(true)
    L.collapsed = lj{"collapsed"}.getBool
    L.depth = max(0, lj{"depth"}.getInt(0))
    let hf = lj{"hdr"}.getStr
    if hf.len > 0 and files.hasKey(hf):
      # (its light at 32 bits)
      let raw = readEntry(path, files[hf])
      if raw.len == w * h * 16:
        L.hdr = newSeqUninit[float32](w * h * 4)
        copyMem(addr L.hdr[0], unsafeAddr raw[0], raw.len)
        L.hdrVer = L.ver
    let hif = lj{"hi"}.getStr
    if hif.len > 0 and files.hasKey(hif):
      # (its 16 bits)
      let raw = readEntry(path, files[hif])
      if raw.len == w * h * 8:
        L.hi = newSeqUninit[uint16](w * h * 4)
        copyMem(addr L.hi[0], unsafeAddr raw[0], raw.len)
    L.locked = lj{"locked"}.getBool
    L.lockPixels = lj{"lockPixels"}.getBool
    L.lockPosition = lj{"lockPosition"}.getBool
    L.link = max(0, lj{"link"}.getInt)
    let ab = lj{"artboard"}.getElems
    if ab.len == 4: L.board = rect(ab[0].getInt, ab[1].getInt, ab[2].getInt, ab[3].getInt)
    if lj.hasKey("blendIf"):
      let bj = lj["blendIf"]
      L.blendIf.channel = clamp(bj{"channel"}.getInt(0), 0, 3)
      for k in 0 .. 3:
        L.blendIf.this[k] = clamp(bj{"this"}{k}.getInt(if k < 2: 0 else: 255), 0, 255)
        L.blendIf.under[k] = clamp(bj{"under"}{k}.getInt(if k < 2: 0 else: 255), 0, 255)
      if L.blendIf.this == [0, 0, 255, 255]: L.blendIf.this = [0, 0, 0, 0]
      if L.blendIf.under == [0, 0, 255, 255]: L.blendIf.under = [0, 0, 0, 0]
    L.maskDensity = lj{"maskDensity"}.getInt(100)
    L.maskFeather = max(0.0, lj{"maskFeather"}.getFloat(0))
    for m in BlendMode:
      if $m == lj{"mode"}.getStr: L.mode = m
    L.gray = lj{"gray"}.getBool
    if lj.hasKey("adjust"):
      L.adjust.kind = lj["adjust"]{"kind"}.getStr
      for v in lj["adjust"]{"args"}.getElems: L.adjust.args.add v.getFloat
      L.adjust.data = lj["adjust"]{"data"}.getStr
      L.gray = true
    if lj.hasKey("text"):
      L.text = textFrom(lj["text"])
      if L.text.spans.len == 0: L.text = TextData()
    if lj.hasKey("shape"): L.shape = shapeFrom(lj["shape"])
    L.clipped = lj{"clipped"}.getBool
    if lj.hasKey("style"): L.fx = layerFxFrom(lj["style"])
    L.fill = lj{"fill"}.getInt(100)
    L.uid = lj{"uid"}.getInt(0)
    L.flowFrom = lj{"flowFrom"}.getInt(0)
    nextLayerUid = max(nextLayerUid, L.uid)
    if lj.hasKey("smart"):
      let sj = lj["smart"]
      let sf = sj{"file"}.getStr
      if files.hasKey(sf):
        let sb = decodePng(readEntry(path, files[sf]))
        if sb != nil and sb.w > 0 and sb.w == sj{"width"}.getInt and sb.h == sj{"height"}.getInt:
          var q: Quad
          let qa = sj{"quad"}.getElems
          if qa.len == 4:
            for k in 0 .. 3:
              q[k] = (qa[k]{0}.getFloat, qa[k]{1}.getFloat)
            var s2 = SmartData(src: sb.px, w: sb.w, h: sb.h, quad: q, name: sj{"name"}.getStr)
            for fj in sj{"filters"}.getElems:
              var f = SmartFilter(name: fj{"name"}.getStr, text: fj{"text"}.getStr,
                                  opacity: clamp(fj{"opacity"}.getInt(100), 0, 100), off: fj{"off"}.getBool)
              for v in fj{"args"}.getElems: f.args.add v.getFloat
              for m in BlendMode:
                if $m == fj{"mode"}.getStr: f.mode = m
              s2.filters.add f
            for c in sj{"warp"}.getElems:
              if s2.warp.len < 16: s2.warp.add (c{0}.getFloat, c{1}.getFloat)
            if s2.warp.len != 16: s2.warp = @[]
            let df = sj{"document"}.getStr
            if df.len > 0 and files.hasKey(df): s2.file = readEntry(path, files[df])
            L.smart = s2
    let mb = pic(lj{"mask"}.getStr)
    if mb != nil:
      L.mask = Layer(name: "Layer Mask", opacity: 100, visible: true, gray: true, px: mb.px)
      for p in L.mask.px.mitems: p = grayPx(rOf(p))
      L.maskOff = lj{"maskOff"}.getBool
    result.layers.add L
  if result.layers.len == 0: result.layers.add result.newLayer("Layer 1")
  for i in 1 ..< result.layers.len: result.layers[i].background = false
  result.fixDepths()
  for cj in j{"channels"}.getElems:
    let b = pic(cj{"file"}.getStr)
    if b == nil: continue
    var m = newSeq[uint8](w * h)
    for i, p in b.px: m[i] = uint8(rOf(p))
    result.alphas.add AlphaChannel(name: cj{"name"}.getStr, m: m)
  let s = pic("selection.png")
  if s != nil:
    result.sel = newSeq[uint8](w * h)
    for i, p in s.px: result.sel[i] = uint8(rOf(p))
  for pj in j{"paths"}.getElems: result.paths.add pathFrom(pj)
  if files.hasKey("profile.icc"): result.icc = readEntry(path, files["profile.icc"])
  for m in ColorMode:
    if $m == j{"mode"}.getStr: result.mode = m
  for c in j{"palette"}.getElems: result.palette.add uint32(c.getInt) or 0xFF000000'u32
  for ij in j{"duotone"}.getElems:
    if result.duotone.len < 4:
      result.duotone.add DuotoneInk(name: ij{"name"}.getStr("Ink"),
                                    color: uint32(ij{"color"}.getInt) or 0xFF000000'u32,
                                    gamma: clamp(ij{"gamma"}.getFloat(1), 0.05, 20.0))
  if result.mode == cmDuotone and result.duotone.len == 0: result.mode = cmGray
  if result.mode == cmMultichannel:
    for m in ColorMode:
      if $m == j{"spotBase"}.getStr: result.spotBase = m
    for sj in j{"spots"}.getElems:
      if result.spots.len < 4:
        result.spots.add SpotChannel(name: sj{"name"}.getStr("Ink"), ch: clamp(sj{"channel"}.getInt, 0, 3))
    if result.spots.len == 0 or result.spotBase notin {cmRGB, cmCMYK, cmGray}: result.mode = cmRGB
  result.cur = clamp(j{"current"}.getInt(0), 0, result.layers.high)
  for cj in j{"comps"}.getElems: result.comps.add compFrom(cj)
  for fj in j{"frames"}.getElems:
    var f = AnimFrame(delay: fj{"delay"}.getInt(100))
    for lj in fj{"layers"}.getElems:
      let e = lj.getElems
      if e.len >= 3:
        f.layers.add FrameLayer(uid: e[0].getInt, visible: e[1].getBool, opacity: e[2].getInt(100),
                                dx: (if e.len > 3: e[3].getInt else: 0), dy: (if e.len > 4: e[4].getInt else: 0))
    result.frames.add f
  result.frameCur = clamp(j{"frameCur"}.getInt(0), 0, max(0, result.frames.high))
  result.animLoop = j{"animLoop"}.getInt(0)
  for sj in j{"charStyles"}.getElems:
    result.charStyles.add TextStyleDef(name: sj{"name"}.getStr, char: charStyleFrom(sj{"char"}),
                                       para: paraFrom(sj{"para"}))
  for sj in j{"paraStyles"}.getElems:
    result.paraStyles.add TextStyleDef(name: sj{"name"}.getStr, char: charStyleFrom(sj{"char"}),
                                       para: paraFrom(sj{"para"}))
  let inf = j{"info"}
  result.info = ImageInfo(caption: inf{"caption"}.getStr, author: inf{"author"}.getStr,
                         title: inf{"title"}.getStr, keywords: inf{"keywords"}.getStr,
                         copyright: inf{"copyright"}.getStr, url: inf{"url"}.getStr)
  result.path = path
  result.format = "rpd"
  let bits = j{"bits"}.getInt(8)
  if bits in [16, 32]: result.depth = bits
  result.exposure = j{"exposure"}.getFloat(0)
  result.viewGamma = j{"viewGamma"}.getFloat(1)
  for L in result.layers:
    if L.hdr.len == w * h * 4: L.hdrVer = L.ver      # (the light read is what it shows)
  result.markAll()
  result.modified = false

proc openImage*(path: string): Doc =
  ## Opens a picture (PNG, JPEG, BMP, GIF: its first frame) or a ".rpd"
  ## document. Raises `IOError` when it cannot be read.
  let ext = path.splitFile.ext.toLowerAscii
  if ext in [".rpd", ".rp3"]: return loadRpd(path)    # (.rp3: its old name)
  let b = loadPicture(path, 30000, 30000)
  if b == nil or b.w <= 0: raise newException(IOError, "cannot read " & path.extractFilename)
  result = fromBitmap(b, path.splitFile.name, take = true)
  result.path = path
  result.format = ext.strip(chars = {'.'})
  result.modified = false

proc saveFlat*(d: Doc; path: string; format: string; quality = 85) =
  ## Saves the image with its layers mixed: "png", "jpg" (`quality`
  ## 1..100), "bmp".
  case format
  of "png":
    writeFile(path, encodePng(d.toBitmap()))
  of "jpg", "jpeg":
    let b = d.toBitmap(0xFFFFFFFF'u32)
    writeFile(path, encodeJpeg(b, quality))
  of "bmp":
    writeFile(path, encodeBmp(d.flattened(), d.w, d.h))
  else:
    d.saveRpd(path)

proc sizeText*(bytes: int): string =
  ## "900K", "1.2M".
  if bytes < 1024 * 1024: $(max(1, bytes div 1024)) & "K"
  else: formatFloat(bytes / (1024 * 1024), ffDecimal, 1) & "M"

proc docSizes*(d: Doc): tuple[flat, layered: int] =
  ## What the image takes flattened and with its layers (the "Doc:" sizes).
  let one = d.w * d.h * (if d.mode in {cmGray, cmBitmap, cmDuotone, cmIndexed}: 1 elif d.mode == cmCMYK: 4 else: 3)
  var n = 0
  for L in d.layers:
    if not L.group: inc n
  (one, if n <= 1: one else: one + (n - 1) * d.w * d.h * 4)

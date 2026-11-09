## The files of `retroui/photo` documents: any picture opened (PNG, JPEG, BMP,
## GIF, TIFF, TGA, Photoshop .psd and .psb with their layers, Retro Photo
## .rpd) and saved or exported with options (JPEG quality, PNG compression,
## PNG-8 and GIF with a palette, TIFF compression, TGA, Photoshop, scaled).
##
## Photoshop layers come in with their masks, blend modes, opacity and fill,
## visibility (a hidden group hides its layers), clipping (made part of the
## layer), adjustment layers (Levels, Hue/Saturation, Color Balance,
## Brightness/Contrast, Exposure, Vibrance, Selective Color, Channel Mixer,
## Black & White, Photo Filter, Invert, Threshold, Posterize), fill layers
## (solid colors, gradients), layer effects (shadows, glows, bevel,
## satin, overlays, stroke), type layers (their text still to edit) and
## Smart Objects (the files embedded for them). Saved as Photoshop: the
## same back -- type layers as Photoshop's (EngineData), Smart Objects as
## placed layers, styles as pixels. A TIFF can keep the layers too
## (`ExportOptions.tiffLayers`, Photoshop's tag 37724) and opens with them.
##
## .. code-block:: nim
##   let d = openPicture("poster.psd")
##   d.exportPicture("poster.jpg", ExportOptions(format: efJpeg, quality: 90, scale: 0.5))

import std/[os, strutils, math, tables, algorithm, unicode, json]
import gfx, imaging, jpeg, imageformats, psd, photo, parallel, photoshapes, mediagif, iccprofile, rawphoto,
       photoimport, pdfview, photohdr, textengine, ttf, exr, gifanim, photoanim, webp, rawformats, systemimage, jxl, svgimport,
       bigpicture
export bigpicture.readScaled, bigpicture.readRegion, bigpicture.BigProgress, bigpicture.BigPictureError
export pdfview.pdfPreview, pdfview.pdfPage, pdfview.addPdfPreviews

type
  ExportFormat* = enum
    ## The kinds of file a document is saved or exported as (`formatExts`:
    ## their file name endings; the strings: their names in a menu).
    efJpeg = "JPEG", efPng = "PNG-24", efPng8 = "PNG-8", efGif = "GIF", efTiff = "TIFF", efBmp = "BMP",
    efTga = "TGA", efPsd = "PSD", efRpd = "Retro Photo", efHdr = "Radiance HDR", efPfm = "PFM",
    efExr = "OpenEXR", efWebp = "WebP", efJxl = "JPEG XL", efAvif = "AVIF", efHeic = "HEIC"

  ExportOptions* = object
    ## How a document is saved or exported (`defaultExport` gives a format's
    ## usual ones); each option says which formats read it.
    format*: ExportFormat       ## the kind of file
    quality*: int               ## JPEG: 1..100 (0: 85)
    chroma420*: bool            ## JPEG: the colors at half size (smaller)
    pngLevel*: int              ## PNG: 1 quick .. 9 smallest (0: by the size)
    colors*: int                ## PNG-8, GIF: 2..256 (0: 256)
    dither*: bool               ## PNG-8, GIF
    transparency*: bool         ## keep what is transparent (PNG, GIF, TIFF, TGA)
    matte*: uint32              ## under what is transparent, when it is not kept (0: white)
    tiff*: TiffCompression      ## TIFF: how it is compressed
    tgaRle*: bool               ## TGA: run-length coded
    scale*: float               ## 0 or 1: as it is
    resample*: Resample         ## how it is scaled
    embedProfile*: bool         ## the color profile in the file (JPEG, PNG, TIFF): the document's, or sRGB
    bmpBits*: int               ## BMP: 24 (0) or 32 (with its transparency)
    webpLossless*: bool         ## WebP: every pixel kept (else `quality`)
    jxlEffort*: int             ## JPEG XL: 1 quick .. 9 smallest (0: 3)
    jxlLossy*: bool             ## JPEG XL: smaller, at `quality` (cjxl's -q: 90 looks the same),
                                ## else every pixel kept
    tiffLayers*: bool           ## TIFF: its layers kept as Photoshop keeps them (tag 37724; opened
                                ## again with them), beside the merged picture; not when scaled

const formatExts*: array[ExportFormat, string] = [".jpg", ".png", ".png", ".gif", ".tif", ".bmp", ".tga", ".psd",
                                                  ".rpd", ".hdr", ".pfm", ".exr", ".webp", ".jxl", ".avif",
                                                  ".heic"]
  ## The file name ending of each format.

proc defaultExport*(f: ExportFormat): ExportOptions =
  ## The options a format starts with.
  ExportOptions(format: f, quality: 85, colors: 256, dither: true, transparency: true, tiff: tcLzw,
                tgaRle: true, scale: 1, resample: rsBicubic, embedProfile: true)

proc formatOf*(path: string): ExportFormat =
  ## The format a file's name says (PNG when it says none we know).
  case path.splitFile.ext.toLowerAscii
  of ".jpg", ".jpeg", ".jpe", ".jfif": efJpeg
  of ".gif": efGif
  of ".tif", ".tiff": efTiff
  of ".bmp", ".dib": efBmp
  of ".tga", ".icb", ".vda", ".vst": efTga
  of ".psd", ".psb": efPsd
  of ".rpd", ".rp3": efRpd    # (.rp3: its old name)
  of ".hdr", ".rgbe": efHdr
  of ".pfm": efPfm
  of ".exr": efExr
  of ".webp": efWebp
  of ".jxl": efJxl
  of ".avif": efAvif
  of ".heic", ".heif": efHeic
  else: efPng

var openAnimations* = true
  ## An animated GIF, WebP or JPEG XL opens as its frames (a layer and an
  ## animation frame each, `photoanim`); false: its first picture only, as
  ## an app without a timeline wants it.

const openableExts* = [".rpd", ".rp3", ".psd", ".psb", ".png", ".jpg", ".jpeg", ".jpe", ".bmp", ".gif", ".tif", ".tiff",
                       ".tga", ".hdr", ".pfm", ".exr", ".webp", ".dng", ".nef", ".nrw", ".arw", ".srf",
                       ".sr2", ".cr2", ".cr3", ".orf", ".rw2", ".pef", ".raf", ".heic", ".heif", ".hif", ".avif",
                       ".jxl", ".svg"]
  ## The files `openPicture` reads (by their name's ending, lower case).
const rawExts* = [".dng", ".nef", ".nrw", ".arw", ".srf", ".sr2", ".cr2", ".cr3", ".orf", ".rw2", ".pef", ".raf"]
  ## Camera raw files (`readRaw`).

# ---- Photoshop's blend modes ----------------------------------------------------------------------------

const blendKeys: array[BlendMode, string] = [
  "norm", "diss", "norm", "norm", "mul ", "scrn", "over", "sLit", "hLit", "dark", "lite", "diff", "hue ", "sat ",
  "colr", "lum ", "idiv", "lbrn", "dkCl", "div ", "lddg", "lgCl", "vLit", "lLit", "pLit", "hMix", "smud", "fsub",
  "fdiv"]

proc blendOfKey*(k: string): BlendMode =
  ## A Photoshop layer blend mode key ("mul ") as a blend mode.
  for m in BlendMode:
    if blendKeys[m] == k and m notin {bmBehind, bmClear}: return m
  bmNormal

proc keyOfBlend*(m: BlendMode): string = blendKeys[m]
  ## A blend mode's Photoshop key ("mul ").

proc blendOfEnum(e: string): BlendMode =
  ## The blend mode of an effect ("Mltp").
  case e
  of "Dslv": bmDissolve
  of "Mltp": bmMultiply
  of "Scrn": bmScreen
  of "Ovrl": bmOverlay
  of "SftL": bmSoftLight
  of "HrdL": bmHardLight
  of "Drkn": bmDarken
  of "Lghn": bmLighten
  of "Dfrn": bmDifference
  of "H   ": bmHue
  of "Strt": bmSaturation
  of "Clr ": bmColor
  of "Lmns": bmLuminosity
  of "CBrn": bmColorBurn
  of "CDdg": bmColorDodge
  of "linearBurn": bmLinearBurn
  of "linearDodge": bmLinearDodge
  of "vividLight": bmVividLight
  of "linearLight": bmLinearLight
  of "pinLight": bmPinLight
  of "hardMix": bmHardMix
  of "Xclu": bmExclusion
  of "blendSubtraction": bmSubtract
  of "blendDivide": bmDivide
  of "darkerColor": bmDarkerColor
  of "lighterColor": bmLighterColor
  else: bmNormal

# ---- reading the binary settings of adjustment layers -------------------------------------------------

type Bytes2 = object
  s: string
  pos: int

proc u16(b: var Bytes2): int =
  if b.pos + 2 > b.s.len: return 0
  result = (ord(b.s[b.pos]) shl 8) or ord(b.s[b.pos + 1])
  b.pos += 2

proc i16(b: var Bytes2): int =
  let v = b.u16
  if v >= 0x8000: v - 0x10000 else: v

proc u8(b: var Bytes2): int =
  if b.pos >= b.s.len: return 0
  result = ord(b.s[b.pos])
  inc b.pos

proc f32(b: var Bytes2): float =
  let hi = uint32(b.u16)
  let lo = uint32(b.u16)
  float(cast[float32]((hi shl 16) or lo))

proc adjustmentOf(L: PsdLayer; gray = false): Adjustment =
  ## A Photoshop adjustment layer as one of ours (kind "" when it has no
  ## equal).
  var b = Bytes2(s: L.adjustData)
  case L.adjustment
  of "nvrt": Adjustment(kind: "Invert")
  of "thrs": Adjustment(kind: "Threshold", args: @[float(b.u16)])
  of "post": Adjustment(kind: "Posterize", args: @[float(max(2, b.u16))])
  of "brit":
    let br = b.i16
    let ct = b.i16
    Adjustment(kind: "Brightness/Contrast", args: @[float(clamp(br, -100, 100)), float(clamp(ct, -100, 100))])
  of "levl":
    discard b.u16
    var args: seq[float]
    for c in 0 .. 3:
      let inLo = b.u16
      let inHi = b.u16
      let outLo = b.u16
      let outHi = b.u16
      let gamma = b.u16
      args.add [float(clamp(inLo, 0, 253)), float(clamp(inHi, 2, 255)), clamp(gamma / 100, 0.1, 9.99),
                float(clamp(outLo, 0, 255)), float(clamp(outHi, 0, 255))]
    if gray and args[5 .. 9] != @[0.0, 255.0, 1.0, 0.0, 255.0]:
      # (one channel: the gray's levels are the only ones)
      args[0 .. 4] = args[5 .. 9]
      for c in 1 .. 3: args[c * 5 .. c * 5 + 4] = @[0.0, 255.0, 1.0, 0.0, 255.0]
    Adjustment(kind: "Levels", args: args)
  of "hue2", "hue ":
    discard b.u16
    let colorize = b.u8
    discard b.u8
    let ch = b.i16
    let cs = b.i16
    let cl = b.i16
    if colorize != 0:
      Adjustment(kind: "Hue/Saturation", args: @[1.0, float((ch + 360) mod 360), float(cs), float(cl)])
    else:
      var args = @[0.0, float(b.i16), float(b.i16), float(b.i16)]
      var lims: seq[float]
      for r in 0 .. 5:
        for _ in 0 .. 3: lims.add float(b.i16)        # (the range's limits)
        args.add [float(b.i16), float(b.i16), float(b.i16)]
      Adjustment(kind: "Hue/Saturation", args: args & lims)
  of "curv":
    # (version 1: the channels a bit each, their points; then "Crv " with
    # all of them again, version 4)
    var curves: array[4, seq[(int, int)]]
    try:
      discard b.u8
      let version = b.u16
      let bits = b.u16 * 65536 + b.u16
      var chans: seq[int]
      if version == 1:
        for k in 0 .. 31:
          if (bits and (1 shl k)) != 0: chans.add k
      else:
        for k in 0 ..< bits: chans.add k
      for ch in chans:
        let n = b.u16
        if n < 2 or n > 19: break
        var pts: seq[(int, int)]
        for _ in 0 ..< n:
          let o = b.u16
          let i = b.u16
          pts.add (i, o)
        if ch <= 3: curves[ch] = pts
      if b.pos + 10 <= b.s.len and b.s[b.pos ..< b.pos + 4] == "Crv ":
        b.pos += 4
        discard b.u16
        let count = b.u16 * 65536 + b.u16
        for _ in 0 ..< count:
          let ch = b.u16
          let n = b.u16
          if n < 2 or n > 19: break
          var pts: seq[(int, int)]
          for _ in 0 ..< n:
            let o = b.u16
            let i = b.u16
            pts.add (i, o)
          if ch <= 3: curves[ch] = pts
    except IndexDefect: discard
    if gray:
      # (one channel: the gray's curve is the only one)
      if curves[1].len >= 2 and curves[1] != @[(0, 0), (255, 255)]: curves[0] = curves[1]
      for ch in 1 .. 3: curves[ch] = @[]
    var args: seq[float]
    for ch in 0 .. 3:
      args.add float(curves[ch].len)
      for (i, o) in curves[ch]: args.add [float(i), float(o)]
    Adjustment(kind: "Curves", args: args)
  of "blnc":
    var args: seq[float]
    for _ in 0 .. 8: args.add float(b.i16)
    args.add float(b.u8)
    Adjustment(kind: "Color Balance", args: args)
  of "expA":
    discard b.u16
    let e = b.f32
    let o = b.f32
    let g = b.f32
    Adjustment(kind: "Exposure", args: @[e, o, (if g > 0: g else: 1.0)])
  of "selc":
    discard b.u16
    let absolute = b.u16 != 0
    for _ in 0 .. 3: discard b.i16                # (a record not used)
    var args = @[(if absolute: 0.0 else: 1.0)]
    for _ in 0 .. 8:
      for _ in 0 .. 3: args.add float(b.i16)
    Adjustment(kind: "Selective Color", args: args)
  of "mixr":
    discard b.u16
    let mono = b.u16
    var args: seq[float]
    for o in 0 .. 2:
      let r = b.i16
      let g = b.i16
      let bl = b.i16
      discard b.i16
      let k = b.i16
      args.add [float(r), float(g), float(bl), float(k)]
    args.add float(mono)
    Adjustment(kind: "Channel Mixer", args: args)
  of "vibA":
    let d = L.adjustDesc
    Adjustment(kind: "Vibrance", args: @[d["vibrance"].num, d["Strt"].num])
  of "blwh":
    let d = L.adjustDesc
    var args: seq[float]
    for k in ["Rd  ", "Yllw", "Grn ", "Cyn ", "Bl  ", "Mgnt"]: args.add d[k].num(50)
    args.add (if d["useTint"].flag: 1.0 else: 0.0)
    let tc = d["tintColor"].rgbOf
    let (h, s, _) = (block:
      let r = float((tc shr 16) and 255) / 255
      let g = float((tc shr 8) and 255) / 255
      let bl = float(tc and 255) / 255
      let mx = max(r, max(g, bl))
      let mn = min(r, min(g, bl))
      var hh = 0.0
      if mx > mn:
        if mx == r: hh = 60 * (((g - bl) / (mx - mn)) mod 6)
        elif mx == g: hh = 60 * ((bl - r) / (mx - mn) + 2)
        else: hh = 60 * ((r - g) / (mx - mn) + 4)
      ((hh + 360) mod 360, (if mx > 0: (mx - mn) / mx * 100 else: 0.0), mx))
    args.add [h, s]
    Adjustment(kind: "Black & White", args: args)
  else: Adjustment()

proc adjustmentData(a: Adjustment): tuple[key, data: string] =
  ## One of our adjustment layers as Photoshop's ("" when it has no equal).
  var o = ""
  proc w16(v: int) =
    let x = v and 0xFFFF
    o.add char((x shr 8) and 255)
    o.add char(x and 255)
  proc wf(v: float) =
    let bits = cast[uint32](float32(v))
    o.add char((bits shr 24) and 255); o.add char((bits shr 16) and 255)
    o.add char((bits shr 8) and 255); o.add char(bits and 255)
  let v = a.args
  template at(i: int; d = 0.0): float = (if i < v.len: v[i] else: d)
  template ai(i: int; d = 0): int = int(round(at(i, d.float)))
  case a.kind
  of "Invert": ("nvrt", "")
  of "Threshold":
    w16(ai(0, 128)); w16(0)
    ("thrs", o)
  of "Posterize":
    w16(ai(0, 4)); w16(0)
    ("post", o)
  of "Brightness/Contrast":
    w16(ai(0)); w16(ai(1)); w16(127); o.add '\0'; o.add '\0'
    ("brit", o)
  of "Levels":
    w16(2)
    for rec in 0 ..< 29:
      if rec < 4 and v.len >= 20:
        w16(ai(rec * 5)); w16(ai(rec * 5 + 1)); w16(ai(rec * 5 + 3)); w16(ai(rec * 5 + 4))
        w16(int(round(at(rec * 5 + 2, 1) * 100)))
      else:
        w16(0); w16(255); w16(0); w16(255); w16(100)
    ("levl", o)
  of "Hue/Saturation":
    w16(2)
    let colorize = ai(0) != 0
    o.add char(ord(colorize)); o.add '\0'
    if colorize:
      w16(ai(1)); w16(ai(2)); w16(ai(3))
      w16(0); w16(0); w16(0)
      for r in 0 .. 5:
        for k in [315, 345, 15, 45]: w16((k + r * 60) mod 360)
        w16(0); w16(0); w16(0)
    else:
      w16(0); w16(25); w16(0)
      w16(ai(1)); w16(ai(2)); w16(ai(3))
      for r in 0 .. 5:
        if v.len >= 46:
          for k in 0 .. 3: w16(ai(22 + r * 4 + k))
        else:
          for k in [315, 345, 15, 45]: w16((k + r * 60) mod 360)
        w16(ai(4 + r * 3)); w16(ai(5 + r * 3)); w16(ai(6 + r * 3))
    ("hue2", o)
  of "Curves":
    var curves: array[4, seq[(int, int)]]
    var i = 0
    for ch in 0 .. 3:
      let n = ai(i)
      inc i
      for _ in 0 ..< n:
        curves[ch].add (clamp(ai(i), 0, 255), clamp(ai(i + 1), 0, 255))
        i += 2
      if curves[ch].len < 2: curves[ch] = @[(0, 0), (255, 255)]
    o.add '\0'
    w16(1)
    w16(0); w16(15)                                # (all four channels)
    for ch in 0 .. 3:
      w16(curves[ch].len)
      for (inp, outp) in curves[ch]:
        w16(outp); w16(inp)
    o.add "Crv "
    w16(4)
    w16(0); w16(4)
    for ch in 0 .. 3:
      w16(ch)
      w16(curves[ch].len)
      for (inp, outp) in curves[ch]:
        w16(outp); w16(inp)
    ("curv", o)
  of "Color Balance":
    for k in 0 .. 8: w16(ai(k))
    o.add char(if v.len > 9: ai(9) else: 1)
    o.add '\0'
    ("blnc", o)
  of "Exposure":
    w16(1); wf(at(0)); wf(at(1)); wf(at(2, 1))
    ("expA", o)
  of "Selective Color":
    w16(1); w16(if ai(0) != 0: 0 else: 1)
    for _ in 0 .. 3: w16(0)
    for k in 0 ..< 36: w16(ai(1 + k))
    ("selc", o)
  of "Channel Mixer":
    w16(1); w16(ai(12))
    for oc in 0 .. 2:
      w16(ai(oc * 4)); w16(ai(oc * 4 + 1)); w16(ai(oc * 4 + 2)); w16(0); w16(ai(oc * 4 + 3))
    for _ in 0 .. 4: w16(0)
    ("mixr", o)
  else: ("", "")

# ---- layer effects ----------------------------------------------------------------------------------

proc fxOf(e: PsdValue; globalAngle, globalAltitude: int): LayerFx =
  ## Photoshop's layer effects (lfx2) as a layer style.
  if e == nil or e.kind != pkObject: return
  if e["masterFXSwitch"] != nil and not e["masterFXSwitch"].flag(true): result.hidden = true
  let scale = e["Scl "].num(100) / 100
  template px(v: PsdValue; d = 0.0): int = int(round(v.num(d) * scale))
  template angle(x: PsdValue): int =
    (if x["uglg"].flag: globalAngle else: int(round(x["lagl"].num(globalAngle.float))))
  proc common(x: PsdValue; k: FxKind): Effect =
    result = Effect(on: x["enab"].flag(true), mode: blendOfEnum(x["Md  "].enumValue),
                    opacity: int(round(x["Opct"].num(75))), color: x["Clr "].rgbOf)
    if x["Md  "] == nil: result.mode = if k in {fxOuterGlow, fxInnerGlow}: bmScreen
                                       elif k in {fxColorOverlay, fxGradientOverlay, fxStroke}: bmNormal
                                       else: bmMultiply
  for (key, k) in [("DrSh", fxDropShadow), ("IrSh", fxInnerShadow), ("OrGl", fxOuterGlow), ("IrGl", fxInnerGlow),
                   ("ChFX", fxSatin), ("SoFi", fxColorOverlay), ("GrFl", fxGradientOverlay), ("FrFX", fxStroke),
                   ("ebbl", fxBevel)]:
    let x = e[key]
    if x == nil or x.kind != pkObject: continue
    var f = common(x, k)
    case k
    of fxDropShadow, fxInnerShadow, fxSatin:
      f.angle = angle(x)
      f.distance = px(x["Dstn"], 5)
      f.spread = int(round(x["Ckmt"].num(0)))
      f.size = px(x["blur"], 5)
      if k == fxSatin: f.down = x["Invr"].flag(true)
    of fxOuterGlow, fxInnerGlow:
      f.spread = int(round(x["Ckmt"].num(0)))
      f.size = px(x["blur"], 5)
      if k == fxInnerGlow: f.style = if x["glwS"].enumValue == "SrcC": 1 else: 0
    of fxStroke:
      f.size = max(1, px(x["Sz  "], 3))
      f.style = case x["Styl"].enumValue
                of "InsF": 1
                of "CtrF": 2
                else: 0
    of fxBevel:
      f.style = case x["bvlS"].enumValue
                of "OtrB": 1
                of "Embs": 2
                of "PlEb": 3
                else: 0
      f.mode = blendOfEnum(x["hglM"].enumValue)
      if x["hglM"] == nil: f.mode = bmScreen
      f.color = if x["hglC"] != nil: x["hglC"].rgbOf else: 0xFFFFFFFF'u32
      f.opacity = int(round(x["hglO"].num(75)))
      f.mode2 = blendOfEnum(x["sdwM"].enumValue)
      if x["sdwM"] == nil: f.mode2 = bmMultiply
      f.color2 = x["sdwC"].rgbOf
      f.opacity2 = int(round(x["sdwO"].num(75)))
      f.angle = angle(x)
      f.altitude = if x["uglg"].flag: globalAltitude else: int(round(x["Lald"].num(30)))
      f.depth = int(round(x["srgR"].num(100)))
      f.size = px(x["blur"], 5)
      f.soften = px(x["Sftn"], 0)
      f.down = x["bvlD"].enumValue == "Out "
    of fxGradientOverlay:
      let g = x["Grad"]
      if g != nil and g["Clrs"] != nil and g["Clrs"].kind == pkList and g["Clrs"].list.len >= 1:
        let l = g["Clrs"].list
        f.color = l[0]["Clr "].rgbOf
        f.color2 = l[^1]["Clr "].rgbOf
      else:
        f.color = 0xFF000000'u32
        f.color2 = 0xFFFFFFFF'u32
      f.angle = int(round(x["Angl"].num(90)))
      f.style = case x["Type"].enumValue
                of "Rdl ": 1
                of "Angl": 2
                of "Rflc": 3
                of "Dmnd": 4
                else: 0
      f.down = x["Rvrs"].flag
      f.scale = int(round(x["Scl "].num(100)))
    else: discard
    result.fx[k] = f

# ---- Photoshop documents in --------------------------------------------------------------------------

proc stopsOf(d: PsdValue): seq[GradientStop] =
  ## A gradient's colors and opacities as stops (Photoshop keeps them
  ## apart), the midpoints between them kept.
  let g = d["Grad"]
  if g == nil: return
  var cs: seq[(float, uint32, float)]
  var ts: seq[(float, float, float)]
  let clrs = g["Clrs"]
  if clrs != nil and clrs.kind == pkList:
    for st in clrs.list: cs.add (st["Lctn"].num / 4096, st["Clr "].rgbOf, st["Mdpn"].num(50) / 100)
  let trns = g["Trns"]
  if trns != nil and trns.kind == pkList:
    for st in trns.list: ts.add (st["Lctn"].num / 4096, st["Opct"].num(100) / 100, st["Mdpn"].num(50) / 100)
  if cs.len == 0: cs = @[(0.0, 0xFF000000'u32, 0.5), (1.0, 0xFFFFFFFF'u32, 0.5)]
  if ts.len == 0: ts = @[(0.0, 1.0, 0.5)]
  proc warp(u, m: float): float =
    if abs(m - 0.5) < 1e-6 or u <= 0: u else: pow(u, ln(0.5) / ln(clamp(m, 0.01, 0.99)))
  proc colorAt(t: float): uint32 =
    if t <= cs[0][0]: return cs[0][1]
    for k in 1 .. cs.high:
      if t <= cs[k][0]:
        let span = cs[k][0] - cs[k - 1][0]
        return if span <= 1e-9: cs[k][1] else: mix(cs[k - 1][1], cs[k][1], warp((t - cs[k - 1][0]) / span, cs[k - 1][2]))
    cs[^1][1]
  proc alphaAt(t: float): float =
    if t <= ts[0][0]: return ts[0][1]
    for k in 1 .. ts.high:
      if t <= ts[k][0]:
        let span = ts[k][0] - ts[k - 1][0]
        return if span <= 1e-9: ts[k][1]
               else: ts[k - 1][1] + (ts[k][1] - ts[k - 1][1]) * warp((t - ts[k - 1][0]) / span, ts[k - 1][2])
    ts[^1][1]
  # (every place a color or an opacity changes -- and, where a midpoint is
  # not half way, its place too)
  var at: seq[float]
  for (t, _, _) in cs: at.add clamp(t, 0.0, 1.0)
  for (t, _, _) in ts: at.add clamp(t, 0.0, 1.0)
  for k in 0 ..< cs.high:
    if abs(cs[k][2] - 0.5) > 0.01 and ts.len > 1: at.add cs[k][0] + (cs[k + 1][0] - cs[k][0]) * cs[k][2]
  for k in 0 ..< ts.high:
    if abs(ts[k][2] - 0.5) > 0.01: at.add ts[k][0] + (ts[k + 1][0] - ts[k][0]) * ts[k][2]
  at.sort()
  var last = -1.0
  for t in at:
    if t - last < 1e-6 and result.len > 0: continue
    last = t
    let c = colorAt(t)
    result.add GradientStop(at: t, color: (c and 0xFFFFFF'u32) or (uint32(clamp(int(round(alphaAt(t) * 255)), 0, 255)) shl 24))
  # (a pair that is one of Photoshop's: its midpoint as it is)
  for k in 0 ..< result.high:
    for j in 0 ..< cs.high:
      if abs(result[k].at - cs[j][0]) < 1e-6 and abs(result[k + 1].at - cs[j + 1][0]) < 1e-6 and
         ts.len == 1:
        result[k].mid = cs[j][2]

proc gradientPaintOf(d: PsdValue): ShapePaint =
  ## A gradient fill (or a stroke's) as ours.
  result = ShapePaint(kind: spGradient, opacity: 100, stops: stopsOf(d))
  if result.stops.len > 0:
    result.color = result.stops[0].color
    result.color2 = result.stops[^1].color
  result.reverse = d["Rvrs"].flag
  result.angle = int(round(d["Angl"].num(90)))
  result.scale = int(round(d["Scl "].num(100)))
  const types = ["Lnr ", "Rdl ", "Angl", "Rflc", "Dmnd"]
  result.style = max(0, types.find(d["Type"].enumValue))

proc gradientFill(d: PsdValue; w, h: int): seq[uint32] =
  ## A gradient fill layer's pixels (over the canvas).
  result = newSeq[uint32](w * h)
  let p = gradientPaintOf(d)
  let rp = cast[ptr UncheckedArray[uint32]](addr result[0])
  let pp = unsafeAddr p
  let box = (0.0, 0.0, w.float, h.float)
  parallelRows(h, y):
    for x in 0 ..< w:
      var t = gradientT(pp.style, pp.angle.float, pp.scale / 100, x.float, y.float, box)
      if pp.reverse: t = 1 - t
      rp[y * w + x] = if pp.stops.len > 0: stopsColor(pp.stops, t) else: mix(pp.color, pp.color2, t)

proc pathOfVector(subs: seq[PsdSubpath]): Path =
  ## A vector mask's outline as a path.
  for sp in subs:
    if sp.knots.len == 0: continue
    var s = SubPath(closed: sp.closed)
    case sp.operation
    of 0: s.op = poExclude
    of 2: s.op = poSubtract
    of 3: s.op = poIntersect
    of -1: s.joined = result.subs.len > 0
    else: s.op = poAdd
    if s.joined: s.op = result.subs[^1].op
    for k in sp.knots: s.pts.add PathPoint(p: k.anchor, inH: k.pre, outH: k.post)
    result.subs.add s

proc subpathsOf(p: Path): seq[PsdSubpath] =
  for k, s in p.subs:
    var o = PsdSubpath(closed: s.closed,
                       operation: (if s.joined and k > 0: -1
                                   else:
                                     case s.op
                                     of poAdd: 1
                                     of poSubtract: 2
                                     of poIntersect: 3
                                     of poExclude: 0))
    for q in s.pts: o.knots.add PsdKnot(pre: q.inH, anchor: q.p, post: q.outH)
    result.add o

const gradTypes = ["Lnr ", "Rdl ", "Angl", "Rflc", "Dmnd"]

proc paintOf(v: PsdValue; key: string): ShapePaint =
  ## A fill layer's (or a stroke's content's) color or gradient.
  if v == nil: return
  if key == "GdFl" or v["Grad"] != nil:
    result = gradientPaintOf(v)
  else:
    result = solidPaint(v["Clr "].rgbOf)

proc shapeOfPsd(P: PsdLayer): ShapeData =
  ## A Photoshop shape layer (a fill layer with a vector mask) as ours.
  result.path = pathOfVector(P.vectorMask)
  result.fill = paintOf(P.adjustDesc, P.adjustment)
  result.strokeWidth = 3
  let st = P.strokeDesc
  if st != nil:
    if not st["fillEnabled"].flag(true): result.fill.kind = spNone
    if st["strokeEnabled"].flag(false):
      result.stroke = paintOf(st["strokeStyleContent"], "")
      result.stroke.opacity = clamp(int(round(st["strokeStyleOpacity"].num(100))), 0, 100)
      result.strokeWidth = max(0.0, st["strokeStyleLineWidth"].num(1))
      result.align = case st["strokeStyleLineAlignment"].enumValue
                     of "strokeStyleAlignCenter": saCenter
                     of "strokeStyleAlignOutside": saOutside
                     else: saInside
      result.cap = case st["strokeStyleLineCapType"].enumValue
                   of "strokeStyleRoundCap": lcRound
                   of "strokeStyleSquareCap": lcSquare
                   else: lcButt
      result.join = case st["strokeStyleLineJoinType"].enumValue
                    of "strokeStyleRoundJoin": ljRound
                    of "strokeStyleBevelJoin": ljBevel
                    else: ljMiter
      let ds = st["strokeStyleLineDashSet"]
      if ds != nil and ds.kind == pkList:
        for v in ds.list: result.dashes.add v.num
  result.kind = "Path"

# ---- color profiles ---------------------------------------------------------------------------------

type ProfilePolicy* = enum
  ## What is done with the color profile of a picture opened.
  ppConvert = "Convert to sRGB"   ## its colors made sRGB's (they look the same)
  ppKeep = "Keep It"              ## its pixels kept, the profile with them (shown converted)
  ppIgnore = "Ignore It"          ## taken as sRGB

var profilePolicy* = ppConvert
  ## (Preferences)

proc profileName*(d: Doc): string =
  ## The name of the document's color profile.
  if d.icc.len == 0: "sRGB IEC61966-2.1" else: parseIcc(d.icc).name

proc convertProfile*(d: Doc; to: IccProfile) =
  ## Edit > Convert to Profile: the pixels of every layer made into `to`'s
  ## colors (they look the same); `to` becomes its profile. (Undoable:
  ## `snapStep` first.)
  let src = if d.icc.len > 0: parseIcc(d.icc) else: srgbProfile()
  if not src.usable or not to.usable: return
  for L in d.layers:
    if L.group or L.gray or L.px.len != d.w * d.h: continue
    convertPixels(L.px, src, to)
    inc L.ver
  d.icc = if to.isSrgbLike: "" else: to.data
  d.markAll()

proc useProfile*(d: Doc; icc: string) =
  ## A picture just opened, with the profile it carries: as the policy
  ## says.
  if icc.len == 0 or profilePolicy == ppIgnore: return
  let p = parseIcc(icc)
  if p.usable and p.isSrgbLike: return
  if profilePolicy == ppConvert and p.usable and p.colorSpace == "RGB " and d.mode in {cmRGB, cmIndexed}:
    for L in d.layers:
      if L.group or L.gray or L.px.len != d.w * d.h: continue
      convertPixels(L.px, p, srgbProfile())
      inc L.ver
    d.markAll()
    return
  if p.colorSpace == "RGB " or p.colorSpace == "GRAY": d.icc = icc

# ---- Photoshop documents in -------------------------------------------------------------------------

# (type layers, Smart Objects and TIFF layers: at the end of the file)
proc textOfPsd*(P: PsdLayer; retro = true): tuple[ok: bool; text: TextData]
  ## A Photoshop type layer's text as ours (from its EngineData, transform,
  ## warp). Not `ok` when it has none, or it is turned or skewed. With
  ## `retro`, the text Retro Photo kept beside it, when Photoshop has not
  ## changed it since.
proc smartOfPsd*(P: PsdLayer; p: PsdDoc): SmartData
  ## A Photoshop placed layer as our Smart Object (nil when it is not one,
  ## or its file is linked from outside or not one we read).
proc typeLayerData*(t: TextData; drawn: Rect): string
  ## A type layer's 'TySh' for Photoshop (`drawn`: where its pixels are),
  ## with the text as ours kept beside it.
proc placedLayer*(s: SmartData; layerIndex: int; dpi: float): tuple[file: PsdLinkedFile; plLd, soLd: string]
  ## A Smart Object as Photoshop's placed layer: the file it shows, its
  ## 'PlLd' and 'SoLd'.
proc tiffLayersOf*(d: Doc): string
  ## The document's layers as a TIFF keeps them for Photoshop (tag 37724),
  ## at 8 bits.
proc docOfLayeredTiff*(data: string; name = "Untitled"): Doc
  ## A TIFF that keeps Photoshop's layers (tag 37724) as a document with
  ## them; nil when it keeps none. Raises `PsdError` when they are damaged.

proc docOfPsd*(p: PsdDoc; name = "Untitled"): Doc =
  ## A Photoshop document as ours: its layers (bottom first) or, with none,
  ## its merged picture.
  result = newDoc(p.w, p.h, 0, dpi = p.dpi, name = name)
  let d = result
  case p.mode
  of pmGray, pmDuotone, pmBitmap: d.mode = cmGray
  of pmCMYK: d.mode = cmCMYK
  of pmLab: d.mode = cmLab
  else: discard
  if p.depth == 16 and p.mode in {pmRGB, pmGray}: d.depth = 16
  let n = p.w * p.h
  d.layers.setLen(0)
  if p.layers.len == 0:
    var px = p.composite
    if px.len != n: px = newSeq[uint32](n)
    if d.depth == 16 and p.composite16.len == n * 4:
      let L = d.newLayer("Background")
      L.px = move(px)
      L.background = true
      d.setHi(L, p.composite16)
      d.layers.add L
      d.cur = 0
      d.markAll()
      d.modified = false
      return
    var opaque = true
    for v in px:
      if (v shr 24) != 255:
        opaque = false
        break
    let L = d.newLayer(if opaque: "Background" else: "Layer 0")
    L.px = move(px)
    L.background = opaque
    d.layers.add L
    d.cur = 0
    d.markAll()
    d.modified = false
    return
  # the groups: a tree (Photoshop lists a group's end, its layers, then the
  # group itself)
  type Node = ref object
    idx: int
    group: bool
    kids: seq[Node]
  var frames: seq[seq[Node]] = @[newSeq[Node]()]
  for i, P in p.layers:
    case P.section
    of psGroupEnd: frames.add newSeq[Node]()
    of psGroupOpen, psGroupClosed:
      if frames.len > 1:
        let kids = frames.pop()
        frames[^1].add Node(idx: i, group: true, kids: kids)
    of psLayer: frames[^1].add Node(idx: i)
  while frames.len > 1:
    let kids = frames.pop()
    frames[^1].add kids
  proc maskOf(P: PsdLayer): seq[uint32] =
    if not (P.hasMask and P.mask.px.len == P.mask.w * P.mask.h): return
    result = newSeq[uint32](n)
    let outside = grayPx(P.mask.outside)
    for v in result.mitems: v = outside
    for yy in 0 ..< P.mask.h:
      let y = P.mask.y + yy
      if y < 0 or y >= p.h: continue
      for xx in 0 ..< P.mask.w:
        let x = P.mask.x + xx
        if x >= 0 and x < p.w: result[y * p.w + x] = grayPx(int(P.mask.px[yy * P.mask.w + xx]))
  proc layerOf(P: PsdLayer): Layer =
    let L = d.newLayer(if P.name.len > 0: P.name else: "Layer " & $(d.layers.len + 1))
    L.opacity = clamp((P.opacity * 100 + 127) div 255, 0, 100)
    L.fill = clamp((P.fill * 100 + 127) div 255, 0, 100)
    L.mode = blendOfKey(P.blend)
    L.visible = P.visible
    L.lockAlpha = P.protectAlpha
    # its pixels, where they are on the canvas
    var adj = Adjustment()
    if P.adjustment.len > 0 and P.adjustment notin ["SoCo", "GdFl", "PtFl"]:
      adj = adjustmentOf(P, p.mode in {pmGray, pmDuotone, pmBitmap})
    let vector = P.hasVectorMask and not P.vectorDisabled and not P.vectorInvert
    if P.adjustment in ["SoCo", "GdFl"] and vector:
      # a shape layer
      L.shape = shapeOfPsd(P)
      if L.shape.path.subs.len == 0:
        L.shape = ShapeData()
        if P.vectorFillAll: L.px = gradientFill(P.adjustDesc, p.w, p.h)
      else: d.drawShape(L)
    elif P.adjustment == "SoCo" or P.adjustment == "GdFl":
      # a fill layer: its color or gradient over all of it (its mask its shape)
      L.shape = ShapeData(kind: "Fill", path: canvasPath(p.w, p.h), fill: paintOf(P.adjustDesc, P.adjustment))
      d.drawShape(L)
    elif adj.kind.len > 0:
      L.adjust = adj
      L.gray = true
      for v in L.px.mitems: v = 0xFFFFFFFF'u32
    elif P.w * P.h > 0 and P.px.len == P.w * P.h:
      let lp = cast[ptr UncheckedArray[uint32]](addr L.px[0])
      let pp = cast[ptr UncheckedArray[uint32]](unsafeAddr P.px[0])
      let (px0, py0, pw, ph, dw, dh) = (P.x, P.y, P.w, P.h, p.w, p.h)
      parallelRows(ph, yy):
        let y = py0 + yy
        if y >= 0 and y < dh:
          for xx in 0 ..< pw:
            let x = px0 + xx
            if x >= 0 and x < dw: lp[y * dw + x] = pp[yy * pw + xx]
      if d.depth == 16 and P.px16.len == P.w * P.h * 4:
        # (its 16 bits, where it is on the canvas)
        var hi = newSeq[uint16](n * 4)
        for yy in 0 ..< ph:
          let y = py0 + yy
          if y < 0 or y >= dh: continue
          for xx in 0 ..< pw:
            let x = px0 + xx
            if x < 0 or x >= dw: continue
            for c in 0 .. 3: hi[(y * dw + x) * 4 + c] = P.px16[(yy * pw + xx) * 4 + c]
        d.setHi(L, hi)
    elif P.adjustment.len > 0:
      # (an adjustment we have not: kept as a hidden, empty layer)
      L.name = L.name & " (" & P.adjustment.strip & ", not kept)"
      L.visible = false
    if P.adjustment.len == 0 and not L.isShape:
      # a type layer: its text still to edit (its pixels Photoshop's until
      # it is); a placed layer: a Smart Object
      if P.textDesc != nil:
        let (ok, t) = textOfPsd(P)
        if ok:
          L.text = t
          if P.w * P.h == 0 or P.px.len != P.w * P.h: d.drawText(L)    # (written without its pixels)
      if P.placedId.len > 0:
        let s = smartOfPsd(P, p)
        if s != nil: L.smart = s
    # its mask
    if P.hasMask and P.mask.px.len == P.mask.w * P.mask.h:
      var m = newSeq[uint32](n)
      let outside = grayPx(P.mask.outside)
      for v in m.mitems: v = outside
      for yy in 0 ..< P.mask.h:
        let y = P.mask.y + yy
        if y < 0 or y >= p.h: continue
        for xx in 0 ..< P.mask.w:
          let x = P.mask.x + xx
          if x >= 0 and x < p.w: m[y * p.w + x] = grayPx(int(P.mask.px[yy * P.mask.w + xx]))
      if L.adjust.kind.len > 0:
        L.px = m                            # (an adjustment layer's pixels are its mask)
      else:
        L.mask = Layer(name: "Layer Mask", px: m, opacity: 100, visible: true, gray: true)
        L.maskOff = P.mask.disabled
      # (its Properties: density and feather, kept as they are -- not applied)
      if P.mask.density in 0 .. 254: L.maskDensity = (P.mask.density * 100 + 127) div 255
      if P.mask.feather > 0: L.maskFeather = P.mask.feather
    # its vector mask (not a shape's): a layer mask
    if P.hasVectorMask and not P.vectorDisabled and not L.isShape:
      var vm = shapeMask(pathOfVector(P.vectorMask), p.w, p.h, P.vectorFillAll)
      if P.vectorInvert:
        for v in vm.mitems: v = 255 - v
      # (the vector mask's own density and feather: worked into it)
      if P.vectorFeather > 0: blurMask(vm, p.w, p.h, P.vectorFeather)
      if P.vectorDensity in 1 .. 254:
        for v in vm.mitems: v = uint8(255 - (255 - int(v)) * P.vectorDensity div 255)
      if L.adjust.kind.len > 0:
        for k in 0 ..< n: L.px[k] = grayPx(int(L.px[k] and 255) * int(vm[k]) div 255)
      elif L.mask != nil:
        for k in 0 ..< n: L.mask.px[k] = grayPx(int(L.mask.px[k] and 255) * int(vm[k]) div 255)
      else:
        L.mask = Layer(name: "Layer Mask", px: newSeq[uint32](n), opacity: 100, visible: true, gray: true)
        for k in 0 ..< n: L.mask.px[k] = grayPx(int(vm[k]))
    L.clipped = P.clipping
    # its effects
    if P.effects != nil: L.fx = fxOf(P.effects, p.globalAngle, p.globalAltitude)
    # Blend If: the first channel that leaves something out
    for ch in 0 .. 3:
      if 2 * ch + 1 >= P.ranges.len: break
      let t = P.ranges[2 * ch]
      let u = P.ranges[2 * ch + 1]
      if t != [0, 0, 255, 255] or u != [0, 0, 255, 255]:
        L.blendIf = BlendIf(channel: ch, this: (if t == [0, 0, 255, 255]: [0, 0, 0, 0] else: t),
                            under: (if u == [0, 0, 255, 255]: [0, 0, 0, 0] else: u))
        break
    result = L
  proc groupMask(G: PsdLayer): seq[uint32] =
    ## (its mask and its vector mask together; empty: none)
    result = maskOf(G)
    if G.hasVectorMask and not G.vectorDisabled:
      let vm = shapeMask(pathOfVector(G.vectorMask), p.w, p.h, G.vectorFillAll)
      if result.len != n:
        result = newSeq[uint32](n)
        for v in result.mitems: v = 0xFFFFFFFF'u32
      for q in 0 ..< n:
        let v = if G.vectorInvert: 255 - int(vm[q]) else: int(vm[q])
        result[q] = grayPx(int(result[q] and 255) * v div 255)
  proc emit(nodes: seq[Node]; depth: int): seq[Layer] =
    for k, nd in nodes:
      if not nd.group:
        let L = layerOf(p.layers[nd.idx])
        L.depth = depth
        if k == 0: L.clipped = false
        result.add L
        continue
      let G = p.layers[nd.idx]
      if G.effects != nil:
        # (a group with a style -- which ours cannot have: its layers mixed
        # into one layer that has it)
        let kids = emit(nd.kids, 0)
        let L = d.newLayer(if G.name.len > 0: G.name else: "Group")
        d.compositeInto(L.px, d.bounds, kids)
        L.opacity = clamp((G.opacity * 100 + 127) div 255, 0, 100)
        L.mode = blendOfKey(if G.blend == "pass": "norm" else: G.blend)
        L.visible = G.visible
        let m = groupMask(G)
        if m.len == n:
          L.mask = Layer(name: "Layer Mask", px: m, opacity: 100, visible: true, gray: true)
          L.maskOff = G.hasMask and G.mask.disabled
        L.fx = fxOf(G.effects, p.globalAngle, p.globalAltitude)
        L.clipped = G.clipping and k > 0
        L.depth = depth
        result.add L
        continue
      result.add emit(nd.kids, depth + 1)
      let L = d.newGroupLayer(if G.name.len > 0: G.name else: "Group")
      L.depth = depth
      # (a group's Fill Opacity: how much of what it holds shows -- as an
      # opacity, a group having no effects of its own)
      L.opacity = clamp((G.opacity * clamp(G.fill, 0, 255) div 255 * 100 + 127) div 255, 0, 100)
      L.passThrough = G.blend == "pass"
      L.mode = if L.passThrough: bmNormal else: blendOfKey(G.blend)
      L.visible = G.visible
      L.collapsed = G.section == psGroupClosed
      let m = groupMask(G)
      if m.len == n:
        L.mask = Layer(name: "Layer Mask", px: m, opacity: 100, visible: true, gray: true)
        L.maskOff = G.hasMask and G.mask.disabled
      result.add L
  d.layers = emit(frames[0], 0)
  d.fixDepths()
  if d.layers.len == 0:
    d.layers.add d.newLayer("Layer 1")
  # an opaque bottom layer named so is the Background
  let b0 = d.layers[0]
  if b0.name == "Background" and b0.adjust.kind.len == 0 and b0.mask == nil:
    var opaque = true
    for v in b0.px:
      if (v shr 24) != 255:
        opaque = false
        break
    b0.background = opaque
  d.cur = d.layers.high
  d.markAll()
  d.modified = false

proc loadPsd*(path: string): Doc =
  ## Opens a Photoshop document. Raises `IOError` when it cannot be read.
  let data = try: readFile(path)
             except IOError, OSError: raise newException(IOError, "cannot read " & path.extractFilename)
  let p = try: readPsd(data)
          except PsdError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
  result = docOfPsd(p, path.splitFile.name)
  result.path = path
  result.format = "psd"
  result.useProfile(p.icc)

# ---- Photoshop documents out ---------------------------------------------------------------------------

proc gradientDesc(f: ShapePaint): PsdValue =
  var stops = f.stops
  if stops.len == 0: stops = @[GradientStop(at: 0, color: f.color), GradientStop(at: 1, color: f.color2)]
  var clrs, trns: seq[PsdValue]
  for st in stops:
    let at = psdLong(int(round(clamp(st.at, 0.0, 1.0) * 4096)))
    let mid = if st.mid <= 0.001 or st.mid >= 0.999: 50 else: int(round(st.mid * 100))
    clrs.add psdObj("Clrt", ("Clr ", psdRgb(st.color)), ("Type", psdEnum("Clry", "UsrS")), ("Lctn", at),
                    ("Mdpn", psdLong(mid)))
    trns.add psdObj("TrnS", ("Opct", psdUnit("#Prc", float(st.color shr 24) / 2.55)), ("Lctn", at),
                    ("Mdpn", psdLong(50)))
  psdObj("Grdn", ("Nm  ", psdText("Custom")), ("GrdF", psdEnum("GrdF", "CstS")), ("Intr", psdNum(4096)),
         ("Clrs", PsdValue(kind: pkList, list: clrs)), ("Trns", PsdValue(kind: pkList, list: trns)))

proc shapeFillDesc(f: ShapePaint): PsdValue =
  let scale = float(if f.scale <= 0: 100 else: f.scale)
  if f.kind == spGradient:
    psdObj("null", ("Grad", gradientDesc(f)), ("Angl", psdUnit("#Ang", f.angle.float)),
           ("Type", psdEnum("GrdT", gradTypes[clamp(f.style, 0, 4)])), ("Rvrs", psdBool(f.reverse)),
           ("Algn", psdBool(true)), ("Scl ", psdUnit("#Prc", scale)))
  else:
    psdObj("null", ("Clr ", psdRgb(f.color)))

proc strokeDesc(s: ShapeData): PsdValue =
  var dashes: seq[PsdValue]
  for v in s.dashes: dashes.add psdUnit("#Nne", v)
  let content = if s.stroke.kind == spGradient: psdObj("gradientLayer", shapeFillDesc(s.stroke).items)
                else: psdObj("solidColorLayer", ("Clr ", psdRgb(s.stroke.color)))
  psdObj("strokeStyle",
         ("strokeStyleVersion", psdLong(2)),
         ("strokeEnabled", psdBool(s.stroke.kind != spNone and s.strokeWidth > 0)),
         ("fillEnabled", psdBool(s.fill.kind != spNone)),
         ("strokeStyleLineWidth", psdUnit("#Pxl", s.strokeWidth)),
         ("strokeStyleLineDashOffset", psdUnit("#Pnt", 0)),
         ("strokeStyleMiterLimit", psdNum(100)),
         ("strokeStyleLineCapType", psdEnum("strokeStyleLineCapType",
                                            ["strokeStyleButtCap", "strokeStyleRoundCap",
                                             "strokeStyleSquareCap"][ord(s.cap)])),
         ("strokeStyleLineJoinType", psdEnum("strokeStyleLineJoinType",
                                             ["strokeStyleMiterJoin", "strokeStyleRoundJoin",
                                              "strokeStyleBevelJoin"][ord(s.join)])),
         ("strokeStyleLineAlignment", psdEnum("strokeStyleLineAlignment",
                                              ["strokeStyleAlignInside", "strokeStyleAlignCenter",
                                               "strokeStyleAlignOutside"][ord(s.align)])),
         ("strokeStyleScaleLock", psdBool(false)),
         ("strokeStyleStrokeAdjust", psdBool(false)),
         ("strokeStyleLineDashSet", PsdValue(kind: pkList, list: dashes)),
         ("strokeStyleBlendMode", psdEnum("BlnM", "Nrml")),
         ("strokeStyleOpacity", psdUnit("#Prc", float(if s.stroke.opacity <= 0: 100 else: s.stroke.opacity))),
         ("strokeStyleContent", content),
         ("strokeStyleResolution", psdNum(72)))

proc enumOfBlend(m: BlendMode): string =
  for k in ["Dslv", "Mltp", "Scrn", "Ovrl", "SftL", "HrdL", "Drkn", "Lghn", "Dfrn", "H   ", "Strt", "Clr ",
            "Lmns", "CBrn", "CDdg", "linearBurn", "linearDodge", "vividLight", "linearLight", "pinLight",
            "hardMix", "Xclu", "blendSubtraction", "blendDivide", "darkerColor", "lighterColor"]:
    if blendOfEnum(k) == m: return k
  "Nrml"

proc lfx2Of(fx: LayerFx): PsdValue =
  ## A layer style as Photoshop's layer effects (lfx2).
  proc pct(v: int): PsdValue = psdUnit("#Prc", v.float)
  proc pxl(v: int): PsdValue = psdUnit("#Pxl", v.float)
  proc ang(v: int): PsdValue = psdUnit("#Ang", v.float)
  proc md(m: BlendMode): PsdValue = psdEnum("BlnM", enumOfBlend(m))
  let contour = psdObj("ShpC", ("Nm  ", psdText("Linear")),
                       ("Crv ", psdList(psdObj("CrPt", ("Hrzn", psdNum(0)), ("Vrtc", psdNum(0))),
                                        psdObj("CrPt", ("Hrzn", psdNum(255)), ("Vrtc", psdNum(255))))))
  result = psdObj("null", ("Scl ", pct(100)), ("masterFXSwitch", psdBool(not fx.hidden)))
  for k, e in fx.fx:
    if not e.on: continue
    let base = @[("enab", psdBool(true)), ("present", psdBool(true)), ("showInDialog", psdBool(true)),
                 ("Md  ", md(e.mode)), ("Clr ", psdRgb(e.color)), ("Opct", pct(e.opacity))]
    case k
    of fxDropShadow, fxInnerShadow:
      result.items.add ((if k == fxDropShadow: "DrSh" else: "IrSh"),
        psdObj((if k == fxDropShadow: "DrSh" else: "IrSh"),
               base & @[("uglg", psdBool(false)), ("lagl", ang(e.angle)), ("Dstn", pxl(e.distance)),
                        ("Ckmt", pxl(e.spread)), ("blur", pxl(e.size)), ("Nose", pct(0)),
                        ("AntA", psdBool(false)), ("TrnS", contour), ("layerConceals", psdBool(true))]))
    of fxOuterGlow, fxInnerGlow:
      var items = base & @[("GlwT", psdEnum("BETE", "SfBL")), ("Ckmt", pxl(e.spread)), ("blur", pxl(e.size)),
                           ("Nose", pct(0)), ("ShdN", pct(0)), ("AntA", psdBool(false)), ("TrnS", contour),
                           ("Inpr", pct(50))]
      if k == fxInnerGlow: items.add ("glwS", psdEnum("IGSr", (if e.style == 1: "SrcC" else: "SrcE")))
      result.items.add ((if k == fxOuterGlow: "OrGl" else: "IrGl"),
                        psdObj((if k == fxOuterGlow: "OrGl" else: "IrGl"), items))
    of fxSatin:
      result.items.add ("ChFX", psdObj("ChFX", base & @[("AntA", psdBool(true)), ("Invr", psdBool(e.down)),
                                                       ("lagl", ang(e.angle)), ("Dstn", pxl(e.distance)),
                                                       ("blur", pxl(e.size)), ("MpgS", contour)]))
    of fxColorOverlay:
      result.items.add ("SoFi", psdObj("SoFi", base))
    of fxGradientOverlay:
      var g = ShapePaint(kind: spGradient, color: e.color, color2: e.color2, angle: e.angle, style: e.style,
                         reverse: e.down, scale: e.scale)
      let gd = shapeFillDesc(g)
      result.items.add ("GrFl", psdObj("GrFl", @[("enab", psdBool(true)), ("present", psdBool(true)),
                                                 ("showInDialog", psdBool(true)), ("Md  ", md(e.mode)),
                                                 ("Opct", pct(e.opacity))] & gd.items))
    of fxStroke:
      result.items.add ("FrFX", psdObj("FrFX", base & @[("Styl", psdEnum("FStl", ["OutF", "InsF", "CtrF"][clamp(e.style, 0, 2)])),
                                                       ("PntT", psdEnum("FrFl", "SClr")), ("Sz  ", pxl(e.size))]))
    of fxBevel:
      result.items.add ("ebbl", psdObj("ebbl", @[("enab", psdBool(true)), ("present", psdBool(true)),
        ("showInDialog", psdBool(true)), ("hglM", md(e.mode)),
        ("hglC", psdRgb(e.color)), ("hglO", pct(e.opacity)), ("sdwM", md(e.mode2)), ("sdwC", psdRgb(e.color2)),
        ("sdwO", pct(e.opacity2)), ("bvlT", psdEnum("bvlT", "SfBL")),
        ("bvlS", psdEnum("BESl", ["InrB", "OtrB", "Embs", "PlEb"][clamp(e.style, 0, 3)])),
        ("uglg", psdBool(false)), ("lagl", ang(e.angle)), ("Lald", ang(e.altitude)), ("srgR", pct(e.depth)),
        ("blur", pxl(e.size)), ("bvlD", psdEnum("BESs", (if e.down: "Out " else: "In  "))), ("TrnS", contour),
        ("antialiasGloss", psdBool(false)), ("Sftn", pxl(e.soften)), ("useShape", psdBool(false)),
        ("useTexture", psdBool(false))]))

var psdMaximizeCompatibility* = true
  ## Photoshop documents carry the merged picture (programs that do not read
  ## layers show it); off, the files are smaller and it is plain white.

proc psdOf*(d: Doc; composite = true): PsdDoc =
  ## Our document as Photoshop's: each layer at the size of what it holds
  ## (layer styles as pixels), masks, adjustment layers that Photoshop has
  ## too, type layers as type layers (their text, EngineData, warp -- and
  ## their pixels, for what cannot set type), Smart Objects as placed
  ## layers (their files embedded), the merged picture (not made without
  ## `composite`).
  result = PsdDoc(w: d.w, h: d.h, depth: (if d.depth == 16 and d.mode in {cmRGB, cmGray}: 16 else: 8),
                  dpi: d.dpi, icc: d.icc,
                  mode: (case d.mode
                         of cmGray, cmBitmap: pmGray
                         of cmCMYK: pmCMYK
                         else: pmRGB))
  let n = d.w * d.h
  for i, L in d.layers:
    # a group's end (before its layers)
    for g in i .. d.layers.high:
      if d.layers[g].group and d.blockStart(g) == i:
        result.layers.add PsdLayer(name: "</Layer group>", opacity: 255, fill: 255, blend: "pass",
                                   visible: true, section: psGroupEnd)
    var P = PsdLayer(name: L.name, opacity: (L.opacity * 255 + 50) div 100, fill: (L.fill * 255 + 50) div 100,
                     blend: keyOfBlend(L.mode), visible: L.visible, protectAlpha: L.lockAlpha,
                     clipping: L.clipped)
    if L.blendIf.isOn:
      let chans = if d.mode in {cmGray, cmBitmap, cmDuotone}: 1 elif d.mode == cmCMYK: 5 else: 4
      for ch in 0 ..< chans:
        if ch == L.blendIf.channel:
          P.ranges.add rangeOf(L.blendIf.this)
          P.ranges.add rangeOf(L.blendIf.under)
        else:
          P.ranges.add [0, 0, 255, 255]
          P.ranges.add [0, 0, 255, 255]
    if L.group:
      P.section = if L.collapsed: psGroupClosed else: psGroupOpen
      if L.passThrough: P.blend = "pass"
      if L.mask != nil and L.mask.px.len == n:
        P.hasMask = true
        P.mask = PsdMask(x: 0, y: 0, w: d.w, h: d.h, outside: 255, disabled: L.maskOff, px: newSeq[uint8](n))
        for k in 0 ..< n: P.mask.px[k] = uint8(L.mask.px[k] and 255)
      result.layers.add P
      continue
    if L.adjust.kind.len > 0:
      let (key, data) = adjustmentData(L.adjust)
      if key.len > 0:
        P.adjustment = key
        P.adjustData = data
        # (its pixels are its mask)
        P.hasMask = true
        P.mask = PsdMask(x: 0, y: 0, w: d.w, h: d.h, outside: 255, px: newSeq[uint8](n))
        for k in 0 ..< n: P.mask.px[k] = uint8(L.px[k] and 255)
      else:
        P.name = L.name & " (" & L.adjust.kind & ")"
        P.visible = false
      result.layers.add P
      continue
    # a fill layer: its color or gradient (no outline)
    if L.isFill and L.shape.fill.kind in {spColor, spGradient}:
      P.adjustment = (if L.shape.fill.kind == spGradient: "GdFl" else: "SoCo")
      P.adjustData = descriptorData(shapeFillDesc(L.shape.fill))
    # a shape layer: a fill layer with a vector mask (and its stroke)
    elif L.isShape:
      let sh = L.shape
      P.extra.add ("vmsk", vectorMaskData(subpathsOf(sh.path), d.w, d.h))
      let fillDesc = shapeFillDesc(sh.fill)
      P.adjustment = (if sh.fill.kind == spGradient: "GdFl" else: "SoCo")
      P.adjustData = descriptorData(fillDesc)
      P.extra.add ("vstk", descriptorData(strokeDesc(sh)))
    # its style: as Photoshop's effects
    if L.hasStyle:
      var dat = "\0\0\0\0"
      dat.add descriptorData(lfx2Of(L.fx))
      P.extra.add ("lfx2", dat)
    let px = L.px
    # the rectangle of what is there
    var x0 = d.w
    var y0 = d.h
    var x1 = -1
    var y1 = -1
    for y in 0 ..< d.h:
      let row = y * d.w
      for x in 0 ..< d.w:
        if (px[row + x] shr 24) != 0:
          if x < x0: x0 = x
          if x > x1: x1 = x
          if y < y0: y0 = y
          y1 = y
    if x1 >= 0:
      P.x = x0
      P.y = y0
      P.w = x1 - x0 + 1
      P.h = y1 - y0 + 1
      P.px = newSeq[uint32](P.w * P.h)
      for y in 0 ..< P.h:
        copyMem(addr P.px[y * P.w], addr px[(y0 + y) * d.w + x0], P.w * 4)
      if d.depth == 16 and d.hiValid(L):
        # (its 16 bits, as it came)
        P.px16 = newSeq[uint16](P.w * P.h * 4)
        for y in 0 ..< P.h:
          copyMem(addr P.px16[y * P.w * 4], unsafeAddr L.hi[((y0 + y) * d.w + x0) * 4], P.w * 8)
    if L.isText and not L.isShape and not L.isFill:
      # a type layer: its text (what it shows: a box the text flows into
      # from another holds what did not fit that one)
      let drawn = if x1 >= 0: rect(x0, y0, x1 - x0 + 1, y1 - y0 + 1) else: rect(0, 0, 0, 0)
      P.extra.add ("TySh", typeLayerData(d.effectiveText(L), drawn))
    elif L.isSmart:
      # a Smart Object: a placed layer, its file embedded once
      let pl = placedLayer(L.smart, i, d.dpi)
      var have = false
      for f in result.linked:
        if f.id == pl.file.id: have = true
      if not have: result.linked.add pl.file
      P.extra.add ("PlLd", pl.plLd)
      P.extra.add ("SoLd", pl.soLd)
    if L.mask != nil and L.mask.px.len == n:
      P.hasMask = true
      P.mask = PsdMask(x: 0, y: 0, w: d.w, h: d.h, outside: 255, disabled: L.maskOff, px: newSeq[uint8](n))
      for k in 0 ..< n: P.mask.px[k] = uint8(L.mask.px[k] and 255)
    result.layers.add P
  if not composite: return
  if result.depth == 16: result.composite16 = d.flattened16()
  if psdMaximizeCompatibility: result.composite = d.flattened()
  else:
    result.composite = newSeqUninit[uint32](d.w * d.h)   # (white, as Photoshop leaves it)
    for p in result.composite.mitems: p = 0xFFFFFFFF'u32

proc savePsd*(d: Doc; path: string) =
  ## Saves the document as a Photoshop document (with its layers).
  let tmp = path & ".part"
  writeFile(tmp, writePsd(psdOf(d)))
  moveFile(tmp, path)

# ---- pictures too big to edit whole ------------------------------------------------------------------

type PictureTooBigError* = object of IOError
  ## `openPicture`: the picture is too big to edit whole here
  ## (`pictureTooBig`) -- a smaller copy of it, or a part, can be opened
  ## instead (`openPictureScaled`, `openPictureRegion`).
  w*, h*: int                   ## the picture's size

const bigKinds = [".png", ".jpg", ".jpeg", ".jpe", ".jfif", ".bmp", ".dib", ".tif", ".tiff", ".tga"]
  ## (the files `retroui/bigpicture` reads in parts)

const bytesPerPixel = 12
  ## (what a pixel of an image open takes at least: its layer, the picture
  ## shown, a step to undo)

proc bigPictureSize*(path: string): tuple[w, h: int] =
  ## The size of a PNG, JPEG, BMP, TIFF or TGA picture from its header (as
  ## it is shown; 0, 0 when it is not one of them).
  if path.splitFile.ext.toLowerAscii notin bigKinds: return
  let (w, h, kind) = bigPictureInfo(path)
  if kind.len > 0: result = (w, h)

proc pictureTooBig*(path: string; freeBytes = 0'i64): bool =
  ## Whether the picture in `path` -- a PNG, JPEG, BMP, TIFF or TGA -- is too
  ## big to edit whole on this device: more pixels than `maxPixels` or a
  ## side longer than `MaxSide` (`sizeOk`), or, given the memory free
  ## (`freeBytes` > 0), more than it leaves room for (12 bytes a pixel).
  let (w, h) = bigPictureSize(path)
  if w <= 0 or h <= 0: return false
  not sizeOk(w, h) or (freeBytes > 0 and w.int64 * h.int64 * bytesPerPixel > freeBytes)

proc largestSize*(w, h: int; freeBytes = 0'i64): tuple[w, h: int] =
  ## The largest size a `w` x `h` picture (or part) can be edited at here,
  ## its shape kept: within `MaxSide` and `maxPixels` -- and the memory
  ## free, when `freeBytes` > 0. As it is when it is within.
  var budget = maxPixels.int64
  if freeBytes > 0: budget = max(1'i64, min(budget, freeBytes div bytesPerPixel))
  if w <= MaxSide and h <= MaxSide and w.int64 * h.int64 <= budget: return (w, h)
  var k = min(MaxSide / w, MaxSide / h)
  k = min(k, sqrt(budget.float / (w.float * h.float)))
  result = (clamp(int(w.float * k), 1, MaxSide), clamp(int(h.float * k), 1, MaxSide))
  while result.w.int64 * result.h.int64 > budget and (result.w > 1 or result.h > 1):
    # (rounding: a pixel less on the longer side)
    if result.w >= result.h: dec result.w else: dec result.h

proc profileNear(path: string): string =
  ## (the color profile at the start of a big file: PNG's iCCP, JPEG's APP2,
  ## a TIFF's tag when it is there)
  try:
    var f: File
    if not open(f, path): return ""
    defer: f.close()
    var head = newString(int(min(getFileSize(f), 16'i64 shl 20)))
    if head.len == 0: return ""
    head.setLen(f.readBuffer(addr head[0], head.len))
    case path.splitFile.ext.toLowerAscii
    of ".png": iccFromPng(head)
    of ".jpg", ".jpeg", ".jpe", ".jfif": iccFromJpeg(head)
    of ".tif", ".tiff": iccFromTiff(head)
    else: ""
  except CatchableError, Defect: ""

proc bigDoc(b: Bitmap; path: string): Doc =
  ## (a document of what was read of a big picture: a copy -- no path, so
  ## saving it never writes over the big file)
  if b == nil or b.w <= 0: raise newException(IOError, "cannot read " & path.extractFilename)
  result = fromBitmap(b, path.splitFile.name, take = true)
  result.path = ""
  result.format = path.splitFile.ext.toLowerAscii.strip(chars = {'.'})
  result.useProfile(profileNear(path))
  result.modified = false

proc openPictureScaled*(path: string; freeBytes = 0'i64; progress: BigProgress = nil): Doc =
  ## A smaller copy of the (big) picture in `path` as a new document: all
  ## of it, made as big as this device allows (`largestSize`), each pixel
  ## the average of those it covers. Read a band at a time: the memory is
  ## the copy's. Raises `IOError` (or `BusyCancelled`).
  let (w, h) = bigPictureSize(path)
  if w <= 0 or h <= 0: raise newException(IOError, "cannot read " & path.extractFilename)
  let (lw, lh) = largestSize(w, h, freeBytes)
  let b = try: readScaled(path, lw, lh, progress)
          except BigPictureError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
  bigDoc(b, path)

proc openPictureRegion*(path: string; x, y, w, h: int; freeBytes = 0'i64; progress: BigProgress = nil): Doc =
  ## The part `x`, `y`, `w` x `h` of the (big) picture in `path` (its
  ## pixels as shown) at full size, as a new document -- made smaller
  ## around its middle when it is more than this device allows
  ## (`largestSize`). Read a band at a time. Raises `IOError` (or
  ## `BusyCancelled`).
  let (pw, ph) = bigPictureSize(path)
  if pw <= 0 or ph <= 0: raise newException(IOError, "cannot read " & path.extractFilename)
  var x0 = clamp(x, 0, pw - 1)
  var y0 = clamp(y, 0, ph - 1)
  var rw = clamp(x + w, x0 + 1, pw) - x0
  var rh = clamp(y + h, y0 + 1, ph) - y0
  let (lw, lh) = largestSize(rw, rh, freeBytes)
  x0 += (rw - lw) div 2
  y0 += (rh - lh) div 2
  let b = try: readRegion(path, x0, y0, lw, lh, 1, progress)
          except BigPictureError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
  bigDoc(b, path)

# ---- any picture ------------------------------------------------------------------------------------

proc openPicture*(path: string): Doc =
  ## Opens any picture we read: a Retro Photo or Photoshop document (with
  ## its layers), a PNG, JPEG, BMP, GIF, TIFF or TGA. Raises `IOError` --
  ## `PictureTooBigError` for a picture too big to edit whole here
  ## (`pictureTooBig`: `openPictureScaled` and `openPictureRegion` open
  ## it in part).
  let ext = path.splitFile.ext.toLowerAscii
  if ext in bigKinds and pictureTooBig(path):
    let (w, h) = bigPictureSize(path)
    var e = newException(PictureTooBigError, path.extractFilename & ": " & $w & " x " & $h &
                         " pixels -- too big to edit whole")
    e.w = w
    e.h = h
    raise e
  case ext
  of ".psd", ".psb": return loadPsd(path)
  of ".pdf", ".ai", ".eps", ".ps":
    # (a PDF, an Illustrator drawing: drawn at 300 ppi -- the drawing's
    # outlines kept as shapes; an EPS: its picture)
    let data = try: readFile(path)
               except IOError, OSError: raise newException(IOError, "cannot read " & path.extractFilename)
    result = if ext in [".pdf", ".ai"] and data.find("%PDF-") in 0 .. 1024:
               importPdf(data, path.splitFile.name, ImportOptions(ppi: 300, shapes: ext == ".ai"))
             else: importPs(data, path.splitFile.name)
    result.path = path
    result.format = ext[1 .. ^1]
    result.modified = false
  of ".dng", ".nef", ".nrw", ".arw", ".srf", ".sr2", ".cr2", ".cr3", ".orf", ".rw2", ".pef", ".raf":
    # a raw photo (DNG, Nikon, Sony, Canon, Olympus, Panasonic, Pentax, Fuji): developed as shot
    let data = try: readFile(path)
               except IOError, OSError: raise newException(IOError, "cannot read " & path.extractFilename)
    let raw = try: readRaw(data)
              except RawError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
    if not sizeOk(raw.w, raw.h): raise newException(IOError, "too big")
    result = docOfRaw(raw, path.splitFile.name)
    result.path = path
    result.format = ext[1 .. ^1]
    result.modified = false
  of ".heic", ".heif", ".hif", ".avif":
    # (HEIF, AVIF: read by the system's decoders)
    var hi: seq[uint16]
    let b = decodeWithSystem(path, addr hi)
    if b == nil: raise newException(IOError, path.extractFilename & ": " & systemImageNote())
    if not sizeOk(b.w, b.h): raise newException(IOError, "too big")
    let deep = hi.len == b.w * b.h * 4 and hi.len > 0
    result = fromBitmap(b, path.splitFile.name, take = true)
    if deep:
      # (10 or 12 bits a channel, as HDR phones' photos are: kept at 16)
      result.depth = 16
      result.setHi(result.layers[0], hi)
    result.path = path
    result.format = ext[1 .. ^1]
    result.modified = false
  of ".svg":
    # (an SVG: its drawing as shape layers -- sharp at any size -- on a
    # transparent canvas its size, at least 1024 pixels across)
    let data = try: readFile(path)
               except IOError, OSError: raise newException(IOError, "cannot read " & path.extractFilename)
    let doc = parseSvg(data)
    var (sw, sh) = svgSize(doc)
    if sw <= 0 or sh <= 0: (sw, sh) = (1024.0, 1024.0)
    let k = max(1.0, 1024 / max(sw, sh))
    let w = clamp(int(round(sw * k)), 1, 16384)
    let h = clamp(int(round(sh * k)), 1, 16384)
    result = newDoc(w, h, 0'u32, 72, path.splitFile.name)
    discard result.placeSvg(data, rect(0, 0, w, h))
    if result.layers.len > 1 and result.layers[0].px.len > 0:
      # (the empty first layer the new document had: not needed)
      var empty = true
      for p in result.layers[0].px:
        if p != 0:
          empty = false
          break
      if empty and not result.layers[0].isShape and not result.layers[0].group: result.deleteLayer(0)
    result.clearHistory()
    result.path = path
    result.format = "svg"
    result.modified = false
  of ".jxl":
    # (a JPEG XL: its frames when it is animated; 16 bits kept when it has more than 8)
    let data = try: readFile(path)
               except IOError, OSError: raise newException(IOError, "cannot read " & path.extractFilename)
    let info = try: jxlInfo(data)
               except CatchableError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
    if not sizeOk(info.w, info.h): raise newException(IOError, "too big")
    try:
      if info.frames > 1 and openAnimations:
        var fr: seq[tuple[px: seq[uint32]; delay: int]]
        for f in decodeJxlFrames(data): fr.add (f.bmp.px, f.delayMs)
        result = docFromFrames(info.w, info.h, fr, path.splitFile.name, 0)
      else:
        let b = decodeJxl(data)
        result = fromBitmap(b, path.splitFile.name, take = true)
        if info.bits > 8:
          let deep = decodeJxl16(data)
          if deep.px.len == result.w * result.h * 4:
            result.depth = 16
            result.setHi(result.layers[0], deep.px)
    except CatchableError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
    result.path = path
    result.format = "jxl"
    result.modified = false
  of ".webp":
    # (a WebP: its frames, when it is animated -- a layer and a frame each)
    let data = try: readFile(path)
               except IOError, OSError: raise newException(IOError, "cannot read " & path.extractFilename)
    let info = try: webpInfo(data)
               except CatchableError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
    if not sizeOk(info.w, info.h): raise newException(IOError, "too big")
    if info.animated and info.frames > 1 and openAnimations:
      let fr0 = try: decodeWebpFrames(data)
                except CatchableError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
      var fr: seq[tuple[px: seq[uint32]; delay: int]]
      for f in fr0: fr.add (f.bmp.px, f.delayMs)
      result = docFromFrames(info.w, info.h, fr, path.splitFile.name, 0)
    else:
      let b = try: decodeWebp(data)
              except CatchableError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
      result = fromBitmap(b, path.splitFile.name, take = true)
    result.path = path
    result.format = "webp"
    result.modified = false
  of ".hdr", ".rgbe", ".pfm":
    # (light at 32 bits: a Radiance or PFM picture)
    let data = try: readFile(path)
               except IOError, OSError: raise newException(IOError, "cannot read " & path.extractFilename)
    let pic = try: (if ext == ".pfm": readPfm(data) else: readHdr(data))
              except CatchableError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
    if not sizeOk(pic.w, pic.h): raise newException(IOError, "too big")
    result = docFromLight(pic.w, pic.h, pic.light, path.splitFile.name)
    result.path = path
    result.format = ext[1 .. ^1]
    result.modified = false
  of ".exr":
    # (light at 32 bits: an OpenEXR picture -- its RGBA layer)
    let data = try: readFile(path)
               except IOError, OSError: raise newException(IOError, "cannot read " & path.extractFilename)
    let pic = try: readExr(data)
              except CatchableError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
    if not sizeOk(pic.w, pic.h): raise newException(IOError, "too big")
    result = docFromLight(pic.w, pic.h, pic.px, path.splitFile.name)
    result.path = path
    result.format = "exr"
    result.modified = false
  of ".gif":
    # (its frames: an animation -- a layer and a frame for each; else its picture)
    let data = try: readFile(path)
               except IOError, OSError: raise newException(IOError, "cannot read " & path.extractFilename)
    let anim = if openAnimations: (try: gifFrames(data) except CatchableError: @[]) else: @[]
    if anim.len > 1 and anim[0].bmp != nil and sizeOk(anim[0].bmp.w, anim[0].bmp.h):
      var fr: seq[tuple[px: seq[uint32]; delay: int]]
      for f in anim: fr.add (f.bmp.px, f.delayMs)
      let gl = gifLoop(data)
      result = docFromFrames(anim[0].bmp.w, anim[0].bmp.h, fr, path.splitFile.name,
                             (if gl < 0: 1 else: gl))
      result.path = path
      result.format = "gif"
      result.modified = false
      return
    let frames = try: loadGif(data)
                 except CatchableError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
    if frames.len == 0 or frames[0].image == nil: raise newException(IOError, "cannot read " & path.extractFilename)
    let b = frames[0].image
    if not sizeOk(b.w, b.h): raise newException(IOError, "too big")
    result = fromBitmap(b, path.splitFile.name, take = true)
    result.path = path
    result.format = "gif"
    result.modified = false
  of ".tif", ".tiff", ".tga":
    let data = try: readFile(path)
               except IOError, OSError: raise newException(IOError, "cannot read " & path.extractFilename)
    if ext != ".tga":
      # (a TIFF that keeps Photoshop's layers: with them)
      let ld = try: docOfLayeredTiff(data, path.splitFile.name) except CatchableError: nil
      if ld != nil:
        ld.path = path
        ld.format = ext.strip(chars = {'.'})
        ld.useProfile(iccFromTiff(data))
        ld.modified = false
        result = ld; return
    let b = try: (if ext == ".tga": decodeTga(data) else: decodeTiff(data))
            except CatchableError as e: raise newException(IOError, path.extractFilename & ": " & e.msg)
    if b == nil or b.w <= 0: raise newException(IOError, "cannot read " & path.extractFilename)
    if not sizeOk(b.w, b.h): raise newException(IOError, "too big")
    result = fromBitmap(b, path.splitFile.name, take = true)
    result.path = path
    result.format = ext.strip(chars = {'.'})
    result.modified = false
    if ext != ".tga": result.useProfile(iccFromTiff(data))
  else:
    # (a Photoshop document with another name: by its first bytes)
    var head = ""
    try:
      var f: File
      if open(f, path):
        head = newString(4)
        if f.readBuffer(addr head[0], 4) != 4: head = ""
        close(f)
    except IOError, OSError: discard
    if head == "8BPS": result = loadPsd(path); return
    var depth16 = false
    if ext == ".png":
      # (its bit depth, from the header: an 8-bit one is not decoded twice)
      try:
        var f: File
        if open(f, path):
          var ihdr = newString(25)
          if f.readBuffer(addr ihdr[0], 25) == 25 and ihdr[12 .. 15] == "IHDR": depth16 = ord(ihdr[24]) == 16
          close(f)
      except IOError, OSError: discard
    if ext == ".png" and depth16:
      # (a 16-bit PNG: its 16 bits kept)
      try:
        let data = readFile(path)
        var hi: seq[uint16]
        let b = decodePng(data, addr hi)
        if hi.len == b.w * b.h * 4 and hi.len > 0:
          result = fromBitmap(b, path.splitFile.name, take = true)
          result.path = path
          result.format = "png"
          result.depth = 16
          result.setHi(result.layers[0], hi)
          result.useProfile(iccFromPng(data))
          result.modified = false
          return
      except CatchableError: discard
    result = openImage(path)
    if ext in [".jpg", ".jpeg", ".jpe", ".jfif", ".png"]:
      # (the color profile it carries)
      try:
        let data = readFile(path)
        result.useProfile(if ext == ".png": iccFromPng(data) else: iccFromJpeg(data))
        result.modified = false
      except IOError, OSError: discard

type FlatExport* = object
  ## A picture to save flattened, ready to compress (on any thread): its
  ## pixels (scaled, over the matte), the inks of a CMYK one, its profile.
  px*: seq[uint32]              ## its pixels (ARGB), `w` x `h`
  w*, h*, dpi*: int             ## its size, and pixels per inch
  ink*: seq[uint8]              ## a CMYK document's TIFF: C, M, Y, K of each pixel ("" otherwise)
  icc*: string                  ## the profile to embed ("" none)
  gray*, keepAlpha*: bool       ## saved as grays; its transparency kept
  px16*: seq[uint16]            ## a 16-bit document's picture at 16 bits (PNG), R G B A each
  light*: seq[float32]          ## its light at 32 bits (Radiance HDR, PFM), R G B A each
  layers*: string               ## TIFF: its layers as Photoshop keeps them (`tiffLayersOf`), "" none

proc flatExport*(d: Doc; o: ExportOptions): FlatExport =
  ## The document's pixels made ready for `encodeFlat` (on the drawing
  ## thread: the layers mixed on all the cores).
  var w = d.w
  var h = d.h
  var px = d.flattened()
  if o.scale > 0 and abs(o.scale - 1) > 1e-6:
    w = max(1, int(round(d.w.float * o.scale)))
    h = max(1, int(round(d.h.float * o.scale)))
    px = resample(px, d.w, d.h, w, h, o.resample)
  let keepAlpha = o.transparency and (o.format in {efPng, efPng8, efGif, efTiff, efTga, efWebp, efJxl, efAvif,
                                                   efHeic} or
                                      (o.format == efBmp and o.bmpBits == 32))
  if not keepAlpha:
    let matte = if o.matte == 0: 0xFFFFFFFF'u32 else: o.matte or 0xFF000000'u32
    let pp = cast[ptr UncheckedArray[uint32]](addr px[0])
    parallelFor(px.len, proc (lo, hi: int) =
      for i in lo ..< hi:
        let p = pp[i]
        if (p shr 24) != 255: pp[i] = blendPx(matte, p, 255, bmNormal), grain = 65536)
  result.keepAlpha = keepAlpha
  result.gray = d.mode in {cmGray, cmBitmap}
  result.dpi = int(round(d.dpi))
  result.icc = if not o.embedProfile or d.mode == cmCMYK: ""
               elif result.gray and o.format == efTiff: grayProfile().data
               elif d.icc.len > 0: d.icc
               else: srgbProfile().data
  if o.format == efTiff and d.mode == cmCMYK:
    # (the separations: the inks themselves)
    var ink = newSeq[uint8](w * h * 4)
    let ip = cast[ptr UncheckedArray[uint8]](addr ink[0])
    let bp = cast[ptr UncheckedArray[uint32]](addr px[0])
    parallelFor(w * h, proc (lo, hi: int) =
      for i in lo ..< hi:
        let v = inkOf(bp[i])
        for c in 0 .. 3: ip[i * 4 + c] = v[c], grain = 16384)
    result.ink = move(ink)
  result.w = w
  result.h = h
  result.px = move(px)
  if d.depth == 16 and o.format == efPng and w == d.w and h == d.h and d.mode in {cmRGB, cmGray}:
    # (16 bits: kept so)
    var hi = d.flattened16()
    if not keepAlpha:
      for i in 0 ..< w * h:
        let a = hi[4 * i + 3].int
        if a < 65535:
          for c in 0 .. 2:
            hi[4 * i + c] = uint16((int64(hi[4 * i + c]) * a + 65535'i64 * (65535 - a)) div 65535)
          hi[4 * i + 3] = 65535
    result.px16 = move(hi)
  if o.format in {efHdr, efPfm, efExr} and w == d.w and h == d.h:
    # (32 bits: the light as it is; another depth: its pixels made light)
    result.light = if d.depth == 32: d.flattenedHdr() else: lightOf(result.px)
  if o.format == efTiff and o.tiffLayers and w == d.w and h == d.h:
    # (its layers too, as Photoshop keeps them in a TIFF)
    result.layers = tiffLayersOf(d)

proc encodeFlat*(f: sink FlatExport; o: ExportOptions): string =
  ## The bytes of the file (`flatExport`'s picture compressed).
  let w = f.w
  let h = f.h
  let dpi = f.dpi
  let icc = f.icc
  let keepAlpha = f.keepAlpha
  var b = newBitmap(w, h)
  b.px = move(f.px)
  case o.format
  of efJpeg: embedInJpeg(encodeJpeg(b, (if o.quality <= 0: 85 else: clamp(o.quality, 1, 100)), o.chroma420, dpi),
                         icc)
  of efPng:
    let lv = if o.pngLevel > 0: o.pngLevel elif w * h > 8_000_000: 3 else: 6
    if f.px16.len == w * h * 4: embedInPng(encodePng16(w, h, f.px16, lv, dpi, alpha = keepAlpha), icc)
    else: embedInPng(encodePng(b, lv, dpi), icc)
  of efPng8, efGif:
    var q = quantize(b.px, (if o.colors <= 0: 256 else: clamp(o.colors, 2, 256)),
                     alphaCut = (if keepAlpha: 128 else: 0))
    if o.dither: q.ditherTo(b.px, w, h, alphaCut = (if keepAlpha: 128 else: 0))
    if o.format == efGif: encodeGif(w, h, q) else: embedInPng(encodePngIndexed(w, h, q, 6, dpi), icc)
  of efTiff:
    encodeTiff(b, o.tiff, alpha = keepAlpha and f.ink.len == 0, gray = f.gray, dpi = max(1, dpi), cmyk = f.ink,
               icc = icc, photoshop = f.layers)
  of efBmp: (if o.bmpBits == 32 and keepAlpha: encodeBmp32(b.px, w, h) else: encodeBmp(b.px, w, h))
  of efTga: encodeTga(b, alpha = keepAlpha, rle = o.tgaRle)
  of efHdr, efPfm:
    # (light: the 32-bit document's, or its pixels made light)
    let light = if f.light.len == w * h * 4: f.light else: lightOf(b.px)
    if o.format == efHdr: writeHdr(w, h, light) else: writePfm(w, h, light)
  of efWebp:
    if o.webpLossless: encodeWebpLossless(b)
    else: encodeWebp(b, (if o.quality <= 0: 80 else: clamp(o.quality, 1, 100)))
  of efJxl:
    let effort = if o.jxlEffort <= 0: 3 else: clamp(o.jxlEffort, 1, 9)
    if o.jxlLossy and o.quality in 1 .. 99: encodeJxl(b, o.quality, effort)
    else: encodeJxlLossless(b, effort)
  of efAvif, efHeic:
    # (by the system's libraries, where it has an encoder: `systemEncodeExts`)
    let data = encodeWithSystem(b, (if o.format == efAvif: "avif" else: "heic"),
                                (if o.quality <= 0: 80 else: clamp(o.quality, 1, 100)))
    if data.len == 0: raise newException(IOError, $o.format & " cannot be written on this system")
    data
  of efExr:
    # (light: half floats, zipped -- as most programs write it)
    let light = if f.light.len == w * h * 4: f.light else: lightOf(b.px)
    writeExr(w, h, light, half = true, compression = "zip")
  else: ""

proc exportAnimation*(d: Doc; path: string; webpFrames: proc (frames: seq[tuple[bmp: Bitmap; delayMs: int]];
                      loop: int): string = nil) =
  ## The animation (the Timeline's frames; none: the image) saved as an
  ## animated GIF -- or, through `webpFrames`, a WebP.
  let shots = d.animationFrames()
  let loop = if d.animLoop <= 0: 0 else: d.animLoop
  var data: string
  if webpFrames != nil:
    var fr: seq[tuple[bmp: Bitmap; delayMs: int]]
    for (px, delay) in shots:
      let b = newBitmap(d.w, d.h)
      b.px = px
      fr.add (b, max(10, delay))
    data = webpFrames(fr, loop)
  else:
    var fr: seq[tuple[px: seq[uint32]; delayMs: int]]
    for (px, delay) in shots: fr.add (px, max(10, delay))
    data = encodeGifFrames(d.w, d.h, fr, loop = (if loop == 1: -1 else: loop))
  let tmp = path & ".part"
  writeFile(tmp, data)
  moveFile(tmp, path)

proc exportPicture*(d: Doc; path: string; o: ExportOptions) =
  ## Saves the image to `path` in a format, with its options (the layers
  ## mixed but for Photoshop and Retro Photo).
  case o.format
  of efPsd:
    d.savePsd(path)
    return
  of efRpd:
    d.saveRpd(path)
    return
  else: discard
  let data = encodeFlat(d.flatExport(o), o)
  let tmp = path & ".part"
  writeFile(tmp, data)
  moveFile(tmp, path)

# ---- pictures of documents, without opening them ---------------------------------------------------------

proc psdPreview*(path: string; maxW = 512; maxH = 512): Bitmap =
  ## The small picture a Photoshop file (.psd, .psb) carries -- its
  ## thumbnail, read without the rest of the file; without one (and not too
  ## big), its merged picture. Nil when there is neither.
  try:
    var f: File
    if not open(f, path): return nil
    defer: f.close()
    proc be(s: string; at, n: int): int =
      for k in 0 ..< n: result = (result shl 8) or ord(s[at + k])
    var head = newString(26)
    if f.readBuffer(addr head[0], 26) != 26 or head[0 .. 3] != "8BPS": return nil
    var lenBuf = newString(4)
    if f.readBuffer(addr lenBuf[0], 4) != 4: return nil
    f.setFilePos(f.getFilePos + be(lenBuf, 0, 4))        # (the color mode's data)
    if f.readBuffer(addr lenBuf[0], 4) != 4: return nil
    let resLen = be(lenBuf, 0, 4)
    if resLen > 0 and resLen < 64 * 1024 * 1024:
      var res = newString(resLen)
      if f.readBuffer(addr res[0], resLen) == resLen:
        var p = 0
        while p + 12 <= resLen and res[p ..< p + 4] == "8BIM":
          let id = be(res, p + 4, 2)
          var q = p + 6
          let nameLen = ord(res[q])
          q += 1 + nameLen
          if (1 + nameLen) mod 2 == 1: inc q
          if q + 4 > resLen: break
          let size = be(res, q, 4)
          q += 4
          if q + size > resLen: break
          if id in [1036, 1033] and size > 28:
            # (the thumbnail: a JPEG after 28 bytes about it)
            let b = decodeJpeg(res[q + 28 ..< q + size])
            if b != nil and b.w > 0:
              if id == 1033:
                # (Photoshop 4's: blue and red swapped)
                for px in b.px.mitems:
                  px = (px and 0xFF00FF00'u32) or ((px and 0xFF) shl 16) or ((px shr 16) and 0xFF)
              return b
          p = q + size + (size and 1)
    if getFileSize(path) < 96 * 1024 * 1024:
      let doc = readPsd(readFile(path))
      if doc.composite.len == doc.w * doc.h and doc.w > 0:
        result = newBitmap(doc.w, doc.h)
        result.px = doc.composite
        result.changed()
  except CatchableError, Defect: result = nil

proc addDocumentPreviews*() =
  ## Teaches the file widgets (lists, previews, Open dialogs) to show the
  ## pictures of Retro Photo and Photoshop documents.
  addPictureReader([".rpd", ".rp3"], proc (path: string; maxW, maxH: int): Bitmap {.nimcall, gcsafe.} =
    {.cast(gcsafe).}: rpdPreview(path, maxW, maxH))
  addPictureReader([".psd", ".psb"], proc (path: string; maxW, maxH: int): Bitmap {.nimcall, gcsafe.} =
    {.cast(gcsafe).}: psdPreview(path, maxW, maxH))
  addPdfPreviews()

# ---- Photoshop's fonts: PostScript names ------------------------------------------------------------

proc guidOf(data: string; salt = ""): string =
  ## A GUID made from bytes (the same bytes, the same GUID).
  var h1 = 0xcbf29ce484222325'u64
  var h2 = 0x9e3779b97f4a7c15'u64
  for c in salt:
    h1 = (h1 xor uint64(ord(c))) * 0x100000001b3'u64
    h2 = (h2 xor uint64(ord(c))) * 0xff51afd7ed558ccd'u64
  for c in data:
    h1 = (h1 xor uint64(ord(c))) * 0x100000001b3'u64
    h2 = (h2 xor uint64(ord(c))) * 0xff51afd7ed558ccd'u64
  h2 = h2 xor (h2 shr 29)
  let x = (toHex(h1, 16) & toHex(h2, 16)).toLowerAscii
  x[0 .. 7] & "-" & x[8 .. 11] & "-4" & x[13 .. 15] & "-a" & x[17 .. 19] & "-" & x[20 .. 31]

proc be16At(s: string; i: int): int =
  if i >= 0 and i + 2 <= s.len: (ord(s[i]) shl 8) or ord(s[i + 1]) else: 0

proc be32At(s: string; i: int): int =
  if i >= 0 and i + 4 <= s.len: (ord(s[i]) shl 24) or (ord(s[i + 1]) shl 16) or (ord(s[i + 2]) shl 8) or ord(s[i + 3])
  else: 0

proc fontNames(data: string; at: int): Table[int, string] =
  ## The names of the font whose table directory is at `at` (name ID:
  ## text; 1 family, 2 style, 6 PostScript name, 16 and 17 the typographic
  ## family and style).
  let n = be16At(data, at + 4)
  for k in 0 ..< min(n, 200):
    let rec = at + 12 + 16 * k
    if rec + 16 > data.len or data[rec ..< rec + 4] != "name": continue
    let off = be32At(data, rec + 8)
    let count = be16At(data, off + 2)
    let strs = off + be16At(data, off + 4)
    var score: Table[int, int]
    for j in 0 ..< min(count, 4000):
      let r = off + 6 + 12 * j
      let plat = be16At(data, r)
      let enc = be16At(data, r + 2)
      let lang = be16At(data, r + 4)
      let id = be16At(data, r + 6)
      let ln = be16At(data, r + 8)
      let s0 = strs + be16At(data, r + 10)
      if id notin [1, 2, 6, 16, 17] or s0 < 0 or s0 + ln > data.len: continue
      var text = ""
      var sc = 0
      if plat in [0, 3]:
        var q = 0
        while q + 1 < ln:
          text.add Rune(be16At(data, s0 + q)).toUTF8
          q += 2
        sc = if plat == 3 and lang == 0x409: 3 else: 2
      elif plat == 1 and enc == 0:
        text = data[s0 ..< s0 + ln]
        sc = 1
      if text.len > 0 and sc > score.getOrDefault(id, 0):
        score[id] = sc
        result[id] = text
    break

var psNames: Table[string, string]

proc postScriptName*(family, style: string): string =
  ## The PostScript name of a font, as Photoshop names fonts
  ## ("FreeSans-Bold"): the font's own when it is installed; else made
  ## from its family and style ("Myriad Pro", "Bold": "MyriadPro-Bold").
  let fam = if family.len == 0: "FreeSans" else: family
  let key = fam & "\t" & style
  if psNames.hasKey(key): return psNames[key]
  if fam in fontFamilies():
    # (installed: the face drawn with -- the style's, or the nearest)
    try:
      let data = fontData(fontFace(fam, style).face)
      var dirs = @[0]
      if data.startsWith("ttcf"):
        dirs = @[]
        for i in 0 ..< min(be32At(data, 8), 64): dirs.add be32At(data, 12 + 4 * i)
      for at in dirs:
        let nm = fontNames(data, at)
        let f = nm.getOrDefault(16, nm.getOrDefault(1, ""))
        let s = nm.getOrDefault(17, nm.getOrDefault(2, ""))
        if dirs.len == 1 or (f == fam and s == style):
          result = nm.getOrDefault(6, "").replace(" ", "")
          if result.len > 0: break
    except CatchableError, Defect: result = ""
  if result.len == 0:
    result = fam.replace(" ", "")
    let st = style.replace(" ", "")
    if st.len > 0: result.add "-" & st
  psNames[key] = result

proc spaced(s: string): string =
  ## "MyriadPro" -> "Myriad Pro".
  for i, c in s:
    if i > 0 and c in {'A' .. 'Z'} and s[i - 1] in {'a' .. 'z'}: result.add ' '
    result.add c

var psFonts: Table[string, tuple[family, style: string]]

proc fontOfPostScript*(ps: string): tuple[family, style: string] =
  ## The family and style of the font a PostScript name names
  ## ("FreeSans-Bold": "FreeSans", "Bold"); one not installed: made
  ## from the name ("MyriadPro-Bold": "Myriad Pro", "Bold"; "ArialMT":
  ## "Arial MT", no style) -- which `postScriptName` makes the same name
  ## again.
  if psFonts.hasKey(ps): return psFonts[ps]
  let dash = ps.find('-')
  let famPart = if dash > 0: ps[0 ..< dash] else: ps
  let stylePart = if dash > 0: ps[dash + 1 .. ^1] else: ""
  proc squash(s: string): string = s.replace(" ", "").toLowerAscii
  let fp = squash(famPart)
  block search:
    if fp.len > 0:
      for fam in fontFamilies():
        let f = squash(fam)
        if f.len == 0 or not fp.startsWith(f): continue
        for st in fontStyles(fam):
          if postScriptName(fam, st) == ps:
            result = (fam, st)
            break search
        if fp == f:
          for st in fontStyles(fam):
            let s = squash(st)
            if s == squash(stylePart) or (stylePart.len == 0 and s in ["regular", "book", "normal", "roman"]):
              result = (fam, st)
              break search
    result = (spaced(famPart), spaced(stylePart))
  psFonts[ps] = result

# ---- Photoshop's type layers: EngineData ------------------------------------------------------------

const psAlignOf: array[TextAlign, int] = [0, 2, 1, 3, 5, 4, 6]
  ## (Photoshop's Justification of each of ours: 0 left, 1 right, 2 center,
  ## 3 justify last left, 4 last right, 5 last centered, 6 all)

const warpKeys: array[WarpStyle, string] = ["warpNone", "warpArc", "warpArcLower", "warpArcUpper", "warpArch",
  "warpBulge", "warpShellLower", "warpShellUpper", "warpFlag", "warpWave", "warpFish", "warpRise", "warpFisheye",
  "warpInflate", "warpSqueeze", "warpTwist"]

proc lookAlign(a: TextAlign; rtl: bool): TextAlign =
  ## Our alignments say where lines start and end (right to left, Left is
  ## at the right); Photoshop's where they look: one to the other (both
  ## ways, it is its own inverse).
  if not rtl: return a
  case a
  of textLeft: textRight
  of textRight: textLeft
  of justifyLeft: justifyRight
  of justifyRight: justifyLeft
  else: a

proc isRtl(t: TextData): bool =
  t.para.rtl == 2 or (t.para.rtl == 0 and strongDir(t.plainText) == 1)

proc utf16Len(s: string): int =
  for r in s.runes: result += (if int(r) >= 0x10000: 2 else: 1)

proc engineColor(c: uint32): EngineValue =
  eDict(("Type", eInt(1)), ("Values", eFloats(float(c shr 24) / 255, float((c shr 16) and 255) / 255,
                                               float((c shr 8) and 255) / 255, float(c and 255) / 255)))

proc styleSheetOf(st: CharStyle; font: int): EngineValue =
  ## A character style as Photoshop's StyleSheetData (all its keys, as it
  ## writes them).
  let size = st.size.float
  let baseline = if st.script == scSuper: 1 elif st.script == scSub: 2 else: 0
  eDict(("Font", eInt(font)), ("FontSize", eFloat(size)), ("FauxBold", eBool(st.fauxBold)),
        ("FauxItalic", eBool(st.fauxItalic)), ("AutoLeading", eBool(st.leading <= 0)),
        ("Leading", eFloat(if st.leading > 0: st.leading.float else: size * 1.2)),
        ("HorizontalScale", eFloat(if st.hScale > 0: st.hScale.float else: 1.0)),
        ("VerticalScale", eFloat(if st.vScale > 0: st.vScale.float else: 1.0)),
        ("Tracking", eInt(st.tracking)), ("AutoKerning", eBool(not st.noKerning)), ("Kerning", eInt(0)),
        ("BaselineShift", eFloat(st.baselineShift.float)),
        ("FontCaps", eInt(if st.allCaps: 2 elif st.smallCaps: 1 else: 0)), ("FontBaseline", eInt(baseline)),
        ("Underline", eBool(st.underline)), ("Strikethrough", eBool(st.strike)), ("Ligatures", eBool(true)),
        ("DLigatures", eBool(false)), ("BaselineDirection", eInt(2)), ("Tsume", eFloat(0)),
        ("StyleRunAlignment", eInt(2)), ("Language", eInt(0)), ("NoBreak", eBool(false)),
        ("FillColor", engineColor(st.color)), ("StrokeColor", engineColor(0xFF000000'u32)),
        ("FillFlag", eBool(true)), ("StrokeFlag", eBool(false)), ("FillFirst", eBool(true)),
        ("YUnderline", eInt(1)), ("OutlineWidth", eFloat(1)), ("CharacterDirection", eInt(0)),
        ("HindiNumbers", eBool(st.digits == 1)), ("Kashida", eInt(1)), ("DiacriticPos", eInt(2)))

proc paraPropsOf(p: ParaStyle; rtl: bool): EngineValue =
  ## A paragraph style as Photoshop's paragraph Properties; right to left:
  ## ParagraphDirection 1 (the Adobe text engine's kRightToLeft), its
  ## start indent at the right.
  let (startI, endI) = if rtl: (p.indentRight, p.indentLeft) else: (p.indentLeft, p.indentRight)
  result = eDict(("Justification", eInt(psAlignOf[lookAlign(p.align, rtl)])),
                 ("FirstLineIndent", eFloat(p.indentFirst.float)), ("StartIndent", eFloat(startI.float)),
                 ("EndIndent", eFloat(endI.float)), ("SpaceBefore", eFloat(p.spaceBefore.float)),
                 ("SpaceAfter", eFloat(p.spaceAfter.float)), ("AutoHyphenate", eBool(false)),
                 ("HyphenatedWordSize", eInt(6)), ("PreHyphen", eInt(2)), ("PostHyphen", eInt(2)),
                 ("ConsecutiveHyphens", eInt(8)), ("Zone", eFloat(36)), ("WordSpacing", eFloats(0.8, 1.0, 1.33)),
                 ("LetterSpacing", eFloats(0.0, 0.0, 0.0)), ("GlyphSpacing", eFloats(1.0, 1.0, 1.0)),
                 ("AutoLeading", eFloat(1.2)), ("LeadingType", eInt(0)), ("Hanging", eBool(false)),
                 ("Burasagari", eBool(false)), ("KinsokuOrder", eInt(0)), ("EveryLineComposer", eBool(false)))
  if rtl: result["ParagraphDirection"] = eInt(1)

proc textResources(fonts: seq[string]; normal, props: EngineValue): EngineValue =
  ## The ResourceDict of a type layer: Photoshop's kinsoku and mojikumi
  ## sets, the normal sheets, the fonts.
  var fontSet = eList()
  for f in fonts:
    fontSet.items.add eDict(("Name", eText(f)), ("Script", eInt(0)),
                            ("FontType", eInt(if f == "AdobeInvisFont": 0 else: 1)), ("Synthetic", eInt(0)))
  eDict(("KinsokuSet", eList(
           eDict(("Name", eText("PhotoshopKinsokuHard")),
                 ("NoStart", eText("、。，．・：；？！ー―’”）〕］｝〉》」』】ヽヾゝゞ々ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ゛゜?!)]},.:;℃℉¢％‰")),
                 ("NoEnd", eText("‘“（〔［｛〈《「『【([{￥＄£＠§〒＃")), ("Keep", eText("―‥")),
                 ("Hanging", eText("、。.,"))),
           eDict(("Name", eText("PhotoshopKinsokuSoft")),
                 ("NoStart", eText("、。，．・：；？！’”）〕］｝〉》」』】ヽヾゝゞ々")),
                 ("NoEnd", eText("‘“（〔［｛〈《「『【")), ("Keep", eText("―‥")), ("Hanging", eText("、。.,"))))),
        ("MojiKumiSet", eList(eDict(("InternalName", eText("Photoshop6MojiKumiSet1"))),
                              eDict(("InternalName", eText("Photoshop6MojiKumiSet2"))),
                              eDict(("InternalName", eText("Photoshop6MojiKumiSet3"))),
                              eDict(("InternalName", eText("Photoshop6MojiKumiSet4"))))),
        ("TheNormalStyleSheet", eInt(0)), ("TheNormalParagraphSheet", eInt(0)),
        ("ParagraphSheetSet", eList(eDict(("Name", eText("Normal RGB")), ("DefaultStyleSheet", eInt(0)),
                                          ("Properties", props)))),
        ("StyleSheetSet", eList(eDict(("Name", eText("Normal RGB")), ("StyleSheetData", normal)))),
        ("FontSet", fontSet), ("SuperscriptSize", eFloat(0.583)), ("SuperscriptPosition", eFloat(0.333)),
        ("SubscriptSize", eFloat(0.583)), ("SubscriptPosition", eFloat(0.333)), ("SmallCapSize", eFloat(0.7)))

proc engineDataOf*(t: TextData): EngineValue =
  ## A text as Photoshop's EngineData (its sizes in pixels: the type
  ## layer's transform is the identity, moved to `t.x`, `t.y`): the
  ## characters (newlines as "\r", one more at the end, as Photoshop ends
  ## a text), a style run for each span, a paragraph run for each
  ## paragraph, the box (text in a box) or the point, the fonts by their
  ## PostScript names.
  let rtl = t.isRtl
  var fonts: seq[string]
  proc fontIndex(st: CharStyle): int =
    let ps = postScriptName(st.family, st.style)
    result = fonts.find(ps)
    if result < 0:
      fonts.add ps
      result = fonts.high
  var text = ""
  var runs = eList()
  var lens = eList()
  for s in t.spans:
    if s.text.len == 0: continue
    let txt = s.text.replace("\r\n", "\n").replace('\r', '\n')
    text.add txt
    runs.items.add eDict(("StyleSheet", eDict(("StyleSheetData", styleSheetOf(s.style, fontIndex(s.style))))))
    lens.items.add eInt(utf16Len(txt))
  let first = if t.spans.len > 0: t.spans[0].style else: defaultStyle()
  if runs.len == 0:
    runs.items.add eDict(("StyleSheet", eDict(("StyleSheetData", styleSheetOf(first, fontIndex(first))))))
    lens.items.add eInt(0)
  text.add '\n'
  lens.items[^1].n += 1
  let psText = text.replace('\n', '\r')
  let props = paraPropsOf(t.para, rtl)
  var paraRuns = eList()
  var paraLens = eList()
  let paras = psText.split('\r')
  for k in 0 ..< paras.high:
    paraRuns.items.add eDict(("ParagraphSheet", eDict(("DefaultStyleSheet", eInt(0)), ("Properties", props))),
                             ("Adjustments", eDict(("Axis", eFloats(1.0, 0.0, 1.0)), ("XY", eFloats(0.0, 0.0)))))
    paraLens.items.add eInt(utf16Len(paras[k]) + 1)
  let normal = styleSheetOf(first, fontIndex(first))
  fonts.add "AdobeInvisFont"
  let boxed = t.boxW > 0 and t.boxH > 0
  let shapeType = ord(boxed)
  var ps = eDict(("ShapeType", eInt(shapeType)))
  if boxed: ps["BoxBounds"] = eFloats(0.0, 0.0, t.boxW.float, t.boxH.float)
  else: ps["PointBase"] = eFloats(0.0, 0.0)
  ps["Base"] = eDict(("ShapeType", eInt(shapeType)), ("TransformPoint0", eFloats(1.0, 0.0)),
                     ("TransformPoint1", eFloats(0.0, 1.0)), ("TransformPoint2", eFloats(0.0, 0.0)))
  let wd = if t.vertical: 2 else: 0
  let rendered = eDict(("Version", eInt(1)), ("Shapes", eDict(("WritingDirection", eInt(wd)), ("Children", eList(
    eDict(("ShapeType", eInt(shapeType)), ("Procession", eInt(ord(t.vertical))),
          ("Lines", eDict(("WritingDirection", eInt(wd)), ("Children", eList()))),
          ("Cookie", eDict(("Photoshop", ps)))))))))
  let gridColor = eDict(("Type", eInt(1)), ("Values", eFloats(0.0, 0.0, 0.0, 1.0)))
  let engineDict = eDict(
    ("Editor", eDict(("Text", eText(psText)))),
    ("ParagraphRun", eDict(("DefaultRunData", eDict(("ParagraphSheet", eDict(("DefaultStyleSheet", eInt(0)),
                                                                              ("Properties", eDict()))),
                                                    ("Adjustments", eDict(("Axis", eFloats(1.0, 0.0, 1.0)),
                                                                          ("XY", eFloats(0.0, 0.0)))))),
                           ("RunArray", paraRuns), ("RunLengthArray", paraLens), ("IsJoinable", eInt(1)))),
    ("StyleRun", eDict(("DefaultRunData", eDict(("StyleSheet", eDict(("StyleSheetData", eDict()))))),
                       ("RunArray", runs), ("RunLengthArray", lens), ("IsJoinable", eInt(2)))),
    ("GridInfo", eDict(("GridIsOn", eBool(false)), ("ShowGrid", eBool(false)), ("GridSize", eFloat(18)),
                       ("GridLeading", eFloat(22)), ("GridColor", gridColor), ("GridLeadingFillColor", gridColor),
                       ("AlignLineHeightToGridFlags", eBool(false)))),
    ("AntiAlias", eInt(if t.antialias: 3 else: 0)),
    ("UseFractionalGlyphWidths", eBool(true)),
    ("Rendered", rendered))
  let res = textResources(fonts, normal, props)
  eDict(("EngineDict", engineDict), ("ResourceDict", res), ("DocumentResources", res))

proc typeLayerData*(t: TextData; drawn: Rect): string =
  ## A type layer's 'TySh' for Photoshop: transform (the identity, moved to
  ## the text's point or box), its text descriptor (what it says, its
  ## EngineData, `drawn` -- where its pixels are -- as its bounds), its warp;
  ## and, under "retroText" (a key Photoshop does not know), the text as
  ## ours, for what Photoshop has no word for (columns, text on a path,
  ## Persian digits...).
  let tr = [1.0, 0, 0, 1, t.x.float, t.y.float]
  let eng = engineDataText(engineDataOf(t))
  var b = (0.0, -t.styleAt(0).size.float, 0.0, 0.0)
  if drawn.w > 0 and drawn.h > 0:
    b = (drawn.x.float - t.x, drawn.y.float - t.y, float(drawn.x + drawn.w) - t.x, float(drawn.y + drawn.h) - t.y)
  elif t.boxW > 0 and t.boxH > 0: b = (0.0, 0.0, t.boxW.float, t.boxH.float)
  proc box(cls: string): PsdValue =
    psdObj(cls, ("Left", psdUnit("#Pnt", b[0])), ("Top ", psdUnit("#Pnt", b[1])), ("Rght", psdUnit("#Pnt", b[2])),
           ("Btom", psdUnit("#Pnt", b[3])))
  let desc = psdObj("TxLr", ("Txt ", psdText(t.plainText.replace("\r\n", "\r").replace('\n', '\r'))),
                    ("textGridding", psdEnum("textGridding", "None")),
                    ("Ornt", psdEnum("Ornt", if t.vertical: "Vrtc" else: "Hrzn")),
                    ("AntA", psdEnum("Annt", if t.antialias: "AnSm" else: "Anno")),
                    ("bounds", box("bounds")), ("boundingBox", box("boundingBox")), ("TextIndex", psdLong(0)),
                    ("EngineData", PsdValue(kind: pkRaw, raw: eng)), ("retroText", psdText($t.toJson)),
                    ("retroEngine", psdText(guidOf(eng, "EngineData"))))
  let warp = psdObj("warp", ("warpStyle", psdEnum("warpStyle", warpKeys[t.warp.style])),
                    ("warpValue", psdNum(t.warp.bend.float)), ("warpPerspective", psdNum(t.warp.hDistort.float)),
                    ("warpPerspectiveOther", psdNum(t.warp.vDistort.float)),
                    ("warpRotate", psdEnum("Ornt", if t.warp.vertical: "Vrtc" else: "Hrzn")))
  typeToolData(tr, desc, warp)

proc engineColorOf(c: EngineValue): uint32 =
  ## Photoshop's FillColor (Type 0 gray, 1 RGB, 2 CMYK; alpha first) as
  ## 0xAARRGGBB.
  if c == nil: return 0xFF000000'u32
  let v = c["Values"]
  proc at(i: int): float = clamp(v[i].num(0), 0.0, 1.0)
  proc b8(x: float): uint32 = uint32(clamp(int(round(x * 255)), 0, 255))
  var a = b8(at(0))
  if a == 0: a = 255                       # (no alpha given: opaque)
  case int(c["Type"].num(1))
  of 0:
    let g = b8(at(1))
    (a shl 24) or (g shl 16) or (g shl 8) or g
  of 2:
    (a shl 24) or (printed(int(b8(at(1))), int(b8(at(2))), int(b8(at(3))), int(b8(at(4)))) and 0xFFFFFF'u32)
  else: (a shl 24) or (b8(at(1)) shl 16) or (b8(at(2)) shl 8) or b8(at(3))

proc textOfEngine*(e: EngineValue; tr: array[6, float]; desc, warp: PsdValue): TextData =
  ## Photoshop's EngineData (with the type layer's transform `tr`, its text
  ## descriptor and warp) as our text: its sizes times the transform's
  ## scale (Photoshop keeps points and scales them), a span for each style
  ## run (alike ones joined), the first paragraph's style, the box or
  ## point, the warp.
  result.antialias = true
  let ed = e["EngineDict"]
  let rd = if e["ResourceDict"] != nil: e["ResourceDict"] else: e["DocumentResources"]
  let sx = if tr[0] > 0: tr[0] else: 1.0
  let sy = if tr[3] > 0: tr[3] else: 1.0
  let fontSet = rd["FontSet"]
  let normalStyle = rd["StyleSheetSet"][int(rd["TheNormalStyleSheet"].num(0))]["StyleSheetData"]
  let normalPara = rd["ParagraphSheetSet"][int(rd["TheNormalParagraphSheet"].num(0))]["Properties"]
  let pr = ed["ParagraphRun"]["RunArray"][0]
  let pp = if pr != nil: pr["ParagraphSheet"]["Properties"] else: nil
  proc pget(k: string): EngineValue =
    result = pp[k]
    if result == nil: result = normalPara[k]
  let autoFactor = pget("AutoLeading").num(1.2)
  let runes = toRunes(ed["Editor"]["Text"].text)
  let sr = ed["StyleRun"]
  var at = 0
  proc chunk(n16: int): string =
    var u = 0
    while u < n16 and at < runes.len:
      let r = runes[at]
      result.add(if int(r) in [3, 13]: "\n" else: r.toUTF8)    # (3: a line break in a paragraph)
      u += (if int(r) >= 0x10000: 2 else: 1)
      inc at
  proc fontOf(i: int): string =
    let f = fontSet[i]
    if f != nil: f["Name"].text else: ""
  let normalFont = fontOf(int(normalStyle["Font"].num(0)))
  for i in 0 ..< sr["RunArray"].len:
    let s = chunk(int(sr["RunLengthArray"][i].num(0)))
    let sd = sr["RunArray"][i]["StyleSheet"]["StyleSheetData"]
    proc get(k: string): EngineValue =
      result = sd[k]
      if result == nil: result = normalStyle[k]
    var st = defaultStyle()
    var ps = if get("Font") != nil: fontOf(int(get("Font").num(0))) else: normalFont
    if ps.len == 0 or ps == "AdobeInvisFont": ps = normalFont
    (st.family, st.style) = fontOfPostScript(ps)
    let size = get("FontSize").num(12) * sy
    st.size = float32(size)
    st.leading = if get("AutoLeading").flag(true):
                   (if abs(autoFactor - 1.2) > 1e-3: float32(size * autoFactor) else: 0'f32)
                 else: float32(get("Leading").num(size * 1.2) * sy)
    st.tracking = int(round(get("Tracking").num(0)))
    st.noKerning = not get("AutoKerning").flag(true)
    st.baselineShift = float32(get("BaselineShift").num(0) * sy)
    st.hScale = float32(get("HorizontalScale").num(1) * sx / sy)
    st.vScale = float32(get("VerticalScale").num(1))
    st.fauxBold = get("FauxBold").flag
    st.fauxItalic = get("FauxItalic").flag
    let caps = int(get("FontCaps").num(0))
    st.allCaps = caps == 2
    st.smallCaps = caps == 1
    st.underline = get("Underline").flag
    st.strike = get("Strikethrough").flag
    let fb = int(get("FontBaseline").num(0))
    st.script = if fb == 1: scSuper elif fb == 2: scSub else: scNormal
    st.digits = ord(get("HindiNumbers").flag)
    st.color = engineColorOf(get("FillColor"))
    if result.spans.len > 0 and result.spans[^1].style == st: result.spans[^1].text.add s
    else: result.spans.add TextSpan(text: s, style: st)
  if at < runes.len:
    # (characters past the runs: in the last style)
    let s = chunk(int.high)
    if result.spans.len > 0: result.spans[^1].text.add s
    else: result.spans.add TextSpan(text: s, style: defaultStyle())
  # (the paragraph's end Photoshop puts after the text: not ours)
  while result.spans.len > 0:
    if result.spans[^1].text.endsWith("\n"):
      result.spans[^1].text.setLen(result.spans[^1].text.len - 1)
      if result.spans[^1].text.len == 0 and result.spans.len > 1: result.spans.setLen(result.spans.len - 1)
    break
  # the paragraphs' style
  let rtlDir = pget("ParagraphDirection").num(0) == 1
  let natural = strongDir(result.plainText) == 1
  result.para.rtl = if rtlDir == natural: 0 elif rtlDir: 2 else: 1
  const fromPs = [textLeft, textRight, textCenter, justifyLeft, justifyRight, justifyCenter, justifyAll]
  result.para.align = lookAlign(fromPs[clamp(int(pget("Justification").num(0)), 0, 6)], rtlDir)
  var startI = float32(pget("StartIndent").num(0) * sx)
  var endI = float32(pget("EndIndent").num(0) * sx)
  if rtlDir: swap(startI, endI)
  result.para.indentLeft = startI
  result.para.indentRight = endI
  result.para.indentFirst = float32(pget("FirstLineIndent").num(0) * sx)
  result.para.spaceBefore = float32(pget("SpaceBefore").num(0) * sy)
  result.para.spaceAfter = float32(pget("SpaceAfter").num(0) * sy)
  # where: a box, or a point
  let ph = ed["Rendered"]["Shapes"]["Children"][0]["Cookie"]["Photoshop"]
  let bb = ph["BoxBounds"]
  if ph != nil and int(ph["ShapeType"].num(0)) == 1 and bb.len == 4:
    result.x = float32(tr[4] + bb[0].num * sx)
    result.y = float32(tr[5] + bb[1].num * sy)
    result.boxW = float32((bb[2].num - bb[0].num) * sx)
    result.boxH = float32((bb[3].num - bb[1].num) * sy)
  else:
    let pb = ph["PointBase"]
    result.x = float32(tr[4] + pb[0].num(0) * sx)
    result.y = float32(tr[5] + pb[1].num(0) * sy)
  result.vertical = desc["Ornt"].enumValue == "Vrtc" or int(ed["Rendered"]["Shapes"]["WritingDirection"].num(0)) == 2
  result.antialias = desc["AntA"].enumValue != "Anno"
  if warp != nil:
    let ws = warp["warpStyle"].enumValue
    for k in WarpStyle:
      if warpKeys[k] == ws: result.warp.style = k
    if result.warp.style != wsNone:
      result.warp.bend = int(round(warp["warpValue"].num(0)))
      result.warp.hDistort = int(round(warp["warpPerspective"].num(0)))
      result.warp.vDistort = int(round(warp["warpPerspectiveOther"].num(0)))
      result.warp.vertical = warp["warpRotate"].enumValue == "Vrtc"

proc textOfPsd*(P: PsdLayer; retro = true): tuple[ok: bool; text: TextData] =
  ## A Photoshop type layer's text as ours (from its EngineData, transform,
  ## warp). Not `ok` when it has none, or it is turned or skewed (ours
  ## cannot be: it stays pixels). With `retro`, the text Retro Photo kept
  ## beside it ("retroText") -- when its EngineData is still the one it
  ## was written with ("retroEngine", a hash of it) and so is its
  ## transform: Photoshop has not changed it since.
  if P.textDesc == nil: return
  let ed = P.textDesc["EngineData"]
  if ed == nil or ed.kind != pkRaw: return
  let tr = P.textTransform
  if abs(tr[1]) > 1e-6 or abs(tr[2]) > 1e-6 or tr[0] <= 0 or tr[3] <= 0: return
  let e = try: parseEngineData(ed.raw) except PsdError, ValueError, IndexDefect: return
  let t = try: textOfEngine(e, tr, P.textDesc, P.textWarp) except CatchableError, IndexDefect: return
  if t.spans.len == 0: return
  result = (true, t)
  let rj = P.textDesc["retroText"]
  let rh = P.textDesc["retroEngine"]
  if retro and rj != nil and rj.kind == pkText and rh != nil and rh.kind == pkText:
    try:
      let rt = textFrom(parseJson(rj.s))
      var raw = ed.raw
      while raw.len > 0 and raw[^1] == '\0': raw.setLen(raw.len - 1)
      if rt.spans.len > 0 and tr == [1.0, 0, 0, 1, rt.x.float, rt.y.float] and
         guidOf(raw, "EngineData") == rh.s:
        result.text = rt
    except CatchableError: discard

# ---- Photoshop's Smart Objects: placed layers ---------------------------------------------------------

var tempCount = 0

proc tempPath(ext: string): string =
  inc tempCount
  getTempDir() / ("retro-psd-" & $getCurrentProcessId() & "-" & $tempCount & ext)

proc rpdBytes(d: Doc): string =
  ## A document as the bytes of a ".rpd" (what a Smart Object with layers
  ## keeps).
  let tmp = tempPath(".rpd")
  try:
    d.saveRpd(tmp)
    result = readFile(tmp)
  finally:
    try: removeFile(tmp) except OSError: discard

proc docOfRpdBytes(data: string): Doc =
  let tmp = tempPath(".rpd")
  try:
    writeFile(tmp, data)
    result = loadRpd(tmp)
  finally:
    try: removeFile(tmp) except OSError: discard

proc smartFile(s: SmartData): tuple[data, fileType, ext: string] =
  ## The file a Smart Object's picture goes in: a .psb of its document
  ## when it is one with layers (its merged picture its own), else a PNG.
  if s.file.len > 0:
    try:
      let sub = docOfRpdBytes(s.file)
      var p = psdOf(sub)
      p.big = true
      if s.src.len == sub.w * sub.h and s.w == sub.w and s.h == sub.h: p.composite = s.src
      return (writePsd(p), "8BPB", ".psb")
    except CatchableError: discard
  var b = newBitmap(s.w, s.h)
  b.px = s.src
  (encodePng(b, level = 6), "png ", ".png")

proc smartJson(s: SmartData): string =
  ## What a Smart Object has that Photoshop's has not the same of: its
  ## name, Smart Filters, warp (kept under "retroSmart").
  var fs = newJArray()
  for f in s.filters:
    fs.add %*{"name": f.name, "args": f.args, "text": f.text, "opacity": f.opacity, "mode": $f.mode, "off": f.off}
  var j = %*{"name": s.name, "filters": fs}
  if s.warp.len > 0:
    var wa = newJArray()
    for c in s.warp: wa.add %*[c[0], c[1]]
    j["warp"] = wa
  $j

proc smartWarpDesc(w, h: int): PsdValue =
  psdObj("warp", ("warpStyle", psdEnum("warpStyle", "warpNone")), ("warpValue", psdNum(0)),
         ("warpPerspective", psdNum(0)), ("warpPerspectiveOther", psdNum(0)),
         ("warpRotate", psdEnum("Ornt", "Hrzn")),
         ("bounds", psdObj("classFloatRect", ("Top ", psdNum(0)), ("Left", psdNum(0)), ("Btom", psdNum(h.float)),
                           ("Rght", psdNum(w.float)))),
         ("uOrder", psdLong(4)), ("vOrder", psdLong(4)))

proc placedLayer*(s: SmartData; layerIndex: int; dpi: float): tuple[file: PsdLinkedFile; plLd, soLd: string] =
  ## A Smart Object as Photoshop's placed layer: the file it shows (its id
  ## a GUID of its bytes: the same picture, the same file), its 'PlLd' and
  ## 'SoLd' (its corners, size, resolution; its Smart Filters, name and
  ## warp under "retroSmart", a key Photoshop does not know).
  let (data, ftype, ext) = smartFile(s)
  let id = guidOf(data)
  var nm = if s.name.len > 0: s.name else: "Smart Object"
  if nm.splitFile.ext.len > 0: nm = nm.changeFileExt(ext) else: nm.add ext
  result.file = PsdLinkedFile(id: id, name: nm, fileType: ftype, data: data)
  var corners: array[8, float]
  for k in 0 .. 3:
    corners[2 * k] = s.quad[k][0]
    corners[2 * k + 1] = s.quad[k][1]
  var cl = PsdValue(kind: pkList)
  for v in corners: cl.list.add psdNum(v)
  let warp = smartWarpDesc(s.w, s.h)
  result.plLd = placedLayerData(id, corners, warp)
  let frac = psdObj("null", ("numerator", psdLong(0)), ("denominator", psdLong(600)))
  let desc = psdObj("null", ("Idnt", psdText(id)), ("placed", psdText(guidOf(data, "placed" & $layerIndex))),
                    ("PgNm", psdLong(1)), ("totalPages", psdLong(1)), ("Crop", psdLong(1)), ("frameStep", frac),
                    ("duration", frac), ("frameCount", psdLong(1)), ("Annt", psdLong(16)), ("Type", psdLong(2)),
                    ("Trnf", cl), ("nonAffineTransform", cl), ("warp", warp),
                    ("Sz  ", psdObj("Pnt ", ("Wdth", psdNum(s.w.float)), ("Hght", psdNum(s.h.float)))),
                    ("Rslt", psdUnit("#Rsl", max(1.0, dpi))), ("comp", psdLong(-1)),
                    ("compInfo", psdObj("null", ("compID", psdLong(-1)), ("originalCompID", psdLong(-1)))),
                    ("retroSmart", psdText(smartJson(s))))
  result.soLd = smartObjectData(desc)

proc smartOfPsd*(P: PsdLayer; p: PsdDoc): SmartData =
  ## A Photoshop placed layer as our Smart Object: the file embedded for it
  ## (PNG, JPEG, TIFF, or a .psd/.psb -- kept as a document with layers),
  ## its corners (SoLd's, or PlLd's); its Smart Filters, name and warp when
  ## Retro Photo kept them ("retroSmart"). Nil when it is not one, its file
  ## is not in the document (linked from outside) or not one we read.
  if P.placedId.len == 0: return nil
  var f: PsdLinkedFile
  var found = false
  for x in p.linked:
    if x.id == P.placedId:
      f = x
      found = true
      break
  if not found: return nil
  var src: seq[uint32]
  var w, h: int
  var file = ""
  let data = f.data
  try:
    if data.startsWith("\x89PNG") or data.startsWith("\xFF\xD8") or data.startsWith("II*\0") or
       data.startsWith("MM\0*"):
      let b = if data.startsWith("\x89PNG"): decodePng(data)
              elif data.startsWith("\xFF\xD8"): decodeJpeg(data)
              else: decodeTiff(data)
      if b == nil or b.w <= 0: return nil
      (src, w, h) = (b.px, b.w, b.h)
    elif data.startsWith("8BPS"):
      let sp = readPsd(data)
      (w, h) = (sp.w, sp.h)
      if sp.composite.len == w * h: src = sp.composite
      if sp.layers.len > 0:
        let sub = docOfPsd(sp, f.name.splitFile.name)
        if src.len != w * h: src = sub.flattened()
        file = rpdBytes(sub)
    else: return nil
  except CatchableError: return nil
  if src.len != w * h or w <= 0: return nil
  # its corners
  var c: seq[float]
  for key in ["nonAffineTransform", "Trnf"]:
    let v = P.smartDesc[key]
    if v != nil and v.kind == pkList and v.list.len == 8:
      for x in v.list: c.add x.num
      break
  if c.len != 8:
    for x in P.placedTransform: c.add x
  if c == newSeq[float](8): c = @[0.0, 0, w.float, 0, w.float, h.float, 0, h.float]
  var q: Quad
  for k in 0 .. 3: q[k] = (c[2 * k], c[2 * k + 1])
  result = SmartData(src: src, w: w, h: h, quad: q, name: f.name, file: file)
  let rj = P.smartDesc["retroSmart"]
  if rj != nil and rj.kind == pkText:
    try:
      let j = parseJson(rj.s)
      result.name = j{"name"}.getStr(result.name)
      for fj in j{"filters"}.getElems:
        var sf = SmartFilter(name: fj{"name"}.getStr, text: fj{"text"}.getStr,
                             opacity: clamp(fj{"opacity"}.getInt(100), 0, 100), off: fj{"off"}.getBool)
        for v in fj{"args"}.getElems: sf.args.add v.getFloat
        for m in BlendMode:
          if $m == fj{"mode"}.getStr: sf.mode = m
        result.filters.add sf
      for cj in j{"warp"}.getElems:
        if result.warp.len < 16: result.warp.add (cj{0}.getFloat, cj{1}.getFloat)
      if result.warp.len != 16: result.warp = @[]
    except CatchableError: discard

# ---- TIFF with layers ------------------------------------------------------------------------------

proc tiffLayersOf*(d: Doc): string =
  ## The document's layers as a TIFF keeps them for Photoshop (tag 37724:
  ## `encodeTiff`'s `photoshop`): as in a .psd -- type, Smart Objects and
  ## all -- at 8 bits.
  var p = psdOf(d, composite = false)
  p.depth = 8
  tiffLayerBlock(p)

proc docOfLayeredTiff*(data: string; name = "Untitled"): Doc =
  ## A TIFF that keeps Photoshop's layers (tag 37724) as a document with
  ## them; nil when it keeps none. Raises `PsdError` when they are damaged.
  let src = tiffImageSource(data)
  if src.layers.len == 0 or not src.layers.startsWith(tiffBlockHead): return nil
  let b = decodeTiff(data)
  if b == nil or b.w <= 0: return nil
  let mode = case src.photometric
             of 0, 1: pmGray
             of 5: pmCMYK
             else: pmRGB
  var p = readTiffLayers(src.layers, b.w, b.h, mode, src.littleEndian)
  if p.layers.len == 0: return nil
  p.composite = b.px
  docOfPsd(p, name)

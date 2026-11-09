## Pictures the kit does not decode itself, read by the system: HEIC and
## HEIF (an iPhone's photos), AVIF, and what else the device knows -- and,
## where the system can, written.
##
## Read with, in order:
## - Android: its own decoders (BitmapFactory: HEIF from Android 9, AVIF from
##   Android 12).
## - Linux and the BSDs: libheif (`libheif.so.1`) and libavif
##   (`libavif.so.16`), opened when first needed -- nothing to link, and
##   nothing missing if they are not installed.
## - macOS and iOS: ImageIO (HEIC from macOS 10.13 / iOS 11, AVIF from
##   macOS 13 / iOS 16).
## - Windows: WIC, with the codecs Windows has (HEIF and AVIF come with the
##   "HEIF Image Extensions", "HEVC Video Extensions" and "AV1 Video
##   Extension" from the Store).
## - Last, on the desktops: a converter program when one is installed
##   (`heif-convert`, `avifdec`, ImageMagick's `magick`, `ffmpeg`).
##
## ```nim
## let b = decodeWithSystem("/sdcard/DCIM/IMG_0042.heic")
## if b == nil: echo "this device cannot read it"
## if "avif" in systemEncodeExts():
##   writeFile("out.avif", encodeWithSystem(b, "avif", 80))
## ```

import std/[os, osproc, strutils]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import gfx, imaging
import uirelays/services
when not androidApp:
  import std/locks

const systemImageExts* = [".heic", ".heif", ".hif", ".avif"]
  ## What `decodeWithSystem` is for.

const
  MaxSide = 1 shl 15          ## (as large as `loadPicture` reads)
  MaxPixels = 1 shl 28

proc sizeOk(w, h: int): bool =
  w > 0 and h > 0 and w <= MaxSide and h <= MaxSide and w * h <= MaxPixels

# ---- pixels -------------------------------------------------------------------

proc finished(b: Bitmap): Bitmap =
  ## (whether all of it is opaque, and that it changed)
  var opaque = true
  for p in b.px:
    if (p shr 24) != 255:
      opaque = false
      break
  b.opaque = opaque
  b.changed()
  b

proc bitmapOf16(w, h: int; hi: openArray[uint16]): Bitmap =
  ## The 8-bit picture of R G B A 16-bit pixels (rounded).
  result = newBitmap(w, h)
  for i in 0 ..< w * h:
    template c(k: int): uint32 = (uint32(hi[4 * i + k]) * 255 + 32767) div 65535
    result.px[i] = (c(3) shl 24) or (c(0) shl 16) or (c(1) shl 8) or c(2)
  discard finished(result)

proc oriented[T](px: seq[T]; w, h, n, o: int): seq[T] =
  ## Pixels of `n` values each turned the way an EXIF orientation `o` (1 ..
  ## 8) says; for 5 .. 8 the picture is then `h` wide and `w` high.
  if o <= 1 or o > 8: return px
  let swap = o >= 5
  let ow = if swap: h else: w
  let oh = if swap: w else: h
  result = newSeq[T](px.len)
  for y in 0 ..< oh:
    for x in 0 ..< ow:
      var sx, sy: int
      case o
      of 2: (sx, sy) = (w - 1 - x, y)
      of 3: (sx, sy) = (w - 1 - x, h - 1 - y)
      of 4: (sx, sy) = (x, h - 1 - y)
      of 5: (sx, sy) = (y, x)
      of 6: (sx, sy) = (y, h - 1 - x)
      of 7: (sx, sy) = (w - 1 - y, h - 1 - x)
      else: (sx, sy) = (w - 1 - y, x)
      for k in 0 ..< n: result[(y * ow + x) * n + k] = px[(sy * w + sx) * n + k]

proc orientationOf(rotCcw: int; mirror: int): int =
  ## The EXIF orientation of turning a picture `rotCcw` quarter turns
  ## counter-clockwise and then mirroring it (-1 not; 0 top and bottom
  ## exchanged; 1 left and right) -- HEIF's `irot` and `imir`.
  const byTurn = [1, 8, 3, 6]
  let r = byTurn[rotCcw and 3]
  if mirror < 0: return r
  # (the mirror after the turn)
  const leftRight = [0, 2, 0, 4, 0, 0, 5, 0, 7]   # by r: 1 -> 2, 3 -> 4, 6 -> 5, 8 -> 7
  const topBottom = [0, 4, 0, 2, 0, 0, 7, 0, 5]
  if mirror == 1: leftRight[r] else: topBottom[r]

proc orientBitmap(b: Bitmap; hi: ptr seq[uint16]; o: int): Bitmap =
  ## `b` (and its 16-bit pixels, when there are) turned to orientation `o`.
  if o <= 1 or o > 8: return b
  let swap = o >= 5
  result = newBitmap(if swap: b.h else: b.w, if swap: b.w else: b.h)
  result.px = oriented(b.px, b.w, b.h, 1, o)
  if hi != nil and hi[].len == b.w * b.h * 4:
    hi[] = oriented(hi[], b.w, b.h, 4, o)
  discard finished(result)

proc isAvif(data: string): bool =
  ## An AVIF file by its `ftyp` box (its brand or one it is compatible with).
  if data.len < 16 or data[4 .. 7] != "ftyp": return false
  let size = min(data.len, (ord(data[0]) shl 24) or (ord(data[1]) shl 16) or
                           (ord(data[2]) shl 8) or ord(data[3]))
  if data[8 .. 11] in ["avif", "avis"]: return true
  var i = 16
  while i + 4 <= size:
    if data[i ..< i + 4] in ["avif", "avis"]: return true
    i += 4

proc encodeKind(ext: string): string =
  ## "heic" or "avif" for an extension of either (with or without the dot).
  let e = ext.toLowerAscii.strip(chars = {'.'}, trailing = false)
  if e in ["heic", "heif", "hif"]: "heic"
  elif e == "avif": "avif"
  else: ""

proc allOpaque(b: Bitmap): bool =
  for p in b.px:
    if (p shr 24) != 255: return false
  true

when not androidApp:
  var libLock: Lock
  initLock(libLock)

# ---- Linux and the BSDs: libheif and libavif ------------------------------------

const UseLibs = (defined(linux) or defined(freebsd) or defined(openbsd) or
                 defined(netbsd) or defined(dragonfly)) and not androidApp

when UseLibs:
  import std/dynlib

  # -- libheif (its C API; `struct heif_error` comes back by value) --

  type
    HeifError {.bycopy.} = object
      code, subcode: cint
      message: cstring
    HeifWriter {.bycopy.} = object
      apiVersion: cint
      write: proc (ctx: pointer; data: pointer; size: csize_t; user: pointer): HeifError {.cdecl.}
    HeifApi = object
      init: proc (params: pointer): HeifError {.cdecl.}
      contextAlloc: proc (): pointer {.cdecl.}
      contextFree: proc (ctx: pointer) {.cdecl.}
      readMemory: proc (ctx: pointer; mem: pointer; size: csize_t; opts: pointer): HeifError {.cdecl.}
      primaryHandle: proc (ctx: pointer; handle: ptr pointer): HeifError {.cdecl.}
      handleRelease: proc (handle: pointer) {.cdecl.}
      handleLumaBits: proc (handle: pointer): cint {.cdecl.}
      handleHasAlpha: proc (handle: pointer): cint {.cdecl.}
      decodeImage: proc (handle: pointer; img: ptr pointer; colorspace, chroma: cint;
                         opts: pointer): HeifError {.cdecl.}
      imageWidth, imageHeight: proc (img: pointer; channel: cint): cint {.cdecl.}
      planeReadonly: proc (img: pointer; channel: cint; stride: ptr cint): ptr UncheckedArray[uint8] {.cdecl.}
      bitsRange: proc (img: pointer; channel: cint): cint {.cdecl.}
      imageRelease: proc (img: pointer) {.cdecl.}
      haveEncoder: proc (format: cint): cint {.cdecl.}
      getEncoder: proc (ctx: pointer; format: cint; enc: ptr pointer): HeifError {.cdecl.}
      encoderRelease: proc (enc: pointer) {.cdecl.}
      setLossyQuality: proc (enc: pointer; quality: cint): HeifError {.cdecl.}
      imageCreate: proc (w, h, colorspace, chroma: cint; img: ptr pointer): HeifError {.cdecl.}
      addPlane: proc (img: pointer; channel, w, h, depth: cint): HeifError {.cdecl.}
      plane: proc (img: pointer; channel: cint; stride: ptr cint): ptr UncheckedArray[uint8] {.cdecl.}
      encodeImage: proc (ctx, img, enc, opts: pointer; handle: ptr pointer): HeifError {.cdecl.}
      write: proc (ctx: pointer; writer: ptr HeifWriter; user: pointer): HeifError {.cdecl.}

  const
    HeifColorspaceRgb = 1.cint
    HeifChromaRgb = 10.cint
    HeifChromaRgba = 11.cint
    HeifChromaRrggbbaaLe = 15.cint
    HeifChannelInterleaved = 10.cint
    HeifCompressionHevc = 1.cint
    HeifCompressionAv1 = 4.cint

  var
    heifState = 0   ## 0: not looked for; 1: there; -1: not
    heif: HeifApi

  proc loadHeif(): bool =
    ## libheif, opened the first time it is wanted.
    withLock libLock:
      if heifState == 0:
        heifState = -1
        let lib = loadLib("libheif.so.1")
        if lib != nil:
          template get(field, name: untyped) =
            heif.field = cast[typeof(heif.field)](lib.symAddr(name))
          get(init, "heif_init")
          get(contextAlloc, "heif_context_alloc")
          get(contextFree, "heif_context_free")
          get(readMemory, "heif_context_read_from_memory_without_copy")
          get(primaryHandle, "heif_context_get_primary_image_handle")
          get(handleRelease, "heif_image_handle_release")
          get(handleLumaBits, "heif_image_handle_get_luma_bits_per_pixel")
          get(handleHasAlpha, "heif_image_handle_has_alpha_channel")
          get(decodeImage, "heif_decode_image")
          get(imageWidth, "heif_image_get_width")
          get(imageHeight, "heif_image_get_height")
          get(planeReadonly, "heif_image_get_plane_readonly")
          get(bitsRange, "heif_image_get_bits_per_pixel_range")
          get(imageRelease, "heif_image_release")
          get(haveEncoder, "heif_have_encoder_for_format")
          get(getEncoder, "heif_context_get_encoder_for_format")
          get(encoderRelease, "heif_encoder_release")
          get(setLossyQuality, "heif_encoder_set_lossy_quality")
          get(imageCreate, "heif_image_create")
          get(addPlane, "heif_image_add_plane")
          get(plane, "heif_image_get_plane")
          get(encodeImage, "heif_context_encode_image")
          get(write, "heif_context_write")
          if heif.contextAlloc != nil and heif.contextFree != nil and heif.readMemory != nil and
             heif.primaryHandle != nil and heif.handleRelease != nil and heif.decodeImage != nil and
             heif.imageWidth != nil and heif.imageHeight != nil and heif.planeReadonly != nil and
             heif.imageRelease != nil and heif.handleLumaBits != nil:
            # (heif_init, from libheif 1.13, loads the decoder and encoder
            # plugins; before it there were none to load)
            if heif.init != nil: discard heif.init(nil)
            heifState = 1
      result = heifState == 1

  proc heifDecode(data: string; hi: ptr seq[uint16]): Bitmap =
    ## The primary picture of a HEIF file (HEIC, or AVIF where libheif has an
    ## AV1 decoder), turned and cropped as the file says.
    if data.len == 0 or not loadHeif(): return nil
    let ctx = heif.contextAlloc()
    if ctx == nil: return nil
    defer: heif.contextFree(ctx)
    if heif.readMemory(ctx, unsafeAddr data[0], csize_t(data.len), nil).code != 0: return nil
    var handle: pointer
    if heif.primaryHandle(ctx, addr handle).code != 0 or handle == nil: return nil
    defer: heif.handleRelease(handle)
    let deep = hi != nil and heif.handleLumaBits(handle) > 8 and heif.bitsRange != nil
    var img: pointer
    if heif.decodeImage(handle, addr img, HeifColorspaceRgb,
                        (if deep: HeifChromaRrggbbaaLe else: HeifChromaRgba), nil).code != 0 or
       img == nil:
      return nil
    defer: heif.imageRelease(img)
    let w = heif.imageWidth(img, HeifChannelInterleaved).int
    let h = heif.imageHeight(img, HeifChannelInterleaved).int
    var stride: cint
    let p = heif.planeReadonly(img, HeifChannelInterleaved, addr stride)
    if p == nil or not sizeOk(w, h) or stride.int < w * (if deep: 8 else: 4): return nil
    if deep:
      # 10 or 12 bits, little-endian in 16: to the full 16
      let bits = heif.bitsRange(img, HeifChannelInterleaved).int
      if bits < 9 or bits > 16: return nil
      let top = uint32((1 shl bits) - 1)
      var px16 = newSeq[uint16](w * h * 4)
      for y in 0 ..< h:
        let row = y * stride.int
        for i in 0 ..< w * 4:
          let v = min(uint32(p[row + 2 * i]) or (uint32(p[row + 2 * i + 1]) shl 8), top)
          px16[y * w * 4 + i] = uint16((v * 65535 + top div 2) div top)
      result = bitmapOf16(w, h, px16)
      hi[] = move px16
    else:
      result = newBitmap(w, h)
      for y in 0 ..< h:
        let row = y * stride.int
        for x in 0 ..< w:
          let o = row + 4 * x
          result.px[y * w + x] = (uint32(p[o + 3]) shl 24) or (uint32(p[o]) shl 16) or
                                 (uint32(p[o + 1]) shl 8) or uint32(p[o + 2])
      discard finished(result)

  proc heifWriteTo(ctx: pointer; data: pointer; size: csize_t; user: pointer): HeifError {.cdecl.} =
    let s = cast[ptr string](user)
    let n = s[].len
    s[].setLen(n + size.int)
    if size > 0: copyMem(addr s[][n], data, size.int)
    HeifError(code: 0, subcode: 0, message: "Success")

  proc heifCanEncode(format: cint): bool =
    loadHeif() and heif.haveEncoder != nil and heif.getEncoder != nil and
      heif.imageCreate != nil and heif.addPlane != nil and heif.plane != nil and
      heif.encodeImage != nil and heif.write != nil and heif.encoderRelease != nil and
      heif.haveEncoder(format) != 0

  proc heifEncode(b: Bitmap; format: cint; quality: int): string =
    ## `b` as a HEIF file (HEVC: HEIC; AV1: AVIF) by libheif's encoder plugin.
    if not heifCanEncode(format) or not sizeOk(b.w, b.h): return ""
    let ctx = heif.contextAlloc()
    if ctx == nil: return ""
    defer: heif.contextFree(ctx)
    var enc: pointer
    if heif.getEncoder(ctx, format, addr enc).code != 0 or enc == nil: return ""
    defer: heif.encoderRelease(enc)
    if heif.setLossyQuality != nil: discard heif.setLossyQuality(enc, cint(clamp(quality, 0, 100)))
    let alpha = not allOpaque(b)
    var img: pointer
    if heif.imageCreate(cint(b.w), cint(b.h), HeifColorspaceRgb,
                        (if alpha: HeifChromaRgba else: HeifChromaRgb), addr img).code != 0 or
       img == nil:
      return ""
    defer: heif.imageRelease(img)
    if heif.addPlane(img, HeifChannelInterleaved, cint(b.w), cint(b.h), 8).code != 0: return ""
    var stride: cint
    let p = heif.plane(img, HeifChannelInterleaved, addr stride)
    if p == nil: return ""
    let n = if alpha: 4 else: 3
    for y in 0 ..< b.h:
      for x in 0 ..< b.w:
        let c = b.px[y * b.w + x]
        let o = y * stride.int + n * x
        p[o] = uint8((c shr 16) and 255)
        p[o + 1] = uint8((c shr 8) and 255)
        p[o + 2] = uint8(c and 255)
        if alpha: p[o + 3] = uint8(c shr 24)
    var handle: pointer
    if heif.encodeImage(ctx, img, enc, nil, addr handle).code != 0: return ""
    if handle != nil: heif.handleRelease(handle)
    var writer = HeifWriter(apiVersion: 1, write: heifWriteTo)
    var bytes = ""
    if heif.write(ctx, addr writer, addr bytes).code != 0: return ""
    bytes

  # -- libavif (1.x, `libavif.so.16`: its structs as 1.0 lays them out; later
  #    1.x versions only add to their ends) --

  type
    AvifRWData {.bycopy.} = object
      data: ptr UncheckedArray[uint8]
      size: csize_t
    AvifRGBImage {.bycopy.} = object
      width, height, depth: uint32
      format: cint
      chromaUpsampling, chromaDownsampling: cint
      avoidLibYUV, ignoreAlpha, alphaPremultiplied, isFloat: cint
      maxThreads: cint
      pixels: pointer
      rowBytes: uint32
      spare: array[16, uint64]   # (room for what a later 1.x adds at the end)
    AvifImageHead = object
      ## The front of `avifImage`, as far as the turn and mirror it carries.
      width, height, depth: uint32
      yuvFormat, yuvRange, yuvChromaSamplePosition: cint
      yuvPlanes: array[3, pointer]
      yuvRowBytes: array[3, uint32]
      imageOwnsYUVPlanes: cint
      alphaPlane: pointer
      alphaRowBytes: uint32
      imageOwnsAlphaPlane, alphaPremultiplied: cint
      icc: AvifRWData
      colorPrimaries, transferCharacteristics, matrixCoefficients: uint16
      clliMaxCLL, clliMaxPALL: uint16
      transformFlags: uint32
      pasp: array[2, uint32]
      clap: array[8, uint32]
      irotAngle: uint8
      imirAxis: uint8
    AvifEncoderHead = object
      ## The front of `avifEncoder`, as far as its quality.
      codecChoice, maxThreads, speed, keyframeInterval: cint
      timescale: uint64
      repetitionCount: cint
      extraLayerCount: uint32
      quality, qualityAlpha: cint
    AvifApi = object
      decoderCreate: proc (): pointer {.cdecl.}
      decoderDestroy: proc (dec: pointer) {.cdecl.}
      readMemory: proc (dec, img: pointer; data: pointer; size: csize_t): cint {.cdecl.}
      imageCreateEmpty: proc (): pointer {.cdecl.}
      imageCreate: proc (w, h, depth: uint32; format: cint): pointer {.cdecl.}
      imageDestroy: proc (img: pointer) {.cdecl.}
      rgbDefaults: proc (rgb: ptr AvifRGBImage; img: pointer) {.cdecl.}
      yuvToRgb: proc (img: pointer; rgb: ptr AvifRGBImage): cint {.cdecl.}
      rgbToYuv: proc (img: pointer; rgb: ptr AvifRGBImage): cint {.cdecl.}
      encoderCreate: proc (): pointer {.cdecl.}
      encoderWrite: proc (enc, img: pointer; output: ptr AvifRWData): cint {.cdecl.}
      encoderDestroy: proc (enc: pointer) {.cdecl.}
      rwDataFree: proc (raw: ptr AvifRWData) {.cdecl.}
      codecName: proc (choice: cint; flags: uint32): cstring {.cdecl.}

  const
    AvifRgbFormatRgba = 1.cint
    AvifRgbFormatBgra = 4.cint
    AvifPixelFormatYuv444 = 1.cint
    AvifPixelFormatYuv420 = 3.cint
    AvifCodecFlagCanEncode = 2'u32
    AvifTransformIrot = 1'u32 shl 2
    AvifTransformImir = 1'u32 shl 3

  var
    avifState = 0
    avif: AvifApi

  proc loadAvif(): bool =
    withLock libLock:
      if avifState == 0:
        avifState = -1
        let lib = loadLib("libavif.so.16")
        if lib != nil:
          template get(field, name: untyped) =
            avif.field = cast[typeof(avif.field)](lib.symAddr(name))
          get(decoderCreate, "avifDecoderCreate")
          get(decoderDestroy, "avifDecoderDestroy")
          get(readMemory, "avifDecoderReadMemory")
          get(imageCreateEmpty, "avifImageCreateEmpty")
          get(imageCreate, "avifImageCreate")
          get(imageDestroy, "avifImageDestroy")
          get(rgbDefaults, "avifRGBImageSetDefaults")
          get(yuvToRgb, "avifImageYUVToRGB")
          get(rgbToYuv, "avifImageRGBToYUV")
          get(encoderCreate, "avifEncoderCreate")
          get(encoderWrite, "avifEncoderWrite")
          get(encoderDestroy, "avifEncoderDestroy")
          get(rwDataFree, "avifRWDataFree")
          get(codecName, "avifCodecName")
          if avif.decoderCreate != nil and avif.decoderDestroy != nil and avif.readMemory != nil and
             avif.imageCreateEmpty != nil and avif.imageDestroy != nil and
             avif.rgbDefaults != nil and avif.yuvToRgb != nil:
            avifState = 1
      result = avifState == 1

  proc avifDecode(data: string; hi: ptr seq[uint16]): Bitmap =
    ## The (first) picture of an AVIF file, turned and mirrored as it says.
    if data.len == 0 or not loadAvif(): return nil
    let dec = avif.decoderCreate()
    if dec == nil: return nil
    defer: avif.decoderDestroy(dec)
    let img = avif.imageCreateEmpty()
    if img == nil: return nil
    defer: avif.imageDestroy(img)
    if avif.readMemory(dec, img, unsafeAddr data[0], csize_t(data.len)) != 0: return nil
    let head = cast[ptr AvifImageHead](img)
    let w = head.width.int
    let h = head.height.int
    if not sizeOk(w, h): return nil
    let deep = hi != nil and head.depth > 8
    var rgb: AvifRGBImage
    avif.rgbDefaults(addr rgb, img)
    if deep:
      var px16 = newSeq[uint16](w * h * 4)
      rgb.format = AvifRgbFormatRgba
      rgb.depth = 16
      rgb.pixels = addr px16[0]
      rgb.rowBytes = uint32(w * 8)
      if avif.yuvToRgb(img, addr rgb) != 0: return nil
      result = bitmapOf16(w, h, px16)
      hi[] = move px16
    else:
      result = newBitmap(w, h)
      rgb.format = AvifRgbFormatBgra        # (0xAARRGGBB as it lies in memory)
      rgb.depth = 8
      rgb.pixels = addr result.px[0]
      rgb.rowBytes = uint32(w * 4)
      if avif.yuvToRgb(img, addr rgb) != 0: result = nil; return
      discard finished(result)
    let flags = head.transformFlags
    if (flags and (AvifTransformIrot or AvifTransformImir)) != 0:
      let turn = if (flags and AvifTransformIrot) != 0: int(head.irotAngle and 3) else: 0
      let mirror = if (flags and AvifTransformImir) != 0: int(head.imirAxis and 1) else: -1
      result = orientBitmap(result, hi, orientationOf(turn, mirror))

  proc avifCanEncode(): bool =
    loadAvif() and avif.imageCreate != nil and avif.rgbToYuv != nil and
      avif.encoderCreate != nil and avif.encoderWrite != nil and
      avif.encoderDestroy != nil and avif.rwDataFree != nil and avif.codecName != nil and
      avif.codecName(0, AvifCodecFlagCanEncode) != nil   # (an AV1 encoder: aom, rav1e, SVT)

  proc avifEncode(b: Bitmap; quality: int): string =
    if not avifCanEncode() or not sizeOk(b.w, b.h): return ""
    let q = clamp(quality, 0, 100)
    let img = avif.imageCreate(uint32(b.w), uint32(b.h), 8,
                               (if q >= 90: AvifPixelFormatYuv444 else: AvifPixelFormatYuv420))
    if img == nil: return ""
    defer: avif.imageDestroy(img)
    var rgb: AvifRGBImage
    avif.rgbDefaults(addr rgb, img)
    rgb.format = AvifRgbFormatBgra
    rgb.depth = 8
    rgb.ignoreAlpha = cint(allOpaque(b))
    rgb.pixels = unsafeAddr b.px[0]
    rgb.rowBytes = uint32(b.w * 4)
    if avif.rgbToYuv(img, addr rgb) != 0: return ""
    let enc = avif.encoderCreate()
    if enc == nil: return ""
    defer: avif.encoderDestroy(enc)
    let eh = cast[ptr AvifEncoderHead](enc)
    eh.quality = cint(q)
    eh.qualityAlpha = cint(q)
    eh.speed = 6
    var output: AvifRWData
    if avif.encoderWrite(enc, img, addr output) == 0 and output.data != nil:
      result = newString(output.size.int)
      if output.size > 0: copyMem(addr result[0], output.data, output.size.int)
    avif.rwDataFree(addr output)

  proc decodeWithLibraries(data: string; ext: string; hi: ptr seq[uint16]): Bitmap =
    if isAvif(data) or ext == ".avif":
      result = avifDecode(data, hi)
      if result == nil: result = heifDecode(data, hi)
    else:
      result = heifDecode(data, hi)

  proc encodeWithLibraries(b: Bitmap; kind: string; quality: int): string =
    if kind == "avif":
      result = avifEncode(b, quality)
      if result.len == 0: result = heifEncode(b, HeifCompressionAv1, quality)
    elif kind == "heic":
      result = heifEncode(b, HeifCompressionHevc, quality)

  proc encodeKinds(): seq[string] =
    if heifCanEncode(HeifCompressionHevc): result.add "heic"
    if avifCanEncode() or heifCanEncode(HeifCompressionAv1): result.add "avif"

# ---- macOS and iOS: ImageIO ------------------------------------------------------

elif defined(macosx) or defined(ios):
  {.passL: "-framework ImageIO -framework CoreGraphics -framework CoreFoundation".}

  type
    CGRect {.bycopy.} = object
      x, y, w, h: cdouble

  proc CFRelease(cf: pointer) {.importc, cdecl.}
  proc CFDataCreate(alloc: pointer; bytes: pointer; length: clong): pointer {.importc, cdecl.}
  proc CFDataCreateMutable(alloc: pointer; capacity: clong): pointer {.importc, cdecl.}
  proc CFDataGetLength(d: pointer): clong {.importc, cdecl.}
  proc CFDataGetBytePtr(d: pointer): pointer {.importc, cdecl.}
  proc CFStringCreateWithCString(alloc: pointer; s: cstring; encoding: uint32): pointer {.importc, cdecl.}
  proc CFEqual(a, b: pointer): uint8 {.importc, cdecl.}
  proc CFArrayGetCount(a: pointer): clong {.importc, cdecl.}
  proc CFArrayGetValueAtIndex(a: pointer; i: clong): pointer {.importc, cdecl.}
  proc CFDictionaryGetValue(d: pointer; key: pointer): pointer {.importc, cdecl.}
  proc CFDictionaryCreate(alloc: pointer; keys, values: ptr pointer; n: clong;
                          keyCallBacks, valueCallBacks: pointer): pointer {.importc, cdecl.}
  proc CFNumberCreate(alloc: pointer; kind: clong; value: pointer): pointer {.importc, cdecl.}
  proc CFNumberGetValue(n: pointer; kind: clong; value: pointer): uint8 {.importc, cdecl.}
  var
    kCFTypeDictionaryKeyCallBacks {.importc.}: array[6, pointer]
    kCFTypeDictionaryValueCallBacks {.importc.}: array[5, pointer]
    kCGImagePropertyOrientation {.importc.}: pointer
    kCGImageDestinationLossyCompressionQuality {.importc.}: pointer
    kCGColorSpaceSRGB {.importc.}: pointer
  proc CGImageSourceCreateWithData(data: pointer; opts: pointer): pointer {.importc, cdecl.}
  proc CGImageSourceCreateImageAtIndex(src: pointer; i: csize_t; opts: pointer): pointer {.importc, cdecl.}
  proc CGImageSourceCopyPropertiesAtIndex(src: pointer; i: csize_t; opts: pointer): pointer {.importc, cdecl.}
  proc CGImageGetWidth(img: pointer): csize_t {.importc, cdecl.}
  proc CGImageGetHeight(img: pointer): csize_t {.importc, cdecl.}
  proc CGImageGetBitsPerComponent(img: pointer): csize_t {.importc, cdecl.}
  proc CGImageRelease(img: pointer) {.importc, cdecl.}
  proc CGColorSpaceCreateWithName(name: pointer): pointer {.importc, cdecl.}
  proc CGColorSpaceRelease(space: pointer) {.importc, cdecl.}
  proc CGBitmapContextCreate(data: pointer; w, h, bitsPerComponent, bytesPerRow: csize_t;
                             space: pointer; info: uint32): pointer {.importc, cdecl.}
  proc CGBitmapContextCreateImage(ctx: pointer): pointer {.importc, cdecl.}
  proc CGContextDrawImage(ctx: pointer; r: CGRect; img: pointer) {.importc, cdecl.}
  proc CGContextRelease(ctx: pointer) {.importc, cdecl.}
  proc CGImageDestinationCreateWithData(data: pointer; uti: pointer; count: csize_t;
                                        opts: pointer): pointer {.importc, cdecl.}
  proc CGImageDestinationAddImage(dest: pointer; img: pointer; props: pointer) {.importc, cdecl.}
  proc CGImageDestinationFinalize(dest: pointer): bool {.importc, cdecl.}
  proc CGImageDestinationCopyTypeIdentifiers(): pointer {.importc, cdecl.}

  const
    kCFStringEncodingUTF8 = 0x08000100'u32
    kCFNumberSInt32Type = 3.clong
    kCFNumberDoubleType = 13.clong
    # premultiplied alpha first, 32-bit little-endian: B G R A in memory (0xAARRGGBB)
    BitmapBgraPremultiplied = 0x2002'u32
    BitmapBgrxOpaque = 0x2006'u32       # (no alpha: skip first)
    # premultiplied alpha last, 16-bit little-endian components: R G B A
    BitmapRgba16Premultiplied = 0x1001'u32

  proc imageIODecode(data: string; hi: ptr seq[uint16]): Bitmap =
    if data.len == 0: return nil
    let cfData = CFDataCreate(nil, unsafeAddr data[0], clong(data.len))
    if cfData == nil: return nil
    defer: CFRelease(cfData)
    let src = CGImageSourceCreateWithData(cfData, nil)
    if src == nil: return nil
    defer: CFRelease(src)
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
    if img == nil: return nil
    defer: CGImageRelease(img)
    let w = CGImageGetWidth(img).int
    let h = CGImageGetHeight(img).int
    if not sizeOk(w, h): return nil
    # the way the picture is to be turned (ImageIO leaves that to the caller)
    var o: int32 = 1
    let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil)
    if props != nil:
      let n = CFDictionaryGetValue(props, kCGImagePropertyOrientation)
      if n == nil or CFNumberGetValue(n, kCFNumberSInt32Type, addr o) == 0: o = 1
      CFRelease(props)
    let space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB)
    if space == nil: return nil
    defer: CGColorSpaceRelease(space)
    let r = CGRect(x: 0, y: 0, w: cdouble(w), h: cdouble(h))
    if hi != nil and CGImageGetBitsPerComponent(img) > 8:
      var px16 = newSeq[uint16](w * h * 4)
      let ctx = CGBitmapContextCreate(addr px16[0], csize_t(w), csize_t(h), 16, csize_t(w * 8),
                                      space, BitmapRgba16Premultiplied)
      if ctx != nil:
        CGContextDrawImage(ctx, r, img)
        CGContextRelease(ctx)
        for i in 0 ..< w * h:
          let a = uint32(px16[4 * i + 3])
          if a != 0 and a != 65535:
            for k in 0 .. 2:
              px16[4 * i + k] = uint16(min(65535'u32, (uint32(px16[4 * i + k]) * 65535 + a div 2) div a))
        result = bitmapOf16(w, h, px16)
        hi[] = move px16
        result = orientBitmap(result, hi, o.int); return
    result = newBitmap(w, h)
    let ctx = CGBitmapContextCreate(addr result.px[0], csize_t(w), csize_t(h), 8, csize_t(w * 4),
                                    space, BitmapBgraPremultiplied)
    if ctx == nil: result = nil; return
    CGContextDrawImage(ctx, r, img)
    CGContextRelease(ctx)
    for p in result.px.mitems:
      let a = p shr 24
      if a != 0 and a != 255:
        var c = p and 0xFF000000'u32
        for s in [16'u32, 8, 0]:
          c = c or (min(255'u32, (((p shr s) and 255) * 255 + a div 2) div a) shl s)
        p = c
    result = orientBitmap(finished(result), nil, o.int)

  proc utiOf(kind: string): string =
    if kind == "heic": "public.heic" elif kind == "avif": "public.avif" else: ""

  proc imageIOCanEncode(kind: string): bool =
    let uti = utiOf(kind)
    if uti.len == 0: return false
    let types = CGImageDestinationCopyTypeIdentifiers()
    if types == nil: return false
    defer: CFRelease(types)
    let want = CFStringCreateWithCString(nil, cstring(uti), kCFStringEncodingUTF8)
    if want == nil: return false
    defer: CFRelease(want)
    for i in 0 ..< CFArrayGetCount(types):
      if CFEqual(CFArrayGetValueAtIndex(types, i), want) != 0: return true

  proc imageIOEncode(b: Bitmap; kind: string; quality: int): string =
    if not imageIOCanEncode(kind) or not sizeOk(b.w, b.h): return ""
    # the pixels as Core Graphics takes them: alpha premultiplied
    let opaque = allOpaque(b)
    var px = b.px
    if not opaque:
      for p in px.mitems:
        let a = p shr 24
        if a != 255:
          var c = p and 0xFF000000'u32
          for s in [16'u32, 8, 0]:
            c = c or (((((p shr s) and 255) * a + 127) div 255) shl s)
          p = c
    let space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB)
    if space == nil: return ""
    defer: CGColorSpaceRelease(space)
    let ctx = CGBitmapContextCreate(addr px[0], csize_t(b.w), csize_t(b.h), 8, csize_t(b.w * 4),
                                    space, (if opaque: BitmapBgrxOpaque else: BitmapBgraPremultiplied))
    if ctx == nil: return ""
    let img = CGBitmapContextCreateImage(ctx)
    CGContextRelease(ctx)
    if img == nil: return ""
    defer: CGImageRelease(img)
    let data = CFDataCreateMutable(nil, 0)
    if data == nil: return ""
    defer: CFRelease(data)
    let uti = CFStringCreateWithCString(nil, cstring(utiOf(kind)), kCFStringEncodingUTF8)
    if uti == nil: return ""
    defer: CFRelease(uti)
    let dest = CGImageDestinationCreateWithData(data, uti, 1, nil)
    if dest == nil: return ""
    defer: CFRelease(dest)
    var q = cdouble(clamp(quality, 0, 100)) / 100
    let num = CFNumberCreate(nil, kCFNumberDoubleType, addr q)
    if num == nil: return ""
    defer: CFRelease(num)
    var key = kCGImageDestinationLossyCompressionQuality
    var value = num
    let opts = CFDictionaryCreate(nil, addr key, addr value, 1,
                                  addr kCFTypeDictionaryKeyCallBacks,
                                  addr kCFTypeDictionaryValueCallBacks)
    CGImageDestinationAddImage(dest, img, opts)
    if opts != nil: CFRelease(opts)
    if not CGImageDestinationFinalize(dest): return ""
    let n = CFDataGetLength(data).int
    result = newString(n)
    if n > 0: copyMem(addr result[0], CFDataGetBytePtr(data), n)

  proc decodeWithLibraries(data: string; ext: string; hi: ptr seq[uint16]): Bitmap =
    imageIODecode(data, hi)

  proc encodeWithLibraries(b: Bitmap; kind: string; quality: int): string =
    imageIOEncode(b, kind, quality)

  proc encodeKinds(): seq[string] =
    for k in ["heic", "avif"]:
      if imageIOCanEncode(k): result.add k

# ---- Windows: WIC -------------------------------------------------------------

elif defined(windows):
  type
    WinGuid = object
      d1: uint32
      d2, d3: uint16
      d4: array[8, uint8]
    PropBag2 = object
      dwType: uint32
      vt, cfType: uint16
      dwHint: uint32
      pstrName: ptr uint16
      clsid: WinGuid
    Variant = object
      vt, r1, r2, r3: uint16
      value: array[2, uint64]   # (the union; a float is its first 4 bytes)

  proc CoInitializeEx(r: pointer; model: uint32): int32 {.stdcall, dynlib: "ole32", importc.}
  proc CoUninitialize() {.stdcall, dynlib: "ole32", importc.}
  proc CoCreateInstance(clsid: ptr WinGuid; outer: pointer; ctx: uint32; iid: ptr WinGuid;
                        obj: ptr pointer): int32 {.stdcall, dynlib: "ole32", importc.}
  proc SHCreateMemStream(p: pointer; n: uint32): pointer {.stdcall, dynlib: "shlwapi", importc.}

  const
    ClsidWicImagingFactory = WinGuid(d1: 0xcacaf262'u32, d2: 0x9370, d3: 0x4615,
      d4: [0xa1'u8, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a])
    IidWicImagingFactory = WinGuid(d1: 0xec5ec8a9'u32, d2: 0xc395, d3: 0x4314,
      d4: [0x9c'u8, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70])
    WicPixelFormat32bppBGRA = WinGuid(d1: 0x6fddc324'u32, d2: 0x4e03, d3: 0x4bfe,
      d4: [0xb1'u8, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f])
    ContainerFormatHeif = WinGuid(d1: 0xe1e62521'u32, d2: 0x6787, d3: 0x405b,
      d4: [0xa3'u8, 0x39, 0x50, 0x07, 0x15, 0xb5, 0x76, 0x3f])

  template comFn(obj: pointer; i: int; T: typedesc): untyped =
    ## Method `i` of a COM object's vtable, as a proc of type `T`.
    cast[T](cast[ptr UncheckedArray[pointer]](cast[ptr pointer](obj)[])[i])

  proc sameGuid(a, b: WinGuid): bool =
    a.d1 == b.d1 and a.d2 == b.d2 and a.d3 == b.d3 and a.d4 == b.d4

  proc comRelease(obj: pointer) =
    if obj != nil:
      discard comFn(obj, 2, proc (this: pointer): uint32 {.stdcall.})(obj)

  proc withWic(body: proc (factory: pointer)) =
    ## Runs `body` with a WIC imaging factory (COM started on this thread
    ## for it when it was not).
    let hr = CoInitializeEx(nil, 0)          # COINIT_MULTITHREADED
    var clsid = ClsidWicImagingFactory
    var iid = IidWicImagingFactory
    var factory: pointer
    if CoCreateInstance(addr clsid, nil, 1, addr iid, addr factory) == 0 and factory != nil:
      body(factory)
      comRelease(factory)
    if hr == 0 or hr == 1: CoUninitialize()  # (S_OK, S_FALSE: this call started it)

  proc wicDecode(data: string): Bitmap =
    ## The first frame of a picture any WIC codec of this Windows reads.
    if data.len == 0 or data.len > high(int32): return nil
    var res: Bitmap
    let bytes = unsafeAddr data[0]   # (the closure takes the address, not a copy)
    let n = uint32(data.len)
    withWic(proc (factory: pointer) =
      let stream = SHCreateMemStream(bytes, n)
      if stream == nil: return
      defer: comRelease(stream)
      var decoder, frame, conv: pointer
      defer:
        comRelease(conv)
        comRelease(frame)
        comRelease(decoder)
      if comFn(factory, 4, proc (this, stream: pointer; vendor: pointer; opts: uint32;
                                  dec: ptr pointer): int32 {.stdcall.})(
           factory, stream, nil, 0, addr decoder) != 0 or decoder == nil: return
      if comFn(decoder, 13, proc (this: pointer; i: uint32; f: ptr pointer): int32 {.stdcall.})(
           decoder, 0, addr frame) != 0 or frame == nil: return
      var w, h: uint32
      if comFn(frame, 3, proc (this: pointer; w, h: ptr uint32): int32 {.stdcall.})(
           frame, addr w, addr h) != 0 or not sizeOk(w.int, h.int): return
      if comFn(factory, 10, proc (this: pointer; c: ptr pointer): int32 {.stdcall.})(
           factory, addr conv) != 0 or conv == nil: return
      var fmt = WicPixelFormat32bppBGRA
      if comFn(conv, 8, proc (this, src: pointer; dst: ptr WinGuid; dither: int32; palette: pointer;
                               alpha: cdouble; paletteKind: int32): int32 {.stdcall.})(
           conv, frame, addr fmt, 0, nil, 0.0, 0) != 0: return
      let b = newBitmap(w.int, h.int)
      if comFn(conv, 7, proc (this: pointer; rect: pointer; stride, size: uint32;
                               buf: pointer): int32 {.stdcall.})(
           conv, nil, w * 4, w * h * 4, addr b.px[0]) != 0: return
      res = finished(b))
    res

  proc wicEncode(b: Bitmap; container: WinGuid; quality: int): string =
    ## `b` by the WIC encoder of `container`; "" when Windows has none.
    if not sizeOk(b.w, b.h): return ""
    var res = ""
    withWic(proc (factory: pointer) =
      var cont = container
      var encoder, stream, frame, bag, bitmap, conv: pointer
      defer:
        comRelease(conv)
        comRelease(bitmap)
        comRelease(bag)
        comRelease(frame)
        comRelease(encoder)
        comRelease(stream)
      if comFn(factory, 8, proc (this: pointer; c: ptr WinGuid; vendor: pointer;
                                  e: ptr pointer): int32 {.stdcall.})(
           factory, addr cont, nil, addr encoder) != 0 or encoder == nil: return
      stream = SHCreateMemStream(nil, 0)
      if stream == nil: return
      if comFn(encoder, 3, proc (this, s: pointer; cache: int32): int32 {.stdcall.})(
           encoder, stream, 2) != 0: return              # WICBitmapEncoderNoCache
      if comFn(encoder, 10, proc (this: pointer; f, bag: ptr pointer): int32 {.stdcall.})(
           encoder, addr frame, addr bag) != 0 or frame == nil: return
      if bag != nil:
        # "ImageQuality", 0 .. 1 (the encoders that have no such option say so; it is let be)
        var name: array[13, uint16]
        for i, c in "ImageQuality": name[i] = uint16(ord(c))
        var prop = PropBag2(pstrName: addr name[0])
        var v = Variant(vt: 4)                           # VT_R4
        cast[ptr float32](addr v.value[0])[] = float32(clamp(quality, 0, 100)) / 100
        discard comFn(bag, 4, proc (this: pointer; n: uint32; p: ptr PropBag2;
                                     v: ptr Variant): int32 {.stdcall.})(bag, 1, addr prop, addr v)
      if comFn(frame, 3, proc (this, bag: pointer): int32 {.stdcall.})(frame, bag) != 0: return
      if comFn(frame, 4, proc (this: pointer; w, h: uint32): int32 {.stdcall.})(
           frame, uint32(b.w), uint32(b.h)) != 0: return
      var fmt = WicPixelFormat32bppBGRA
      if comFn(frame, 6, proc (this: pointer; f: ptr WinGuid): int32 {.stdcall.})(
           frame, addr fmt) != 0: return
      let stride = uint32(b.w * 4)
      let size = stride * uint32(b.h)
      if sameGuid(fmt, WicPixelFormat32bppBGRA):
        if comFn(frame, 10, proc (this: pointer; lines, stride, size: uint32;
                                   px: pointer): int32 {.stdcall.})(
             frame, uint32(b.h), stride, size, unsafeAddr b.px[0]) != 0: return
      else:
        # the encoder wants another format: the pixels converted to it
        var bgra = WicPixelFormat32bppBGRA
        if comFn(factory, 20, proc (this: pointer; w, h: uint32; f: ptr WinGuid; stride, size: uint32;
                                     px: pointer; bmp: ptr pointer): int32 {.stdcall.})(
             factory, uint32(b.w), uint32(b.h), addr bgra, stride, size, unsafeAddr b.px[0],
             addr bitmap) != 0 or bitmap == nil: return
        if comFn(factory, 10, proc (this: pointer; c: ptr pointer): int32 {.stdcall.})(
             factory, addr conv) != 0 or conv == nil: return
        if comFn(conv, 8, proc (this, src: pointer; dst: ptr WinGuid; dither: int32; palette: pointer;
                                 alpha: cdouble; paletteKind: int32): int32 {.stdcall.})(
             conv, bitmap, addr fmt, 0, nil, 0.0, 0) != 0: return
        if comFn(frame, 11, proc (this, src: pointer; rect: pointer): int32 {.stdcall.})(
             frame, conv, nil) != 0: return
      if comFn(frame, 12, proc (this: pointer): int32 {.stdcall.})(frame) != 0: return
      if comFn(encoder, 11, proc (this: pointer): int32 {.stdcall.})(encoder) != 0: return
      # what the stream got
      var total: uint64
      if comFn(stream, 5, proc (this: pointer; move: int64; origin: uint32;
                                 pos: ptr uint64): int32 {.stdcall.})(stream, 0, 2, addr total) != 0 or
         total == 0 or total > uint64(high(int32)):
        return
      discard comFn(stream, 5, proc (this: pointer; move: int64; origin: uint32;
                                      pos: ptr uint64): int32 {.stdcall.})(stream, 0, 0, nil)
      var bytes = newString(int(total))
      var got: uint32
      if comFn(stream, 3, proc (this: pointer; buf: pointer; n: uint32;
                                 got: ptr uint32): int32 {.stdcall.})(
           stream, addr bytes[0], uint32(total), addr got) != 0 or got.uint64 != total: return
      res = move bytes)
    res

  var heicEncoder = 0   ## 0: not asked; 1: Windows has one; -1: not

  proc decodeWithLibraries(data: string; ext: string; hi: ptr seq[uint16]): Bitmap =
    wicDecode(data)

  proc encodeWithLibraries(b: Bitmap; kind: string; quality: int): string =
    if kind == "heic": wicEncode(b, ContainerFormatHeif, quality) else: ""

  proc encodeKinds(): seq[string] =
    withLock libLock:
      if heicEncoder == 0:
        heicEncoder = -1
        withWic(proc (factory: pointer) =
          var cont = ContainerFormatHeif
          var encoder: pointer
          if comFn(factory, 8, proc (this: pointer; c: ptr WinGuid; vendor: pointer;
                                      e: ptr pointer): int32 {.stdcall.})(
               factory, addr cont, nil, addr encoder) == 0 and encoder != nil:
            heicEncoder = 1
          comRelease(encoder))
      if heicEncoder == 1: result.add "heic"

elif not androidApp:
  proc decodeWithLibraries(data: string; ext: string; hi: ptr seq[uint16]): Bitmap = nil
  proc encodeWithLibraries(b: Bitmap; kind: string; quality: int): string = ""
  proc encodeKinds(): seq[string] = @[]

# ---- the API ------------------------------------------------------------------

proc decodeWithSystem*(path: string; hi: ptr seq[uint16] = nil): Bitmap =
  ## The picture at `path` decoded by the system (nil when it cannot be).
  ## With `hi`, a picture of more than 8 bits a channel (a 10-bit HDR HEIC or
  ## AVIF) also puts its pixels there at 16 bits, R G B A each (as
  ## `decodePng` does) -- where the system's libraries give them; else `hi`
  ## is left empty.
  when androidApp:
    let tmp = getTempDir() / ("retro-sysimg-" & $getCurrentProcessId() & "-" & $getThreadId() & ".png")   # (one per thread)
    defer:
      try: removeFile(tmp) except OSError: discard
    if systemCall("media.decode", path & "\t" & tmp) == "1" and fileExists(tmp):
      return loadPicture(tmp, 1 shl 15, 1 shl 15)
    return nil
  else:
    let ext = path.splitFile.ext.toLowerAscii
    # the system's own libraries
    var data = ""
    try: data = readFile(path)
    except IOError, OSError: discard
    if data.len > 0:
      if hi != nil: hi[].setLen(0)
      try:
        result = decodeWithLibraries(data, ext, hi)
      except CatchableError:
        result = nil
      if result != nil: return
      if hi != nil: hi[].setLen(0)
    # a converter program, last
    let tmp = getTempDir() / ("retro-sysimg-" & $getCurrentProcessId() & "-" & $getThreadId() & ".png")   # (one per thread)
    defer:
      try: removeFile(tmp) except OSError: discard
    var tries: seq[seq[string]]
    if ext in [".heic", ".heif", ".hif"]: tries.add @["heif-convert", path, tmp]
    if ext == ".avif": tries.add @["avifdec", path, tmp]
    tries.add @["magick", path, tmp]
    tries.add @["convert", path, tmp]
    tries.add @["ffmpeg", "-loglevel", "error", "-y", "-i", path, "-frames:v", "1", tmp]
    for t in tries:
      let exe = findExe(t[0])
      if exe.len == 0: continue
      try:
        let p = startProcess(exe, args = t[1 .. ^1], options = {poStdErrToStdOut})
        let code = p.waitForExit(60_000)
        p.close()
        if code == 0 and fileExists(tmp):
          let b = loadPicture(tmp, 1 shl 15, 1 shl 15)
          if b != nil: result = b; return
      except CatchableError, OSError: discard
    result = nil

proc systemEncodeExts*(): seq[string] =
  ## What `encodeWithSystem` can write on this system: "heic", "avif", both
  ## or neither (Linux: libheif with an HEVC or AV1 encoder plugin, libavif
  ## with an AV1 encoder; macOS: what ImageIO writes; Windows: a WIC HEIF
  ## encoder; Android: none).
  when androidApp: @[]
  else:
    try: encodeKinds()
    except CatchableError: @[]

proc encodeWithSystem*(b: Bitmap; ext: string; quality: int): string =
  ## `b` as the bytes of a HEIC file (`ext` "heic", "heif" or "hif") or an
  ## AVIF file ("avif"), by the system's encoder at `quality` 0 .. 100 (100:
  ## the best); "" when this system has no encoder for it (see
  ## `systemEncodeExts`).
  when androidApp: ""
  else:
    let kind = encodeKind(ext)
    if b == nil or kind.len == 0 or b.w <= 0 or b.h <= 0 or b.px.len < b.w * b.h: return ""
    try: encodeWithLibraries(b, kind, quality)
    except CatchableError: ""

proc systemImageNote*(): string =
  ## What to say when such a picture could not be read.
  when androidApp: "this device cannot read it (HEIF needs Android 9, AVIF Android 12)"
  elif defined(macosx) or defined(ios):
    "this system cannot read it (HEIC needs macOS 10.13 or iOS 11, AVIF macOS 13 or iOS 16)"
  elif defined(windows):
    "Windows cannot read it (HEIC needs the HEIF and HEVC Video Extensions, AVIF the AV1 " &
      "Video Extension) and no converter for it is installed (ImageMagick or ffmpeg)"
  else:
    "neither libheif nor libavif can read it and no converter for it is installed " &
      "(heif-convert, avifdec, ImageMagick or ffmpeg)"

## Tests of `retroui/exr` (OpenEXR read and write) and `retroui/gifanim`
## (animated GIF write and read).
##
## How the data was made (with Python; nothing of it ships):
##
## - tests/data/exr: OpenEXR files written by the OpenEXR library (its python
##   bindings, 3.5.2): each compression it has but DWA and HTJ2K; half, float
##   and uint channels; a data window off the display window; tiles; two
##   parts; scanlines stored bottom first; layers; PIZ on pictures big enough
##   for it to pay; B44 of perceptually linear channels. A mipmapped file by
##   OpenImageIO 3.2's maketx; luminance-chroma files (RY BY sampled every 2
##   pixels) by hand, plain and ZIP, as the bindings cannot write subsampled
##   channels (then read by the library to check them). For each file
##   manifest.txt names a reference: what the OpenEXR library (OpenImageIO for
##   the mipmap) reads from it, as R G B A on the display window (alpha 1 when
##   absent, 0 outside the data window, Y as gray, RY BY as colors), the four
##   planes one after another, zlib-compressed; halves for half files, floats
##   for the others. Each must be read the same, bit for bit. `wide_piz.exr`
##   (PIZ's 16-bit wavelet) is a ramp of 16-bit values, as the library reads
##   it. tohalf.bin: floats, each with numpy's nearest half.
## - tests/data/gif: frames.gif, by a small encoder in the generator (frames
##   at offsets, local palettes, interlacing, transparency, disposal 1 2 3, a
##   delay of 0, loop 3), and pillow.gif, by Pillow 12.3 itself (optimized,
##   disposal 2); the .ref beside each holds the frames Pillow composes from
##   it (RGBA), manifest.txt their durations and loop.
##
## The other way round -- the files this test writes, read by the OpenEXR
## library and by Pillow -- is checked with EXRGIF_OUT set to a directory:
## the test leaves its files there, with what they were made from.

import std/[os, times, math, strutils, monotimes]
import retroui/[exr, codec]

const dataDir = currentSourcePath().parentDir / "data"
let outDir = getEnv("EXRGIF_OUT")
if outDir.len > 0: createDir(outDir)

proc ms(t: MonoTime): float = (getMonoTime() - t).inNanoseconds.float / 1e6

block halfFloats:
  # every half is a float exactly and back (NaN payloads kept)
  for i in 0 .. 65535:
    # (a 32-bit x86 hands floats back through the x87, which makes a NaN
    # quiet: there NaNs are not compared -- WebAssembly keeps them)
    when defined(i386):
      if (i and 0x7C00) == 0x7C00 and (i and 0x3FF) != 0: continue
    doAssert floatToHalf(halfToFloat(uint16(i))) == uint16(i), $i
  doAssert floatToHalf(1.0) == 0x3C00 and floatToHalf(65504) == 0x7BFF and floatToHalf(65520) == 0x7C00
  doAssert floatToHalf(1.0 + 1.0 / 2048) == 0x3C00            # (a tie: to the even)
  doAssert floatToHalf(1.0 + 3.0 / 2048) == 0x3C02
  # floats to halves as numpy rounds them (tests/data/exr/tohalf.bin: 1509
  # floats -- random, ties, subnormals, too big, NaN -- each with numpy's half)
  let raw = zlibDecompress(readFile(dataDir / "exr" / "tohalf.bin").toBytes)
  for k in 0 ..< raw.len div 6:
    let p = 6 * k
    let f = cast[float32](uint32(raw[p]) or (uint32(raw[p + 1]) shl 8) or (uint32(raw[p + 2]) shl 16) or (uint32(raw[p + 3]) shl 24))
    let want = uint16(raw[p + 4]) or (uint16(raw[p + 5]) shl 8)
    let got = floatToHalf(f)
    if f != f: doAssert (got and 0x7C00) == 0x7C00 and (got and 0x3FF) != 0, "NaN"
    else: doAssert got == want, $f & ": " & toHex(got) & " want " & toHex(want)

block exrFromOpenExr:
  var files = 0
  for line in lines(dataDir / "exr" / "manifest.txt"):
    if line.startsWith("#") or line.strip.len == 0: continue
    let f = line.splitWhitespace
    let (file, refName, kind, w, h, chans) = (f[0], f[1], f[2], parseInt(f[3]), parseInt(f[4]), f[5].split(','))
    let data = readFile(dataDir / "exr" / file)
    doAssert isExr(data), file
    let e = readExr(data)
    doAssert e.w == w and e.h == h, file & ": " & $e.w & " x " & $e.h
    doAssert e.channels == chans, file & ": " & $e.channels
    var want = newSeq[uint32](w * h * 4)
    if kind == "ramp":
      for y in 0 ..< h:
        for x in 0 ..< w:
          for i, slot in [3, 2, 1, 0]:                   # A B G R, in the file's order
            want[(y * w + x) * 4 + slot] = cast[uint32](halfToFloat(uint16(((y * w + x) * 4 + i) mod 65536)))
    else:
      let raw = zlibDecompress(readFile(dataDir / "exr" / refName).toBytes)
      let n = w * h
      for c in 0 .. 3:
        for i in 0 ..< n:
          want[i * 4 + c] =
            if kind == "half": cast[uint32](halfToFloat(uint16(raw[2 * (c * n + i)]) or (uint16(raw[2 * (c * n + i) + 1]) shl 8)))
            else:
              let k = 4 * (c * n + i)
              uint32(raw[k]) or (uint32(raw[k + 1]) shl 8) or (uint32(raw[k + 2]) shl 16) or (uint32(raw[k + 3]) shl 24)
    var bad = 0
    for i in 0 ..< want.len:
      if cast[uint32](e.px[i]) != want[i]:
        if bad == 0:
          echo file, ": first difference at pixel ", i div 4 mod w, ",", i div 4 div w, " channel ", i mod 4,
               ": ", e.px[i], " want ", cast[float32](want[i])
        inc bad
    doAssert bad == 0, file & ": " & $bad & " values differ"
    inc files
  echo "EXR: ", files, " files written by the OpenEXR library read bit for bit the same"

proc sampleLight(w, h: int; alpha: bool; smooth = false): seq[float32] =
  ## Light past white, below zero, a smooth gradient and some noise (none
  ## when `smooth`: in steps, as PIZ compresses it).
  result = newSeq[float32](w * h * 4)
  var s = 12345'u32
  for y in 0 ..< h:
    for x in 0 ..< w:
      s = s * 1664525 + 1013904223
      let n = if smooth: 0'f32 else: float32(s shr 16) / 65536 * 0.01
      let i = (y * w + x) * 4
      result[i] = float32(x) / float32(w) * 4 + n
      result[i + 1] = sin(float32(y) * 0.05) * 2 - 0.3 + n
      result[i + 2] = float32(x + y) / float32(w + h) + n * 3
      result[i + 3] = if alpha: clamp(float32(y) / float32(h), 0, 1) else: 1
      if smooth:
        for c in 0 .. 3: result[i + c] = round(result[i + c] * 16) / 16

block exrRoundTrip:
  # written and read back: halves exactly, floats exactly
  for (w, h, smooth) in [(1, 1, false), (37, 29, false), (130, 70, false), (75, 45, true)]:
    for alpha in [false, true]:
      let light = sampleLight(w, h, alpha, smooth)
      for comp in ["none", "rle", "zips", "zip", "piz"]:
        for half in [true, false]:
          let f = writeExr(w, h, light, half, comp)
          let e = readExr(f)
          doAssert e.w == w and e.h == h
          doAssert e.channels == (if alpha: @["A", "B", "G", "R"] else: @["B", "G", "R"]), $e.channels
          for i in 0 ..< light.len:
            let want = if half: halfToFloat(floatToHalf(light[i])) else: light[i]
            doAssert cast[uint32](e.px[i]) == cast[uint32](want), comp & " " & $half & " " & $i
          if outDir.len > 0 and w > 1:
            writeFile(outDir / "written_" & comp & (if half: "_half" else: "_float") & (if alpha: "_rgba_" else: "_rgb_") &
                      $w & "x" & $h & ".exr", f)
      if outDir.len > 0 and w > 1:
        var raw = newString(light.len * 4)
        copyMem(addr raw[0], unsafeAddr light[0], raw.len)
        writeFile(outDir / "written_" & (if alpha: "rgba_" else: "rgb_") & $w & "x" & $h & ".f32", raw)
  var refused = false
  try: discard writeExr(2, 2, newSeq[float32](16), compression = "dwaa")
  except ValueError: refused = true
  doAssert refused
  refused = false
  try: discard readExr("\x76\x2F\x31\x01\x02\0\0\0garbage")
  except ValueError: refused = true
  doAssert refused
  echo "EXR: written and read back, every compression, half and float"

block exrDamaged:
  # cut short or with bytes changed past the header: read, or refused with ValueError
  var s = 99'u32
  proc rnd(n: int): int =
    s = s * 1664525 + 1013904223
    int((s shr 8) mod uint32(max(1, n)))
  var refused, read = 0
  for file in walkFiles(dataDir / "exr" / "*.exr"):
    let good = readFile(file)
    for t in 0 ..< 40:
      var d = good
      if t mod 4 == 0: d.setLen(rnd(d.len))
      else:
        for k in 0 .. rnd(8):
          let at = d.len div 3 + rnd(d.len - d.len div 3)
          d[at] = char(rnd(256))
      try:
        discard readExr(d)
        inc read
      except ValueError: inc refused
  echo "EXR: damaged files: ", refused, " refused, ", read, " read anyway; none crashed"

block exrSpeed:
  let (w, h) = (3840, 2160)
  let light = sampleLight(w, h, true)
  for comp in ["zip", "piz"]:
    var t = getMonoTime()
    var c = cpuTime()
    let f = writeExr(w, h, light, half = false, compression = comp)
    let (wt, wc) = (ms(t), (cpuTime() - c) * 1000)
    t = getMonoTime()
    c = cpuTime()
    let e = readExr(f)
    let (rt, rc) = (ms(t), (cpuTime() - c) * 1000)
    doAssert e.px.len == light.len and e.px[12345] == light[12345]
    echo "EXR 4K float RGBA ", comp, ": write ", int(wt), " ms (", int(wc), " ms of processor time), read ",
         int(rt), " ms (", int(rc), "), ", f.len div 1024, " KB"
    let fh = writeExr(w, h, light, half = true, compression = comp)
    t = getMonoTime()
    discard readExr(fh)
    echo "  (half: read ", int(ms(t)), " ms, ", fh.len div 1024, " KB)"


# ---- GIF ------------------------------------------------------------------------------------------------------

import retroui/[gfx, gifanim]

type GifRef = tuple[file: string; w, h, frames, loop: int; durations: seq[int]; px: seq[uint32]]

proc gifRefs(): seq[GifRef] =
  ## tests/data/gif: each file with the frames Pillow composes from it.
  for line in lines(dataDir / "gif" / "manifest.txt"):
    if line.startsWith("#") or line.strip.len == 0: continue
    let f = line.splitWhitespace
    var r: GifRef
    r.file = f[0]
    (r.w, r.h, r.frames, r.loop) = (parseInt(f[1]), parseInt(f[2]), parseInt(f[3]), parseInt(f[4]))
    for d in f[5].split(','): r.durations.add parseInt(d)
    let raw = zlibDecompress(readFile(dataDir / "gif" / (f[0][0 ..< ^4] & ".ref")).toBytes)
    r.px = newSeq[uint32](raw.len div 4)
    for i in 0 ..< r.px.len:
      r.px[i] = (uint32(raw[4 * i + 3]) shl 24) or (uint32(raw[4 * i]) shl 16) or (uint32(raw[4 * i + 1]) shl 8) or uint32(raw[4 * i + 2])
    result.add r

proc sameShown(a, b: uint32): bool =
  ## The same pixel as seen: transparent ones alike whatever their color.
  (a shr 24) == 0 and (b shr 24) == 0 or a == b

block gifReadAgainstPillow:
  # tests/data/gif: frames.gif (made by a small encoder in the generator: frames
  # at offsets, local palettes, interlacing, transparency, disposal 1 2 3, a
  # delay of 0, loop 3) and pillow.gif (Pillow's own, optimized, disposal 2);
  # each with the frames Pillow composes from it (RGBA), their durations and loop
  for r in gifRefs():
    let data = readFile(dataDir / "gif" / r.file)
    let frames = gifFrames(data)
    doAssert frames.len == r.frames, r.file
    doAssert gifLoop(data) == r.loop, r.file
    for k in 0 ..< r.frames:
      doAssert frames[k].bmp.w == r.w and frames[k].bmp.h == r.h
      doAssert frames[k].delayMs == r.durations[k], r.file & " frame " & $k & ": " & $frames[k].delayMs
      for i in 0 ..< r.w * r.h:
        doAssert sameShown(frames[k].bmp.px[i], r.px[k * r.w * r.h + i]), r.file & " frame " & $k & " pixel " & $i
  echo "GIF: frames as Pillow composes them (disposal 1, 2, 3; offsets, local palettes, interlacing)"
  # damaged: frames up to the damage, or ValueError
  var s = 7'u32
  for r in gifRefs():
    let good = readFile(dataDir / "gif" / r.file)
    for t in 0 ..< 200:
      var d = good
      s = s * 1664525 + 1013904223
      if t mod 3 == 0: d.setLen(int(s shr 8) mod d.len)
      else: d[int(s shr 8) mod d.len] = char(s shr 24)
      try: discard gifFrames(d) & @[]
      except ValueError: discard
      discard gifLoop(d)

type Frames = seq[tuple[px: seq[uint32]; delayMs: int]]

proc dump(name: string; w, h: int; frames: Frames; loop: int; gif: string) =
  ## (left for other programs to check: the GIF, the frames it was made from, their delays)
  if outDir.len == 0: return
  writeFile(outDir / name & ".gif", gif)
  var raw = newString(frames.len * w * h * 4)
  for k, f in frames: copyMem(addr raw[k * w * h * 4], unsafeAddr f.px[0], w * h * 4)
  writeFile(outDir / name & ".argb", raw)
  var d: seq[string]
  for f in frames: d.add $f.delayMs
  writeFile(outDir / name & ".txt", $w & " " & $h & " " & $frames.len & " " & $loop & " " & d.join(","))

proc exactFrames(w, h: int): Frames =
  ## Few colors in each frame (more than 256 in all), a sprite moving,
  ## transparency coming and going, a frame like the one before.
  for k in 0 ..< 12:
    var px = newSeq[uint32](w * h)
    let shift = if k in 6 .. 8: 100 else: 0               # (other colors: a palette of their own)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let v = (x * 3 + y * 2 + shift) mod 200
        px[y * w + x] = 0xFF000000'u32 or uint32(v shl 16) or uint32((255 - v) shl 8) or uint32(v div 2 + shift)
    for y in 10 ..< 18:                                    # the sprite
      for x in 0 ..< 10:
        let sx = x + k * 4
        if sx < w: px[(y + k) * w + sx] = [0xFFFF0000'u32, 0xFF00FF00'u32, 0xFF0000FF'u32][(x + y) mod 3]
    if k in [3, 4, 9]:                                     # a hole, then filled again
      for y in 5 ..< 25:
        for x in 30 ..< 50: px[y * w + x] = 0x20FFFFFF'u32
    if k == 10:
      for i in 0 ..< w * h div 2: px[i] = 0
    if k == 5: px = result[4].px                           # (nothing changed)
    result.add (px, 30 + k * 10)

proc lightFrames(w, h, n: int; drift: bool): Frames =
  ## Many colors: a smooth picture (moving, when `drift`) and a disc going round.
  for k in 0 ..< n:
    var px = newSeq[uint32](w * h)
    let t = if drift: float(k) * 0.15 else: 0.0
    let cx = w.float / 2 + cos(float(k) * 0.3) * w.float / 4
    let cy = h.float / 2 + sin(float(k) * 0.3) * h.float / 4
    for y in 0 ..< h:
      for x in 0 ..< w:
        let r = int(127 + 127 * sin(x.float * 0.02 + t))
        let g = int(127 + 127 * sin(y.float * 0.03 + t * 0.7))
        let b = int(127 + 127 * sin((x + y).float * 0.015 - t))
        px[y * w + x] = 0xFF000000'u32 or uint32(r shl 16) or uint32(g shl 8) or uint32(b)
        let d = (x.float - cx) * (x.float - cx) + (y.float - cy) * (y.float - cy)
        if d < (h.float / 8) * (h.float / 8): px[y * w + x] = 0xFFFFE040'u32 - uint32(min(64, int(d / 8)))
    result.add (px, 40)

block gifWriteExact:
  let (w, h) = (64, 48)
  let frames = exactFrames(w, h)
  for dither in [true, false]:
    let gif = encodeGifFrames(w, h, frames, loop = 2, dither = dither)
    let back = gifFrames(gif)
    doAssert back.len == frames.len and gifLoop(gif) == 2
    for k in 0 ..< frames.len:
      doAssert back[k].delayMs == frames[k].delayMs
      for i in 0 ..< w * h:
        let want = if frames[k].px[i] >= 0x80000000'u32: frames[k].px[i] else: 0'u32
        doAssert sameShown(back[k].bmp.px[i], want), "frame " & $k & " pixel " & $i & ": " &
                 toHex(back[k].bmp.px[i]) & " want " & toHex(want)
    if dither: dump("anim_exact", w, h, frames, 2, gif)
  # one frame; played once
  let one = encodeGifFrames(5, 3, [(newSeq[uint32](15), 0)], loop = -1)
  doAssert gifLoop(one) == -1 and gifFrames(one).len == 1
  echo "GIF: written and read back exactly (few colors a frame)"

block gifWriteQuantized:
  let (w, h) = (96, 64)
  let frames = lightFrames(w, h, 8, true)
  for dither in [true, false]:
    let gif = encodeGifFrames(w, h, frames, dither = dither)
    let back = gifFrames(gif)
    doAssert back.len == frames.len and gifLoop(gif) == 0
    var sum, worst = 0
    for k in 0 ..< frames.len:
      for i in 0 ..< w * h:
        let a = back[k].bmp.px[i]
        let b = frames[k].px[i]
        doAssert (a shr 24) == 255
        for s in [0, 8, 16]:
          let d = abs(int((a shr s) and 255) - int((b shr s) and 255))
          sum += d
          worst = max(worst, d)
    let mean = sum / (frames.len * w * h * 3)
    echo "GIF: many colors, dither ", dither, ": mean error ", mean.formatFloat(ffDecimal, 2), ", worst ", worst,
         " (of 255), ", gif.len, " bytes"
    doAssert mean < 4 and (dither or worst <= 24)
    dump(if dither: "anim_dither" else: "anim_nodither", w, h, frames, 0, gif)

block gifSpeed:
  for drift in [true, false]:
    let frames = lightFrames(640, 480, 60, drift)
    let t = getMonoTime()
    let c = cpuTime()
    let gif = encodeGifFrames(640, 480, frames)
    echo "GIF 60 frames 640 x 480 (", (if drift: "every pixel changing" else: "a disc moving"), "): ",
         int(ms(t)), " ms (", int((cpuTime() - c) * 1000), " ms of processor time), ", gif.len div 1024, " KB"
    let t2 = getMonoTime()
    doAssert gifFrames(gif).len == 60
    echo "  read back: ", int(ms(t2)), " ms"

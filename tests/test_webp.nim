## Tests of `retroui/webp`: WebP files read and written, checked against libwebp.
##
## tests/data/webp holds files libwebp 1.6.0 wrote -- the copy Pillow 12
## carries, through Pillow and, for the settings Pillow does not offer
## (segments, the simple filter, sharpness, partitions, raw and filtered
## alpha, palettes, near-lossless), through ctypes -- and animations made
## by Pillow or put together by hand (offsets, blending, disposal, an
## unknown chunk). They were made, and the references below printed, by
##
##   python3 tests/data/webp/make.py tests/data/webp
##
## A reference is what libwebp decodes: the CRC-32 of the pixels (R G B A
## bytes, row by row; each frame of an animation as WebPAnimDecoder
## composes it) and the frame's duration. The retro-*.webp files were
## written by this module's encoders, their references printed by
## `make.py --refs` (libwebp's reading of them); astronaut-q75.png is
## libwebp's decoding of astronaut-q75.webp, whole.

import std/[os, math, monotimes, times, random, strutils]
import retroui/[gfx, codec, imaging, webp]

const dir = currentSourcePath().parentDir / "data" / "webp"

type Ref = tuple[name: string; w, h: int; frames: seq[(uint32, int)]]

const refs: seq[Ref] = @[
  # VP8: lossy 151x113, default settings: 4 segments, normal filter
  ("astronaut-q75.webp", 151, 113, @[(0x0035d134'u32, 0)]),
  # VP8: lossy, simple filter, sharpness 3, 8 partitions
  ("coffee-q30-simple.webp", 160, 97, @[(0xd9ac746f'u32, 0)]),
  # VP8: lossy, sharpness 6, 4 partitions
  ("chelsea-q92-sharp.webp", 97, 61, @[(0x1e3dbee6'u32, 0)]),
  # VP8: lossy, very low quality, strongest filter
  ("china-q5.webp", 128, 85, @[(0x437c3c44'u32, 0)]),
  # VP8: lossy graphic, one segment, no filter
  ("graphic-q50.webp", 129, 67, @[(0x7d2f6c37'u32, 0)]),
  # VP8: lossy, autofilter, 3 segments
  ("rocket-q60-auto.webp", 70, 111, @[(0xf23ccbf6'u32, 0)]),
  # VP8: lossy 3x1
  ("tiny-3x1.webp", 3, 1, @[(0xebf6d8eb'u32, 0)]),
  # VP8: lossy 1x17
  ("tiny-1x17.webp", 1, 17, @[(0xd679508e'u32, 0)]),
  # VP8X: lossy + alpha (lossless-coded alpha, fast filter)
  ("alpha-q70.webp", 101, 77, @[(0x908d595a'u32, 0)]),
  # VP8X: lossy + raw alpha, best filter
  ("alpha-raw-q60.webp", 91, 71, @[(0x2cb4686a'u32, 0)]),
  # VP8X: lossy + alpha with reduced levels
  ("alpha-levels-q60.webp", 91, 71, @[(0x44995d35'u32, 0)]),
  # VP8X: hand-made raw ALPH, horizontal filter, unknown chunk
  ("alpha-raw-horizontal.webp", 67, 49, @[(0x154616d9'u32, 0)]),
  # VP8X: hand-made raw ALPH, vertical filter, unknown chunk
  ("alpha-raw-vertical.webp", 67, 49, @[(0x154616d9'u32, 0)]),
  # VP8X: hand-made raw ALPH, gradient filter, unknown chunk
  ("alpha-raw-gradient.webp", 67, 49, @[(0x154616d9'u32, 0)]),
  # VP8L: lossless photo, default method 4
  ("ll-photo-m4.webp", 120, 90, @[(0x8ecd58fe'u32, 0)]),
  # VP8: the picture of ll-photo-m4.webp, lossy at quality 75 (for comparing encoders)
  ("ref-q75.webp", 120, 90, @[(0x19f36592'u32, 0)]),
  # VP8L: lossless photo, method 6 quality 100
  ("ll-photo-m6.webp", 96, 72, @[(0xbe7a5302'u32, 0)]),
  # VP8L: lossless photo, method 0 quality 0
  ("ll-photo-m0.webp", 96, 64, @[(0x15abb692'u32, 0)]),
  # VP8L: lossless, 12 colors (2 a byte)
  ("ll-palette12.webp", 77, 45, @[(0xfe408d3b'u32, 0)]),
  # VP8L: lossless, 4 colors (4 a byte)
  ("ll-palette4.webp", 63, 31, @[(0x76e0c710'u32, 0)]),
  # VP8L: lossless, 2 colors (8 a byte)
  ("ll-palette2.webp", 45, 21, @[(0x2782e3c7'u32, 0)]),
  # VP8L: lossless, ~200 colors (palette, 1 a byte)
  ("ll-palette200.webp", 64, 64, @[(0x4eb5ce63'u32, 0)]),
  # VP8L: lossless with alpha
  ("ll-alpha.webp", 80, 60, @[(0x42a1746a'u32, 0)]),
  # VP8L: near-lossless 60 (a VP8L stream)
  ("ll-near60.webp", 80, 60, @[(0x2bda25e3'u32, 0)]),
  # VP8L: lossless noise
  ("ll-noise.webp", 40, 30, @[(0x5f84cf13'u32, 0)]),
  # VP8X: VP8X with ICCP and EXIF, lossless
  ("ll-icc-exif.webp", 48, 40, @[(0x46e44cee'u32, 0)]),
  # VP8X: animation, mixed lossy/lossless, alpha, keyframes every 3
  ("anim-mixed.webp", 64, 48, @[
    (0x79face89'u32, 80), (0x6d1acc73'u32, 120), (0xaa928a9b'u32, 40), (0x8d663859'u32, 200),
    (0x1727bcb9'u32, 60), (0xb208a4c1'u32, 100)]),
  # VP8X: animation, lossy, sub-rectangles
  ("anim-lossy.webp", 64, 48, @[
    (0x66992284'u32, 70), (0x091b150b'u32, 70), (0xfd8450d6'u32, 70), (0xb69cbdd2'u32, 70),
    (0x1f1d95e6'u32, 70)]),
  # VP8X: hand-made animation: offsets, dispose, blend, lossy+alpha frames
  ("anim-handmade.webp", 60, 40, @[
    (0xb84cff64'u32, 100), (0x5c39e109'u32, 50), (0xe13c180e'u32, 70), (0xc22bcbce'u32, 90),
    (0x84015a17'u32, 60), (0xac8b461f'u32, 40), (0x8223f560'u32, 30)]),
  # VP8X: written by retroui/webp
  ("retro-alpha-q60.webp", 80, 60, @[(0xbea06d94'u32, 0)]),
  # VP8X: written by retroui/webp
  ("retro-anim-ll.webp", 60, 40, @[
    (0xb84cff64'u32, 100), (0x5c39e109'u32, 50), (0xe13c180e'u32, 70), (0xc22bcbce'u32, 90),
    (0x84015a17'u32, 60), (0xac8b461f'u32, 40), (0x8223f560'u32, 30)]),
  # VP8X: written by retroui/webp
  ("retro-anim-q70.webp", 60, 40, @[
    (0xbfc25060'u32, 100), (0xa60d79e0'u32, 50), (0x2ae152f6'u32, 70), (0xa51df5a0'u32, 90),
    (0x71b624bd'u32, 60), (0x11aa991a'u32, 40), (0x33d30766'u32, 30)]),
  # VP8L: written by retroui/webp
  ("retro-ll-palette.webp", 77, 45, @[(0xfe408d3b'u32, 0)]),
  # VP8L: written by retroui/webp
  ("retro-ll.webp", 96, 72, @[(0xbe7a5302'u32, 0)]),
  # VP8: written by retroui/webp
  ("retro-q75.webp", 120, 90, @[(0x616e4be3'u32, 0)]),
]

proc crcOf(b: Bitmap): uint32 =
  var bytes = newSeq[byte](b.px.len * 4)
  for i, p in b.px:
    bytes[4 * i] = byte((p shr 16) and 255)
    bytes[4 * i + 1] = byte((p shr 8) and 255)
    bytes[4 * i + 2] = byte(p and 255)
    bytes[4 * i + 3] = byte(p shr 24)
  crc32(bytes)

proc psnr(a, b: Bitmap): float =
  ## Of the colors (not alpha), in dB.
  var se = 0.0
  for i in 0 ..< a.px.len:
    for sh in [0, 8, 16]:
      let d = float(int((a.px[i] shr sh) and 255) - int((b.px[i] shr sh) and 255))
      se += d * d
  10 * log10(255.0 * 255.0 * float(a.px.len * 3) / max(se, 1e-9))

proc pic(name: string): Bitmap = decodeWebp(readFile(dir / name))

block libwebpFiles:
  # every file decodes to libwebp's pixels exactly, each frame of an animation too
  for r in refs:
    let data = readFile(dir / r.name)
    doAssert isWebp(data), r.name
    let info = webpInfo(data)
    doAssert info.w == r.w and info.h == r.h and info.frames == r.frames.len, r.name
    let frames = decodeWebpFrames(data)
    doAssert frames.len == r.frames.len, r.name
    for i, (b, ms) in frames:
      doAssert b.w == r.w and b.h == r.h
      doAssert crcOf(b) == r.frames[i][0], r.name & ", frame " & $i
      doAssert ms == r.frames[i][1], r.name & ", frame " & $i & " duration"
    doAssert crcOf(decodeWebp(data)) == r.frames[0][0]
  echo "webp: ", refs.len, " files decoded exactly as libwebp decodes them"

block levels:
  # the lossy picture against libwebp's, level by level
  let mine = pic("astronaut-q75.webp")
  let theirs = decodePng(readFile(dir / "astronaut-q75.png"))
  var most = 0
  var sum = 0
  for i in 0 ..< mine.px.len:
    for sh in [0, 8, 16]:
      let d = abs(int((mine.px[i] shr sh) and 255) - int((theirs.px[i] shr sh) and 255))
      most = max(most, d)
      sum += d
  echo "webp: lossy against libwebp: largest difference ", most, ", mean ",
       formatFloat(sum / (mine.px.len * 3), ffDecimal, 3), " levels"
  doAssert most == 0

block info:
  let a = webpInfo(readFile(dir / "ll-alpha.webp"))
  doAssert a.alpha and a.lossless and not a.animated and a.frames == 1
  let b = webpInfo(readFile(dir / "alpha-q70.webp"))
  doAssert b.alpha and not b.lossless and not b.animated
  let c = webpInfo(readFile(dir / "astronaut-q75.webp"))
  doAssert not c.alpha and not c.lossless
  let d = webpInfo(readFile(dir / "anim-mixed.webp"))
  doAssert d.animated and d.frames == 6 and d.alpha and d.lossless   # (libwebp chose so)
  let e = webpInfo(readFile(dir / "anim-lossy.webp"))
  doAssert e.animated and e.frames == 5 and not e.alpha and not e.lossless
  doAssert webpInfo(readFile(dir / "retro-anim-ll.webp")).lossless
  doAssert pic("astronaut-q75.webp").opaque and not pic("ll-alpha.webp").opaque

block damaged:
  # cut or scribbled on: refused with WebpError, never anything worse
  doAssert not isWebp("") and not isWebp("RIFF\0\0\0\0WAVEfmt ")
  for bad in ["", "RIFF", "\x89PNG\r\n\x1a\n0000000000000000"]:
    try:
      discard decodeWebp(bad)
      doAssert false
    except WebpError: discard
  var r = initRand(7)
  var files: seq[string]
  for f in refs: files.add readFile(dir / f.name)
  var refused = 0
  for it in 0 ..< 1500:
    var d = files[it mod files.len]
    case r.rand(2)
    of 0: d.setLen(r.rand(d.len))
    of 1:
      for _ in 0 .. r.rand(4): d[r.rand(d.high)] = char(r.rand(255))
    else:
      let i = 12 + r.rand(max(0, d.len - 13))
      for k in i ..< min(d.len, i + 8): d[k] = char(r.rand(255))
    try:
      discard decodeWebpFrames(d)
    except WebpError:
      inc refused
  doAssert refused > 0
  echo "webp: 1500 damaged files: ", refused, " refused, the rest decoded"

block lossless:
  # every pixel back, the color under transparent ones too; the size against libwebp's
  for name in ["ll-photo-m4.webp", "ll-photo-m6.webp", "ll-alpha.webp", "ll-palette12.webp",
               "ll-palette4.webp", "ll-palette2.webp", "ll-palette200.webp", "ll-noise.webp",
               "alpha-q70.webp", "graphic-q50.webp"]:
    let src = pic(name)
    let data = encodeWebpLossless(src)
    let info = webpInfo(data)
    doAssert info.lossless and not info.animated and info.alpha == not src.opaque
    doAssert decodeWebp(data).px == src.px, name
  for (w, h) in [(1, 1), (1, 17), (3, 1), (17, 33)]:
    let src = newBitmap(w, h)
    for i in 0 ..< w * h: src.px[i] = uint32(i) * 0x01030507'u32 or 0x80000000'u32
    doAssert decodeWebp(encodeWebpLossless(src)).px == src.px
  let photo = pic("ll-photo-m4.webp")
  let mine = encodeWebpLossless(photo).len
  let theirs = readFile(dir / "ll-photo-m4.webp").len
  echo "webp: lossless photo 120x90: ", mine, " bytes, libwebp (method 4) ", theirs
  doAssert mine <= theirs * 11 div 10

block lossy:
  # the same picture as libwebp at quality 75: PSNR and size
  let src = pic("ll-photo-m4.webp")
  let mine = encodeWebp(src, 75)
  let theirs = readFile(dir / "ref-q75.webp")
  let pm = psnr(decodeWebp(mine), src)
  let pt = psnr(decodeWebp(theirs), src)
  echo "webp: lossy q75 120x90: ", mine.len, " bytes ", formatFloat(pm, ffDecimal, 2),
       " dB; libwebp ", theirs.len, " bytes ", formatFloat(pt, ffDecimal, 2), " dB"
  doAssert pm >= pt - 0.5 and mine.len <= theirs.len * 13 div 10
  doAssert not webpInfo(mine).alpha and not webpInfo(mine).lossless
  # better with the quality, larger with it
  var lastSize = 0
  var lastPsnr = 0.0
  for q in [0, 25, 50, 75, 100]:
    let data = encodeWebp(src, q)
    let p = psnr(decodeWebp(data), src)
    doAssert data.len >= lastSize and p > lastPsnr, "quality " & $q
    lastSize = data.len
    lastPsnr = p
  doAssert lastPsnr > 40
  # transparency kept exactly
  let clear = pic("ll-alpha.webp")
  let back = decodeWebp(encodeWebp(clear, 60))
  doAssert webpInfo(encodeWebp(clear, 60)).alpha
  for i in 0 ..< clear.px.len: doAssert (back.px[i] shr 24) == (clear.px[i] shr 24)
  # small and odd sizes
  for (w, h) in [(1, 1), (1, 17), (3, 1), (17, 33)]:
    let s = newBitmap(w, h, 0xFF336699'u32)
    let b = decodeWebp(encodeWebp(s, 90))
    doAssert b.w == w and b.h == h
    for p in b.px: doAssert abs(int((p shr 8) and 255) - 0x66) <= 3

block encoderFiles:
  # the retro-*.webp (libwebp's reading of them is among the references
  # above) are what the encoders still write
  doAssert encodeWebp(pic("ll-photo-m4.webp"), 75) == readFile(dir / "retro-q75.webp")
  doAssert encodeWebp(pic("ll-alpha.webp"), 60) == readFile(dir / "retro-alpha-q60.webp")
  doAssert encodeWebpLossless(pic("ll-photo-m6.webp")) == readFile(dir / "retro-ll.webp")
  doAssert encodeWebpLossless(pic("ll-palette12.webp")) == readFile(dir / "retro-ll-palette.webp")
  let frames = decodeWebpFrames(readFile(dir / "anim-handmade.webp"))
  doAssert encodeWebpFrames(frames, loop = 3, quality = 70) == readFile(dir / "retro-anim-q70.webp")
  doAssert encodeWebpFrames(frames, lossless = true) == readFile(dir / "retro-anim-ll.webp")

block animation:
  var frames: seq[tuple[bmp: Bitmap; delayMs: int]]
  let base = pic("ll-photo-m6.webp")
  for k in 0 .. 4:
    let b = newBitmap(base.w, base.h)
    b.px = base.px
    for y in 10 ..< 30:
      for x in 5 + 9 * k ..< 25 + 9 * k: b.px[y * b.w + x] = 0x80FF2020'u32
    frames.add (b, 30 + k)
  frames.add (frames[^1].bmp, 50)                  # the same again: one frame, longer
  let ll = encodeWebpFrames(frames, loop = 2, lossless = true)
  let back = decodeWebpFrames(ll)
  doAssert back.len == 5 and back[4].delayMs == 34 + 50
  for k in 0 .. 4:
    doAssert back[k].bmp.px == frames[k].bmp.px
    if k < 4: doAssert back[k].delayMs == 30 + k
  let info = webpInfo(ll)
  doAssert info.animated and info.frames == 5 and info.alpha and info.lossless
  let lossy = decodeWebpFrames(encodeWebpFrames(frames, quality = 80))
  doAssert lossy.len == 5
  for k in 0 .. 4: doAssert psnr(lossy[k].bmp, frames[k].bmp) > 30
  doAssert crcOf(decodeWebp(ll)) == crcOf(frames[0].bmp)

block speed:
  # a 12-megapixel lossy picture: a photo laid side by side, with noise
  let tile = pic("ll-photo-m4.webp")
  let big = newBitmap(4000, 3000)
  var r = initRand(3)
  for y in 0 ..< 3000:
    for x in 0 ..< 4000:
      let p = tile.px[(y mod tile.h) * tile.w + (x * 7 div 5) mod tile.w]
      let n = r.rand(10) - 5
      var c = 0xFF000000'u32
      for sh in [0, 8, 16]: c = c or (uint32(clamp(int((p shr sh) and 255) + n, 0, 255)) shl sh)
      big.px[y * 4000 + x] = c
  var t = getMonoTime()
  let data = encodeWebp(big, 80)
  let enc = (getMonoTime() - t).inMilliseconds
  var best = high(int64)
  for _ in 0 .. 2:                                 # (the best of three: other work may run)
    t = getMonoTime()
    let b = decodeWebp(data)
    best = min(best, (getMonoTime() - t).inMilliseconds)
    doAssert b.w == 4000 and b.h == 3000
  echo "webp: 12 MP lossy (", data.len div 1024, " KB): encoded in ", enc, " ms, decoded in ",
       best, " ms"
  when defined(release) or defined(danger):
    doAssert best < 1500

echo "webp: all tests passed"

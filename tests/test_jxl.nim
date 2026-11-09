## Tests of `retroui/jxl`: JPEG XL files read and written, checked against libjxl.
##
## tests/data/jxl holds files libjxl 0.12 wrote -- the copy the imagecodecs
## wheel carries, reached through ctypes (lj.py) -- and two from libjxl's own
## test data (splines.jxl and splines-first-frame.jxl, CC BY 4.0, the JPEG XL
## Project Authors: no encoder writes splines). They were made, and the
## references below printed, by
##
##   python3 tests/data/jxl/make.py tests/data/jxl
##
## A reference is what libjxl decodes: the CRC-32 of the pixels (R G B A
## bytes, row by row; each frame of an animation as libjxl coalesces it) and
## the frame's duration. A lossless file must give exactly those pixels. A
## lossy one is measured against <name>.png, libjxl's pixels (the frames one
## under the other; of splines.jxl a 128x128 part): libjxl and this module
## dither their 8-bit output the same way, but float arithmetic done in
## another order is a last bit off now and then, so a sample may come out a
## level apart. The retro-*.jxl were written by this module's encoder; their
## references (`make.py --refs`) are libjxl's reading of them.

import std/[os, math, monotimes, times, random, strutils]
import retroui/[gfx, codec, imaging, jxl]

const dir = currentSourcePath().parentDir / "data" / "jxl"

type Ref = tuple[name: string; w, h: int; lossy: bool; frames: seq[(uint32, int)]]

const refs: seq[Ref] = @[
  # modular lossless 64x48, effort 1 (libjxl's fast lossless writer)
  ("ll-photo-e1.jxl", 64, 48, false, @[(0x4663e083'u32, 0)]),
  # modular lossless, effort 7: weighted predictor, MA tree, ANS
  ("ll-photo-e7.jxl", 64, 48, false, @[(0x4663e083'u32, 0)]),
  # modular lossless drawing 96x64, effort 9: palette
  ("ll-graphic-e9.jxl", 96, 64, false, @[(0xbb4c1337'u32, 0)]),
  # modular lossless with alpha (some of it 0), effort 3
  ("ll-alpha.jxl", 64, 48, false, @[(0x95e419c4'u32, 0)]),
  # modular lossless grayscale
  ("ll-gray.jxl", 64, 48, false, @[(0x5c99b166'u32, 0)]),
  # modular lossless, 16 bits a sample
  ("ll-16.jxl", 48, 32, false, @[(0xab1b28c0'u32, 0)]),
  # modular lossless 300x260 in nine groups of 128x128, effort 2
  ("ll-groups.jxl", 300, 260, false, @[(0xd21e55b8'u32, 0)]),
  # modular lossless, responsive: the squeeze transform
  ("ll-squeeze.jxl", 64, 48, false, @[(0x4663e083'u32, 0)]),
  # modular lossless text 160x48: patches
  ("ll-patches.jxl", 160, 48, false, @[(0xe2b37eb7'u32, 0)]),
  # modular lossless 48x32 with orientation 6: shown turned, 32x48
  ("ll-orient6.jxl", 32, 48, false, @[(0xf3e7fe0a'u32, 0)]),
  # container 32x24: the codestream in three jxlp boxes, an Exif box among them
  ("ll-container.jxl", 32, 24, false, @[(0x295fbee6'u32, 0)]),
  # lossless animation 48x32: frames cropped and blended (blend, replace, add)
  ("anim-ll.jxl", 48, 32, false, @[
    (0x3c244331'u32, 50), (0xab326e7e'u32, 100), (0x3c92d847'u32, 200), (0xd011af66'u32, 70)]),
  # VarDCT 96x72 at distance 1, effort 7 (what cjxl writes by default)
  ("vd-d1.jxl", 96, 72, true, @[(0xd9e2c4cf'u32, 0)]),
  # VarDCT with alpha
  ("vd-alpha.jxl", 64, 48, true, @[(0x36097cbb'u32, 0)]),
  # VarDCT, progressive: AC in passes, LF in a frame of its own
  ("vd-prog.jxl", 96, 72, true, @[(0x273cb52f'u32, 0)]),
  # VarDCT with photon noise and three passes of the edge preserving filter
  ("vd-noise.jxl", 64, 48, true, @[(0xeb75a47a'u32, 0)]),
  # VarDCT coded at half size, upsampled
  ("vd-up2.jxl", 96, 72, true, @[(0x6b3b410c'u32, 0)]),
  # a JPEG (4:2:0) recompressed, in a container with its jbrd box
  ("jpeg-420.jxl", 64, 48, true, @[(0x8c795a18'u32, 0)]),
  # modular lossy (quantized squeeze, XYB)
  ("md-lossy.jxl", 64, 48, true, @[(0x63c4f0f2'u32, 0)]),
  # VarDCT animation 48x32, three frames
  ("anim-lossy.jxl", 48, 32, true, @[(0x028ee3a9'u32, 100), (0x14d6d0bc'u32, 250), (0xcbdafdbe'u32, 40)]),
  # libjxl test data: splines on two frames, the first not shown
  ("splines-first-frame.jxl", 32, 32, true, @[(0x5a85f01b'u32, 0)]),
  # libjxl test data: many splines on 2048x2048
  ("splines.jxl", 2048, 2048, true, @[(0x71db92b5'u32, 0)]),
  # written by retroui/jxl (effort 5): libjxl reads ll-alpha.jxl's pixels back
  ("retro-alpha.jxl", 64, 48, false, @[(0x95e419c4'u32, 0)]),
  # written by retroui/jxl (effort 1): ll-photo-e7.jxl's pixels
  ("retro-e1.jxl", 64, 48, false, @[(0x4663e083'u32, 0)]),
  # written by retroui/jxl (effort 3)
  ("retro-e3.jxl", 64, 48, false, @[(0x4663e083'u32, 0)]),
  # written by retroui/jxl (effort 9)
  ("retro-e9.jxl", 64, 48, false, @[(0x4663e083'u32, 0)]),
  # written by retroui/jxl (effort 7): ll-graphic-e9.jxl's pixels, a palette
  ("retro-graphic.jxl", 96, 64, false, @[(0xbb4c1337'u32, 0)]),
  # written by retroui/jxl (effort 4): ll-gray.jxl's pixels
  ("retro-gray.jxl", 64, 48, false, @[(0x5c99b166'u32, 0)]),
  # written by retroui/jxl (effort 2): ll-groups.jxl's pixels, four groups of 256x256
  ("retro-groups.jxl", 300, 260, false, @[(0xd21e55b8'u32, 0)]),
]

proc crcOf(b: Bitmap): uint32 =
  var bytes = newSeq[byte](b.px.len * 4)
  for i, p in b.px:
    bytes[4 * i] = byte((p shr 16) and 255)
    bytes[4 * i + 1] = byte((p shr 8) and 255)
    bytes[4 * i + 2] = byte(p and 255)
    bytes[4 * i + 3] = byte(p shr 24)
  crc32(bytes)

proc crcOf(px: seq[uint16]): uint32 =
  var bytes = newSeq[byte](px.len * 2)
  for i, v in px:
    bytes[2 * i] = byte(v and 255)
    bytes[2 * i + 1] = byte(v shr 8)
  crc32(bytes)

proc pic(name: string): Bitmap = decodeJxl(readFile(dir / name))

proc sample(p: uint32; c: int): int = int((p shr (8 * c)) and 255)

var lossyMost = 0                       # (over all the lossy files)
var lossySum, lossyOff, lossyCount = 0

block libjxlFiles:
  # lossless files decode to libjxl's pixels exactly, lossy ones within a
  # level of them; each frame of an animation, and its duration
  var exact, near = 0
  for r in refs:
    let data = readFile(dir / r.name)
    doAssert isJxl(data), r.name
    let info = jxlInfo(data)
    doAssert info.w == r.w and info.h == r.h and info.frames == r.frames.len, r.name
    let frames = decodeJxlFrames(data)
    doAssert frames.len == r.frames.len, r.name
    for i, (b, ms) in frames:
      doAssert b.w == r.w and b.h == r.h, r.name
      doAssert ms == r.frames[i][1], r.name & ", frame " & $i & " duration"
    if not r.lossy:
      for i, (b, ms) in frames:
        doAssert crcOf(b) == r.frames[i][0], r.name & ", frame " & $i
      doAssert crcOf(decodeJxl(data)) == r.frames[0][0], r.name
      inc exact
    else:
      let theirs = decodePng(readFile(dir / r.name.changeFileExt("png")))
      let (x0, y0) = if r.name == "splines.jxl": (1024, 0) else: (0, 0)
      var most, sum, n = 0
      for i, (b, ms) in frames:
        for y in 0 ..< theirs.h div frames.len:
          for x in 0 ..< theirs.w:
            let p = b.px[(y0 + y) * b.w + x0 + x]
            let q = theirs.px[(i * (theirs.h div frames.len) + y) * theirs.w + x]
            for c in 0 .. 3:
              let d = abs(sample(p, c) - sample(q, c))
              most = max(most, d)
              sum += d
              if d != 0: inc lossyOff
              inc n
      doAssert most <= 2, r.name & ": " & $most & " levels from libjxl's pixels"
      doAssert sum <= n div 50, r.name & ": " & $(sum / n) & " levels from libjxl's pixels on average"
      doAssert decodeJxl(data).px == frames[0].bmp.px, r.name
      lossyMost = max(lossyMost, most)
      lossySum += sum
      lossyCount += n
      inc near
  echo "jxl: ", exact, " lossless files decoded exactly as libjxl decodes them; ", near,
       " lossy ones at most ", lossyMost, " level from libjxl's pixels (", lossyOff, " samples of ",
       lossyCount, " differ; ", formatFloat(lossySum / lossyCount, ffDecimal, 5), " on average)"

block info:
  let a = jxlInfo(readFile(dir / "ll-alpha.jxl"))
  doAssert a.hasAlpha and a.bits == 8 and a.frames == 1
  let b = jxlInfo(readFile(dir / "vd-d1.jxl"))
  doAssert not b.hasAlpha and b.bits == 8
  let c = jxlInfo(readFile(dir / "ll-16.jxl"))
  doAssert c.bits == 16 and not c.hasAlpha
  let d = jxlInfo(readFile(dir / "anim-ll.jxl"))
  doAssert d.frames == 4 and d.hasAlpha
  let e = jxlInfo(readFile(dir / "ll-orient6.jxl"))       # turned: as shown
  doAssert e.w == 32 and e.h == 48
  let t = getMonoTime()
  let f = jxlInfo(readFile(dir / "flat-12mp.jxl"))        # headers only: at once
  doAssert f.w == 4000 and f.h == 3000 and f.frames == 1
  doAssert (getMonoTime() - t).inMilliseconds < (when sizeof(int) == 8: 100 else: 1000)
  doAssert jxlInfo(readFile(dir / "vd-prog.jxl")).frames == 1   # (the LF frame is not shown)
  doAssert jxlInfo(readFile(dir / "splines-first-frame.jxl")).frames == 1
  doAssert pic("vd-d1.jxl").opaque and not pic("ll-alpha.jxl").opaque

block sixteen:
  # 16 bits a sample, exactly as libjxl gives them (an 8-bit file widened)
  let a = decodeJxl16(readFile(dir / "ll-16.jxl"))
  doAssert a.w == 48 and a.h == 32 and a.px.len == 48 * 32 * 4
  doAssert crcOf(a.px) == 0x2638ae1d'u32
  let b = decodeJxl16(readFile(dir / "ll-alpha.jxl"))
  doAssert crcOf(b.px) == 0x8732933a'u32
  # a lossy file: the 8-bit pixels are these, rounded (and dithered: a level at most)
  let c = decodeJxl16(readFile(dir / "vd-d1.jxl"))
  let c8 = pic("vd-d1.jxl")
  doAssert c.w == c8.w and c.h == c8.h
  for i, p in c8.px:
    for k, sh in [16, 8, 0, 24]:
      let wide = int(c.px[4 * i + k])
      doAssert abs(int((p shr sh) and 255) * 257 - wide) <= 257 + 128

block container:
  # the codestream bare, in one jxlc box, in jxlp boxes: the same picture
  let cs = readFile(dir / "ll-photo-e7.jxl")
  proc box(t, payload: string): string =
    let n = 8 + payload.len
    result = char(n shr 24) & char((n shr 16) and 255) & char((n shr 8) and 255) & char(n and 255)
    result.add t
    result.add payload
  let head = "\0\0\0\x0CJXL \r\n\x87\n" & box("ftyp", "jxl \0\0\0\0jxl ")
  let one = head & box("Exif", "\0\0\0\0MM\0\x2a") & box("jxlc", cs)
  let parts = head & box("jxlp", "\0\0\0\0" & cs[0 ..< 10]) & box("xml ", "<x/>") &
              box("jxlp", "\x80\0\0\x01" & cs[10 .. ^1])
  doAssert isJxl(cs) and isJxl(one) and isJxl(parts)
  let want = pic("ll-photo-e7.jxl").px
  doAssert decodeJxl(one).px == want and decodeJxl(parts).px == want
  doAssert jxlInfo(one).w == 64 and jxlInfo(parts).h == 48

block damaged:
  # cut or scribbled on: refused with JxlError, never anything worse
  doAssert not isJxl("") and not isJxl("\xFF") and not isJxl("\x89PNG\r\n\x1a\n")
  for bad in ["", "\xFF\x0A", "\xFF\x0A\0\0", "\0\0\0\x0CJXL \r\n\x87\n", "\x89PNG\r\n\x1a\n0000"]:
    doAssertRaises(JxlError): discard decodeJxl(bad)
    doAssertRaises(JxlError): discard decodeJxl16(bad)
    doAssertRaises(JxlError): discard decodeJxlFrames(bad)
    doAssertRaises(JxlError): discard jxlInfo(bad)
  var r = initRand(7)
  var files: seq[string]
  for f in refs:
    if f.w * f.h <= 100_000: files.add readFile(dir / f.name)
  var refused = 0
  for it in 0 ..< 1500:
    var d = files[it mod files.len]
    case r.rand(2)
    of 0: d.setLen(r.rand(d.len))
    of 1:
      for _ in 0 .. r.rand(4): d[r.rand(d.high)] = char(r.rand(255))
    else:
      let i = 2 + r.rand(max(0, d.len - 3))
      for k in i ..< min(d.len, i + 8): d[k] = char(r.rand(255))
    try:
      discard decodeJxlFrames(d)
    except JxlError:
      inc refused
  doAssert refused > 0
  echo "jxl: 1500 damaged files: ", refused, " refused, the rest decoded"

block lossless:
  # every pixel back at every effort, the color under transparent ones too
  for name in ["ll-photo-e7.jxl", "ll-alpha.jxl", "ll-gray.jxl", "ll-graphic-e9.jxl",
               "ll-patches.jxl", "vd-alpha.jxl", "anim-ll.jxl"]:
    let src = pic(name)
    for effort in 1 .. 9:
      let data = encodeJxlLossless(src, effort)
      let info = jxlInfo(data)
      doAssert info.w == src.w and info.h == src.h and info.hasAlpha == not src.opaque
      doAssert decodeJxl(data).px == src.px, name & ", effort " & $effort
  var r = initRand(5)
  for (w, h) in [(1, 1), (1, 17), (3, 1), (17, 33), (257, 3), (2, 300)]:
    let src = newBitmap(w, h)
    for i in 0 ..< w * h: src.px[i] = uint32(r.next() and 0xFFFFFFFF'u64)
    for effort in [1, 3, 7]:
      doAssert decodeJxl(encodeJxlLossless(src, effort)).px == src.px, $w & "x" & $h
  # one color; 2000 colors (too many for a palette); gray with alpha
  let flat = newBitmap(40, 30, 0xFF123456'u32)
  doAssert decodeJxl(encodeJxlLossless(flat)).px == flat.px
  doAssert encodeJxlLossless(flat).len < 100
  let many = newBitmap(80, 50)
  for i in 0 ..< many.px.len: many.px[i] = 0xFF000000'u32 or uint32(i * 7919 mod 2000 * 4099)
  for effort in [1, 3, 5]: doAssert decodeJxl(encodeJxlLossless(many, effort)).px == many.px
  let ga = newBitmap(30, 20)
  for i in 0 ..< ga.px.len:
    let v = uint32(i * 3 mod 256)
    ga.px[i] = (uint32(i mod 200) shl 24) or (v shl 16) or (v shl 8) or v
  doAssert decodeJxl(encodeJxlLossless(ga, 5)).px == ga.px
  # sizes against libjxl's lossless files of the same picture
  let photo = pic("ll-photo-e7.jxl")
  var sizes: seq[string]
  for effort in [1, 3, 7, 9]: sizes.add $encodeJxlLossless(photo, effort).len & " (effort " & $effort & ")"
  echo "jxl: lossless photo 64x48: ", sizes.join(", "), " bytes; libjxl ",
       readFile(dir / "ll-photo-e1.jxl").len, " (effort 1), ", readFile(dir / "ll-photo-e7.jxl").len,
       " (effort 7)"
  doAssert encodeJxlLossless(photo, 1).len <= readFile(dir / "ll-photo-e1.jxl").len
  doAssert encodeJxlLossless(photo, 7).len <= readFile(dir / "ll-photo-e7.jxl").len * 21 div 20
  doAssertRaises(JxlError): discard encodeJxlLossless(newBitmap(0, 0))

block encoderFiles:
  # the retro-*.jxl are what the encoder still writes; libjxl's reading of
  # them (the references above) is the picture each was made from
  for (name, src, effort) in [("retro-e1.jxl", "ll-photo-e7.jxl", 1), ("retro-e3.jxl", "ll-photo-e7.jxl", 3),
                              ("retro-e9.jxl", "ll-photo-e7.jxl", 9), ("retro-alpha.jxl", "ll-alpha.jxl", 5),
                              ("retro-graphic.jxl", "ll-graphic-e9.jxl", 7),
                              ("retro-gray.jxl", "ll-gray.jxl", 4), ("retro-groups.jxl", "ll-groups.jxl", 2)]:
    let p = pic(src)
    doAssert encodeJxlLossless(p, effort) == readFile(dir / name), name
    for r in refs:
      if r.name == name: doAssert r.frames[0][0] == crcOf(p), name

proc psnr(a, b: Bitmap): float =
  ## (of the color, in dB)
  var se = 0.0
  for i in 0 ..< a.px.len:
    for c in 0 .. 2:
      let d = float(sample(a.px[i], c) - sample(b.px[i], c))
      se += d * d
  10 * log10(255.0 * 255.0 * float(a.px.len * 3) / max(se, 1e-9))

proc scene(w, h: int; seed = 1): Bitmap =
  ## Gradients, a soft blob, hard edges (a disc, a bar, thin lines), stripes and noise.
  result = newBitmap(w, h)
  var r = initRand(seed)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let fx = x / w
      let fy = y / h
      var c = [40 + 170 * fx, 60 + 130 * fy, 170 - 90 * fx * fy]
      let blob = exp(-((fx - 0.7) ^ 2 + (fy - 0.3) ^ 2) * 18)
      c[0] += 60 * blob
      c[2] -= 80 * blob
      if (x - w div 4) ^ 2 + (y - h * 2 div 3) ^ 2 < (h div 5) ^ 2: c = [210.0 - 40 * fy, 190.0, 60.0]
      if x in w * 3 div 5 ..< w * 3 div 5 + w div 8 and y > h div 2: c = [25.0, 35.0, 60.0 + 60 * fy]
      if (x + 2 * y) mod 97 < 2: c = [10.0, 10.0, 20.0]
      if y in h div 8 ..< h div 4: c[1] += 22 * sin(float(x) * 1.1)
      for k in 0 .. 2: c[k] += r.gauss(0, 1.5)
      result.px[y * w + x] = 0xFF000000'u32 or (uint32(clamp(c[0], 0, 255)) shl 16) or
                             (uint32(clamp(c[1], 0, 255)) shl 8) or uint32(clamp(c[2], 0, 255))

block lossy:
  # encodeJxl: the picture in XYB, squeezed, the squeeze's differences
  # quantized the more the lower the quality; the quality falls with q, and
  # the size with it; 100 is lossless
  doAssert jxlDistance(100) == 0 and abs(jxlDistance(90) - 1.0) < 1e-9
  doAssert abs(jxlDistance(50) - 4.6) < 1e-9 and abs(jxlDistance(30) - 6.4) < 1e-9
  for q in 1 ..< 100: doAssert jxlDistance(q) > jxlDistance(q + 1)
  let pic = scene(320, 240)
  let ll = encodeJxlLossless(pic)
  doAssert encodeJxl(pic, 100) == ll and encodeJxlDistance(pic, 1.0) == encodeJxl(pic, 90)
  var lastSize = ll.len
  var lastDb = Inf
  var report: seq[string]
  for (q, least) in [(99, 41.5), (95, 37.0), (90, 34.0), (75, 30.5), (50, 28.5), (30, 26.5), (10, 22.5)]:
    let data = encodeJxl(pic, q)
    let info = jxlInfo(data)
    doAssert info.w == 320 and info.h == 240 and not info.hasAlpha and info.frames == 1
    let back = decodeJxl(data)
    doAssert back.w == 320 and back.h == 240 and back.opaque
    let db = psnr(pic, back)
    doAssert db >= least, "quality " & $q & ": " & $db & " dB"
    doAssert data.len < lastSize and db < lastDb, "quality " & $q
    if q == 90: doAssert data.len * 100 <= ll.len * 15, "quality 90: " & $data.len & " bytes"
    lastSize = data.len
    lastDb = db
    report.add $q & ": " & formatFloat(db, ffDecimal, 1) & " dB " & $data.len
  echo "jxl: lossy 320x240 (", ll.len, " bytes lossless), quality ", report.join(", ")
  # the effort changes the bytes, never the pixels
  let at3 = encodeJxl(pic, 90, 3)
  for e in [1, 2, 5, 7]: doAssert decodeJxl(encodeJxl(pic, 90, e)).px == decodeJxl(at3).px
  doAssert at3.len < encodeJxl(pic, 90, 1).len
  # one pixel, two, thin pictures, groups crossed (257 wide, 300 high), LF
  # groups crossed (2100 wide)
  for (w, h, least) in [(1, 1, 40.0), (2, 1, 40.0), (3, 700, 21.0), (700, 3, 21.0), (257, 300, 27.0),
                        (2100, 40, 27.0)]:
    let p = scene(w, h)
    for (q, e) in [(90, 3), (40, 1)]:
      let data = encodeJxl(p, q, e)
      let info = jxlInfo(data)
      doAssert info.w == w and info.h == h and not info.hasAlpha
      let back = decodeJxl(data)
      doAssert back.w == w and back.h == h and back.opaque
      doAssert psnr(p, back) >= least + (if q == 90: 4.0 else: 0.0), $w & "x" & $h & " quality " & $q
  # alpha kept exactly: a gradient of it, every pixel clear, ll-alpha.jxl's
  var ag = scene(300, 200)
  for i in 0 ..< ag.px.len: ag.px[i] = (ag.px[i] and 0xFFFFFF) or (uint32((i mod 300) * 255 div 299) shl 24)
  var clear = scene(64, 48)
  for p in clear.px.mitems: p = p and 0xFFFFFF
  for (p, e) in [(ag, 1), (ag, 3), (ag, 5), (clear, 3), (pic("ll-alpha.jxl"), 2)]:
    let data = encodeJxl(p, 80, e)
    doAssert jxlInfo(data).hasAlpha
    let back = decodeJxl(data)
    for i in 0 ..< p.px.len: doAssert back.px[i] shr 24 == p.px[i] shr 24
    doAssert psnr(p, back) >= 28
  # gray: Y alone (X and B - Y are 0 and cost nothing), read back gray (a
  # level apart at most: each channel is dithered on its own)
  var gray = scene(200, 150)
  for p in gray.px.mitems:
    let v = uint32(sample(p, 1))
    p = 0xFF000000'u32 or (v shl 16) or (v shl 8) or v
  let gd = encodeJxl(gray, 90)
  let gback = decodeJxl(gd)
  for p in gback.px: doAssert abs(sample(p, 0) - sample(p, 1)) <= 1 and abs(sample(p, 2) - sample(p, 1)) <= 1
  doAssert psnr(gray, gback) >= 38 and gd.len * 5 < encodeJxl(scene(200, 150), 90).len * 4
  # one color: next to nothing
  let flat = newBitmap(500, 400, 0xFF3366CC'u32)
  for e in [1, 3]:
    let data = encodeJxl(flat, 90, e)
    doAssert data.len <= 120, $data.len
    for p in decodeJxl(data).px:
      for c in 0 .. 2: doAssert abs(sample(p, c) - sample(0xFF3366CC'u32, c)) <= 1
  doAssertRaises(JxlError): discard encodeJxl(newBitmap(0, 0))
  # files libjxl 0.12 (the imagecodecs wheel's, through tests/data/jxl/lj.py)
  # read to within a level of what decodeJxl makes of them: the encoder still
  # writes those bytes. When it changes, and these CRCs with it, read its
  # files with lj.decode again before writing the new CRCs here
  let photo = pic("ll-photo-e7.jxl")
  let wide = newBitmap(2100, 300)                    # (9 x 2 groups, 2 LF groups)
  for y in 0 ..< 300:
    for x in 0 ..< 2100: wide.px[y * 2100 + x] = photo.px[(y mod 48) * 64 + (x * 3 + y) mod 64]
  for (p, q, e, crc) in [(photo, 90, 3, 0x2d41e6ff'u32), (pic("ll-alpha.jxl"), 75, 2, 0x9fcccc42'u32),
                         (wide, 60, 4, 0xe699595d'u32), (pic("ll-gray.jxl"), 90, 7, 0x4b1cb3e9'u32)]:
    let data = encodeJxl(p, q, e)
    doAssert crc32(data.toOpenArrayByte(0, data.high)) == crc, $p.w & "x" & $p.h & " quality " & $q

block animation:
  let frames = decodeJxlFrames(readFile(dir / "anim-ll.jxl"))
  doAssert frames.len == 4
  var ms: seq[int]
  for f in frames: ms.add f.delayMs
  doAssert ms == @[50, 100, 200, 70]
  doAssert crcOf(pic("anim-ll.jxl")) == crcOf(frames[0].bmp)
  let still = decodeJxlFrames(readFile(dir / "ll-alpha.jxl"))
  doAssert still.len == 1 and still[0].delayMs == 0

block speed:
  # 12 megapixels of VarDCT (little in them, but every step of the decoder runs
  # over all of them), and a 12-megapixel photo written lossless and read back
  let data = readFile(dir / "flat-12mp.jxl")
  var best = high(int64)
  var b: Bitmap
  for _ in 0 .. 2:                                 # (the best of three: other work may run)
    let t = getMonoTime()
    b = decodeJxl(data)
    best = min(best, (getMonoTime() - t).inMilliseconds)
  doAssert b.w == 4000 and b.h == 3000
  for (x, y, want) in [(0, 0, 0xff4579b4'u32), (2000, 1500, 0xffc7a03e'u32), (2000, 1050, 0xfffafafa'u32),
                       (1101, 1500, 0xffc89f3c'u32), (3999, 2999, 0xff4579b4'u32)]:
    for c in 0 .. 3: doAssert abs(sample(b.px[y * 4000 + x], c) - sample(want, c)) <= 1
  let tile = pic("ll-photo-e7.jxl")
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
  let ll = encodeJxlLossless(big, 1)
  let enc = (getMonoTime() - t).inMilliseconds
  t = getMonoTime()
  let back = decodeJxl(ll)
  let dec = (getMonoTime() - t).inMilliseconds
  doAssert back.px == big.px
  echo "jxl: 12 MP VarDCT decoded in ", best, " ms; 12 MP photo lossless (effort 1, ",
       ll.len div 1024, " KB) written in ", enc, " ms, read in ", dec, " ms"
  t = getMonoTime()
  let lossy = encodeJxl(big, 90, 3)
  let lenc = (getMonoTime() - t).inMilliseconds
  t = getMonoTime()
  let lback = decodeJxl(lossy)
  let ldec = (getMonoTime() - t).inMilliseconds
  doAssert lback.w == 4000 and lback.h == 3000 and lossy.len < ll.len div 3
  echo "jxl: 12 MP photo at quality 90 (effort 3, ", lossy.len div 1024, " KB, ",
       formatFloat(psnr(big, lback), ffDecimal, 1), " dB) written in ", lenc, " ms, read in ", ldec, " ms"
  when defined(release) or defined(danger):
    doAssert best < 3000

echo "jxl: all tests passed"

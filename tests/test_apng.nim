## Animated PNG (`retroui/apng`): frames written as one and read back the same, each delay and
## the loop kept; a plain PNG read as one frame; frames that cover part of the picture put on
## it as they say (over what is there, the area cleared after, put back after); Python's
## Pillow reads what is written, when it is there; a document's animation saved and opened as
## an APNG (`retroui/photofiles`).

import std/[os, osproc, strutils]
import retroui/[gfx, imaging, apng, photo, photoanim, photofiles, codec]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc solid(w, h: int; c: uint32): seq[uint32] =
  result = newSeq[uint32](w * h)
  for p in result.mitems: p = c

block roundTrip:
  let frames = @[(solid(8, 6, 0xFFFF0000'u32), 100), (solid(8, 6, 0xFF00FF00'u32), 250),
                 (solid(8, 6, 0x800000FF'u32), 40)]
  let data = encodeApng(8, 6, frames, loop = 3)
  check isApng(data) and apngLoop(data) == 3, "an animated PNG playing three times"
  let back = decodeApng(data)
  check back.len == 3 and back[0].delayMs == 100 and back[1].delayMs == 250 and back[2].delayMs == 40,
        "three frames, each its delay"
  check back[0].bmp.px[0] == 0xFFFF0000'u32 and back[1].bmp.px[47] == 0xFF00FF00'u32 and
        back[2].bmp.px[5] == 0x800000FF'u32, "each frame's pixels, transparency kept"
  check decodePng(data).px[0] == 0xFFFF0000'u32, "a program that shows one picture: the first frame"
  let plain = encodePng(newBitmap(4, 4))
  check not isApng(plain) and decodeApng(plain).len == 1 and apngLoop(plain) == -1, "a plain PNG: one frame"
  if findExe("python3").len > 0:
    let tmp = getTempDir() / "retro-apng-test.png"
    writeFile(tmp, data)
    let (o, code) = execCmdEx("python3 -c \"from PIL import Image; im=Image.open('" & tmp &
                              "'); print(im.n_frames, im.info.get('loop'))\"")
    if code == 0: check o.strip == "3 3", "Pillow reads it: " & o.strip
    else: echo "  (Pillow not here: not tried)"
    removeFile(tmp)

block partsOfThePicture:
  # (an APNG made by hand: a 4 x 4 red picture, then a 2 x 2 blue frame at 1, 1 over it, cleared
  # after; then a 1 x 1 green one at 0, 0)
  proc chunk(tag, data: string): string =
    proc p32(v: int): string = char((v shr 24) and 255) & char((v shr 16) and 255) & char((v shr 8) and 255) &
                               char(v and 255)
    let body = tag & data
    # (the CRC as its four bytes: as an int it would not fit in 32 bits)
    let crc = crc32(body.toOpenArrayByte(0, body.high))
    p32(data.len) & body & char((crc shr 24) and 255) & char((crc shr 16) and 255) & char((crc shr 8) and 255) &
      char(crc and 255)
  proc idatOf(px: seq[uint32]; w, h: int): tuple[hdr, idat: string] =
    let b = newBitmap(w, h)
    b.px = px
    let png = encodePng(b, alpha = 1)
    var i = 8
    while i + 8 <= png.len:
      let n = (ord(png[i]) shl 24) or (ord(png[i + 1]) shl 16) or (ord(png[i + 2]) shl 8) or ord(png[i + 3])
      let tag = png[i + 4 ..< i + 8]
      if tag == "IHDR": result.hdr = png[i + 8 ..< i + 8 + n]
      if tag == "IDAT": result.idat.add png[i + 8 ..< i + 8 + n]
      i += 12 + n
  proc fctl(sq, w, h, x, y, dispose, blend: int): string =
    proc p32(v: int): string = char((v shr 24) and 255) & char((v shr 16) and 255) & char((v shr 8) and 255) &
                               char(v and 255)
    p32(sq) & p32(w) & p32(h) & p32(x) & p32(y) & "\x00\x0A\x00\x64" & char(dispose) & char(blend)
  let a = idatOf(solid(4, 4, 0xFFFF0000'u32), 4, 4)
  let b = idatOf(solid(2, 2, 0xFF0000FF'u32), 2, 2)
  let c = idatOf(solid(1, 1, 0xFF00FF00'u32), 1, 1)
  var data = "\x89PNG\r\n\x1a\n" & chunk("IHDR", a.hdr) & chunk("acTL", "\x00\x00\x00\x03\x00\x00\x00\x00")
  data.add chunk("fcTL", fctl(0, 4, 4, 0, 0, 0, 0)) & chunk("IDAT", a.idat)
  data.add chunk("fcTL", fctl(1, 2, 2, 1, 1, 1, 1)) & chunk("fdAT", "\x00\x00\x00\x02" & b.idat)
  data.add chunk("fcTL", fctl(3, 1, 1, 0, 0, 0, 1)) & chunk("fdAT", "\x00\x00\x00\x04" & c.idat)
  data.add chunk("IEND", "")
  let f = decodeApng(data)
  check f.len == 3 and f[0].delayMs == 100, "three frames, 10/100 of a second each"
  check f[1].bmp.px[1 * 4 + 1] == 0xFF0000FF'u32 and f[1].bmp.px[0] == 0xFFFF0000'u32,
        "the second over the first where it is"
  check f[2].bmp.px[0] == 0xFF00FF00'u32 and f[2].bmp.px[1 * 4 + 1] == 0 and f[2].bmp.px[3] == 0xFFFF0000'u32,
        "the third after the second's area was cleared"

block documents:
  let d = newDoc(16, 12, 0xFFFFFFFF'u32, name = "anim")
  let A = d.addLayer("one")
  for p in A.px.mitems: p = 0xFFFF0000'u32
  let B = d.addLayer("two")
  for p in B.px.mitems: p = 0xFF0000FF'u32
  d.framesFromLayers(delay = 120)
  d.animLoop = 0
  let path = getTempDir() / "retro-apng-doc.png"
  d.exportAnimation(path, format = "apng")
  let data = readFile(path)
  check isApng(data) and decodeApng(data).len == d.frames.len, "a document's frames saved as an APNG (" &
        $d.frames.len & ")"
  let back = openPicture(path)
  check back.frames.len == d.frames.len and back.frames[0].delay == 120, "opened as frames again"
  removeFile(path)

if failures > 0:
  echo "test_apng: ", failures, " failed"
  quit(1)
echo "test_apng: all passed"

## retroui/lzma: every font the kit packs with LZMA unpacks to its own
## .ttf; packings cut short or damaged anywhere, and bytes of no packing at
## all, give "" -- never a crash, never a read past their end.

import std/[os, random]
import retroui/[lzma, unpacking]

const fonts = currentSourcePath().parentDir / ".." / "src" / "retroui" / "fonts"

var n = 0
for z in walkFiles(fonts / "*.ttf.z"):
  let packed = readFile(z)
  let ttf = readFile(z[0 ..< ^2])
  if isLzma(packed):
    doAssert unlzma(packed) == ttf, z
    inc n
  doAssert unpackBytes(packed) == ttf, z     # (zlib or LZMA, the same bytes)
doAssert n >= 8, "the fonts packed with LZMA: " & $n

# cut short, damaged, or not a packing: "" (or, damaged where it does not
# matter, the font), and nothing read past the end
let sample = readFile(fonts / "FreeSerif.ttf.z")
let want = readFile(fonts / "FreeSerif.ttf")
doAssert isLzma(sample)
for cut in [0, 4, 12, 13, 17, 18, 64, sample.len div 3, sample.len - 40]:
  let got = unlzma(sample[0 ..< cut])
  doAssert got.len == 0, "cut at " & $cut
# (its last bytes are the end's mark, not needed when the size is known)
doAssert unlzma(sample[0 ..< ^1]) in ["", want]
var r = initRand(48)
for round in 0 ..< 60:
  var bad = sample
  for _ in 0 .. r.rand(8):
    let i = 13 + r.rand(bad.len - 14)
    bad[i] = char(r.rand(255))
  let got = unlzma(bad)
  doAssert got.len == 0 or got.len == want.len
for round in 0 ..< 200:
  var junk = "RLZ1"
  for _ in 0 ..< 9 + r.rand(300): junk.add char(r.rand(255))
  discard unlzma(junk)
doAssert unlzma("not packed at all") == ""
doAssert not isLzma("RLZ")
echo "lzma: ", n, " fonts, damaged packings: ok"

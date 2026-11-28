## Reading codes: QR codes from their modules (mended where damaged) and from pictures -- placed
## anywhere, turned, in perspective --; barcodes (EAN-13, UPC-A, EAN-8, Code 128, Code 39) made
## and read back across, turned and upside down; the scanner view built.

import retroui/scanner
doAssert compiles(scannerView()), "the scanner view"
import std/[math, random]
import retroui/[gfx, qrcode, barcode]
randomize(3)
# modules straight back
for text in ["HELLO WORLD", "0123456789012345", "https://foxoman.net/retroui?x=1&y=2", "سلام عليكم"]:
  for ec in QrEcc:
    let q = qrEncode(text, ec)
    var mods = newSeq[bool](q.size * q.size)
    for y in 0 ..< q.size:
      for x in 0 ..< q.size: mods[y * q.size + x] = q[x, y]
    var m = 0
    let r = qrDecodeModules(mods, q.size, m)
    doAssert r.ok and r.text == text, text & " " & $ec
    # damage a few codewords' modules: mended
    var bad = mods
    for k in 0 ..< 6:
      let x = 9 + rand(q.size - 18)
      let y = 9 + rand(q.size - 18)
      bad[y * q.size + x] = not bad[y * q.size + x]
    var m2 = 0
    let r2 = qrDecodeModules(bad, q.size, m2)
    if ec >= qrM: doAssert r2.ok and r2.text == text and m2 > 0, "mended " & text & " " & $ec & " " & $m2
echo "  ok   QR from its modules, mended"
# from pictures
for (text, ver) in [("HELLO", 1), ("https://github.com/foxoman/retroui", 3), ("A longer text that needs a bigger code, version seven or more to hold it all in", 7)]:
  let q = qrEncode(text, qrM, minVersion = ver)
  let b = qrBitmap(q, scale = 6, border = 4)
  let rs = qrRead(b)
  doAssert rs.len == 1 and rs[0].text == text, "picture " & text & " " & $rs.len
  # on a bigger picture, off its middle, gray background
  let big = newBitmap(b.w + 220, b.h + 160, 0xFFB0B0B0'u32)
  for y in 0 ..< b.h:
    for x in 0 ..< b.w: big.px[(y + 70) * big.w + x + 130] = b.px[y * b.w + x]
  let rs2 = qrRead(big)
  doAssert rs2.len == 1 and rs2[0].text == text, "placed " & text
  # turned a quarter
  let t = newBitmap(b.h, b.w)
  for y in 0 ..< b.h:
    for x in 0 ..< b.w: t.px[x * t.w + (b.h - 1 - y)] = b.px[y * b.w + x]
  let rs3 = qrRead(t)
  doAssert rs3.len == 1 and rs3[0].text == text, "turned " & text
  # turned 20 degrees, a little smaller
  let a = degToRad(20.0)
  let sz = int(float(b.w) * 1.5)
  let rot = newBitmap(sz, sz, 0xFFFFFFFF'u32)
  for y in 0 ..< sz:
    for x in 0 ..< sz:
      let dx = float(x - sz div 2)
      let dy = float(y - sz div 2)
      let sx = int(cos(a) * dx + sin(a) * dy) + b.w div 2
      let sy = int(-sin(a) * dx + cos(a) * dy) + b.h div 2
      if sx >= 0 and sy >= 0 and sx < b.w and sy < b.h: rot.px[y * sz + x] = b.px[sy * b.w + sx]
  let rs4 = qrRead(rot)
  doAssert rs4.len == 1 and rs4[0].text == text, "rotated " & text & " " & $rs4.len
echo "  ok   QR from pictures"
for (k, t, want) in [(bcEan13, "400638133393", "4006381333931"), (bcEan13, "9780201379624", "9780201379624"),
                     (bcUpcA, "03600029145", "036000291452"), (bcEan8, "9638507", "96385074"),
                     (bcCode128, "Hello, World!", "Hello, World!"), (bcCode128, "1234567890", "1234567890"),
                     (bcCode128, "ABC123456xyz", "ABC123456xyz"), (bcCode128, "A12345B", "A12345B"),
                     (bcCode39, "CODE-39 TEST", "CODE-39 TEST")]:
  let b = barcodeBitmap(k, t)
  doAssert b != nil, $k & " " & t
  let r = barcodeRead(b)
  doAssert r.len == 1 and r[0].text == want and r[0].kind == k, $k & " " & t & " -> " & $r
  # turned a quarter and upside down
  let q = newBitmap(b.h, b.w)
  for y in 0 ..< b.h:
    for x in 0 ..< b.w: q.px[x * q.w + (b.h - 1 - y)] = b.px[y * b.w + x]
  let r2 = barcodeRead(q)
  doAssert r2.len == 1 and r2[0].text == want, "turned " & t & " " & $r2
  let u = newBitmap(b.w, b.h)
  for y in 0 ..< b.h:
    for x in 0 ..< b.w: u.px[(b.h - 1 - y) * b.w + (b.w - 1 - x)] = b.px[y * b.w + x]
  let r3 = barcodeRead(u)
  doAssert r3.len == 1 and r3[0].text == want, "upside down " & t & " " & $r3
  # smaller (2 px a module) and on gray
  let s = barcodeBitmap(k, t, module = 2, light = color(200, 200, 200), dark = color(40, 40, 40))
  let r4 = barcodeRead(s)
  doAssert r4.len == 1 and r4[0].text == want, "small " & t
doAssert barcodeBitmap(bcEan13, "4006381333932") == nil, "a wrong check digit: refused"
echo "  ok   barcodes"
echo "codes ok"

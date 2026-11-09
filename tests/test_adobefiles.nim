## Photoshop's preset files (retroui/adobefiles): swatches (.aco, .ase),
## curves (.acv), levels (.alv) written and read back; gradients (.grd) and
## patterns (.pat) made as Photoshop writes them, then read.

import std/unittest
import retroui/[adobefiles, psd, photo]

proc be16(o: var string; v: int) =
  o.add char((v shr 8) and 255); o.add char(v and 255)
proc be32(o: var string; v: int) =
  o.add char((v shr 24) and 255); o.add char((v shr 16) and 255)
  o.add char((v shr 8) and 255); o.add char(v and 255)

suite "swatches":
  test ".aco: written and read back, names and all":
    let sw: seq[Swatch] = @[("Red", 0xFFFF0000'u32), ("Sky Blue", 0xFF87CEEB'u32), ("أخضر", 0xFF00FF00'u32)]
    let back = readAco(writeAco(sw))
    check back.len == 3
    for i in 0 ..< 3:
      check back[i].name == sw[i].name
      check back[i].color == sw[i].color
  test ".aco: version 1 alone (no names), and the other color spaces":
    var s = ""
    s.be16(1); s.be16(3)
    s.be16(0); s.be16(65535); s.be16(0); s.be16(0); s.be16(0)              # RGB red
    s.be16(8); s.be16(10000); s.be16(0); s.be16(0); s.be16(0)              # gray: 100 % (black)
    s.be16(2); s.be16(65535); s.be16(65535); s.be16(65535); s.be16(0)     # CMYK: no ink, all K
    let got = readAco(s)
    check got.len == 3
    check got[0].color == 0xFFFF0000'u32
    check got[1].color == 0xFF000000'u32
    check got[2].color == 0xFF000000'u32
    expect AdobeError: discard readAco("hello")
  test ".ase: written and read back":
    let sw: seq[Swatch] = @[("Orange", 0xFFFF8000'u32), ("Teal", 0xFF008080'u32)]
    let back = readAse(writeAse(sw))
    check back.len == 2
    check back[0].name == "Orange" and back[0].color == 0xFFFF8000'u32
    check back[1].name == "Teal" and back[1].color == 0xFF008080'u32
    expect AdobeError: discard readAse("ASEX....")

suite "curves and levels":
  test ".acv":
    let curves = @[@[(0, 0), (64, 40), (192, 220), (255, 255)], @[(0, 10), (255, 245)]]
    let back = readAcv(writeAcv(curves))
    check back.len == 2
    check back[0] == curves[0] and back[1] == curves[1]
    expect AdobeError: discard readAcv("\0\x09\0\x01")
  test ".alv":
    let recs = @[LevelsRecord(inLo: 10, inHi: 240, outLo: 0, outHi: 255, gamma: 1.2),
                 LevelsRecord(inLo: 0, inHi: 255, outLo: 5, outHi: 250, gamma: 0.8)]
    let back = readAlv(writeAlv(recs))
    check back.len == 29
    check back[0].inLo == 10 and back[0].inHi == 240 and abs(back[0].gamma - 1.2) < 0.001
    check back[1].outLo == 5 and abs(back[1].gamma - 0.8) < 0.001
    check back[5].inHi == 255 and back[5].gamma == 1.0

suite "gradients and patterns":
  test ".grd (version 5): names and stops":
    proc stop(loc: int; r, g, b: float): PsdValue =
      psdObj("Clrt", ("Clr ", psdObj("RGBC", ("Rd  ", psdNum(r)), ("Grn ", psdNum(g)), ("Bl  ", psdNum(b)))),
             ("Type", psdEnum("Clry", "UsrS")), ("Lctn", psdLong(loc)), ("Mdpn", psdLong(50)))
    proc grad(name: string; stops: seq[PsdValue]): PsdValue =
      psdObj("Grdn", ("Nm  ", psdText(name)), ("GrdF", psdEnum("GrdF", "CstS")), ("Intr", psdNum(4096)),
             ("Clrs", PsdValue(kind: pkList, list: stops)),
             ("Trns", psdList(psdObj("TrnS", ("Opct", psdUnit("#Prc", 100)), ("Lctn", psdLong(0)), ("Mdpn", psdLong(50))),
                              psdObj("TrnS", ("Opct", psdUnit("#Prc", 50)), ("Lctn", psdLong(4096)), ("Mdpn", psdLong(50))))))
    let root = psdObj("null", ("GrdL", psdList(
      psdObj("Objc", ("Grad", grad("$$$/Gradient/Fire=Fire", @[stop(0, 255, 0, 0), stop(4096, 255, 255, 0)]))),
      psdObj("Objc", ("Grad", grad("Ocean", @[stop(0, 0, 0, 128), stop(2048, 0, 128, 255), stop(4096, 255, 255, 255)]))))))
    var s = "8BGR"
    s.be16(5)
    s.add descriptorData(root)
    let g = readGrd(s)
    check g.len == 2
    check g[0].name == "Fire" and g[0].stops.len == 2
    check (g[0].stops[0].color and 0xFFFFFF) == 0xFF0000'u32 and (g[0].stops[0].color shr 24) == 255
    check (g[0].stops[1].color and 0xFFFFFF) == 0xFFFF00'u32 and (g[0].stops[1].color shr 24) in 126'u32 .. 129'u32
    check g[1].name == "Ocean" and g[1].stops.len == 3 and abs(g[1].stops[1].at - 0.5) < 0.001
    expect AdobeError: discard readGrd("8BGR\0\x03")
  test ".pat: an RGB pattern and a gray one":
    proc pattern(mode, w, h: int; chans: seq[seq[uint8]]; name: string; packed = false): string =
      result.be32(1); result.be32(mode); result.be16(h); result.be16(w)
      result.be32(name.len + 1)
      for c in name: result.be16(ord(c))
      result.be16(0)
      result.add char(4); result.add "id01"
      var vm = ""
      vm.be32(0); vm.be32(0); vm.be32(h); vm.be32(w)
      vm.be32(chans.len)
      for ch in chans:
        var c = ""
        c.be32(8)
        c.be32(0); c.be32(0); c.be32(h); c.be32(w)
        c.be16(8)
        if packed:
          c.add char(1)
          for y in 0 ..< h: c.be16(2)                 # (each row: one run of the same value)
          for y in 0 ..< h:
            c.add char(256 - (w - 1))
            c.add char(ch[y * w])
        else:
          c.add char(0)
          for v in ch: c.add char(v)
        vm.be32(1)
        vm.be32(c.len)
        vm.add c
      result.be32(3)
      result.be32(vm.len)
      result.add vm
    var s = "8BPT"
    s.be16(1)
    s.be32(2)
    s.add pattern(3, 2, 2, @[@[255'u8, 0, 0, 255], @[0'u8, 255, 0, 0], @[0'u8, 0, 255, 0]], "Bits")
    s.add pattern(1, 3, 2, @[@[50'u8, 50, 50, 200, 200, 200]], "Gray", packed = true)
    let p = readPat(s)
    check p.len == 2
    check p[0].name == "Bits" and p[0].w == 2 and p[0].h == 2
    check p[0].px == @[0xFFFF0000'u32, 0xFF00FF00'u32, 0xFF0000FF'u32, 0xFFFF0000'u32]
    check p[1].name == "Gray" and p[1].px[0] == 0xFF323232'u32 and p[1].px[5] == 0xFFC8C8C8'u32
    expect AdobeError: discard readPat("8BPT\0\x02")
  test "the kind of a file":
    check kindOf("a.aco", "\0\x01") == "aco"
    check kindOf("whatever", "ASEF....") == "ase"
    check kindOf("x.bin", "8BGR\0\x05") == "grd"
    check kindOf("x.txt", "hello") == ""

suite "color books":
  test ".acb: written and read back, in each model":
    var b = ColorBook(title: "Test Inks", prefix: "TEST ", postfix: " C", model: bkCmyk, pageSize: 7, spot: true)
    b.colors.add BookColor(name: "100", code: "T100", cmyk: [0, 100, 80, 0])
    b.colors.add BookColor(name: "200", code: "T200", cmyk: [100, 50, 0, 10])
    let back = readAcb(writeAcb(b))
    check back.title == "Test Inks" and back.prefix == "TEST " and back.colors.len == 2 and back.spot
    check back.fullName(back.colors[0]) == "TEST 100 C"
    check back.colors[1].cmyk == [100, 50, 0, 10] and back.colors[0].code == "T100"
    check (back.colors[0].color and 0xFF0000) > 0x800000'u32       # (magenta and yellow: red)
    var l = ColorBook(title: "Lab", model: bkLab)
    l.colors.add BookColor(name: "L", code: "L1", lab: [50, 20, -30])
    let lb = readAcb(writeAcb(l))
    check lb.colors[0].lab == [50, 20, -30]
    var r = ColorBook(title: "RGB", model: bkRgb)
    r.colors.add BookColor(name: "R", code: "R1", color: 0xFF123456'u32)
    check readAcb(writeAcb(r)).colors[0].color == 0xFF123456'u32
    expect AdobeError: discard readAcb("8BCX....")
    check kindOf("x.bin", writeAcb(r)) == "acb"
  test "the libraries that come with the kit":
    let books = builtinBooks()
    check books.len == 4
    check books[0].colors.len == 216 and books[1].colors.len >= 140
    check books[2].model == bkCmyk and books[2].colors[0].cmyk == [100, 0, 0, 0]

#!/usr/bin/env python3
"""Makes the tests' fonts of the older kinds, from FreeSerif and FreeMono (GPL v3 or later with the
font exception, src/retroui/fonts/LICENSE-FreeFont.txt):

  OldBitmap-Test.fon   -- a Windows bitmap font (an NE file holding two FNT 2.0 fonts, 13 and
                          20 px): FreeMono's ASCII drawn black and white at each size.
  OldType1-Test.pfb    -- a PostScript Type 1 font: FreeSerif's ASCII letters, digits and some
                          signs, each quadratic curve written as the cubic one it is; "Aacute"
                          made of A and acute (seac); eexec and charstrings encrypted, PFB
                          segments.
  OldSymbol-Test.pfb   -- a Type 1 font whose codes are other letters (Symbol's kind: a is
                          alpha, b beta...), StandardEncoding nowhere.
  ArabicNoLayout-Test.woff -- ArabicNoLayout-Test.ttf as a WOFF web font.
  VarCFF2-Test.otf     -- a variable font with CFF2 outlines (fontTools' FontBuilder): two
                          boxes whose sides blend along a weight axis.

test_fontkinds reads them with the kit (retroui/fontconv) against the fonts they were made from.

  python3 tools/genoldfonts.py tests/data/fonts

Needs: pip install fonttools pillow (the fonts are in the repository: this is only to make them
again).

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
"""
import os
import struct
import sys
from fontTools.ttLib import TTFont
from fontTools.misc.psCharStrings import T1CharString
from fontTools.misc import eexec
from fontTools.pens.basePen import BasePen
from fontTools.fontBuilder import FontBuilder
from fontTools.misc.psCharStrings import T2CharString
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONTS = os.path.join(HERE, "..", "src", "retroui", "fonts")


# ---- the Windows bitmap font -------------------------------------------------------------------

def fnt(height, name):
    """An FNT 2.0 font: FreeMono's 0x20..0x7E drawn at `height` px, one bit a pixel."""
    pil = ImageFont.truetype(os.path.join(FONTS, "FreeMono.ttf"), height)
    asc, desc = pil.getmetrics()
    first, last = 0x20, 0x7E
    glyphs = []
    for c in range(first, last + 1):
        w = max(1, int(round(pil.getlength(chr(c)))))
        im = Image.new("1", (w, height), 0)
        ImageDraw.Draw(im).text((0, 0), chr(c), font=pil, fill=1)
        cols = (w + 7) // 8
        bits = bytearray(cols * height)
        px = im.load()
        for x in range(w):
            for y in range(height):
                if px[x, y]:
                    bits[(x // 8) * height + y] |= 0x80 >> (x % 8)
        glyphs.append((w, bytes(bits)))
    count = last - first + 2                       # (and the sentinel)
    header = 118
    table = header + 4 * count
    face = name.encode("ascii") + b"\0"
    bits_at = table + len(face)
    entries = b""
    bitmaps = b""
    for w, b in glyphs:
        entries += struct.pack("<HH", w, bits_at + len(bitmaps))
        bitmaps += b
    entries += struct.pack("<HH", 0, 0)
    size = bits_at + len(bitmaps)
    avg = sum(w for w, _ in glyphs) // len(glyphs)
    h = struct.pack("<HI60sHHHHHHHBBBHBHHBHHBBBBHIII",
                    0x200, size, b"(c) GNU FreeFont, GPL with the font exception", 0, 10, 96, 96,
                    asc, 0, 0, 0, 0, 0, 400, 0, 0, height, 0x31, avg, max(w for w, _ in glyphs),
                    first, last, ord("?") - first, 0, 0, 0, table, 0)
    h += b"\0" * (header - len(h))
    data = bytearray(h + entries + face + bitmaps)
    struct.pack_into("<I", data, 105, table)       # (dfFace: the name, after the table)
    struct.pack_into("<I", data, 113, bits_at)     # (dfBitsOffset)
    return bytes(data)


def fon(fnts):
    """An NE file holding FNT fonts as its FONT resources (the parts of it the kit reads)."""
    mz = bytearray(64)
    mz[0:2] = b"MZ"
    struct.pack_into("<I", mz, 0x3C, 64)
    ne = bytearray(64)
    ne[0:2] = b"NE"
    shift = 4
    res = struct.pack("<H", shift)
    res += struct.pack("<HHI", 0x8008, len(fnts), 0)
    body_at = 64 + 64 + 2 + 8 + 12 * len(fnts) + 2
    body_at = (body_at + 15) // 16 * 16
    entries = b""
    body = b""
    for f in fnts:
        at = body_at + len(body)
        entries += struct.pack("<HHHHI", at >> shift, (len(f) + 15) >> shift, 0x1C30, 0x8001, 0)
        body += f + b"\0" * ((-len(f)) % 16)
    res += entries + struct.pack("<H", 0)
    struct.pack_into("<H", ne, 0x24, 64)           # (the resource table, from NE)
    out = bytes(mz) + bytes(ne) + res
    out += b"\0" * (body_at - len(out))
    return out + body


# ---- Type 1 --------------------------------------------------------------------------------------

class T1Pen(BasePen):
    """A glyph's outline as a Type 1 charstring program (quadratic curves raised to cubic)."""

    def __init__(self, glyphset, width):
        super().__init__(glyphset)
        self.prog = [0, width, "hsbw"]
        self.cur = (0, 0)

    def _rel(self, p):
        return int(round(p[0] - self.cur[0])), int(round(p[1] - self.cur[1]))

    def _moveTo(self, p):
        dx, dy = self._rel(p)
        self.prog += [dx, dy, "rmoveto"]
        self.cur = (self.cur[0] + dx, self.cur[1] + dy)

    def _lineTo(self, p):
        dx, dy = self._rel(p)
        self.prog += [dx, dy, "rlineto"]
        self.cur = (self.cur[0] + dx, self.cur[1] + dy)

    def _curveToOne(self, a, b, c):
        pts = []
        cur = self.cur
        for p in (a, b, c):
            dx, dy = int(round(p[0] - cur[0])), int(round(p[1] - cur[1]))
            pts += [dx, dy]
            cur = (cur[0] + dx, cur[1] + dy)
        self.prog += pts + ["rrcurveto"]
        self.cur = cur

    def _closePath(self):
        self.prog.append("closepath")


def type1(family, glyphs, encoding, upem_font):
    """A PFB file: the clear part, the private part (eexec), the trailer."""
    clear = ("%!PS-AdobeFont-1.0: {0} 001.000\n"
             "11 dict begin\n"
             "/FontInfo 8 dict dup begin\n"
             "/FamilyName ({1}) readonly def\n"
             "/FullName ({1}) readonly def\n"
             "/Weight (Regular) readonly def\n"
             "/ItalicAngle 0 def\n"
             "/isFixedPitch false def\n"
             "end readonly def\n"
             "/FontName /{0} def\n"
             "/PaintType 0 def\n"
             "/FontType 1 def\n"
             "/FontMatrix [0.001 0 0 0.001 0 0] readonly def\n").format(family.replace(" ", ""), family)
    if encoding is None:
        clear += "/Encoding StandardEncoding def\n"
    else:
        clear += "/Encoding 256 array\n0 1 255 {1 index exch /.notdef put} for\n"
        for code, name in sorted(encoding.items()):
            clear += "dup %d /%s put\n" % (code, name)
        clear += "readonly def\n"
    clear += "/FontBBox {-200 -250 1100 900} readonly def\ncurrentdict end\ncurrentfile eexec\n"
    priv = b"dup /Private 8 dict dup begin\n/RD{string currentfile exch readstring pop}executeonly def\n"
    priv += b"/ND{noaccess def}executeonly def\n/NP{noaccess put}executeonly def\n/lenIV 4 def\n"
    # (the four standard subroutines: flex and hint replacement)
    subrs = [[3, 0, "callothersubr", "pop", "pop", "setcurrentpoint", "return"],
             [0, 1, "callothersubr", "return"], [0, 2, "callothersubr", "return"],
             ["return"]]
    priv += b"/Subrs %d array\n" % len(subrs)
    for i, s in enumerate(subrs):
        cs = T1CharString(program=s)
        cs.compile()
        enc, _ = eexec.encrypt(b"\0\0\0\0" + cs.bytecode, 4330)
        priv += b"dup %d %d RD " % (i, len(enc)) + enc + b" NP\n"
    priv += b"ND\n2 index /CharStrings %d dict dup begin\n" % len(glyphs)
    for name, prog in glyphs:
        cs = T1CharString(program=prog)
        cs.compile()
        enc, _ = eexec.encrypt(b"\0\0\0\0" + cs.bytecode, 4330)
        priv += b"/%s %d RD " % (name.encode(), len(enc)) + enc + b" ND\n"
    priv += b"end\nend\nreadonly put\nnoaccess put\ndup /FontName get exch definefont pop\n"
    priv += b"mark currentfile closefile\n"
    body, _ = eexec.encrypt(b"\0\0\0\0" + priv, 55665)
    trailer = ("0" * 64 + "\n") * 8 + "cleartomark\n"

    def seg(kind, data):
        return bytes([0x80, kind]) + struct.pack("<I", len(data)) + data
    return seg(1, clear.encode("ascii")) + seg(2, body) + seg(1, trailer.encode("ascii")) + b"\x80\x03"


def serif_glyphs(names):
    f = TTFont(os.path.join(FONTS, "FreeSerif.ttf"))
    gs = f.getGlyphSet()
    out = []
    for nm in names:
        if nm not in gs:
            continue
        pen = T1Pen(gs, f["hmtx"][nm][0])
        gs[nm].draw(pen)
        out.append((nm, pen.prog + ["endchar"]))
    return f, out


def main(out_dir):
    with open(os.path.join(out_dir, "OldBitmap-Test.fon"), "wb") as fh:
        fh.write(fon([fnt(13, "Old Bitmap Test"), fnt(20, "Old Bitmap Test")]))
    names = [".notdef", "space", "comma", "period", "exclam", "question", "acute"]
    names += [chr(c) for c in range(ord("A"), ord("Z") + 1)] + [chr(c) for c in range(ord("a"), ord("z") + 1)]
    names += ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
    f, glyphs = serif_glyphs(names)
    # (Aacute: A and acute, the acute raised over A -- seac names them by Standard codes: A 65,
    # acute 194)
    adv = f["hmtx"]["Aacute"][0] if "Aacute" in f["hmtx"].metrics else f["hmtx"]["A"][0]
    glyphs.append(("Aacute", [0, adv, "hsbw", 0, 230, 190, 65, 194, "seac"]))
    with open(os.path.join(out_dir, "OldType1-Test.pfb"), "wb") as fh:
        fh.write(type1("Old Type1 Test", glyphs, None, 1000))
    greek = ["alpha", "beta", "gamma", "delta", "epsilon"]
    _, sym = serif_glyphs([".notdef", "space"] + greek)
    enc = {32: "space"}
    for i, g in enumerate(greek):
        enc[ord("a") + i] = g
    with open(os.path.join(out_dir, "OldSymbol-Test.pfb"), "wb") as fh:
        fh.write(type1("Old Symbol Test", sym, enc, 1000))
    w = TTFont(os.path.join(out_dir, "ArabicNoLayout-Test.ttf"))
    w.flavor = "woff"
    w.save(os.path.join(out_dir, "ArabicNoLayout-Test.woff"))
    # (CFF2: A a box 100..500 x 0..700 at the default, wider bolder; B 50..250 x 0..500, taller)
    fb = FontBuilder(1000, isTTF=False)
    fb.setupGlyphOrder([".notdef", "A", "B"])
    fb.setupCharacterMap({0x41: "A", 0x42: "B"})
    fb.setupNameTable({"familyName": "Var CFF2 Test", "styleName": "Regular"})
    fb.setupFvar(axes=[("wght", 100, 400, 900, "Weight")], instances=[])
    a = T2CharString(program=[100, 0, "rmoveto", 400, 200, 1, "blend", 0, "rlineto", 0, 700, "rlineto",
                              -400, -200, 1, "blend", 0, "rlineto"])
    b = T2CharString(program=[50, 0, "rmoveto", 0, 500, 0, 200, 2, "blend", "rlineto", 200, 0, "rlineto",
                              0, -500, 0, -200, 2, "blend", "rlineto"])
    fb.setupCFF2({".notdef": T2CharString(program=[]), "A": a, "B": b}, regions=[{"wght": (0, 1, 1)}])
    fb.setupHorizontalMetrics({".notdef": (500, 0), "A": (600, 100), "B": (300, 50)})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupOS2(sTypoAscender=800, usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    fb.save(os.path.join(out_dir, "VarCFF2-Test.otf"))


if __name__ == "__main__":
    main(sys.argv[1])

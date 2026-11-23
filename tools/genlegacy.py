#!/usr/bin/env python3
"""Makes the tests' Arabic fonts with no shaping tables, from FreeSerif (its Arabic, the
Unicode presentation forms among it; the same glyphs, in the same order, in both):

  ArabicLegacy-Test.ttf   -- an Arabic font as they were before Unicode (Windows 3.1, 95): only
                             a symbol character map, each byte's glyph at 0xF200 + the byte, the
                             byte's shape the one the kit's table (`legacyArabic` in
                             src/retroui/ttf.nim) gives it; no GSUB, GPOS, GDEF.
  ArabicNoLayout-Test.ttf -- the letters, marks and presentation forms (and ASCII with the
                             combining accents) in a Unicode character map, and two variation
                             sequences (cmap 14: A + VS1 is B's glyph, C + VS1 C's); no GSUB,
                             GPOS, GDEF (what the shaper's fallback joins and places marks for,
                             as HarfBuzz's).

  HebrewThaiNoLayout-Test.ttf -- Hebrew (its points, and the presentation forms of letters with
                             dagesh, rafe, the shin and sin dots), Thai and ASCII; no GSUB,
                             GPOS, GDEF: what HarfBuzz's Hebrew shaper puts presentation forms
                             in for, and its Thai shaper takes SARA AM apart in.

  Win1256-Test.ttf        -- laid out as the Arabic fonts of Windows 3.1 encoded as Windows-1256:
                             each character's glyph at its byte, plain boxes (marks small and
                             high, no advance), no layout: what HarfBuzz gives its own lookups
                             for (hb-ot-shaper-arabic-win1256).
  ArabicPua-Test.ttf      -- laid out as Simplified Arabic of Windows 3.1: OS/2 version 0, font
                             page 0xB2, only a symbol character map, a box at each private-use
                             code HarfBuzz maps a character to (`arabicPuaSimp` in ttf.nim).

test_otshape shapes Arabic with the first two and checks them against each other; HarfBuzz
shaped the last two (otshape-cases.txt.z).

  python3 tools/genlegacy.py src/retroui/fonts/FreeSerif.ttf tests/data/fonts

Needs: pip install fonttools (the fonts are in the repository: this is only to make them again).

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
"""
import os
import re
import sys
from fontTools.ttLib import TTFont
from fontTools.ttLib.tables._c_m_a_p import CmapSubtable

HERE = os.path.dirname(os.path.abspath(__file__))


def legacy_table():
    src = open(os.path.join(HERE, "..", "src", "retroui", "ttf.nim"), encoding="utf-8").read()
    at = src.index("const legacyArabic: array[256, uint16] = [")
    body = src[at:src.index("]", at + 45)]
    t = [int(x, 16) for x in re.findall(r"0x([0-9A-F]{4})", body)]
    assert len(t) == 256
    return t


def isolated_forms():
    """letter -> its isolated presentation form (src/retroui/arabicdata.nim)."""
    src = open(os.path.join(HERE, "..", "src", "retroui", "arabicdata.nim"), encoding="utf-8").read()
    return {int(m.group(1), 16): int(m.group(2), 16)
            for m in re.finditer(r"\(0x([0-9A-F]{4})'u16, \[0x([0-9A-F]{4})'u16", src)
            if m.group(2) != "0000"}


def box_font(path, family, order, cmap, marks, symbol=False):
    """Plain boxes, each glyph's size and advance from its index (marks small, high, no
    advance); no layout tables."""
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    from fontTools.ttLib.tables._c_m_a_p import cmap_format_4
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({} if symbol else cmap)
    if symbol:
        t = cmap_format_4(4)
        t.platformID, t.platEncID, t.language = 3, 0, 0
        t.cmap = cmap
        fb.font["cmap"].tables = [t]
    glyphs, metrics = {}, {}
    for i, n in enumerate(order):
        p = TTGlyphPen(None)
        mark = n in marks
        w = 80 + (i % 7) * 40
        h = 120 if mark else 300 + (i % 5) * 80
        y0 = 500 if mark else 0
        x0 = 30 + (i % 3) * 10
        p.moveTo((x0, y0)); p.lineTo((x0, y0 + h)); p.lineTo((x0 + w, y0 + h))
        p.lineTo((x0 + w, y0)); p.closePath()
        glyphs[n] = p.glyph()
        metrics[n] = (0 if mark else 200 + (i % 9) * 30, x0)
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=900, descent=-300)
    fb.setupNameTable({"familyName": family, "styleName": "Regular"})
    if symbol:
        # (OS/2 version 0, its font page in fsSelection's high byte: 0xB2, Simplified Arabic)
        fb.setupOS2(version=0, sTypoAscender=900, sTypoDescender=-300, usWinAscent=900,
                    usWinDescent=300)
        fb.font["OS/2"].fsSelection = 0xB240
    else:
        fb.setupOS2(sTypoAscender=900, sTypoDescender=-300, usWinAscent=900, usWinDescent=300)
    fb.setupPost()
    fb.save(path)


def windows31(out_dir):
    import unicodedata
    def is_mark(u):
        return unicodedata.category(chr(u)) == "Mn"
    # Windows-1256: the glyph of byte b is glyph b
    order = [".notdef"] + ["g%d" % i for i in range(1, 256)]
    cmap, marks = {}, set()
    for b in range(0x20, 0x100):
        try:
            u = ord(bytes([b]).decode("cp1252" if b < 0x80 else "cp1256"))
        except UnicodeDecodeError:
            continue
        cmap[u] = order[b]
        if is_mark(u):
            marks.add(order[b])
    box_font(os.path.join(out_dir, "Win1256-Test.ttf"), "Win1256 Test", order, cmap, marks)
    # Simplified Arabic: a glyph at each private-use code
    src = open(os.path.join(HERE, "..", "src", "retroui", "ttf.nim"), encoding="utf-8").read()
    body = src.split("const arabicPuaSimp = [")[1].split("]")[0]
    pairs = [(int(a, 16), int(b, 16))
             for a, b in re.findall(r"\(0x([0-9A-F]+)'u16, 0x([0-9A-F]+)'u16\)", body)]
    codes = sorted({p for _, p in pairs})
    first = {}
    for u, p in pairs:
        first.setdefault(p, u)
    order = [".notdef"] + ["p%04X" % c for c in codes]
    marks = {"p%04X" % p for p, u in first.items() if is_mark(u)}
    box_font(os.path.join(out_dir, "ArabicPua-Test.ttf"), "Arabic PUA Test", order,
             {c: "p%04X" % c for c in codes}, marks, symbol=True)
    print("Windows-1256:", len(cmap), "characters; Simplified Arabic:", len(codes), "codes")


def strip(font, family):
    for tag in ["GSUB", "GPOS", "GDEF", "STAT", "MVAR", "HVAR", "avar", "fvar", "gvar"]:
        if tag in font:
            del font[tag]
    for rec in font["name"].names:
        if rec.nameID in (1, 16):
            rec.string = family
        elif rec.nameID in (4,):
            rec.string = family + " Regular"
        elif rec.nameID == 6:
            rec.string = family.replace(" ", "") + "-Regular"
        elif rec.nameID in (17,):
            rec.string = "Regular"


def main(src_path, out_dir):
    from fontTools import subset
    table = legacy_table()
    # (Arabic, its presentation forms, and Latin with the combining accents: the fallback's
    # marks left to right too)
    want = set(range(0x20, 0x7F)) | {0xA0} | set(range(0x0300, 0x0370)) | \
        set(range(0x0600, 0x0700)) | set(range(0xFB50, 0xFE00)) | set(range(0xFE70, 0xFF00)) | \
        {cp for cp in table if cp}
    opts = subset.Options()
    opts.layout_features = []
    opts.name_IDs = ["*"]
    opts.notdef_outline = True
    opts.hinting = False
    base = TTFont(src_path)
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=want)
    sub.subset(base)
    tmp = os.path.join(out_dir, ".genlegacy.ttf")
    base.save(tmp)
    glyph = TTFont(tmp).getBestCmap()

    # the font as it was before Unicode
    old = TTFont(tmp)
    strip(old, "Arabic Legacy Test")
    sym = CmapSubtable.newSubtable(4)
    sym.platformID, sym.platEncID, sym.language = 3, 0, 0
    sym.cmap = {}
    iso = isolated_forms()
    for b, cp in enumerate(table):
        # (a letter's byte holds its isolated shape, as in those fonts)
        cp = iso.get(cp, cp) if iso.get(cp, cp) in glyph else cp
        if cp and cp in glyph:
            sym.cmap[0xF200 + b] = glyph[cp]
    # (the kit knows such a font by glyphs at 0xF241 and 0xF2C7, and none at 0xF041)
    assert 0xF241 in sym.cmap and 0xF2C7 in sym.cmap
    old["cmap"].tables = [sym]
    old["OS/2"].ulCodePageRange1 = 1 << 31     # (symbol)
    old["OS/2"].usFirstCharIndex = min(sym.cmap)
    old["OS/2"].usLastCharIndex = max(sym.cmap)
    old.save(os.path.join(out_dir, "ArabicLegacy-Test.ttf"))

    # the Unicode one, no layout tables
    uni = TTFont(tmp)
    strip(uni, "Arabic No Layout Test")
    u = CmapSubtable.newSubtable(4)
    u.platformID, u.platEncID, u.language = 3, 1, 0
    u.cmap = dict(glyph)
    # (and variation sequences: A + VS1 drawn as B, C + VS1 as C itself)
    vs = CmapSubtable.newSubtable(14)
    vs.platformID, vs.platEncID, vs.language = 0, 5, 0
    vs.cmap = {}
    vs.uvsDict = {0xFE00: [(0x41, glyph[0x42]), (0x43, None)]}
    uni["cmap"].tables = [u, vs]
    uni.save(os.path.join(out_dir, "ArabicNoLayout-Test.ttf"))
    os.remove(tmp)
    print("legacy:", len(sym.cmap), "codes; no layout:", len(u.cmap), "characters")

    # Hebrew and Thai, no layout tables
    ht = TTFont(src_path)
    sub = subset.Subsetter(opts)
    sub.populate(unicodes=set(range(0x20, 0x7F)) | {0xA0, 0x25CC} | set(range(0x0590, 0x0600)) |
                 set(range(0xFB1D, 0xFB50)) | set(range(0x0E00, 0x0E80)))
    sub.subset(ht)
    strip(ht, "Hebrew Thai No Layout Test")
    ht.save(os.path.join(out_dir, "HebrewThaiNoLayout-Test.ttf"))
    print("Hebrew and Thai:", len(ht.getBestCmap()), "characters")

    # the Arabic fonts of Windows 3.1, as boxes
    windows31(out_dir)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

#!/usr/bin/env python3
"""Makes the tests' font with PostScript (CFF) outlines from a TrueType one: the same glyphs,
their quadratic curves written as the cubic ones that are exactly them, every other table
(cmap, GSUB, GPOS, GDEF, name...) as it was (a variable font: its default instance). test_cff reads it with the kit (retroui/cff) and
draws each glyph against the TrueType font's.

  python3 tools/gencff.py tests/data/fonts/NotoSansArabic-Subset.ttf \\
      tests/data/fonts/NotoSansArabic-Subset-CFF.otf

Needs: pip install fonttools (the font is in the repository: this is only to make it again).

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
"""
import sys
from fontTools.ttLib import TTFont, newTable
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.fontBuilder import FontBuilder


def main(src_path, out_path):
    src = TTFont(src_path)
    if "fvar" in src:
        # (a variable font: its default instance)
        from fontTools.varLib import instancer
        axes = {a.axisTag: a.defaultValue for a in src["fvar"].axes}
        src = instancer.instantiateVariableFont(src, axes)
    order = src.getGlyphOrder()
    glyphs = src.getGlyphSet()
    hmtx = src["hmtx"].metrics
    strings = {}
    for name in order:
        pen = T2CharStringPen(width=hmtx[name][0], glyphSet=glyphs)
        glyphs[name].draw(pen)
        strings[name] = pen.getCharString()
    fb = FontBuilder(src["head"].unitsPerEm, isTTF=False)
    fb.setupGlyphOrder(order)
    ps = src["name"].getDebugName(6) or "TestCFF"
    fb.setupCFF(ps, {"FullName": ps}, strings, {})
    for tag in ("glyf", "loca", "fpgm", "prep", "cvt ", "gasp", "hdmx", "LTSH", "VDMX"):
        if tag in src:
            del src[tag]
    src["CFF "] = fb.font["CFF "]
    maxp = newTable("maxp")
    maxp.tableVersion = 0x00005000
    maxp.numGlyphs = len(order)
    src["maxp"] = maxp
    src.sfntVersion = "OTTO"
    src.save(out_path)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])

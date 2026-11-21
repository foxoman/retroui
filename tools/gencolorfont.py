#!/usr/bin/env python3
"""Makes the tests' colour fonts: a small font whose "A" is two coloured layers (COLR and CPAL,
version 0: a red square under a blue diamond; green under blue in the second palette), whose "D"
is one layer in the text's own colour (palette entry 0xFFFF), whose "B" is a picture (sbix: a 2x2 PNG of four colours, at 64 pixels an
em) and whose "C" is a picture too (CBDT and CBLC: format 17, the same PNG). test_colorfonts reads
them with the kit (retroui/ttf, retroui/textengine).

  python3 tools/gencolorfont.py tests/data/fonts/ColorTest.ttf

Needs: pip install fonttools (the font is in the repository: this is only to make it again).

Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
"""
import sys, struct, zlib
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import newTable
from fontTools.ttLib.tables import otTables
from fontTools.colorLib.builder import buildCOLR, buildCPAL


def png(w, h, rows):
    """(a PNG of RGBA rows)"""
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def square(x0, y0, x1, y1):
    pen = TTGlyphPen(None)
    pen.moveTo((x0, y0)); pen.lineTo((x0, y1)); pen.lineTo((x1, y1)); pen.lineTo((x1, y0)); pen.closePath()
    return pen.glyph()


def diamond(cx, cy, r):
    pen = TTGlyphPen(None)
    pen.moveTo((cx, cy - r)); pen.lineTo((cx - r, cy)); pen.lineTo((cx, cy + r)); pen.lineTo((cx + r, cy))
    pen.closePath()
    return pen.glyph()


def main(out):
    upem = 1000
    order = [".notdef", "A", "B", "C", "sq", "dia", "D"]
    fb = FontBuilder(upem, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({ord("A"): "A", ord("B"): "B", ord("C"): "C", ord("D"): "D"})
    empty = TTGlyphPen(None).glyph()
    fb.setupGlyf({".notdef": empty, "A": square(100, 0, 900, 800), "B": square(100, 0, 900, 800),
                  "C": square(100, 0, 900, 800), "sq": square(100, 0, 900, 800), "dia": diamond(500, 400, 300),
                  "D": square(100, 0, 900, 800)})
    fb.setupHorizontalMetrics({g: (1000, 100) for g in order})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "Color Test", "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, sTypoDescender=-200, usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    font = fb.font
    # COLR and CPAL, version 0
    font["COLR"] = buildCOLR({"A": [("sq", 0), ("dia", 1)], "D": [("dia", 0xFFFF)]}, version=0)
    font["CPAL"] = buildCPAL([[(1.0, 0.0, 0.0, 1.0), (0.0, 0.0, 1.0, 1.0)],
                              [(0.0, 0.6, 0.0, 1.0), (0.0, 0.0, 1.0, 1.0)]])
    # sbix: "B" a 2x2 picture at 64 pixels an em
    picture = png(2, 2, [[255, 0, 0, 255, 0, 255, 0, 255], [0, 0, 255, 255, 255, 255, 0, 255]])
    from fontTools.ttLib.tables import sbixStrike, sbixGlyph
    sbix = newTable("sbix")
    sbix.version = 1
    sbix.flags = 1
    strike = sbixStrike.Strike(ppem=64, resolution=72)
    for g in order:
        sg = sbixGlyph.Glyph(glyphName=g)
        if g == "B":
            sg = sbixGlyph.Glyph(glyphName=g, graphicType="png ", imageData=picture, originOffsetX=8,
                                 originOffsetY=4)
        strike.glyphs[g] = sg
    sbix.strikes = {64: strike}
    font["sbix"] = sbix
    font.save(out)
    # CBDT and CBLC: "C" the same picture, format 17, at 64 pixels an em -- written by hand
    from fontTools.ttLib import TTFont
    f = TTFont(out)
    gidC = f.getGlyphID("C")
    data = struct.pack(">BBbbB", 2, 2, 4, 20, 64) + struct.pack(">I", len(picture)) + picture
    cbdt = struct.pack(">HH", 3, 0) + data
    # (CBLC: one strike, one index subtable of format 1 for glyph C)
    sub = struct.pack(">HHI", 1, 17, 4) + struct.pack(">II", 0, len(data))
    arr = struct.pack(">HHI", gidC, gidC, 8)
    size_rec_len = 48
    ista_off = 8 + size_rec_len
    line = struct.pack(">bbBbbbbbbbbb", 51, -13, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    size = (struct.pack(">IIII", ista_off, len(arr) + len(sub), 1, 0) + line + line +
            struct.pack(">HHBBBb", gidC, gidC, 64, 64, 32, 1))
    cblc = struct.pack(">HHI", 3, 0, 1) + size + arr + sub
    from fontTools.ttLib.tables.DefaultTable import DefaultTable
    t1 = DefaultTable("CBDT"); t1.data = cbdt
    t2 = DefaultTable("CBLC"); t2.data = cblc
    f["CBDT"] = t1
    f["CBLC"] = t2
    f.save(out)


if __name__ == "__main__":
    main(sys.argv[1])

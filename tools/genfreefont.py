#!/usr/bin/env python3
"""Build the kit's text fonts: GNU FreeFont (FreeSans, FreeSerif, FreeMono,
each in four styles), cut down to what an app needs.

Maintainers only: users of the library never run this, the outputs are
checked in. Needs Python 3 with fontTools (`pip install fonttools`) and the
twelve TrueType files of GNU FreeFont (release 0412, 2012:
https://ftp.gnu.org/gnu/freefont/freefont-ttf-20120503.zip, or Debian's
`fonts-freefont-ttf`) in the folder given as argument:

    python3 tools/genfreefont.py /usr/share/fonts/truetype/freefont

Writes src/retroui/fonts/Free*.ttf (the subsets, the sources of record) and
Free*.ttf.z (the same, packed -- LZMA, or zlib for FreeSans and its bold
which every program unpacks as it starts: what typeset.nim builds into every
app and unpacks the first time a face is used).

    python3 tools/genfreefont.py --add /usr/share/fonts/truetype/freefont

keeps the checked-in subsets (cut from release 0412) as they are and adds
to them only the letters of ADDED (the Vietnamese letters and Thai, new in
0.37) that they lack, from the fonts in the folder -- any FreeFont release,
Debian's 20211204 snapshot too: their outlines and advances, not their
kerning or layout (the kit places Thai's marks itself, `thaiPlace` in
typeset.nim). A newer release cut whole is bigger for the same letters
(more glyphs): this keeps every app about as small as it was.

What is kept:

* the regular of each family (the faces every style falls back to):
  Latin (Basic, Latin-1, Extended-A and -B, the Vietnamese letters of
  Additional, IPA, the spacing modifiers and combining marks), Greek,
  Cyrillic, Hebrew, the punctuation, super- and subscripts, currency signs,
  letterlike symbols, number forms, arrows, mathematical operators, the technical symbols, box drawing, blocks,
  geometric shapes, the miscellaneous symbols the kit's own text uses, a
  few dingbats (check marks, crosses), the Latin ligatures and the
  replacement character; FreeSerif and FreeMono also their Arabic, with
  the presentation forms A and B (the kit joins Arabic into them);
  FreeSerif its Thai (the other faces draw Thai with it);
* bold: the same letters without IPA and the symbol blocks (a symbol in
  bold text comes from the regular); FreeSerif Bold its Arabic too
  (FreeSans and FreeMono Bold draw Arabic with it) and its Thai;
* italic and oblique: the Latin, Greek and Cyrillic letters, the marks,
  the punctuation and currency signs (Hebrew and Arabic have no italic:
  they come from the upright faces);
* the tables the kit reads: cmap, glyf/loca, hmtx/hhea, head, maxp, OS/2,
  post (without glyph names), name (the family, style, copyright, licence
  and URL, in English), and the OpenType layout (GSUB, GPOS, GDEF) for the
  features that matter to text -- kerning, marks, ligatures, the Arabic
  forms -- which the kit's kerning (GPOS pairs) and its OpenType shaper
  (documents, `textengine`) read. The legacy `kern` table goes: GPOS has
  the same pairs, as classes, in a fraction of the room.

The TrueType hinting (fpgm, prep, cvt, the glyph programs) is dropped: the
kit does not run it, it fits outlines to the pixels itself (ttf.nim).
Outlines, advances, kerning and line metrics are the fonts' own.

GNU FreeFont is free software under the GNU GPL v3 or later with the font
exception (see src/retroui/fonts/LICENSE-FreeFont.txt): an app that embeds
these files is not made a derivative of them.
"""
import copy, io, os, sys, zlib
from fontTools.ttLib import TTFont
from fontTools import subset

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import packlzma


def packed_font(dst, data):
    """(what the programs carry: zlib for the faces unpacked as every
    program starts, LZMA for the rest -- tools/packlzma.py)"""
    if os.path.basename(dst) + ".z" in packlzma.KEEP_ZLIB:
        return zlib.compress(data, 9)
    return packlzma.pack(data)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FONTS = os.path.join(ROOT, "src", "retroui", "fonts")

# (the Unicode blocks, as code point ranges)
VIETNAMESE = [(0x1EA0, 0x1EF9)]        # (the letters of Latin Extended Additional it uses)
LATIN = [(0x0020, 0x007E), (0x00A0, 0x024F)] + VIETNAMESE
IPA = [(0x0250, 0x02AF)]
MARKS = [(0x02B0, 0x036F)]             # spacing modifier letters, combining marks
GREEK = [(0x0370, 0x03FF)]
CYRILLIC = [(0x0400, 0x04FF)]
HEBREW = [(0x0590, 0x05FF), (0xFB1D, 0xFB4F)]
THAI = [(0x0E00, 0x0E7F)]              # (FreeSerif's alone: the others draw Thai with it)
ARABIC = [(0x0600, 0x06FF), (0x0750, 0x077F), (0xFB50, 0xFDFF), (0xFE70, 0xFEFF)]
PUNCT = [(0x2000, 0x206F), (0x20A0, 0x20CF), (0xFB00, 0xFB06), (0xFFFD, 0xFFFD)]
LETTERLIKE = [(0x2103, 0x2103), (0x2109, 0x2109), (0x2116, 0x2117), (0x2122, 0x2122),
              (0x2153, 0x215E)]       # (in bold and italic: the ones text uses)
SYMBOLS = [(0x2070, 0x209F), (0x2100, 0x218F), (0x2190, 0x21FF), (0x2200, 0x22FF),
           (0x2300, 0x23FF), (0x2500, 0x259F), (0x25A0, 0x25FF),
           (0x2600, 0x2603), (0x2605, 0x2606), (0x260E, 0x260E), (0x2610, 0x2612),
           (0x2639, 0x263A), (0x2640, 0x2642), (0x2660, 0x2667), (0x266A, 0x266F),
           (0x2713, 0x2718), (0x27E8, 0x27E9)]

REGULAR = LATIN + IPA + MARKS + GREEK + CYRILLIC + HEBREW + PUNCT + SYMBOLS
BOLD = LATIN + MARKS + GREEK + CYRILLIC + HEBREW + PUNCT + LETTERLIKE
ITALIC = LATIN + MARKS + GREEK + CYRILLIC + PUNCT + LETTERLIKE

FACES = [  # (file, what it keeps)
    ("FreeSans", REGULAR), ("FreeSansBold", BOLD),
    ("FreeSansOblique", ITALIC), ("FreeSansBoldOblique", ITALIC),
    ("FreeSerif", REGULAR + ARABIC + THAI), ("FreeSerifBold", BOLD + ARABIC + THAI),
    ("FreeSerifItalic", ITALIC), ("FreeSerifBoldItalic", ITALIC),
    ("FreeMono", REGULAR + ARABIC), ("FreeMonoBold", BOLD),
    ("FreeMonoOblique", ITALIC), ("FreeMonoBoldOblique", ITALIC),
]

# (what 0.37 added to the subsets cut in 0.20: `--add` brings these alone)
ADDED = VIETNAMESE + THAI

FEATURES = ["kern", "mark", "mkmk", "curs", "ccmp", "locl", "liga", "clig", "rlig", "calt",
            "isol", "init", "medi", "fina"]


def cut(src, ranges, dst):
    font = TTFont(src)
    opt = subset.Options()
    opt.layout_features = FEATURES
    opt.hinting = False                 # (fpgm, prep, cvt, gasp and the glyph programs)
    opt.legacy_kern = False             # (GPOS has the pairs)
    opt.glyph_names = False
    opt.notdef_outline = True
    opt.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14, 16, 17]
    opt.name_languages = [0x409]
    opt.drop_tables += ["FFTM", "gasp", "MATH", "BASE"]   # (a newer release's MATH: its
                                                          # glyphs would come along)
    sub = subset.Subsetter(opt)
    sub.populate(unicodes=[c for a, b in ranges for c in range(a, b + 1)])
    sub.subset(font)
    out = io.BytesIO()
    font.save(out)
    data = out.getvalue()
    with open(dst, "wb") as f:
        f.write(data)
    packed = packed_font(dst, data)
    with open(dst + ".z", "wb") as f:
        f.write(packed)
    return len(data), len(packed), font["maxp"].numGlyphs


def wanted(ranges):
    return {c for a, b in ranges for c in range(a, b + 1)}


def grow(dst, src):
    """Face `dst` (a checked-in subset) given the letters of its ranges it
    lacks and face `src` has: their outlines and advances, nothing else (no
    kerning, no layout -- the kit places the marks itself). A letter made of
    others (an accented one) keeps using the ones `dst` has."""
    font = TTFont(dst)
    have = font.getBestCmap()
    name = os.path.basename(dst)[:-4]
    ranges = dict(FACES)[name]
    s = TTFont(src)
    scmap = s.getBestCmap()
    sglyf, sgo = s["glyf"], s.getGlyphOrder()
    rev = {}                                   # (the source's glyph -> a letter it is)
    for c, g in scmap.items():
        rev.setdefault(g, c)
    new = sorted(c for c in wanted(ranges) & wanted(ADDED) if c not in have and c in scmap)
    if not new:
        return 0
    order = font.getGlyphOrder()
    glyf, hmtx = font["glyf"], font["hmtx"]
    names = set(order)
    copied = {}                                # (source glyph -> its name here)

    def bring(g):
        # (the source's glyph g here: a letter already here is the one used)
        if g in copied:
            return copied[g]
        c = rev.get(g)
        if c is not None and c in have:
            copied[g] = have[c]
            return have[c]
        n = "add_" + g
        while n in names:
            n += "_"
        names.add(n)
        copied[g] = n
        sg = sglyf[g]
        gl = copy.deepcopy(sg)
        if sg.isComposite():
            for comp in gl.components:
                comp.glyphName = bring(comp.glyphName)
        order.append(n)
        font.setGlyphOrder(order)
        glyf.glyphs[n] = gl
        if hasattr(glyf, "glyphOrder"):
            glyf.glyphOrder = order
        hmtx.metrics[n] = s["hmtx"][g]
        return n

    for c in new:
        have[c] = bring(scmap[c])
    for n in copied.values():
        if n.startswith("add_"):
            gl = glyf[n]
            gl.recalcBounds(glyf)
            hmtx.metrics[n] = (hmtx.metrics[n][0], getattr(gl, "xMin", 0))
    for t in font["cmap"].tables:
        if t.isUnicode():
            for c in new:
                if t.format != 4 or c <= 0xFFFF:
                    t.cmap[c] = have[c]
    out = io.BytesIO()
    font.save(out)
    data = out.getvalue()
    with open(dst, "wb") as f:
        f.write(data)
    with open(dst + ".z", "wb") as f:
        f.write(packed_font(dst, data))
    return len(new)


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--add":
        # (the letters the ranges gained since the subsets were cut, from any
        # FreeFont release, the subsets otherwise kept as they are)
        for name, _ in FACES:
            n = grow(os.path.join(FONTS, name + ".ttf"), os.path.join(sys.argv[2], name + ".ttf"))
            z = os.path.getsize(os.path.join(FONTS, name + ".ttf.z"))
            print("%-24s %5d letters added, %7d compressed" % (name, n, z))
        return
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    total = [0, 0]
    for name, ranges in FACES:
        n, z, g = cut(os.path.join(src, name + ".ttf"), ranges, os.path.join(FONTS, name + ".ttf"))
        total[0] += n
        total[1] += z
        print("%-24s %5d glyphs %8d bytes, %7d compressed" % (name, g, n, z))
    print("%-24s %21d bytes, %7d compressed" % ("all", total[0], total[1]))


main()

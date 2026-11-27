#!/usr/bin/env python3
"""Build the kit's Suhar App fonts: Suhar App -- the UI's text, the default
font of every app -- and Suhar App Read, its cut for paragraphs, each in
its regular, bold, italic and bold italic. Suhar is Sultan Al Isaiee's own
typeface (Latin and Arabic drawn together, with Greek, Cyrillic, Hebrew and
the Vietnamese letters), under the SIL Open Font License 1.1
(src/retroui/fonts/LICENSE-Suhar.txt).

Maintainers only: users of the library never run this, the outputs are
checked in. Needs Python 3 with fontTools (`pip install fonttools`) and the
eight TrueType files of Suhar App (SuharApp-Regular.ttf, SuharApp-Bold.ttf,
SuharApp-Italic.ttf, SuharApp-BoldItalic.ttf, and SuharAppRead-*.ttf) in
the folder given as argument:

    python3 tools/gensuharfont.py FOLDER

Writes src/retroui/fonts/SuharApp*.ttf (the sources of record) and
SuharApp*.ttf.z (the same, packed: zlib for Suhar App and its bold, which
every program unpacks as it starts; LZMA for the others, unpacked when
first used -- tools/packlzma.py).

Every glyph is kept. What goes: the hinting the kit does not run (it fits
outlines to the pixels itself, ttf.nim), `gasp`, the glyph names (`post`
format 3) and the names in languages other than English. The OpenType
layout (GSUB, GPOS, GDEF) stays: the Arabic forms, kerning and marks.
Letters Suhar has not drawn come from GNU FreeFont (typeset.nim's chain).
"""
import io, os, sys, zlib
from fontTools.ttLib import TTFont

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import packlzma

ROOT = os.path.dirname(HERE)
FONTS = os.path.join(ROOT, "src", "retroui", "fonts")

FACES = [  # (the file in FOLDER, the kit's name for it)
    ("SuharApp-Regular.ttf", "SuharApp"), ("SuharApp-Bold.ttf", "SuharAppBold"),
    ("SuharApp-Italic.ttf", "SuharAppItalic"), ("SuharApp-BoldItalic.ttf", "SuharAppBoldItalic"),
    ("SuharAppRead-Regular.ttf", "SuharAppRead"), ("SuharAppRead-Bold.ttf", "SuharAppReadBold"),
    ("SuharAppRead-Italic.ttf", "SuharAppReadItalic"),
    ("SuharAppRead-BoldItalic.ttf", "SuharAppReadBoldItalic"),
]

DROP = ["gasp", "fpgm", "prep", "cvt ", "hdmx", "LTSH", "VDMX", "DSIG", "kern"]
KEEP_NAMES = {0, 1, 2, 3, 4, 5, 6, 13, 14}   # (copyright, family, style, ids, version, licence, URL)


def build(src, name):
    f = TTFont(src)
    for t in DROP:
        if t in f:
            del f[t]
    f["post"].formatType = 3.0
    f["post"].extraNames = []
    f["post"].mapping = {}
    names = f["name"]
    names.names = [n for n in names.names
                   if n.nameID in KEEP_NAMES and n.platformID == 3 and n.langID == 0x409]
    out = io.BytesIO()
    f.save(out)
    data = out.getvalue()
    ttf = os.path.join(FONTS, name + ".ttf")
    with open(ttf, "wb") as w:
        w.write(data)
    z = ttf + ".z"
    packed = zlib.compress(data, 9) if os.path.basename(z) in packlzma.KEEP_ZLIB else packlzma.pack(data)
    with open(z, "wb") as w:
        w.write(packed)
    print("%-24s %7d bytes, %7d packed" % (name, len(data), len(packed)))


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        sys.exit(2)
    folder = sys.argv[1]
    for src, name in FACES:
        build(os.path.join(folder, src), name)


if __name__ == "__main__":
    main()

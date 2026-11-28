#!/usr/bin/env python3
"""The test fonts of tests/test_suhar.nim, cut from the kit's Suhar App
(src/retroui/fonts; SIL Open Font License, tests/data/fonts/Suhar-OFL.txt):

  SuharNoForms-Test.ttf        Suhar App: Latin and a few Arabic letters with
                               their marks, GSUB's joining forms and GPOS, no
                               presentation forms
  SuharMarks-Test.ttf          Suhar App Bold with the presentation forms, its
                               damma and fathatan moved down across the
                               baseline, its kasra up across it
  SuharMarksNoLayout-Test.ttf  the same without GSUB, GPOS and GDEF
  SuharVar-Test.ttf            Suhar's variable font (wght 400-700, opsz 8-72):
                               Latin and a few Arabic letters, its axes kept
                               (made when its file is given as a fourth
                               argument)

    python3 tools/gensuhartestfonts.py src/retroui/fonts/SuharApp.ttf \
        src/retroui/fonts/SuharAppBold.ttf tests/data/fonts [Suhar[opsz,wght].ttf]

Maintainers only: the outputs are checked in. Needs fontTools.
"""
import sys, io
from fontTools.ttLib import TTFont
from fontTools import subset
src_reg, src_bold, out = sys.argv[1], sys.argv[2], sys.argv[3]
src_var = sys.argv[4] if len(sys.argv) > 4 else ''
LATIN = list(range(0x20, 0x7F))
import unicodedata
LETTERS = [ord(c) for c in "اأبتحرصفكلمنهوي"]
ARABIC = LETTERS + list(range(0x064B, 0x0653)) + [0x0640, 0x060C, 0x061F]
FORMS = []
for cp in list(range(0xFB50, 0xFE00)) + list(range(0xFE70, 0xFF00)):
    d = unicodedata.decomposition(chr(cp)).split()
    if d and d[0] in ('<initial>', '<medial>', '<final>', '<isolated>') and \
       all(int(x, 16) in LETTERS or int(x, 16) in range(0x064B, 0x0653) for x in d[1:]):
        FORMS.append(cp)
def cut(src, unicodes, keep_layout, dst, shift=None):
    f = TTFont(src)
    opts = subset.Options()
    opts.layout_features = ['init', 'medi', 'fina', 'isol', 'rlig', 'calt', 'kern', 'mark', 'mkmk'] if keep_layout else []
    opts.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    opts.notdef_outline = True
    opts.glyph_names = False
    opts.hinting = False
    s = subset.Subsetter(opts)
    s.populate(unicodes=unicodes)
    s.subset(f)
    if not keep_layout:
        for t in ['GSUB', 'GPOS', 'GDEF']:
            if t in f: del f[t]
    if shift:
        cm = f.getBestCmap()
        glyf = f['glyf']
        for cp, dy in shift.items():
            g = glyf[cm[cp]]
            if g.numberOfContours > 0:
                for i, (x, y) in enumerate(g.coordinates):
                    g.coordinates[i] = (x, y + dy)
                g.recalcBounds(glyf)
    names = f['name']
    for n in names.names:
        if n.nameID in (1, 4, 6, 16):
            pass
    f.save(dst)
    t = TTFont(dst); gs = t.getGlyphSet(); cm = t.getBestCmap()
    from fontTools.pens.boundsPen import BoundsPen
    for cp in (shift or {}):
        p = BoundsPen(gs); gs[cm[cp]].draw(p); print(dst, hex(cp), p.bounds)
    print(dst, len(open(dst,'rb').read()), 'bytes', 'forms' if 0xFE91 in cm else 'no forms', sorted(t.keys()))
# 1. no presentation forms, GSUB joining kept (Suhar App Regular)
cut(src_reg, LATIN + ARABIC, True, out + '/SuharNoForms-Test.ttf')
# 2. marks crossing the baseline (Suhar App Bold): damma's foot and fathatan under it, kasra's top over it
cross = {0x064F: -40, 0x064B: -35, 0x0650: 40}
cut(src_bold, LATIN + ARABIC + FORMS, True, out + '/SuharMarks-Test.ttf', cross)
# 3. ... without the layout tables: the kit places the marks itself
cut(src_bold, LATIN + ARABIC + FORMS, False, out + '/SuharMarksNoLayout-Test.ttf', cross)
# 4. the variable font: its weights and optical sizes (axes, gvar, HVAR, MVAR kept)
if src_var:
    cut(src_var, LATIN + ARABIC, True, out + '/SuharVar-Test.ttf')

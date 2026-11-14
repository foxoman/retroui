#!/usr/bin/env python3
"""Packs the fonts the kit carries with LZMA, for src/retroui/lzma.nim:
each Name.ttf next to its Name.ttf.z is packed again into Name.ttf.z
(the file the programs build in), behind the kit's header --

    "RLZ1"  props: (pb * 5 + lp) * 9 + lc  dictionary size (4)  size (4)
    the raw LZMA stream

-- with the literal settings that pack each file smallest. Fonts without
their .ttf beside them (the hand fonts) are unpacked from their .ttf.z
first. FreeSans, FreeSansBold and Icons stay zlib: every program unpacks
them as it starts, and zlib is five times as fast; so do Retro Board's
handwriting fonts (fonts/hand), unpacked as it opens -- LZMA made its first
frame 60 ms later. 13 % smaller than zlib's best for the faces packed.

    python3 tools/packlzma.py              (src/retroui/fonts)
    python3 tools/packlzma.py FILE.ttf...  (those, into FILE.ttf.z)
"""

import glob, lzma, os, struct, sys, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
# (unpacked as every program starts -- the UI's text, its bold, the icons:
# zlib, which unpacks five times as fast; the rest only when first used)
KEEP_ZLIB = {'FreeSans.ttf.z', 'FreeSansBold.ttf.z', 'Icons.ttf.z'}
FONTS = os.path.join(HERE, '..', 'src', 'retroui', 'fonts')


def pack(data):
    """The smallest LZMA packing of `data`, behind the header."""
    dict_size = max(4096, 1 << (max(1, len(data)) - 1).bit_length())
    best = None
    for lc in (0, 1, 2, 3):
        for pb in (0, 2):
            f = [{"id": lzma.FILTER_LZMA1, "preset": 9 | lzma.PRESET_EXTREME,
                  "lc": lc, "lp": 0, "pb": pb, "dict_size": dict_size}]
            raw = lzma.compress(data, format=lzma.FORMAT_RAW, filters=f)
            if best is None or len(raw) < len(best[1]):
                best = ((pb * 5 + 0) * 9 + lc, raw)
    props, raw = best
    return b"RLZ1" + bytes([props]) + struct.pack("<II", dict_size, len(data)) + raw


def unpacked(path):
    """What a .ttf.z holds, zlib or LZMA (this tool's own)."""
    b = open(path, 'rb').read()
    if b[:4] == b"RLZ1":
        props = b[4]
        lc, lp, pb = props % 9, (props // 9) % 5, props // 45
        dict_size, size = struct.unpack("<II", b[5:13])
        f = [{"id": lzma.FILTER_LZMA1, "lc": lc, "lp": lp, "pb": pb, "dict_size": dict_size}]
        return lzma.LZMADecompressor(lzma.FORMAT_RAW, filters=f).decompress(b[13:], max_length=size)
    return zlib.decompress(b)


def main():
    if len(sys.argv) > 1:
        targets = [(p, open(p, 'rb').read()) for p in sys.argv[1:]]
    else:
        targets = []
        for z in sorted(glob.glob(os.path.join(FONTS, '*.ttf.z'))):
            if os.path.basename(z) in KEEP_ZLIB: continue
            ttf = z[:-2]
            targets.append((ttf, open(ttf, 'rb').read() if os.path.exists(ttf) else unpacked(z)))
    before = after = 0
    for ttf, data in targets:
        z = ttf + '.z'
        old = os.path.getsize(z) if os.path.exists(z) else 0
        out = pack(data)
        assert unpacked_bytes(out) == data, ttf
        open(z, 'wb').write(out)
        before += old
        after += len(out)
        print('%-28s %8d -> %8d' % (os.path.basename(z), old, len(out)))
    print('%d -> %d bytes (%.1f %% smaller)' % (before, after, 100 * (1 - after / max(1, before))))


def unpacked_bytes(b):
    props = b[4]
    lc, lp, pb = props % 9, (props // 9) % 5, props // 45
    dict_size, size = struct.unpack("<II", b[5:13])
    f = [{"id": lzma.FILTER_LZMA1, "lc": lc, "lp": lp, "pb": pb, "dict_size": dict_size}]
    return lzma.LZMADecompressor(lzma.FORMAT_RAW, filters=f).decompress(b[13:], max_length=size)


if __name__ == '__main__':
    main()

#!/usr/bin/env python3
"""A Windows program's table of procs, put at its end: for a hang's report to
name the procs the window's thread was in (retroui/hangwatch). The program
is stripped here, after its procs are read:

    python3 tools/winsym.py build/win/RetroFiles.exe

At the program's end: the table packed (zlib; a line a proc -- where it
starts in the program, hex, and its name -- in order), its length (8
bytes, the low one first) and "RETROSYM". Windows runs a program with
more after its last section as it runs any other. `--file` writes the
table beside the program instead (RetroFiles.sym), unpacked, and leaves
the program as it is.

Needs MinGW's nm and strip (x86_64-w64-mingw32-nm, -strip).
"""
import re
import struct
import subprocess
import sys
import zlib

MAGIC = b"RETROSYM"


def table(exe):
    nm = subprocess.run(["x86_64-w64-mingw32-nm", "-n", "--defined-only", exe],
                        capture_output=True, text=True, check=True).stdout
    rows = []
    for line in nm.splitlines():
        parts = line.split()
        if len(parts) != 3 or parts[1] not in "Tt":
            continue
        rows.append((int(parts[0], 16), parts[2]))
    if not rows:
        sys.exit("winsym: no procs in " + exe + " (stripped already?)")
    # (where the program starts: its first section is 0x1000 in)
    base = (rows[0][0] - 0x1000) & ~0xFFFF
    lines = []
    for at, name in rows:
        # (a Nim proc: its name, then the module it is in -- "listFolder@files")
        name = re.sub(r"__OOZ(?:[A-Za-z0-9_]*Z)*([A-Za-z0-9]+)_u\d+", r"@\1", name)
        name = re.sub(r"__([A-Za-z0-9]+)_u\d+", r"@\1", name)
        lines.append("%x %s" % (at - base, name))
    return ("\n".join(lines) + "\n").encode()


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 1:
        sys.exit(__doc__)
    exe = args[0]
    with open(exe, "rb") as f:
        if f.read()[-len(MAGIC):] == MAGIC:
            print("winsym: " + exe + " has its table already")
            return
    text = table(exe)
    if "--file" in sys.argv:
        out = exe[:-4] + ".sym" if exe.lower().endswith(".exe") else exe + ".sym"
        with open(out, "wb") as f:
            f.write(text)
        print("winsym: %d procs in %s" % (text.count(b"\n"), out))
        return
    subprocess.run(["x86_64-w64-mingw32-strip", exe], check=True)
    packed = zlib.compress(text, 9)
    with open(exe, "ab") as f:
        f.write(packed + struct.pack("<Q", len(packed)) + MAGIC)
    print("winsym: %d procs at the end of %s (%d KB)" % (text.count(b"\n"), exe, len(packed) // 1024))


if __name__ == "__main__":
    main()

#!/bin/sh
# Rebuilds classes.dex from tools/android/*.java and writes it into
# src/retroui/androiddex.nim, which retroapk puts in every APK.
# Needs javac, an android.jar (API 23+) and dx (Debian: dalvik-exchange).
set -e
here=$(cd "$(dirname "$0")" && pwd)
jar=${ANDROID_JAR:-$(ls /usr/lib/android-sdk/platforms/*/android.jar | head -1)}
dx=$(command -v dx || command -v dalvik-exchange)
work=$(mktemp -d)
javac -source 8 -target 8 -nowarn -bootclasspath "$jar" -d "$work" "$here"/*.java
"$dx" --dex --min-sdk-version=24 --output="$work/classes.dex" "$work"
python3 - "$work/classes.dex" "$here/../../src/retroui/androiddex.nim" "$here" <<'PY'
import sys, os, hashlib
data = open(sys.argv[1], 'rb').read()
# (the Java it was made from: each file's name and text, by name -- test_apk checks that
# androiddex.nim was made again after a change to them)
h = hashlib.sha256()
for name in sorted(f for f in os.listdir(sys.argv[3]) if f.endswith('.java')):
    h.update(name.encode() + b'\n')
    h.update(open(os.path.join(sys.argv[3], name), 'rb').read().replace(b'\r\n', b'\n'))
lines = []
for i in range(0, len(data), 36):
    lines.append('"' + ''.join('\\x%02x' % b for b in data[i:i+36]) + '"')
# (in parenthesized groups of 64 lines: one long chain of & crashes the compiler)
groups = []
for g in range(0, len(lines), 64):
    groups.append("  (" + " &\n   ".join(lines[g:g+64]) + ")")
open(sys.argv[2], 'w').write(
    "## classes.dex of `tools/android/*.java` (made by\n"
    "## `tools/android/build_dex.sh`): the Java part of every retro APK. Only the\n"
    "## APK builder (`retroapk`) uses it; apps never import it.\n"
    "##\n"
    "## ```nim\n"
    "## z.addFile(\"classes.dex\", classesDex.toBytes)   # into the APK's zip\n"
    "## ```\n\n"
    "const classesDexOf* = \"" + h.hexdigest() + "\"\n"
    "  ## the SHA-256 of the Java it was made from (`javaSources` in tests/test_apk.nim)\n\n"
    "const classesDex* =\n" + " &\n".join(groups) + "\n")
PY
rm -rf "$work"
echo "wrote src/retroui/androiddex.nim"

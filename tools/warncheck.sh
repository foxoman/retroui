#!/bin/sh
# The kit without a warning, on every system: every module checked
# (`nim check`) as each system builds it -- Linux, Termux, an Android app,
# Windows, macOS, iOS, a web page with threads and without -- then the
# tools, the examples as Linux, Termux, Android and the web build them,
# and the tests. Lists every warning (and error) in the kit's own files --
# src/, examples/ and tests/ -- and ends with 1 when there is one.
#
#   sh tools/warncheck.sh            (from the repository's root)
#   sh tools/warncheck.sh quick      (the modules and tools, not the examples and tests)
#
# (The file of every module is written in build/warncheck: inside the
# package, so Nim reports unused imports in it as it does for an app here.)
set -u
out=build/warncheck
mkdir -p $out
here=$(pwd)
# the modules: every file in src/retroui but the ones `include`d by another
inc=$(grep -rh "^include \|^  include \|^    include " src/retroui/*.nim | awk '{print $NF}' | sort -u | tr '\n' ' ')
{
  echo "# every module of the kit (tools/warncheck.sh)"
  for f in src/retroui/*.nim; do
    n=$(basename "$f" .nim)
    case " $inc " in *" $n "*) continue;; esac
    echo "import retroui/$n"
  done
} > $out/allmods.nim
common="--path:src --hints:off -d:ssl -d:useMalloc"
found=0
check() {
  # check NAME FILE FLAGS...
  name=$1; file=$2; shift 2
  nim check $common "$@" "$file" > "$out/$name.log" 2>&1
  # (the kit's own lines; a warning shown for two systems is one to fix)
  grep -E "(Warning|Error):" "$out/$name.log" | grep -E "$here/(src|examples|tests)/" |
    grep -v "\[User\]" | sed "s|$here/||; s|^|$name: |" > "$out/$name.found"
  if grep -q "Error:" "$out/$name.log"; then
    { echo "does not compile ($out/$name.log):"
      grep -m4 -E "Error:|instantiation of" "$out/$name.log" | sed "s|$here/||"; } |
      sed "s|^|$name: |" >> "$out/$name.found"
  fi
  n=$(wc -l < "$out/$name.found")
  if [ "$n" -gt 0 ]; then cat "$out/$name.found"; found=$((found + n)); fi
  echo "  $name: $n" >&2
}
web="--cpu:wasm32 --os:linux -d:wasm --noMain --mm:orc"
android="--os:android --cpu:arm64 --app:lib --noMain -d:noSignalHandler -d:release"
echo "the modules" >&2
check linux $out/allmods.nim
check termux $out/allmods.nim --os:android --cpu:arm64 -d:termux
check android $out/allmods.nim $android
check windows $out/allmods.nim --os:windows
check macos $out/allmods.nim --os:macosx
check ios $out/allmods.nim --os:macosx -d:ios --noMain
check web $out/allmods.nim $web --threads:off
check web-threads $out/allmods.nim $web --threads:on
echo "the tools" >&2
for t in retrokit retroapk retroios retroweb retrostore; do
  check "$t" src/$t.nim
  check "$t-termux" src/$t.nim --os:android --cpu:arm64 -d:termux
  check "$t-windows" src/$t.nim --os:windows
done
if [ "${1:-}" != "quick" ]; then
  echo "the examples" >&2
  for f in examples/*.nim; do
    e=$(basename "$f" .nim)
    check "$e" "$f"
    check "$e-android" "$f" $android
    # (Retro Mail and Communicator are pages with threads only)
    case $e in mail|communicator) t=on;; *) t=off;; esac
    check "$e-web" "$f" $web --threads:$t
  done
  echo "the tests" >&2
  for f in tests/test_*.nim; do
    t=$(basename "$f" .nim)
    check "$t" "$f"
  done
fi
sort -u $out/*.found | sed 's/^[^:]*: //' | sort -u > $out/all.txt
echo "warncheck: $(wc -l < $out/all.txt) warnings and errors in the kit's files ($found in all, each system counted)" >&2
[ "$found" -eq 0 ]

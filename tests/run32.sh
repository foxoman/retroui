#!/bin/sh
# The headless tests as 32-bit programs: `int` has 32 bits there, as in
# WebAssembly (`retrokit web`), so a number that only fits in 64 bits
# (a checksum, a color, a size of a big file) shows up as a RangeDefect.
# Needs gcc-multilib and the 32-bit X11 libraries (Debian, Ubuntu:
# dpkg --add-architecture i386; apt install gcc-multilib libx11-6:i386
# libxext6:i386 libxrandr2:i386 libxcursor1:i386 libxi6:i386).
#
#   sh tests/run32.sh [test_name ...]       (all of `nimble test`'s else)
#
# Exit code: the number of tests that failed.

set -u
cd "$(dirname "$0")/.."
OUT=${RETRO32_OUT:-$(mktemp -d)}
mkdir -p "$OUT"
JOBS=${RETRO32_JOBS:-4}
if [ $# -gt 0 ]; then
  tests="$*"
else
  tests=$(tr '\n' ' ' < retroui.nimble | sed -n 's/.*task test,[^[]*\[\([^]]*\)\].*/\1/p' | tr -d '",')
fi
one() {
  t=$1
  # (SSE for the floats, not the x87's 80 bits: as WebAssembly computes them)
  if nim c -r --hints:off --warnings:off --cpu:i386 --passC:"-m32 -msse2 -mfpmath=sse" --passL:-m32 \
       --nimcache:"$OUT/c_$t" -o:"$OUT/$t" "tests/$t.nim" > "$OUT/$t.log" 2>&1; then
    echo "ok   $t"
  else
    echo "FAIL $t ($OUT/$t.log)"
    grep -m3 "Error\|Defect\|FAIL" "$OUT/$t.log" | sed 's/^/       /'
  fi
  rm -rf "$OUT/c_$t" "$OUT/$t"
}
export OUT
running=0
for t in $tests; do
  one "$t" &
  running=$((running + 1))
  if [ $running -ge "$JOBS" ]; then wait; running=0; fi
done | tee "$OUT/summary"
wait
failed=$(grep -c "^FAIL" "$OUT/summary")
echo "32-bit: $failed failed"
exit "$failed"

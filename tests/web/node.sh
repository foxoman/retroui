#!/bin/sh
# The headless tests that need nothing of the system (no processes, no
# sockets, no threads of their own: not test_calendar, Retro Mail's, nor
# test_hardening) built as WebAssembly (retroweb: clang and wasm-ld) and run
# under Node: the kit's C library for the web, its 32-bit int, its page
# side (retro.js), checked without a browser.
#
#   sh tests/web/node.sh [test_name ...]
#
# Exit code: the number of tests that failed.

set -u
cd "$(dirname "$0")/../.."
OUT=${RETRO_NODE_OUT:-$(mktemp -d)}
JOBS=${RETRO_NODE_JOBS:-4}
tests=${*:-"test_widgets test_business test_text test_bidi test_input test_records
  test_charts test_planning test_mapview test_view3d test_htmlview test_canvas2d test_pdf
  test_report test_scroll test_xlsx test_letters test_morecontrols test_dock test_toolcustom
  test_richedit test_qrcode test_touchsizes test_scale
  test_tilemap test_gltf test_update"}
nim c -d:release --hints:off --warnings:off -o:"$OUT/retroweb" src/retroweb.nim || exit 1
one() {
  t=$1
  if ! "$OUT/retroweb" "tests/$t.nim" --out:"$OUT/$t" --path:src --path:tests --warnings:off \
       > "$OUT/$t.build" 2>&1; then
    echo "FAIL $t (it did not build: $OUT/$t.build)"
    grep -m3 "Error" "$OUT/$t.build" | sed 's/^/       /'
    return
  fi
  if node tests/web/node.js "$OUT/$t/app.wasm" --mount:tests="$(pwd)/tests" \
       --mount:src/retroui/fonts="$(pwd)/src/retroui/fonts" > "$OUT/$t.log" 2>&1; then
    echo "ok   $t"
  else
    echo "FAIL $t ($OUT/$t.log)"
    grep -m3 "Error\|Defect\|FAIL" "$OUT/$t.log" | sed 's/^/       /'
  fi
}
running=0
for t in $tests; do
  one "$t" &
  running=$((running + 1))
  if [ $running -ge "$JOBS" ]; then wait; running=0; fi
done | tee "$OUT/summary"
wait
failed=$(grep -c "^FAIL" "$OUT/summary")
echo "WebAssembly under Node: $failed failed"
exit "$failed"

#!/bin/sh
# The kit as a web page in a real browser: tests/web/webcheck.nim built with
# retroweb (clang and wasm-ld, no Emscripten), served on localhost, driven
# by headless Chromium (Playwright: npm install playwright; npx playwright
# install chromium). At 100 % and at 200 % (a dense screen).
#
#   sh tests/web/run.sh
#
# Exit code: 0 when every check passed.

set -u
cd "$(dirname "$0")/../.."
OUT=${RETRO_WEB_OUT:-$(mktemp -d)}
mkdir -p "$OUT/files"
cp tests/web/files/* "$OUT/files/"
cp tests/data/media/live.mp4 "$OUT/files/"
nim c -d:release --hints:off --warnings:off -o:"$OUT/retroweb" src/retroweb.nim || exit 1
"$OUT/retroweb" tests/web/webcheck.nim --out:"$OUT/page" --files:"$OUT/files" --path:src || exit 1
PORT=${RETRO_WEB_PORT:-8766}
( cd "$OUT/page" && python3 -m http.server "$PORT" --bind 127.0.0.1 > "$OUT/http.log" 2>&1 ) &
server=$!
sleep 1
failed=0
for scale in 1 2; do
  echo "== $scale x"
  node tests/web/run.js "http://127.0.0.1:$PORT/" "$scale" || failed=$((failed + 1))
done
kill $server 2> /dev/null
# retroweb's own server (retrokit run --web): the page, a part of a video
# (seeking), the version the page polls to reload itself
DEV=$((PORT + 1))
"$OUT/retroweb" tests/web/webcheck.nim --serve --no-open --port:$DEV --out:"$OUT/dev" \
  --files:"$OUT/files" --path:src > "$OUT/dev.log" 2>&1 &
dev=$!
i=0
until curl -s -o /dev/null "http://127.0.0.1:$DEV/" || [ $i -ge 120 ]; do sleep 1; i=$((i + 1)); done
check() {
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: $2 (not $3)"; failed=$((failed + 1)); fi
}
check "the dev server: the page" "$(curl -s "http://127.0.0.1:$DEV/" | grep -c __retro_version)" 1
check "the dev server: a part of a video" \
  "$(curl -s -o /dev/null -w '%{http_code} %{size_download}' -H 'Range: bytes=100-199' "http://127.0.0.1:$DEV/app/live.mp4")" "206 100"
check "the dev server: the version" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$DEV/__retro_version")" 200
check "the dev server: nothing outside the page" "$(curl -s -o /dev/null -w '%{http_code}' --path-as-is "http://127.0.0.1:$DEV/../retroweb")" 403
kill $dev 2> /dev/null
[ $failed -eq 0 ] && echo "web: all ok" || echo "web: $failed failed"
exit $failed

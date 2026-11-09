#!/bin/sh
# The screen driver (no windowing system: fb_driver) by itself: the screen
# a file, the input devices a pipe the check app writes the kernel's input
# events into (tests/kiosk/fbcheck.nim). At 32 bits a pixel and at 16
# (RGB565), at two sizes.
#
#   sh tests/kiosk/run.sh
#
# Exit code: 0 when every check passed.

set -u
cd "$(dirname "$0")/../.."
OUT=${RETRO_FB_OUT:-$(mktemp -d)}
mkdir -p "$OUT"
nim c -d:release --hints:off --warnings:off --path:src -o:"$OUT/fbcheck" tests/kiosk/fbcheck.nim || exit 1
failed=0
for screen in 1024x600:32 1280x800:16 1920x1080:32; do
  echo "== $screen"
  rm -f "$OUT/input" "$OUT/screen"
  mkfifo "$OUT/input"
  RETRO_DRIVER=fb RETRO_FB_FILE="$OUT/screen:$screen" RETRO_FB_INPUT="$OUT/input" \
    timeout 60 "$OUT/fbcheck" > "$OUT/log" 2>&1
  code=$?
  cat "$OUT/log" | grep -v "^ *$"
  if [ $code -ne 0 ] || ! grep -q "^DONE 0" "$OUT/log"; then
    echo "FAIL $screen (exit code $code)"
    failed=$((failed + 1))
  else
    echo "PASS Ctrl+Alt+Backspace closed the app"
  fi
done
[ $failed -eq 0 ] && echo "screen: all ok" || echo "screen: $failed failed"
exit $failed

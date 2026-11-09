#!/bin/sh
# tests/live/ref made again: the live check run on Linux (an X server;
# Xvfb is started when there is none) and its pictures kept as the
# reference every system is compared with. Run it after a change to how
# one of the live check's pages draws, and look at the pictures first.
#
#   sh tools/live/makeref.sh        (from the repository's root)
set -e
out=$(mktemp -d)
nim c -d:release --hints:off -o:"$out/livecheck" tests/live/livecheck.nim
if [ -z "${DISPLAY:-}" ]; then
  Xvfb :77 -screen 0 1280x800x24 >/dev/null 2>&1 &
  xvfb=$!
  export DISPLAY=:77
  sleep 1
fi
RETRO_GPU=cpu RETRO_SCALE=100 RETRO_LIVE_OUT="$out/live" RETRO_LIVE_ONLY=controls,grid,chart,html,menu,dialog "$out/livecheck"
[ -n "${xvfb:-}" ] && kill $xvfb
for f in "$out"/live/*.png; do cp "$f" tests/live/ref/; done
rm -rf "$out"
echo "tests/live/ref made again: $(ls tests/live/ref | tr '\n' ' ')"

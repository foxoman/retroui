#!/bin/sh
# The Wayland driver on a real compositor: sway with no screen and no
# devices (wlroots' headless backend, the pixman renderer), the check app
# full screen, its own virtual mouse and keyboard (vinput). Once at 100%,
# once at 150% (fractional scaling). Needs sway, grim and wl-clipboard:
#
#   apt install sway grim wl-clipboard         (Debian, Ubuntu)
#   sh tests/wayland/run.sh
#
# Exit code: 0 when every check passed.

set -u
cd "$(dirname "$0")/../.."
OUT=${RETRO_WL_OUT:-$(mktemp -d)}
mkdir -p "$OUT"
export XDG_RUNTIME_DIR="$OUT/run"
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"

nim c -d:release -d:wayland --hints:off --warnings:off --path:src -o:"$OUT/wlcheck" tests/wayland/wlcheck.nim || exit 1
nim c -d:release --hints:off --warnings:off --path:src -o:"$OUT/vinput" tests/wayland/vinput.nim || exit 1

failed=0
for scale in ${RETRO_WL_SCALES:-1 1.5}; do
  cat > "$OUT/sway.conf" <<EOF
output HEADLESS-1 resolution 1200x780 scale $scale
default_border none
for_window [app_id="wlcheck"] fullscreen enable
EOF
  rm -f "$XDG_RUNTIME_DIR"/wayland-*
  WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_LIBINPUT_NO_DEVICES=1 \
    sway -c "$OUT/sway.conf" > "$OUT/sway-$scale.log" 2>&1 &
  sway=$!
  for i in $(seq 1 40); do
    ls "$XDG_RUNTIME_DIR"/wayland-? > /dev/null 2>&1 && break
    sleep 0.25
  done
  export WAYLAND_DISPLAY=$(basename "$(ls "$XDG_RUNTIME_DIR"/wayland-? | head -1)")
  echo "== $scale x"
  RETRO_GPU=cpu VINPUT="$OUT/vinput" WLCHECK_SAVE="$OUT" timeout 60 "$OUT/wlcheck"
  code=$?
  [ $code -ne 0 ] && failed=$((failed + 1))
  kill $sway 2> /dev/null
  wait $sway 2> /dev/null
done
[ $failed -eq 0 ] && echo "wayland: ok" || echo "wayland: $failed run(s) failed"
exit $failed

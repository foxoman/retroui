#!/bin/sh
# The apps started for real -- their own window, the system's driver -- each
# in a home of its own: the kit's smoke run (RETRO_SMOKE) measures the first
# frame and 3 seconds untouched, then clicks, keys and types until it ends;
# on Linux with an X server, real input comes too (xdotool). A fault, a
# crash, a hang or an app busy while untouched fails it. The results go to
# build/smoke/results.txt, a line each.
#
#   sh tests/smoke/run.sh                       every app below
#   sh tests/smoke/run.sh filemanager photo     these
#
# Linux without a screen: xvfb-run -a sh tests/smoke/run.sh
set -u
apps=${*:-gallery filemanager photo retroboard mail taskman hrbook notepad}
secs=${RETRO_SMOKE_SECS:-14}
out=build/smoke
mkdir -p "$out"
results=$out/results.txt
: > "$results"
failed=""
exe=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exe=".exe" ;; esac
for app in $apps; do
  echo "== $app"
  if ! nim c --hints:off -o:"$out/$app$exe" "examples/$app.nim" > "$out/$app-build.txt" 2>&1; then
    tail -20 "$out/$app-build.txt"
    echo "$app: did not build" >> "$results"
    failed="$failed $app"
    continue
  fi
  home=$(mktemp -d)
  mkdir -p "$home/AppData/Roaming" "$home/AppData/Local"
  # (a home of its own: settings, faults and anything the clicks delete are there)
  HOME=$home USERPROFILE=$home APPDATA=$home/AppData/Roaming LOCALAPPDATA=$home/AppData/Local \
  XDG_CONFIG_HOME=$home/.config XDG_DATA_HOME=$home/.local/share XDG_CACHE_HOME=$home/.cache \
  RETRO_SMOKE=$secs RETRO_SMOKE_OUT=$results \
    "$out/$app$exe" > "$out/$app-log.txt" 2>&1 &
  pid=$!
  # real input on an X server, while the kit's own goes on
  if [ -n "${DISPLAY:-}" ] && command -v xdotool > /dev/null 2>&1; then
    (
      sleep 8
      for i in 1 2 3 4 5 6 7 8 9 10; do
        xdotool mousemove $((40 + i * 37 % 500)) $((60 + i * 53 % 400)) click 1 2>/dev/null
        xdotool key Tab Down Escape 2>/dev/null
        xdotool type --delay 20 "retro" 2>/dev/null
        sleep 0.3
      done
    ) &
  fi
  # (a hang: stopped after twice its time)
  waited=0
  while kill -0 $pid 2>/dev/null && [ $waited -lt $((secs * 2 + 30)) ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 $pid 2>/dev/null; then
    kill -9 $pid 2>/dev/null
    echo "$app: HUNG (stopped after $waited s)" >> "$results"
    failed="$failed $app"
  else
    wait $pid
    code=$?
    if [ $code -ne 0 ]; then
      failed="$failed $app"
      grep -q "^" "$out/$app-log.txt" && tail -25 "$out/$app-log.txt"
      [ $code -gt 2 ] && echo "$app: STOPPED (exit code $code)" >> "$results"
    fi
  fi
  rm -rf "$home"
done
echo
echo "smoke runs:"
cat "$results"
[ -z "$failed" ] || { echo "failed:$failed"; exit 1; }

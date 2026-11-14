#!/bin/sh
# What each example app costs, measured the same way: its program's size
# (built as its packages are: release, stripped, LTO, size-optimized for the
# small ones), the time to its first frame on screen and its processor at
# rest (the kit's smoke run, RETRO_SMOKE), its memory at rest (resident, 3 s
# after it settled, untouched) and the most it took while the smoke run
# clicked, typed and scrolled through it. Each app in a home of its own, on
# the screen in $DISPLAY. The table goes to build/appbench/table.md (for
# docs/benchmarks.md) and a line each to build/appbench/results.txt.
#
#   sh tools/appbench.sh                         the apps below
#   sh tools/appbench.sh podcast filemanager     these
#
# Linux only (/proc); without a screen: xvfb-run -a sh tools/appbench.sh
set -u
cd "$(dirname "$0")/.."
apps=${*:-hello gallery filemanager photo retroboard mail navigator retrodns podcast grow taskman sevenguis}
secs=${RETRO_SMOKE_SECS:-16}
out=build/appbench
mkdir -p "$out"
: > "$out/results.txt"
small="hello gallery filemanager retroboard navigator retrodns podcast grow taskman sevenguis"
for app in $apps; do
  echo "== $app"
  opt=""
  case " $small " in *" $app "*) opt="--opt:size" ;; esac
  # (APPBENCH_PREBUILT=1: the programs are in build/appbench already --
  # built by another user than the one that runs them)
  if [ -z "${APPBENCH_PREBUILT:-}" ] && ! nim c -d:release -d:strip -d:lto $opt --hints:off \
       -o:"$out/$app" "examples/$app.nim" > "$out/$app-build.txt" 2>&1; then
    echo "$app: did not build" | tee -a "$out/results.txt"
    continue
  fi
  [ -x "$out/$app" ] || { echo "$app: not built" | tee -a "$out/results.txt"; continue; }
  size=$(wc -c < "$out/$app")
  home=$(mktemp -d)
  root=$(pwd)
  ( cd "$home" && exec env HOME="$home" XDG_CONFIG_HOME="$home/.config" \
      XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" \
      RETRO_SMOKE=$secs RETRO_SMOKE_OUT="$root/$out/$app-smoke.txt" \
      "$root/$out/$app" > "$root/$out/$app-log.txt" 2>&1 ) &
  pid=$!
  rest=0
  peak=0
  t=0
  # (every half second: the resident memory; at rest is the reading 6 s in --
  # the smoke run settles 4 s, then 3 s untouched)
  while kill -0 $pid 2>/dev/null && [ $t -lt $((secs * 2 + 60)) ]; do
    rss=$(awk '/^VmRSS/ {print $2}' /proc/$pid/status 2>/dev/null || echo 0)
    hwm=$(awk '/^VmHWM/ {print $2}' /proc/$pid/status 2>/dev/null || echo 0)
    [ -n "$hwm" ] && [ "$hwm" -gt "$peak" ] 2>/dev/null && peak=$hwm
    [ $t -eq 12 ] && rest=${rss:-0}
    sleep 0.5
    t=$((t + 1))
  done
  kill -9 $pid 2>/dev/null
  wait $pid 2>/dev/null
  line=$(cat "$out/$app-smoke.txt" 2>/dev/null | tail -1)
  first=$(echo "$line" | sed -n 's/.*first frame \([0-9]*\) ms.*/\1/p')
  idle=$(echo "$line" | sed -n 's/.* \([0-9]*\) ms of processor.*/\1/p')
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$app" "$size" "${first:-?}" "$rest" "$peak" "${idle:-?}" \
    | tee -a "$out/results.txt"
  rm -rf "$home"
done
# the table
{
  echo "| App | Program (stripped) | First frame | Memory at rest | Most memory in use | Processor at rest (3 s) |"
  echo "|---|---|---|---|---|---|"
  awk -F'\t' 'NF == 6 {
    printf "| %s | %.1f MB | %s ms | %.1f MB | %.1f MB | %s ms |\n", $1, $2 / 1048576, $3, $4 / 1024, $5 / 1024, $6
  }' "$out/results.txt"
} > "$out/table.md"
cat "$out/table.md"

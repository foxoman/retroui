#!/bin/sh
# Soak: each app worked by the kit's smoke run for a long while -- clicks,
# keys, the wheel, typing, for an hour by default (RETRO_SMOKE with
# RETRO_SMOKE_STAY: a click on Exit does not end it) -- its memory sampled
# every 20 seconds. Memory that keeps growing once the app has warmed up is
# a leak's sign: an app fails when it holds more than SOAK_LIMIT_MB (16) at
# the end than half way in -- the middle sample of the run's last sixth
# against that of the sixth after the half (a cache filled once, a
# page's pictures, do not count; a spike does not either) -- or ends with
# a fault. A line an app in build/soak/results.txt (and table.md); its
# samples in build/soak/APP.mem. The apps run as on a phone of 2 GB
# (RETRO_DEVICE_MB, SOAK_DEVICE_MB=0 for this machine's own): their caches'
# budgets follow the device's memory, and filled up to a big machine's
# they would look like growth for a long while.
#
#   sh tools/soak.sh                          60 minutes, the apps below
#   sh tools/soak.sh 10 filemanager mail      10 minutes, these
#
# Linux without a screen: xvfb-run -a sh tools/soak.sh. The clicks can
# delete what they reach: each app runs in a home of its own, and the
# script is best run as a user of its own (SOAK_PREBUILT=1: the programs
# are in build/soak already, built by another).
set -u
mins=${1:-60}
[ $# -gt 0 ] && shift
# (not Retro Board nor Retro Navigator unless asked: the clicks keep adding
# shapes, or opening tabs, and their memory grows with what they hold)
apps=${*:-gallery filemanager photo mail retrodns podcast grow taskman}
limit=${SOAK_LIMIT_MB:-16}
out=build/soak
mkdir -p "$out"
: > "$out/results.txt"
failed=""
secs=$((mins * 60))
for app in $apps; do
  echo "== $app ($mins minutes, RETRO_SMOKE_SEED=$$)"
  if [ -z "${SOAK_PREBUILT:-}" ] && ! nim c -d:release --hints:off -o:"$out/$app" "examples/$app.nim" \
       > "$out/$app-build.txt" 2>&1; then
    echo "$app: did not build" | tee -a "$out/results.txt"
    failed="$failed $app"
    continue
  fi
  home=$(mktemp -d)
  root=$(pwd)
  ( cd "$home" && exec env HOME="$home" XDG_CONFIG_HOME="$home/.config" \
      XDG_DATA_HOME="$home/.local/share" XDG_CACHE_HOME="$home/.cache" \
      RETRO_SMOKE=$secs RETRO_SMOKE_STAY=1 RETRO_SMOKE_SEED=$$ RETRO_DEVICE_MB=${SOAK_DEVICE_MB:-2048} \
      "$root/$out/$app" > "$root/$out/$app-run.txt" 2>&1 ) &
  pid=$!
  : > "$out/$app.mem"
  t=0
  while kill -0 $pid 2>/dev/null; do
    kb=$(awk '/^VmRSS:/ {print $2}' /proc/$pid/status 2>/dev/null || true)
    [ -n "$kb" ] && echo "$t $kb" >> "$out/$app.mem"
    sleep 20
    t=$((t + 20))
    [ $t -gt $((secs + 120)) ] && { kill $pid 2>/dev/null; echo "$app: did not end" >> "$out/$app-run.txt"; }
  done
  wait $pid
  code=$?
  rm -rf "$home"
  # its memory half way in, at the end (the middle of a sixth of
  # the samples each), the most
  line=$(awk -v warm=$(( secs / 2 > 60 ? secs / 2 : 60 )) -v limit=$limit -v app=$app -v code=$code '
    function mid(a, b,   n, i, j, v, x) {
      n = 0; for (i = a; i <= b; i++) x[++n] = m[i]
      for (i = 2; i <= n; i++) { v = x[i]; for (j = i - 1; j >= 1 && x[j] > v; j--) x[j + 1] = x[j]; x[j + 1] = v }
      return x[int((n + 1) / 2)]
    }
    { t[NR] = $1; m[NR] = $2; if ($2 > most) most = $2 }
    END {
      if (NR < 6) { printf "%s: too few samples (exit %d)\n", app, code; exit }
      w = 1; while (w < NR && t[w] < warm) w++
      k = int((NR - w + 1) / 6); if (k < 2) k = 2
      if (w + k - 1 > NR - k) w = NR - 2 * k + 1
      if (w < 1) w = 1
      early = mid(w, w + k - 1); late = mid(NR - k + 1, NR)
      grew = (late - early) / 1024
      verdict = (grew > limit || code != 0) ? "FAIL" : "ok"
      printf "%s\t%.1f\t%.1f\t%.1f\t%+.1f\t%d\t%s\n", app, early / 1024, late / 1024, most / 1024, grew, code, verdict
    }' "$out/$app.mem")
  echo "$line" | tee -a "$out/results.txt"
  case "$line" in *FAIL*|*"too few"*) failed="$failed $app" ;; esac
done
{
  echo "| App | Half way in | At the end | Most | Grew | Exit | |"
  echo "|---|---|---|---|---|---|---|"
  awk -F'\t' 'NF >= 7 { printf "| %s | %s MB | %s MB | %s MB | %s MB | %s | %s |\n", $1, $2, $3, $4, $5, $6, $7 }' "$out/results.txt"
} > "$out/table.md"
cat "$out/table.md"
[ -z "$failed" ] || { echo "soak: failed:$failed"; exit 1; }

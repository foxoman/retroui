#!/bin/sh
# Every example checked as the compiler reads it -- every module, every type,
# every call -- for a system (`nim check`: no C compiled, so a few minutes for
# all of them, not the half hour of building them, and any system's from
# this one: its `when defined(windows)` parts read too). An example that
# breaks shows up on the push that broke it. The tutorials' steps are built
# by `nimble tutorials`; full builds: `nimble apps`.
#
#   sh tools/examplescheck.sh                 every examples/*.nim, for this system
#   sh tools/examplescheck.sh photo mail      these
#   EXAMPLES_FOR=android sh tools/examplescheck.sh   for an APK's (windows, macosx, ios too)
set -u
names=${*:-$(ls examples/*.nim | sed 's|examples/||; s|\.nim$||')}
case "${EXAMPLES_FOR:-}" in
  "") target="" ;;
  android) target="--os:android --cpu:arm64 --app:lib --noMain -d:noSignalHandler -d:release" ;;
  ios) target="--os:ios --cpu:arm64 --app:staticlib --noMain -d:release" ;;
  *) target="--os:$EXAMPLES_FOR" ;;
esac
failed=""
n=0
log=$(mktemp)
for e in $names; do
  n=$((n + 1))
  start=$(date +%s)
  # shellcheck disable=SC2086
  if nim check --hints:off --warnings:off $target "examples/$e.nim" > "$log" 2>&1; then
    echo "ok   $e ($(( $(date +%s) - start )) s)"
  else
    echo "FAIL $e"
    grep -E "Error|error:" "$log" | head -5
    failed="$failed $e"
  fi
done
rm -f "$log"
for_what=${EXAMPLES_FOR:-this system}
if [ -n "$failed" ]; then
  echo "examples ($for_what): failed:$failed (of $n)"
  exit 1
fi
echo "examples ($for_what): all $n checked"

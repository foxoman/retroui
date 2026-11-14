#!/bin/sh
# The headless tests of `nimble test`, as many at once as the machine has
# cores, each with a temporary folder of its own (TMPDIR) and its own log
# in build/tests. A test that fails among the others is run again alone
# when they are done: passing then, it is named "flaky" (it fails with
# the machine busy: a timing, a port, a file another test reaches) and the
# run still passes; failing again, the run fails.
#
#   sh tests/runall.sh                      every test (retroui.nimble's list)
#   sh tests/runall.sh test_board test_lzma these
#   RETRO_JOBS=2                            at once (the cores' number)
#   RETRO_REPEAT=5                          every test 5 times: the flaky ones
#   RETRO_RETRY=0                           a failure stands (no run alone)
#   RETRO_FLAKY_FAILS=1                     a flaky test fails the run too
#   RETRO_TEST_FLAGS="--cc:clang ..."       for every build (the sanitizers)
#   RETRO_TEST_MINUTES=30                   a test that runs longer is stopped
#
# Exit code: 0 when every test passed (flaky ones too, unless
# RETRO_FLAKY_FAILS=1), else 1.
# build/tests/results.txt: a line a test -- ok, flaky or FAIL, its seconds.
set -u
cd "$(dirname "$0")/.."
OUT=${RETRO_TEST_OUT:-build/tests}

if [ "${1:-}" = "--one" ]; then
  # one test: built, then run (with a time limit, where `timeout` is)
  job=$2
  src=$job
  flags=""
  case $job in
    test_fontsoption-ui) src=test_fontsoption; flags="-d:retroFonts=ui" ;;
  esac
  log="$OUT/$job.log"
  # (a short path, in the system's temporary folder: tests lay out paths
  # under it and check they fit a bar)
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/rt.XXXXXX")
  mkdir -p "$OUT/bin"
  limit=""
  command -v timeout > /dev/null && limit="timeout -k 10 $((${RETRO_TEST_MINUTES:-30} * 60))"
  start=$(date +%s)
  # (a test of its own build folder: the variant of a test beside it)
  # shellcheck disable=SC2086
  if nim c --hints:off $flags ${RETRO_TEST_FLAGS:-} --nimcache:"${XDG_CACHE_HOME:-$HOME/.cache}/nim/${job}_d" \
       -o:"$OUT/bin/$job" "tests/$src.nim" > "$log" 2>&1 &&
     TMPDIR="$tmp" TEMP="$tmp" TMP="$tmp" $limit "$OUT/bin/$job" >> "$log" 2>&1; then
    printf 'ok\t%s\t%s\n' "$job" $(( $(date +%s) - start )) >> "$OUT/round.txt"
    rm -rf "$tmp" "$OUT/bin/$job"
  else
    code=$?
    [ $code = 124 ] && echo "(stopped: ran over ${RETRO_TEST_MINUTES:-30} minutes)" >> "$log"
    echo "(its temporary folder: $tmp)" >> "$log"
    printf 'FAIL\t%s\t%s\n' "$job" $(( $(date +%s) - start )) >> "$OUT/round.txt"
    echo "FAIL $job"
  fi
  exit 0
fi

if [ $# -gt 0 ]; then
  tests="$*"
else
  tests="$(tr '\n' ' ' < retroui.nimble | sed -n 's/.*task test,[^[]*\[\([^]]*\)\].*/\1/p' | tr -d '",') test_fontsoption-ui"
fi
jobs=${RETRO_JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}
repeat=${RETRO_REPEAT:-1}
mkdir -p "$OUT"
: > "$OUT/all.txt"
n=$(echo $tests | wc -w | tr -d ' ')
echo "tests: $n, $jobs at once$( [ "$repeat" -gt 1 ] && echo ", $repeat times")"
round=1
while [ $round -le "$repeat" ]; do
  : > "$OUT/round.txt"
  # shellcheck disable=SC2086
  printf '%s\n' $tests | xargs -P "$jobs" -I{} sh tests/runall.sh --one {}
  cat "$OUT/round.txt" >> "$OUT/all.txt"
  round=$((round + 1))
done

# what failed: alone, again (unless RETRO_RETRY=0)
failedOnce=$(awk -F'\t' '$1 == "FAIL" { print $2 }' "$OUT/all.txt" | sort -u)
: > "$OUT/results.txt"
bad=""
flaky=""
for t in $failedOnce; do
  if [ "${RETRO_RETRY:-1}" != 0 ]; then
    : > "$OUT/round.txt"
    mv "$OUT/$t.log" "$OUT/$t.first.log"
    sh tests/runall.sh --one "$t" > /dev/null
    if grep -q "^ok" "$OUT/round.txt"; then flaky="$flaky $t"; continue; fi
  fi
  bad="$bad $t"
done
for t in $tests; do
  secs=$(awk -F'\t' -v t="$t" '$2 == t { s += $3; n++ } END { if (n) printf "%d", s / n }' "$OUT/all.txt")
  v=ok
  case " $flaky " in *" $t "*) v=flaky ;; esac
  case " $bad " in *" $t "*) v=FAIL ;; esac
  printf '%s\t%s\t%s\n' "$v" "$t" "${secs:-0}" >> "$OUT/results.txt"
done

gh=${GITHUB_ACTIONS:-}
for t in $flaky; do
  echo "flaky: $t (failed with the others running, passed alone; $OUT/$t.first.log)"
  [ -n "$gh" ] && echo "::warning title=$t::failed with the other tests running, passed alone"
done
for t in $bad; do
  echo "FAIL: $t"
  [ -n "$gh" ] && echo "::error title=$t::failed"
  [ -n "$gh" ] && echo "::group::$t"
  tail -40 "$OUT/$t.log" 2>/dev/null
  [ -n "$gh" ] && echo "::endgroup::"
done
echo "the slowest:"
sort -t "$(printf '\t')" -k3 -rn "$OUT/results.txt" | head -8 | awk -F'\t' '{ printf "  %4d s  %s\n", $3, $2 }'
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "Tests: $n ($(echo $bad | wc -w | tr -d ' ') failed, $(echo $flaky | wc -w | tr -d ' ') flaky)"
    for t in $flaky; do echo "- flaky: \`$t\`"; done
    for t in $bad; do echo "- **failed: \`$t\`**"; done
  } >> "$GITHUB_STEP_SUMMARY"
fi
echo "tests: $(echo $bad | wc -w | tr -d ' ') failed, $(echo $flaky | wc -w | tr -d ' ') flaky, of $n"
[ -z "$bad" ] && { [ "${RETRO_FLAKY_FAILS:-0}" != 1 ] || [ -z "$flaky" ]; }

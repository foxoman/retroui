#!/bin/sh
# The apps driven by their controls' names (RETRO_DRIVE): every tab clicked,
# every menu opened and closed, each app asked after each step that it is
# still there, then closed by its close box (tests/drive/tour.nim). The
# smoke run's builds are taken when they are there (build/smoke).
#
#   sh tests/drive/run.sh                       the apps below
#   sh tests/drive/run.sh gallery notepad       these
#   TOUR_STRICT=1 sh tests/drive/run.sh         a finding fails it too (the
#                                               Linux job of the CI)
#
# Linux without a screen: xvfb-run -a sh tests/drive/run.sh
set -u
apps=${*:-gallery notepad taskman hrbook sevenguis}
out=build/drive
mkdir -p "$out"
exe=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exe=".exe" ;; esac
nim c -d:release --hints:off --path:src -o:"$out/tour$exe" tests/drive/tour.nim || exit 1
list=""
for app in $apps; do
  # (the smoke run's build when nothing changed since: built just before)
  if [ -f "build/smoke/$app$exe" ] &&
     [ -z "$(find src "examples/$app.nim" -newer "build/smoke/$app$exe" 2>/dev/null | head -1)" ]; then
    list="$list build/smoke/$app$exe"
  elif nim c --hints:off -o:"$out/$app$exe" "examples/$app.nim" > "$out/$app-build.txt" 2>&1; then
    list="$list $out/$app$exe"
  else
    tail -20 "$out/$app-build.txt"
    echo "$app: did not build"
    exit 1
  fi
done
strict=""
[ -n "${TOUR_STRICT:-}" ] && strict="--strict"
# shellcheck disable=SC2086
"$out/tour$exe" $strict $list

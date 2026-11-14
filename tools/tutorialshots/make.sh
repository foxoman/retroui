#!/bin/sh
# The tutorials' pictures (tutorials/LESSON/STEP.png), made again from the
# steps' own programs: each runs on a fake screen at 200 %, its script
# brings it to the moment the picture shows. The steps marked
# `#> build-only` are checked by the compiler for every system they are
# for. Then a check that every step's code is in its lesson as it is.
# Needs Python 3.
#
#   sh tools/tutorialshots/make.sh        (from the repository's root)
set -e
here=$(dirname "$0")
python3 "$here/gen.py"
nim c --hints:off --warnings:off -d:useMalloc --path:src \
  --nimcache:"$here/build/cache" -o:"$here/build/study" "$here/build/study.nim"
rm -rf "$here/build/out"
# (a home of its own: what the steps save stays there)
home=$(mktemp -d)
HOME="$home" XDG_DATA_HOME="$home/.local/share" XDG_CONFIG_HOME="$home/.config" \
  OUT="$here/build/out" "$here/build/study"
rm -rf "$home"
for f in "$here"/build/out/*.png; do
  name=$(basename "$f" .png)              # LESSON--STEP
  lesson=${name%%--*}
  cp "$f" "tutorials/$lesson/${name#*--}.png"
done
# the steps built only: checked as each system builds them
while read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    *15-testing*) nim check --hints:off --path:src --path:tests "$f" ;;
    *) for os in "" "--os:windows" "--os:macosx" "--os:android -d:androidNDK"; do
         nim check --hints:off --path:src $os "$f" > /dev/null || { echo "does not build ($os): $f"; exit 1; }
       done ;;
  esac
done < "$here/build/buildonly.txt"
python3 "$here/gen.py" --check
echo "tutorials: pictures made, every step built, the lessons show their code"

#!/usr/bin/env sh
# Compiles glue/java into glue/classes.dex, the Java that retroapk puts in
# the app (--java:glue). Needed again only when the Java changes: the
# repository has the dex, so an APK builds with no Java on the computer.
#
# Termux:  pkg install openjdk-21   and one of:  d8  or  dx
#          (pkg search d8 / pkg search dx shows what your repo has)
# Linux:   a JDK, and d8 (Android SDK build-tools) or dx (Debian: dalvik-exchange)
#
# No android.jar is needed: glue/stubs stand in for the Android classes the
# Java uses, at compile time only.
set -e
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

command -v javac >/dev/null || { echo "javac is missing (Termux: pkg install openjdk-21)"; exit 1; }
mkdir -p "$work/stubs" "$work/classes" "$work/out"
javac -source 8 -target 8 -nowarn -Xlint:-options -d "$work/stubs" \
  $(find "$here/stubs" -name '*.java')
javac -source 8 -target 8 -nowarn -Xlint:-options -cp "$work/stubs" -d "$work/classes" \
  $(find "$here/java" -name '*.java')

if command -v d8 >/dev/null; then
  d8 --release --min-api 24 --output "$work/out" $(find "$work/classes" -name '*.class')
elif command -v dx >/dev/null; then
  dx --dex --min-sdk-version=24 --output="$work/out/classes.dex" "$work/classes"
elif command -v dalvik-exchange >/dev/null; then
  dalvik-exchange --dex --min-sdk-version=24 --output="$work/out/classes.dex" "$work/classes"
else
  echo "No dex compiler: install d8 or dx (Termux: pkg search d8)"
  exit 1
fi
cp "$work/out/classes.dex" "$here/classes.dex"
echo "wrote glue/classes.dex ($(wc -c < "$here/classes.dex") bytes)"

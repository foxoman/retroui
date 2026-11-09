#!/bin/sh
# The live check's APK on a running emulator or phone (adb): installed,
# started, its pictures and results.txt fetched into live/ (from its files
# folder: the APK is built --debuggable for run-as), a picture of the
# screen too. Fails when a check failed or no results came.
set -u
pkg=org.retro.livecheck
mkdir -p live
adb install -r build/livecheck.apk
adb shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 >/dev/null
for i in $(seq 1 150); do
  adb shell run-as $pkg ls files/results.txt >/dev/null 2>&1 && break
  sleep 1
done
adb exec-out screencap -p > live/screen.png 2>/dev/null || true
for f in $(adb shell run-as $pkg ls files 2>/dev/null | tr -d '\r'); do
  case "$f" in
    *.png|*.txt) adb exec-out run-as $pkg cat "files/$f" > "live/$f" ;;
  esac
done
adb logcat -d -s retro:* livecheck:* > live/logcat.txt 2>/dev/null || true
[ -f live/results.txt ] || { echo "no results from the app"; exit 1; }
cat live/results.txt
! grep -q '^FAIL' live/results.txt

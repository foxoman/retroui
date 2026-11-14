#!/bin/sh
# The live check's APK on a running emulator or phone (adb): installed,
# started, its pictures and results.txt fetched into live/ (from its files
# folder: the APK is built --debuggable for run-as), a picture of the
# screen too. Fails when a check failed or no results came.
#
# Started by its launcher activity and waited for, as tests/android/apps.sh
# starts the apps -- not the monkey, whose one event stops the emulator's
# own system UI now and then (then the app never draws: no pictures, no
# results) -- and started once more when no results came. What the system
# says of the app is printed when they do not come.
#
#   sh tests/live/android.sh                    the live check (build/livecheck.apk)
#   sh tests/live/android.sh APK PACKAGE DIR    another check of its kind (its
#                                               results.txt in its data folder)
set -u
apk=${1:-build/livecheck.apk}
pkg=${2:-org.retro.livecheck}
dir=${3:-live}
mkdir -p "$dir"
# (every adb reads from /dev/null: adb shell would eat the script's input)
adb install -r "$apk" < /dev/null
launch() {
  adb shell am force-stop $pkg < /dev/null
  adb shell input keyevent KEYCODE_WAKEUP < /dev/null > /dev/null 2>&1
  adb shell wm dismiss-keyguard < /dev/null > /dev/null 2>&1
  act=$(adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER $pkg \
        < /dev/null 2>/dev/null | tr -d '\r' | tail -1)
  case $act in
    */*) adb shell am start -W -n "$act" < /dev/null > /dev/null 2>&1 ;;
    *) adb shell monkey -p $pkg -c android.intent.category.LAUNCHER 1 < /dev/null > /dev/null 2>&1 ;;
  esac
}
finished() { adb shell run-as $pkg ls files/results.txt < /dev/null > /dev/null 2>&1; }
said() {
  # (what the system knows: is it running, what has the focus, its log)
  echo "--- no results from the app in 90 s (start $1)"
  echo "process: $(adb shell pidof $pkg < /dev/null 2>/dev/null | tr -d '\r')"
  adb shell dumpsys window < /dev/null 2>/dev/null | tr -d '\r' | grep -E "mCurrentFocus|mFocusedApp" | head -4
  adb shell run-as $pkg ls files < /dev/null 2>/dev/null | tr -d '\r' | tr '\n' ' '; echo
  adb logcat -d < /dev/null 2>/dev/null |
    grep -E " uirelays *:| retro *:|livecheck|$pkg|AndroidRuntime|DEBUG *:|libc *:|ANR in" | tail -40
  echo "---"
}
for start in 1 2; do
  adb shell run-as $pkg rm -f files/results.txt < /dev/null > /dev/null 2>&1
  launch
  for i in $(seq 1 90); do
    finished && break
    sleep 1
  done
  finished && break
  said $start
done
adb exec-out screencap -p > "$dir/screen.png" 2>/dev/null < /dev/null || true
for f in $(adb shell run-as $pkg ls files < /dev/null 2>/dev/null | tr -d '\r'); do
  case "$f" in
    *.png|*.txt) adb exec-out run-as $pkg cat "files/$f" < /dev/null > "$dir/$f" ;;
  esac
done
adb logcat -d -s retro:* livecheck:* < /dev/null > "$dir/logcat.txt" 2>/dev/null || true
[ -f "$dir/results.txt" ] || { echo "no results from the app"; exit 1; }
cat "$dir/results.txt"
! grep -q '^FAIL' "$dir/results.txt"

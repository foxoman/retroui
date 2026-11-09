#!/bin/sh
# Every app's APK on a running emulator or phone (adb), as people use them:
# installed and opened without its permissions (nothing allowed yet), then
# with them all; then the monkey -- random taps, swipes and keys, the same
# ones each time (a fixed seed) -- for a while. A crash anywhere, the Java
# side's or the native code's, fails it. The screens and the logs go to
# live/apps/.
#
#   sh tests/android/apps.sh build/apps/list.txt
#
# list.txt: one "PACKAGE FILE.apk" a line (the APKs built by the workflow).
set -u
list=${1:-build/apps/list.txt}
out=live/apps
mkdir -p "$out"
failed=0
alive() { [ -n "$(adb shell pidof "$1" 2>/dev/null | tr -d '\r')" ]; }
crashed() {
  # (the app's own crash lines in the log: Java's, or a native signal)
  grep -A2 "FATAL EXCEPTION" "$2" | grep -q "Process: $1" ||
    grep -q "Fatal signal.*($1)\|>>> $1 <<<" "$2"
}
start() {
  adb shell am force-stop "$1"
  adb shell monkey -p "$1" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 10
}
while read -r pkg apk; do
  [ -z "$pkg" ] && continue
  name=$(basename "$apk" .apk)
  echo "== $name ($pkg)"
  adb uninstall "$pkg" >/dev/null 2>&1
  if ! adb install -r "$apk" >/dev/null; then
    echo "FAIL $name: it did not install"; failed=$((failed + 1)); continue
  fi
  adb logcat -c
  bad=""
  # 1. opened with nothing allowed yet
  start "$pkg"
  adb exec-out screencap -p > "$out/$name-1-first.png" 2>/dev/null
  alive "$pkg" || bad="it closed when opened without its permissions"
  # 2. every permission it asks for allowed (and all files' access)
  for p in $(adb shell dumpsys package "$pkg" | tr -d '\r' |
             sed -n '/requested permissions:/,/install permissions:/p' |
             grep -o 'android.permission.[A-Z_]*'); do
    adb shell pm grant "$pkg" "$p" >/dev/null 2>&1
  done
  adb shell appops set --uid "$pkg" MANAGE_EXTERNAL_STORAGE allow >/dev/null 2>&1
  start "$pkg"
  adb exec-out screencap -p > "$out/$name-2-allowed.png" 2>/dev/null
  [ -z "$bad" ] && ! alive "$pkg" && bad="it closed when opened with its permissions"
  # 3. the monkey: 600 events, the same each time
  adb shell monkey -p "$pkg" -s 4242 --throttle 120 --pct-syskeys 0 --pct-appswitch 0 \
    --pct-anyevent 0 -v 600 > "$out/$name-monkey.txt" 2>&1
  adb exec-out screencap -p > "$out/$name-3-monkey.png" 2>/dev/null
  if [ -z "$bad" ] && grep -q "// CRASH\|// NATIVE CRASH\|// NOT RESPONDING" "$out/$name-monkey.txt"; then
    bad="it stopped under the monkey ($(grep -m1 '// CRASH\|// NATIVE CRASH\|// NOT RESPONDING' "$out/$name-monkey.txt"))"
  fi
  adb logcat -d > "$out/$name-logcat.txt" 2>/dev/null
  [ -z "$bad" ] && crashed "$pkg" "$out/$name-logcat.txt" && bad="a crash in its log"
  # (what the app wrote down itself: the kit's fault log)
  adb shell run-as "$pkg" cat files/faults.log > "$out/$name-faults.txt" 2>/dev/null
  if [ -n "$bad" ]; then
    echo "FAIL $name: $bad"
    grep -E -A 25 "FATAL EXCEPTION|Fatal signal|backtrace:" "$out/$name-logcat.txt" | head -60
    [ -s "$out/$name-faults.txt" ] && head -40 "$out/$name-faults.txt"
    failed=$((failed + 1))
  else
    echo "ok   $name"
  fi
  adb uninstall "$pkg" >/dev/null 2>&1
done < "$list"
echo "apps on Android: $failed failed"
exit $failed

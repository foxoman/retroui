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
# (every adb here reads from /dev/null: adb shell reads its input, and would
# eat the rest of the list -- only the first app was tried)
alive() { [ -n "$(adb shell pidof "$1" < /dev/null 2>/dev/null | tr -d '\r')" ]; }
crashed() {
  # (the app's own crash lines in the log: Java's, or a native signal)
  grep -A2 "FATAL EXCEPTION" "$2" | grep -q "Process: $1" ||
    grep -q "Fatal signal.*($1)\|>>> $1 <<<" "$2"
}
start() {
  # (by its launcher activity, waited for -- not the monkey, whose one event
  # stops the emulator's own system UI now and then; then up to 30 s for a
  # big app's library to load on an emulator without a GPU)
  adb shell am force-stop "$1" < /dev/null
  act=$(adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$1" \
        < /dev/null 2>/dev/null | tr -d '\r' | tail -1)
  case $act in
    */*) adb shell am start -W -n "$act" < /dev/null > /dev/null 2>&1 ;;
    *) adb shell monkey -p "$1" -c android.intent.category.LAUNCHER 1 < /dev/null > /dev/null 2>&1 ;;
  esac
  for i in 1 2 3 4 5 6; do
    sleep 5
    alive "$1" && break
  done
  sleep 3
}
while read -r pkg apk; do
  [ -z "$pkg" ] && continue
  name=$(basename "$apk" .apk)
  echo "== $name ($pkg)"
  adb uninstall "$pkg" < /dev/null >/dev/null 2>&1
  if ! adb install -r "$apk" < /dev/null >/dev/null; then
    echo "FAIL $name: it did not install"; failed=$((failed + 1)); continue
  fi
  adb logcat -c < /dev/null
  bad=""
  # 1. opened with nothing allowed yet
  start "$pkg"
  adb exec-out screencap -p < /dev/null > "$out/$name-1-first.png" 2>/dev/null
  alive "$pkg" || bad="it closed when opened without its permissions"
  # 2. every permission it asks for allowed (and all files' access)
  for p in $(adb shell dumpsys package "$pkg" < /dev/null | tr -d '\r' |
             sed -n '/requested permissions:/,/install permissions:/p' |
             grep -o 'android.permission.[A-Z_]*'); do
    adb shell pm grant "$pkg" "$p" < /dev/null >/dev/null 2>&1
  done
  adb shell appops set --uid "$pkg" MANAGE_EXTERNAL_STORAGE allow < /dev/null >/dev/null 2>&1
  start "$pkg"
  adb exec-out screencap -p < /dev/null > "$out/$name-2-allowed.png" 2>/dev/null
  [ -z "$bad" ] && ! alive "$pkg" && bad="it closed when opened with its permissions"
  # 3. the monkey: 600 events, the same each time
  adb shell monkey -p "$pkg" -s 4242 --throttle 120 --pct-syskeys 0 --pct-appswitch 0 \
    --pct-anyevent 0 -v 600 < /dev/null > "$out/$name-monkey.txt" 2>&1
  adb exec-out screencap -p < /dev/null > "$out/$name-3-monkey.png" 2>/dev/null
  # (the app's own: the emulator's system UI stops now and then by itself)
  if [ -z "$bad" ] && grep -q "// CRASH: $pkg\|// NATIVE CRASH: $pkg\|// NOT RESPONDING: $pkg" "$out/$name-monkey.txt"; then
    bad="it stopped under the monkey ($(grep -m1 "// CRASH: $pkg\|// NATIVE CRASH: $pkg\|// NOT RESPONDING: $pkg" "$out/$name-monkey.txt"))"
  fi
  adb logcat -d < /dev/null > "$out/$name-logcat.txt" 2>/dev/null
  [ -z "$bad" ] && crashed "$pkg" "$out/$name-logcat.txt" && bad="a crash in its log"
  # (what the app wrote down itself: the kit's fault log)
  adb shell run-as "$pkg" cat files/faults.log < /dev/null > "$out/$name-faults.txt" 2>/dev/null
  if [ -n "$bad" ]; then
    echo "FAIL $name: $bad"
    # (the app's own crash, else what the system said of its process)
    if crashed "$pkg" "$out/$name-logcat.txt"; then
      grep -E -A 25 "FATAL EXCEPTION|Fatal signal|backtrace:" "$out/$name-logcat.txt" |
        grep -v "com.android.systemui" | head -60
    else
      grep -E "$pkg|ActivityManager|libc|DEBUG|linker|dlopen|UnsatisfiedLink|RetroActivity" \
        "$out/$name-logcat.txt" | grep -v "monkey" | tail -60
    fi
    [ -s "$out/$name-faults.txt" ] && head -40 "$out/$name-faults.txt"
    failed=$((failed + 1))
  else
    echo "ok   $name"
  fi
  adb uninstall "$pkg" < /dev/null >/dev/null 2>&1
done < "$list"
echo "apps on Android: $failed failed"
exit $failed

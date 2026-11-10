#!/bin/sh
# Every app's APK on a running emulator or phone (adb), as people use them:
# installed and opened without its permissions (nothing allowed yet), then
# with them all; turned both ways, put away and brought back; then the
# monkey -- random taps, swipes and keys, the same ones each time (a fixed
# seed) -- for a while. A crash anywhere, the Java
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
# (a log big enough for an app's whole run: the emulator's own is a few
# hundred kilobytes, gone in a minute)
adb logcat -G 16M < /dev/null > /dev/null 2>&1
# (every adb here reads from /dev/null: adb shell reads its input, and would
# eat the rest of the list -- only the first app was tried)
alive() { [ -n "$(adb shell pidof "$1" < /dev/null 2>/dev/null | tr -d '\r')" ]; }
crashed() {
  # (the app's own crash lines in the log: Java's, or a native signal)
  grep -A2 "FATAL EXCEPTION" "$2" | grep -q "Process: $1" ||
    grep -q "Fatal signal.*($1)\|>>> $1 <<<" "$2"
}
addr2line=$(ls "${ANDROID_NDK_HOME:-${ANDROID_SDK_ROOT:-/usr/local/lib/android/sdk}/ndk}"/*/toolchains/llvm/prebuilt/*/bin/llvm-addr2line \
            "${ANDROID_NDK_HOME:-/nonexistent}"/toolchains/llvm/prebuilt/*/bin/llvm-addr2line 2>/dev/null | tail -1)
named() {
  # named APK LOG: the native crash's frames in the app's library, named
  # (the emulator's APKs are built --debuggable: not stripped)
  [ -n "$addr2line" ] || return 0
  lib=$(mktemp -d)
  unzip -q -o "$1" 'lib/*/libmain.so' -d "$lib" 2>/dev/null || { rm -rf "$lib"; return 0; }
  so=$(ls "$lib"/lib/*/libmain.so 2>/dev/null | head -1)
  grep -E "#[0-9]+ pc [0-9a-f]+ .*libmain.so" "$2" | grep -v Monkey | head -24 |
    while read -r line; do
      pc=$(echo "$line" | sed -n 's/.* pc \([0-9a-f]*\) .*/\1/p')
      fn=$("$addr2line" -f -C -e "$so" "0x$pc" 2>/dev/null | head -1)
      echo "  $(echo "$line" | sed -n 's/.*\(#[0-9]*\) pc.*/\1/p') 0x$pc $fn"
    done
  rm -rf "$lib"
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
why() {
  # (what the system knows of how the app's process ended, said at once:
  # the log rotates on an emulator in a minute or two)
  echo "--- $1: $2"
  adb shell dumpsys activity exit-info "$1" < /dev/null 2>/dev/null | tr -d '\r' |
    grep -E "ApplicationExitInfo|reason=|status=|importance=|description=|timestamp=" | head -24
  adb logcat -d -b crash < /dev/null 2>/dev/null | tail -60
  adb logcat -d -b events < /dev/null 2>/dev/null |
    grep -E "am_proc_died|am_crash|am_kill|wm_finish_activity|wm_destroy_activity|wm_relaunch|am_proc_start" |
    grep "$1" | tail -20
  adb logcat -d < /dev/null 2>/dev/null | grep -E " uirelays *:|$1|AndroidRuntime|DEBUG *:|libc *:" |
    grep -v "monkey\|InputDispatcher\|ImeTracker\|InputMethod" | tail -40
  echo "---"
}
online() {
  # (the emulator drops off adb now and then -- "device offline" -- for a
  # moment: it is waited for, up to a minute, before the next app)
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [ "$(adb get-state < /dev/null 2>/dev/null | tr -d '\r')" = device ] && return 0
    adb reconnect offline < /dev/null > /dev/null 2>&1
    sleep 5
  done
  return 1
}
back() {
  # (brought back from the background as its icon does: not stopped first)
  act=$(adb shell cmd package resolve-activity --brief -c android.intent.category.LAUNCHER "$1" \
        < /dev/null 2>/dev/null | tr -d '\r' | tail -1)
  adb shell am start -n "$act" < /dev/null > /dev/null 2>&1
  sleep 4
}
while read -r pkg apk; do
  [ -z "$pkg" ] && continue
  name=$(basename "$apk" .apk)
  echo "== $name ($pkg)"
  online || echo "(the emulator is offline)"
  adb uninstall "$pkg" < /dev/null >/dev/null 2>&1
  if ! adb install -r "$apk" < /dev/null >/dev/null; then
    # (once more, the emulator back first)
    online
    if ! adb install -r "$apk" < /dev/null >/dev/null; then
      echo "FAIL $name: it did not install ($(adb get-state < /dev/null 2>&1 | tr -d '\r'))"
      failed=$((failed + 1)); continue
    fi
  fi
  adb logcat -c < /dev/null
  adb logcat -b crash -c < /dev/null 2>/dev/null
  bad=""
  # 1. opened with nothing allowed yet
  start "$pkg"
  adb exec-out screencap -p < /dev/null > "$out/$name-1-first.png" 2>/dev/null
  alive "$pkg" || { bad="it closed when opened without its permissions"; why "$pkg" "$bad"; }
  # 2. every permission it asks for allowed (and all files' access)
  for p in $(adb shell dumpsys package "$pkg" < /dev/null | tr -d '\r' |
             sed -n '/requested permissions:/,/install permissions:/p' |
             grep -o 'android.permission.[A-Z_]*'); do
    adb shell pm grant "$pkg" "$p" < /dev/null >/dev/null 2>&1
  done
  adb shell appops set --uid "$pkg" MANAGE_EXTERNAL_STORAGE allow < /dev/null >/dev/null 2>&1
  start "$pkg"
  adb exec-out screencap -p < /dev/null > "$out/$name-2-allowed.png" 2>/dev/null
  [ -z "$bad" ] && ! alive "$pkg" && { bad="it closed when opened with its permissions"; why "$pkg" "$bad"; }
  # 3. turned both ways (a phone held upright turns an app that wants
  # landscape as it starts), then put away and brought back
  adb shell settings put system accelerometer_rotation 0 < /dev/null
  for r in 1 0 3 0; do
    adb shell settings put system user_rotation $r < /dev/null
    sleep 2
  done
  adb exec-out screencap -p < /dev/null > "$out/$name-3-turned.png" 2>/dev/null
  [ -z "$bad" ] && ! alive "$pkg" && { bad="it closed when the screen was turned"; why "$pkg" "$bad"; }
  adb shell input keyevent KEYCODE_HOME < /dev/null
  sleep 3
  back "$pkg"
  adb exec-out screencap -p < /dev/null > "$out/$name-4-back.png" 2>/dev/null
  [ -z "$bad" ] && ! alive "$pkg" && { bad="it closed when put away and brought back"; why "$pkg" "$bad"; }
  # 5. the monkey: 600 events, the same each time
  adb shell monkey -p "$pkg" -s 4242 --throttle 120 --pct-syskeys 0 --pct-appswitch 0 \
    --pct-anyevent 0 -v 600 < /dev/null > "$out/$name-monkey.txt" 2>&1
  adb exec-out screencap -p < /dev/null > "$out/$name-5-monkey.png" 2>/dev/null
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
      echo "the frames in the app's library, named:"
      named "$apk" "$out/$name-logcat.txt"
      # (what led there: the app's own lines, its activity's starts)
      echo "the app's own lines and its activity's starts:"
      grep -E " uirelays *:|START u0.*$pkg|Displayed $pkg|Relaunch|$pkg.*(died|has died)" \
        "$out/$name-logcat.txt" | grep -v "monkey" | tail -30
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

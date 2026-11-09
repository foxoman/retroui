#!/bin/sh
# Runs the Android driver on a fake Android on a Linux computer. Android's
# headers come from the sysroot retroapk carries (tools/android), or from
# an NDK: NDK_INCLUDE=.../sysroot/usr/include
set -e
here=$(cd "$(dirname "$0")" && pwd)
work=${TMPDIR:-/tmp}/retro-android-mock
mkdir -p "$work/include"
if [ -n "$NDK_INCLUDE" ]; then
  inc=$NDK_INCLUDE
else
  mkdir -p "$work/sysroot"
  tar xzf "$here/../../tools/android/sysroot.tar.gz" -C "$work/sysroot" usr/include
  inc=$work/sysroot/usr/include
fi
cp -r "$inc/android" "$work/include/"
cp "$inc/jni.h" "$work/include/"
cat > "$work/include/mockdefs.h" <<'EOF'
#define __INTRODUCED_IN(x)
#define __INTRODUCED_IN_32(x)
#define __INTRODUCED_IN_64(x)
#define __DEPRECATED_IN(x, ...)
#define __REMOVED_IN(x, ...)
#define __ANDROID_API__ 34
#define __ANDROID_API_FUTURE__ 10000
#define __ANDROID_MIN_SDK_VERSION__ 24
#define __BIONIC_AVAILABILITY_GUARD(x) 1
#define __attribute_pure__
EOF
# (the driver links libandroid and liblog: empty ones here, the fake
# Android has their functions)
mkdir -p "$work/stubs"
ar rc "$work/stubs/libandroid.a"
ar rc "$work/stubs/liblog.a"
nim c --hints:off --cc:clang --noMain -d:retroAndroidMock --passL:"-L$work/stubs" \
  --path:"$here/../../src" --nimcache:"$work/cache" \
  --passC:"-D_GNU_SOURCE -include $work/include/mockdefs.h -I$work/include" \
  -o:"$work/app" "$here/app.nim"
# (the fake Android's process ends as Android's does, with _exit(0) in the
# last activity's end: passed only when it said so)
RETRO_GPU=0 "$work/app" 2>&1 | tee "$work/out.txt"
grep -q "android mock tests passed" "$work/out.txt"

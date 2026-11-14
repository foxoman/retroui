#!/bin/sh
# What the systems workflow runs in Android's emulator: the live check
# (tests/live/android.sh), the 3D view on Android's GPU against the CPU
# (tests/gpu3d/gpu3dcheck.nim, its results in live/gpu3d; "no GPU here"
# is not a failure), then every app opened and driven
# (tests/android/apps.sh). Ends with 1 when one of them failed.
set -u
sh tests/live/android.sh; live=$?
gpu=0
if [ -f build/gpu3dcheck.apk ]; then
  sh tests/live/android.sh build/gpu3dcheck.apk org.retro.gpu3dcheck live/gpu3d; gpu=$?
fi
sh tests/android/apps.sh build/apps/list.txt; apps=$?
[ $live -eq 0 ] && [ $gpu -eq 0 ] && [ $apps -eq 0 ]

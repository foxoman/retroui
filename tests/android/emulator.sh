#!/bin/sh
# What the systems workflow runs in Android's emulator: the live check
# (tests/live/android.sh), then every app opened and driven
# (tests/android/apps.sh). Ends with 1 when either failed.
set -u
sh tests/live/android.sh; live=$?
sh tests/android/apps.sh build/apps/list.txt; apps=$?
[ $live -eq 0 ] && [ $apps -eq 0 ]

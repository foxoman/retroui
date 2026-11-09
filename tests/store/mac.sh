#!/bin/sh
# The macOS bundle made and signed in Nim (ad hoc), checked by macOS
# itself: codesign's strict check of the program and its sealed resources,
# and the program run from the bundle. Run from the repository on a Mac.
set -e
nim c -d:release --hints:off -o:build/retrokit src/retrokit.nim
nim c -d:release --hints:off -o:build/storehello tests/store/storehello.nim
mkdir -p build/store-files/sub
echo "a file" > "build/store-files/sub/a note.txt"
build/retrokit mac build/storehello --name:"Store Hello" --id:org.retro.storehello \
  --version:1.0 --files:build/store-files -o:build/store-mac
app="build/store-mac/Store Hello.app"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dvv "$app" 2>&1 | grep -E "Identifier|Signature|Sealed Resources"
"$app/Contents/MacOS/Store Hello"
# from the zip, as a downloaded app is opened
rm -rf build/store-unzipped && mkdir -p build/store-unzipped
ditto -x -k "build/store-mac/Store Hello.zip" build/store-unzipped
codesign --verify --deep --strict --verbose=2 "build/store-unzipped/Store Hello.app"
"build/store-unzipped/Store Hello.app/Contents/MacOS/Store Hello"
# built from the source here, for Apple silicon and Intel at once
build/retrokit mac tests/store/storehello.nim --universal --name:"Store Hello 2" -o:build/store-mac2
lipo -info "build/store-mac2/Store Hello 2.app/Contents/MacOS/Store Hello 2"
codesign --verify --deep --strict --verbose=2 "build/store-mac2/Store Hello 2.app"
"build/store-mac2/Store Hello 2.app/Contents/MacOS/Store Hello 2"
echo "store packages: ok"

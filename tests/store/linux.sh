#!/bin/sh
# The store packages, checked with the tools of others where they are:
# osslsigncode (Authenticode, MSIX), jarsigner and bundletool (App
# Bundles), rcodesign (macOS signatures). Run from the repository.
set -e
mkdir -p build
if [ ! -f build/bundletool.jar ]; then
  curl -sSfL -o build/bundletool.jar \
    https://github.com/google/bundletool/releases/download/1.17.2/bundletool-all-1.17.2.jar
fi
if [ ! -x build/rcodesign ]; then
  curl -sSfL -o build/rcodesign.tgz \
    "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F0.29.0/apple-codesign-0.29.0-x86_64-unknown-linux-musl.tar.gz"
  tar xzf build/rcodesign.tgz -C build
  cp build/apple-codesign-0.29.0-x86_64-unknown-linux-musl/rcodesign build/rcodesign
fi
export RETRO_BUNDLETOOL="$PWD/build/bundletool.jar" RETRO_RCODESIGN="$PWD/build/rcodesign"
command -v osslsigncode >/dev/null || echo "(osslsigncode is not here: its checks are skipped)"
nim c -r --hints:off tests/test_store.nim
nim c -r --hints:off tests/test_apk.nim
echo "store packages: ok"

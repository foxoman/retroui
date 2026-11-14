#!/usr/bin/env sh
# Retro DNS builds, for Termux (or any Linux/macOS with Nim and retroui).
# Run it from anywhere: it works in examples/retrodns, the app is ../retrodns.nim.
#
#   sh build.sh apk       build/RetroDNS.apk, to install and try (debug key)
#   sh build.sh install   the same, then opens Android's installer
#   sh build.sh key       makes your Google Play upload key in keys/ (once)
#   sh build.sh aab       build/RetroDNS.aab for Google Play (upload key)
#   sh build.sh dex       compiles glue/java into glue/classes.dex again
#   sh build.sh desktop   runs it in a window (Windows, macOS, Linux, Termux:X11)
#
# apk and aab: retroapk puts the VPN in (--java:glue: glue/classes.dex and
# glue/manifest.txt). Raise CODE (and VERSION) for every upload to Google
# Play: VERSION is also what the app's About box shows.
set -e
cd "$(dirname "$0")"

NAME="Retro DNS"
ID="net.foxoman.retrodns"
VERSION="1.2"
CODE="4"
# Play needs 36 for new apps since 31 Aug 2026. x86_64 too (Chromebooks)
# when lld is there: pkg install lld, then ABIS="arm64-v8a,x86_64".
TARGET="36"
ABIS="${ABIS:-arm64-v8a}"
PERMS="--permission:INTERNET --permission:POST_NOTIFICATIONS"
# smaller code (-Os rather than -O3), and the version for the About box
NIMOPTS="--nim:--opt:size --nim:-d:retrodnsVersion=$VERSION"
RETROAPK="nim c -r -d:release --hints:off ../../src/retroapk.nim"
command -v retroapk >/dev/null && RETROAPK="retroapk"

mkdir -p build

dex_ready() {
  # (the repository's dex, made again when the Java changed since and javac
  # is here; without a JDK the repository's is used)
  if [ ! -f glue/classes.dex ]; then
    sh glue/build-dex.sh
  elif command -v javac >/dev/null && [ -n "$(find glue/java -name '*.java' -newer glue/classes.dex)" ]; then
    sh glue/build-dex.sh
  fi
}

case "$1" in
  apk|install)
    dex_ready
    $RETROAPK ../retrodns.nim --name:"$NAME" --id:$ID --version:$VERSION --code:$CODE \
      --icon:icon.png --target-sdk:$TARGET --abi:$ABIS --java:glue $PERMS $NIMOPTS \
      -o:build/RetroDNS.apk
    if [ "$1" = install ]; then
      if command -v termux-open >/dev/null; then
        termux-open --view --content-type application/vnd.android.package-archive build/RetroDNS.apk
        echo "Confirm the installation on the screen."
      else
        adb install -r build/RetroDNS.apk
      fi
    fi
    ;;
  key)
    mkdir -p keys
    if [ -f keys/upload.pem ]; then echo "keys/upload.pem is there already: keep it"; exit 1; fi
    openssl req -x509 -newkey rsa:2048 -nodes -keyout keys/upload.pem -out keys/upload.crt \
      -days 9125 -subj "/CN=Sultan Al Isaiee/O=foxoman"
    openssl x509 -in keys/upload.crt -outform DER -out keys/upload.der
    echo "Made keys/upload.pem and keys/upload.der. Copy keys/ somewhere safe: every"
    echo "update to Google Play must be signed with this same key."
    ;;
  aab)
    if [ ! -f keys/upload.pem ]; then echo "No upload key yet: sh build.sh key"; exit 1; fi
    dex_ready
    $RETROAPK ../retrodns.nim --aab --name:"$NAME" --id:$ID --version:$VERSION --code:$CODE \
      --icon:icon.png --target-sdk:$TARGET --abi:$ABIS --java:glue $PERMS $NIMOPTS \
      --key:keys/upload.pem --cert:keys/upload.der -o:build/RetroDNS.aab
    ;;
  dex)
    sh glue/build-dex.sh
    ;;
  desktop)
    nim c -r -d:release --opt:size -d:retrodnsVersion=$VERSION -o:build/retrodns ../retrodns.nim
    ;;
  *)
    sed -n '2,14p' "$0"
    ;;
esac

#!/bin/sh
# A macOS program as an .app, zipped -- its icon, name, version and id:
#
#   sh tools/macapp.sh build/mac/retrofiles "Retro Files" 3.3.2 icon.png org.retro.files build/mac/RetroFiles-macOS.zip
#
# makes <Name>.app next to the zip (Contents/MacOS/<program>,
# Contents/Resources/icon.icns from the PNG, Contents/Info.plist), signs it
# ad hoc (codesign -s -: enough to run on Apple silicon; Gatekeeper still
# asks the first time, as for any app from the web that is not notarized)
# and zips it with ditto. Needs sips, iconutil and ditto: run it on a Mac.
#
# Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net
set -e
[ $# -eq 6 ] || { echo "usage: $0 program \"Name\" version icon.png id out.zip"; exit 2; }
bin=$1 name=$2 version=$3 icon=$4 id=$5 out=$6
exe=$(basename "$bin")
dir=$(dirname "$out")
app="$dir/$name.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$exe"
chmod +x "$app/Contents/MacOS/$exe"

# the icon: every size an .icns holds, from the PNG
set_=$(mktemp -d)/icon.iconset
mkdir -p "$set_"
for s in 16 32 128 256 512; do
  sips -z $s $s "$icon" --out "$set_/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$icon" --out "$set_/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$set_" -o "$app/Contents/Resources/icon.icns"
rm -rf "$(dirname "$set_")"

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$exe</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIconFile</key><string>icon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>10.15</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCameraUsageDescription</key><string>$name uses the camera when you ask it to.</string>
  <key>NSMicrophoneUsageDescription</key><string>$name records sound when you ask it to.</string>
  <key>NSHumanReadableCopyright</key><string>Sultan Al Isaiee @foxoman -- www.foxoman.net</string>
</dict>
</plist>
EOF

codesign --force --deep -s - "$app"
rm -f "$out"
ditto -c -k --keepParent "$app" "$out"
echo "$out"

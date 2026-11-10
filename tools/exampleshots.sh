#!/bin/sh
# The pictures of examples/README.md that no other page has: each example
# built, started in a home of its own on a screen of its own (Xvfb), its
# window saved once it is up (ImageMagick's import). The others' pictures
# are the README's own (docs/*.png).
#
#   sh tools/exampleshots.sh                 hello charts native gallery hrbook magazine sevenguis
#   sh tools/exampleshots.sh hello charts    these
#
# 7GUIs is driven to its spreadsheet first (RETRO_DRIVE, `retrokit drive`).
#
# Needs Xvfb, xdotool and ImageMagick (Debian: xvfb xdotool imagemagick).
set -eu
cd "$(dirname "$0")/.."
apps=${*:-hello charts native gallery hrbook magazine sevenguis}
out=docs/examples
mkdir -p "$out" build/shots
case " $apps " in
  *" sevenguis "*) nim c -d:release --hints:off -o:build/shots/retrokit src/retrokit.nim ;;
esac
for app in $apps; do
  echo "== $app"
  home=$(mktemp -d)
  export HOME="$home" XDG_CONFIG_HOME="$home/.config" XDG_DATA_HOME="$home/.local/share" \
         XDG_CACHE_HOME="$home/.cache" RETRO_FRAME=classic   # (the 3.1 frame: no window manager here)
  case $app in
    magazine)
      # (it writes three pages and a PDF: the pages side by side)
      nim c -r -d:release --hints:off -o:build/shots/magazine examples/magazine.nim \
        "$home/mag" > build/shots/magazine.txt 2>&1
      convert "$home/mag/Retro-04-page1.png" "$home/mag/Retro-04-page2.png" \
        "$home/mag/Retro-04-page3.png" -resize x700 +append -bordercolor white -border 12 \
        "$out/magazine.png"
      rm -rf "$home"
      continue ;;
    hrbook)
      # (its demo book, PIN 246810: invented people)
      nim c -r -d:release --hints:off -o:build/shots/hrbook_demo tests/hrbook_demo.nim \
        > build/shots/hrbook_demo.txt 2>&1 ;;
  esac
  nim c -d:release --hints:off -o:"build/shots/$app" "examples/$app.nim" > "build/shots/$app.txt" 2>&1
  xvfb-run -a -s "-screen 0 1280x860x24" sh -c '
    if [ "$2" = sevenguis ]; then RETRO_DRIVE=7131 "$1" > /dev/null 2>&1 &
    else "$1" > /dev/null 2>&1 &
    fi
    pid=$!
    sleep 6
    w=$(xdotool search --onlyvisible --pid $pid 2>/dev/null | head -1)
    [ -n "$w" ] || w=$(xdotool search --onlyvisible --name . 2>/dev/null | tail -1)
    if [ "$2" = hrbook ]; then
      # (the PIN, then the book opens)
      xdotool type --delay 60 246810; xdotool key Return; sleep 3
    fi
    if [ "$2" = sevenguis ]; then
      # (its last task, the spreadsheet: driven there by the tab'"'"'s name)
      build/shots/retrokit drive 7131 click Cells --role tab > /dev/null
      build/shots/retrokit drive 7131 wait --frames 3 > /dev/null
    fi
    import -window "$w" "$3"
    kill $pid 2>/dev/null || true' sh "build/shots/$app" "$app" "$out/$app.png"
  rm -rf "$home"
  ls -l "$out/$app.png"
done

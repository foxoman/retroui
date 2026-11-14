#!/bin/sh
# The pictures of examples/README.md that no other page has: each example
# built, started in a home of its own on a screen of its own (Xvfb), its
# window saved once it is up (ImageMagick's import). The others' pictures
# are the README's own (docs/*.png).
#
#   sh tools/exampleshots.sh                 hello charts native gallery gallery-forms hrbook magazine sevenguis navigator retrodns podcast grow
#   sh tools/exampleshots.sh hello charts    these
#
# 7GUIs is driven to its spreadsheet first (RETRO_DRIVE, `retrokit drive`);
# Retro Podcast follows a feed file of its own and plays an episode;
# gallery-forms is the Gallery's Forms & Code page; Grow's two pages side
# by side (the plan, then its result with the bars risen).
#
# Needs Xvfb, xdotool and ImageMagick (Debian: xvfb xdotool imagemagick);
# Retro Navigator's picture, WebKitGTK too (libwebkit2gtk-4.1-0).
set -eu
cd "$(dirname "$0")/.."
apps=${*:-hello charts native gallery gallery-forms hrbook magazine sevenguis navigator retrodns podcast grow}
out=docs/examples
mkdir -p "$out" build/shots
case " $apps " in
  *" sevenguis "*|*" podcast "*|*" grow "*) nim c -d:release --hints:off -o:build/shots/retrokit src/retrokit.nim ;;
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
    podcast)
      # (a show of its own: a feed file, a picture, three short sounds)
      python3 - "$home" "$(pwd)/examples/assets/podcast-icon-512.png" <<'PY'
import sys, wave, struct, math
home, art = sys.argv[1], sys.argv[2]
items = ""
for i, (t, d, len_) in enumerate([("Windows 3.1 at thirty-four", "Mon, 09 Nov 2026 08:00:00 GMT", "1:02:03"),
                                   ("Immediate mode, explained", "Mon, 02 Nov 2026 08:00:00 GMT", "42:07"),
                                   ("Pixel fonts and why they last", "Mon, 26 Oct 2026 08:00:00 GMT", "38:40"),
                                   ("Nim for people who ship", "Mon, 19 Oct 2026 08:00:00 GMT", "51:12")]):
    f = "%s/ep%d.wav" % (home, i)
    w = wave.open(f, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(8000)
    w.writeframes(b"".join(struct.pack("<h", int(3000 * math.sin(n * 0.3))) for n in range(8000 * 20))); w.close()
    items += ('<item><title>%s</title><pubDate>%s</pubDate><enclosure url="%s" type="audio/wav" length="1"/>'
              '<itunes:duration>%s</itunes:duration><description>Show notes of %s.</description></item>\n') % (t, d, f, len_, t)
open(home + "/retro-talk.xml", "w").write(
    '<?xml version="1.0"?><rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">'
    '<channel><title>Retro Talk</title><itunes:author>Retro Nim UI</itunes:author>'
    '<itunes:image href="file://%s"/>%s</channel></rss>' % (art, items))
PY
      # (a sound server with a silent output: the episode plays in real time)
      if command -v pulseaudio > /dev/null; then
        XDG_RUNTIME_DIR="$home" pulseaudio -D --exit-idle-time=-1 -n --load=module-null-sink \
          --load="module-native-protocol-unix socket=$home/pulse.sock auth-anonymous=1" 2> /dev/null || true
        export PULSE_SERVER="unix:$home/pulse.sock"
      fi
      ;;
  esac
  src=$app
  [ "$app" = gallery-forms ] && src=gallery
  nim c -d:release --hints:off -o:"build/shots/$src" "examples/$src.nim" > "build/shots/$src.txt" 2>&1
  xvfb-run -a -s "-screen 0 1280x860x24" sh -c '
    if [ "$2" = sevenguis ] || [ "$2" = podcast ] || [ "$2" = grow ]; then RETRO_DRIVE=7131 "$1" > /dev/null 2>&1 &
    elif [ "$2" = gallery-forms ]; then GALLERY_TAB=18 "$1" > /dev/null 2>&1 &
    else "$1" > /dev/null 2>&1 &
    fi
    pid=$!
    sleep 6
    w=$(xdotool search --onlyvisible --pid $pid 2>/dev/null | head -1)
    [ -n "$w" ] || w=$(xdotool search --onlyvisible --name . 2>/dev/null | tail -1)
    # (the web engine starts, then draws its page)
    if [ "$2" = navigator ]; then sleep 8; fi
    if [ "$2" = hrbook ]; then
      # (the PIN, then the book opens)
      xdotool type --delay 60 246810; xdotool key Return; sleep 3
    fi
    if [ "$2" = sevenguis ]; then
      # (its last task, the spreadsheet: driven there by the tab'"'"'s name)
      build/shots/retrokit drive 7131 click Cells --role tab > /dev/null
      build/shots/retrokit drive 7131 wait --frames 3 > /dev/null
    fi
    if [ "$2" = podcast ]; then
      # (the show followed, its second episode queued, the first playing at 1.25x)
      build/shots/retrokit drive 7131 key ctrl+n > /dev/null
      build/shots/retrokit drive 7131 type "$HOME/retro-talk.xml" > /dev/null
      build/shots/retrokit drive 7131 key Enter > /dev/null
      build/shots/retrokit drive 7131 wait "Immediate mode, explained" --timeout 5000 > /dev/null
      build/shots/retrokit drive 7131 click "Immediate mode, explained" > /dev/null
      build/shots/retrokit drive 7131 click Queue --role button > /dev/null
      build/shots/retrokit drive 7131 click "Windows 3.1 at thirty-four" > /dev/null
      build/shots/retrokit drive 7131 click Play --role button --nth 1 > /dev/null
      sleep 4
    fi
    if [ "$2" = grow ]; then
      # (the plan, then its result once the bars have risen)
      import -window "$w" "$3.plan.png"
      build/shots/retrokit drive 7131 click "See my plan" --role button > /dev/null
      sleep 4
      import -window "$w" "$3.result.png"
      convert "$3.plan.png" "$3.result.png" +append -bordercolor white -border 12 "$3"
      rm -f "$3.plan.png" "$3.result.png"
    else
      import -window "$w" "$3"
    fi
    kill $pid 2>/dev/null || true' sh "build/shots/$src" "$app" "$out/$app.png"
  if [ "$app" = podcast ]; then
    pkill -f "pulse.sock" 2> /dev/null || true
    unset PULSE_SERVER
  fi
  rm -rf "$home"
  ls -l "$out/$app.png"
done

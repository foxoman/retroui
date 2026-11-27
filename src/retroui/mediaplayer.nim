## The player `videoView` draws in the window, the system's own on each:
## GStreamer on Linux, BSD and Termux (`mediagst`), Media Foundation's
## engine on Windows (`mediamf`), AVFoundation's AVPlayer on macOS and iOS
## (`mediaav`). Each plays the sound itself and hands the kit the pictures,
## which the kit draws -- under its menus and dialogs, scaled, as any of its
## drawing. Files, and web addresses (http, https; HLS where the system
## plays it). An Android app's videos are the system's VideoView over the
## widget (`retroui/media`), and nothing here is used.
##
## .. code-block:: nim
##   if playerAvailable():
##     let p = openPlayer("intro.mp4", video = true)
##     p.play()
##     # each frame:
##     if p.poll(): drawBitmap(r, p.frame)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/strutils
when not (defined(wasm) or defined(windows)):
  import uirelays/target

when defined(wasm):
  import gfx
  include mediaweb
elif defined(windows):
  import gfx
  include mediamf
elif (defined(macosx) or defined(ios)) and not androidApp:
  import gfx
  include mediaav
else:
  import mediagst

  type MediaPlayer* = GstPlayer
    ## A file or an address playing (GStreamer here).

  proc playerAvailable*(): bool = gstAvailable()
    ## The system's player is there: GStreamer here.

  proc openPlayer*(path: string; video: bool; audioSink = ""): MediaPlayer =
    ## `path` (a file or a web address) ready to play, paused at its start;
    ## nil when the system cannot play it. `audioSink` "fakesink": no sound.
    gstOpen(path, video, audioSink)

  proc openPlayer*(path: string; video: bool; audioSink: string; equalizer: bool): MediaPlayer =
    ## `openPlayer`, a sound with an equalizer (`setEqualizer`) where the system has one.
    gstOpen(path, video, audioSink, equalizer)

  proc playerEqualizer*(): bool = gstEqualizerAvailable()
    ## The system's player has an equalizer (`setEqualizer`): GStreamer's equalizer-10bands here.

  export mediagst.close, mediagst.play, mediagst.pause, mediagst.playing,
         mediagst.positionMs, mediagst.durationMs, mediagst.seekMs, mediagst.setVolume, mediagst.setRate,
         mediagst.showFirstPicture, mediagst.poll, mediagst.setEqualizer

template noEqualizer() =
  proc openPlayer*(path: string; video: bool; audioSink: string; equalizer: bool): MediaPlayer =
    ## `openPlayer` (no equalizer here).
    openPlayer(path, video, audioSink)
  proc setEqualizer*(p: MediaPlayer; gains: openArray[float]) = discard
    ## (no equalizer here)
  proc playerEqualizer*(): bool = false
    ## (no equalizer here)

when defined(wasm) or defined(windows): noEqualizer()
elif (defined(macosx) or defined(ios)) and not androidApp: noEqualizer()

proc isStream*(path: string): bool =
  ## `path` is a web address a player opens itself (http, https, rtsp).
  let l = path.toLowerAscii
  l.startsWith("http://") or l.startsWith("https://") or l.startsWith("rtsp://")

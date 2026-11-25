## Retro Music -- Spotify and YouTube in one player, through their own services: search, your
## playlists and liked songs, what plays where. Spotify plays in your own Spotify apps and
## speakers (Spotify Connect, Premium) and this is their remote and their screen; YouTube's
## music videos play in YouTube's own embedded player; lyrics come from LrcLib, timed. A tab
## bar and pages on a phone, the pages beside a list on a computer; the Glass look, or any.
##
## Spotify: make an app at developer.spotify.com (Redirect URI http://127.0.0.1) and give
## Retro Music its Client ID (Settings), then Sign In. YouTube: a key of Google Cloud's with
## the YouTube Data API v3 on.
##
##   nim c -r -d:release examples/music.nim           (Windows, macOS, Linux)
##   nimble appapk with RETRO_APP=music                (Android)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net

import retroui, retroui/parallel
import music/screens

const MusicIconPng = staticRead("assets/music-icon.png")

proc main() =
  setThreadCount(2)
  loadSettings()
  appNavBars = true
  uiLook = lookGlass
  ui.theme = GlassLight
  openApp("Retro Music", 980, 680, id = AppKey, icon = MusicIconPng, look = AppKey, version = "1.0")
  while beginFrame():
    if stoppedFrame():
      endFrame()
      continue
    captionBar()
    musicView()
    endFrame()
    appFrameDone()
  closeApp()

main()

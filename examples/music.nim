## Retro Music -- Spotify and YouTube in one player, through their own services: search, your
## playlists and liked songs, what plays where. Spotify plays in your own Spotify apps and
## speakers (Spotify Connect, Premium) and this is their remote and their screen; your YouTube
## Music -- your playlists and the songs you like, signed in with Google -- plays in the app,
## in YouTube's own player (on a phone on Now Playing, on a tablet under the sections; on a
## computer without a web view it opens in YouTube Music); lyrics come from LrcLib, timed. A tab
## bar and pages on a phone; on a tablet or a computer the sections in a list down the left, the
## page beside it. It starts in the Gloss look (Settings > Appearance changes it).
##
## Settings > Spotify and Settings > YouTube walk you through connecting them, step by step, with
## buttons to the right pages: Spotify, an app of your own at developer.spotify.com (Redirect
## URI http://127.0.0.1/) whose Client ID you paste, then Sign In; YouTube, a Google Cloud
## project with the YouTube Data API v3 on, yourself a test user and a Desktop app client whose
## Client ID and secret you paste, then Sign In with Google (or a key alone, for search).
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
  webPageBase = AppOrigin & "/"   # (YouTube's player: the app's address, as YouTube asks)
  uiLook = lookGloss
  ui.theme = GlossLight
  # (the look kept under a name of this version's: Gloss once, then your own choice)
  openApp("Retro Music", 980, 680, id = AppKey, icon = MusicIconPng, look = AppKey & "-1.1",
          version = MusicVersion)
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

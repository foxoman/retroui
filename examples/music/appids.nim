## The Google client Retro Music signs in with, so that your YouTube playlists and the songs you
## like are one tap away -- Sign In with Google, your browser, done -- with no Google Cloud project
## of your own.
##
## A client ID names the app, not you (every desktop program carries one), and Google says a
## desktop client's "secret" is not kept secret either. Give them when building -- CI takes them
## from its secrets --; Retro Mail's are taken when Music's are not given:
##
##   RETRO_MUSIC_GOOGLE_ID=... RETRO_MUSIC_GOOGLE_SECRET=... nimble music
##
## Its Google Cloud project needs the YouTube Data API v3 turned on, once. Empty: Settings >
## YouTube Music shows the way to a client of your own.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net

import std/os

proc pick(envs: openArray[string]): string {.compileTime.} =
  for e in envs:
    let v = getEnv(e)
    if v.len > 0: return v
  ""

const
  builtinGoogleId* = pick(["RETRO_MUSIC_GOOGLE_ID", "RETRO_MAIL_GOOGLE_ID"])
    ## Retro Music's Google client, "Desktop app" ("" when this build has none)
  builtinGoogleSecret* = pick(["RETRO_MUSIC_GOOGLE_SECRET", "RETRO_MAIL_GOOGLE_SECRET"])
    ## ... its secret

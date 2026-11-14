## Retro Podcast's library: the shows followed, where each episode was left,
## the downloads and the queue -- kept as JSON in the app's data folder.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, json, jsonutils, tables, strutils, hashes, times]
import retroui
import retroui/[feeds, http]
export feeds, http

type
  Show* = object
    ## A podcast followed: its feed read last.
    url*, title*, author*, image*, description*, link*: string
    episodes*: seq[Episode]
    refreshed*: int64          ## when its feed was read (Unix seconds)
  Heard* = object
    ## What became of an episode.
    posMs*: int                ## where it was left
    played*: bool              ## heard to the end (or marked)
    file*: string              ## its downloaded copy ("": none)
  Library* = object
    shows*: seq[Show]
    heard*: Table[string, Heard]   ## by the episode's sound address
    queue*: seq[string]            ## the sound addresses to play next, in order
    nowPlaying*: string            ## the sound address playing (or paused)
    speed*: float                  ## 0.5 .. 3
    skipBack*, skipAhead*: int     ## seconds
    tray*: bool                    ## an icon in the tray with the player's buttons
    proxy*: string                 ## (web pages: put before a feed's address -- CORS)
    checkAtStart*: bool            ## the shows' feeds read again when the app starts
    autoDownload*: bool            ## a show's new episodes downloaded when they come
    directory*: int                ## where Find asks: 0 Apple's, 1 fyyd
    started*: bool                 ## (the settings above were set once: a new library's
                                   ## defaults are not taken again)

proc folder*(): string = dataDir("RetroPodcast")
proc downloadsFolder*(): string = folder() / "episodes"
proc artFolder*(): string = folder() / "art"

proc newLibrary*(): Library =
  Library(speed: 1.0, skipBack: 15, skipAhead: 30, checkAtStart: true, started: true)

proc load*(): Library =
  ## The library saved last (a new one the first time).
  result = newLibrary()
  try:
    let j = parseJson(readFile(folder() / "library.json"))
    result.fromJson(j, Joptions(allowMissingKeys: true, allowExtraKeys: true))
    if result.speed <= 0: result.speed = 1.0
    if result.skipBack <= 0: result.skipBack = 15
    if result.skipAhead <= 0: result.skipAhead = 30
    if not result.started:                  # (a library of 1.0.0: the new settings' defaults)
      result.checkAtStart = true
      result.started = true
  except CatchableError:
    discard

proc save*(lib: Library) =
  try:
    createDir(folder())
    let tmp = folder() / "library.json.part"
    writeFile(tmp, $lib.toJson)
    moveFile(tmp, folder() / "library.json")
  except CatchableError:
    discard

proc find*(lib: Library; audio: string): tuple[show, ep: int] =
  ## Where the episode with this sound address is (-1, -1: nowhere).
  for i, s in lib.shows:
    for j, e in s.episodes:
      if e.audio == audio: return (i, j)
  (-1, -1)

proc showOf*(lib: Library; url: string): int =
  for i, s in lib.shows:
    if s.url == url: return i
  -1

proc fileFor*(audio, mime: string): string =
  ## Where an episode's download goes (named by its address).
  var ext = audio.split('?')[0].splitFile.ext.toLowerAscii
  if ext.len notin 2 .. 5:
    ext = if "mp4" in mime or "m4a" in mime: ".m4a" elif "ogg" in mime: ".ogg" else: ".mp3"
  downloadsFolder() / ($uint32(hash(audio)) & ext)

proc artFor*(url: string): string =
  artFolder() / ($uint32(hash(url)) & ".img")

proc source*(lib: Library; audio: string): string =
  ## What the player plays: the downloaded copy when there is one.
  let f = lib.heard.getOrDefault(audio).file
  if f.len > 0 and fileExists(f): f else: audio

proc dateText*(t: int64): string =
  if t <= 0: "" else: fromUnix(t).local.format("d MMM yyyy")

proc merge*(old: Show; f: Feed): Show =
  ## A show read again: its new feed, the order the feed gives.
  result = old
  result.url = if f.url.len > 0: f.url else: old.url
  result.title = if f.title.len > 0: f.title else: old.title
  result.author = f.author
  result.image = f.image
  result.description = f.description
  result.link = f.link
  var eps: seq[Episode]
  for e in f.episodes:
    if e.audio.len > 0: eps.add e          # (only what can be played)
  result.episodes = eps
  result.refreshed = getTime().toUnix

proc readFeedAt*(url, proxy: string): Feed {.gcsafe.} =
  ## The feed at `url` (a web address, or a file), read now (on a worker).
  if url.startsWith("http://") or url.startsWith("https://"):
    let r = httpRequest("GET", proxy & url, {"User-Agent": "RetroPodcast/1.0"}, timeoutSec = 30)
    if not r.ok:
      raise newException(IOError, if r.status == 0: r.error else: "the server answered " & $r.status)
    parseFeed(r.body, url)
  else:
    parseFeed(readFile(url), url)

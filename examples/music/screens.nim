## Retro Music's screens: Home, Search, Library, the free sources (YouTube Music, the radio,
## Audius, the Internet Archive), your own server, Spotify, Now Playing and Settings -- on a phone
## pages one over another, the places in a menu that slides out from the left; on a tablet or a
## computer the same places down the left, the page beside them; in every look (Gloss its own).
## Our own player's Now Playing is the music players' of 2012: the cover as wide as the screen,
## the lyrics over it, the queue on its back. YouTube plays in the app, in YouTube's own player:
## on a phone on Now Playing, on a tablet under the places (it plays while it is on the screen,
## as YouTube's rules ask). Settings walks you through Spotify and, for your own YouTube
## playlists, a Google account, step by step. (examples/music.nim opens the window;
## tests/test_music.nim and tests/test_musicsources.nim draw them.)

import std/[json, strutils, tables, times, os, uri]
import retroui
import retroui/[oauth, secrets, jobs, http, jpeg, imaging, webp]
import retroui/uirelays/input
import api, local, online, sources, tv, appids
export local, online, tv

const
  AppKey* = "RetroMusic"
  MusicVersion* = "2.1.3"
  AppOrigin* = "https://net.foxoman.retromusic"
    ## (the app's address for YouTube's player: its identifier, as YouTube asks)

type
  ReqKind = enum
    rkPlayback, rkDevices, rkSearch, rkVideos, rkPlaylists, rkLiked, rkRecent, rkListTracks,
    rkCommand, rkLyrics, rkCover, rkRefresh, rkKeyTest, rkYtPlaylists, rkYtLiked, rkYtList
  Pending = object
    kind: ReqKind
    key: string                          # (a cover's address, a command's name)
    job: Job[HttpResponse]

var ytAsked = (lists: false, liked: false)   # (YouTube's library asked for, once)

var
  # accounts and settings (kept with retroui/secrets)
  clientId* = ""
  youtubeKey* = ""
  tokens*: OAuthTokens
  signIn: OAuthFlow
  refreshing: Job[OAuthTokens]
  googleId* = ""                         # your Google Cloud project's Desktop app client
  googleSecret* = ""                     # (its "secret": Google's desktop clients need it; not secret)
  gTokens*: OAuthTokens                  # signed in with Google: YouTube's library
  gSignIn: OAuthFlow
  gRefreshing: Job[OAuthTokens]
  # what the services said
  playback*: Playback
  playbackAt = 0                         # (ui.now when it was read: the progress goes on from it)
  devices*: seq[Device]
  results*: seq[Track]
  videos*: seq[Track]
  playlists*: seq[Playlist]
  liked*, recent*, listTracks*: seq[Track]
  listName = ""
  saved*: seq[Track]                     # YouTube videos you saved (kept in a file)
  ytPlaylists*: seq[Playlist]            # your YouTube (Music) playlists
  ytLiked*: seq[Track]                   # the songs you like on YouTube
  ytListId = ""                          # (the YouTube playlist open in Library)
  # YouTube's player in the app: what it plays and what comes next
  ytQueue*: seq[Track]
  ytAt* = 0
  ytPage* = ""                           # (its page, made once: the songs after are loaded in it)
  ytReady = false
  ytMadeAt = 0                           # (when its page was made: not ready in 15 seconds, said)
  ytWant = ""                            # (a song asked before the player was ready)
  ytPlaying* = false
  ytTimeMs*, ytLengthMs* = 0
  ytShown = false                        # (the player drawn the frame before: away, it pauses)
  lyricLines*: seq[LyricLine]
  lyricText* = ""
  lyricsFor = ""
  covers: Table[string, Bitmap]
  coverAsked: Table[string, bool]
  pending: seq[Pending]
  lastPoll = 0.0
  # the screens
  tab* = 0                               # Home, Search, Library, Settings, the free sources, ... (Sections)
  onlinePage* = ""                       # a free source's page ("" its first; "yt:list", "audius:user"...)
  menuOpen* = false                      # (a phone's side menu out)
  ytAdvanced = false                     # (Settings > YouTube Music: the Google account's steps shown)
  nowOpen* = false                       # Now Playing over them
  youtubeNow*: Track                     # the video playing in YouTube's player
  query* = ""
  searchSource* = 0                      # what Search searches (SearchNames)
  searchedFor = ""
  queryChanged = 0
  libraryPage* = ""                      # "" the list; "liked", "list", "ytliked", "ytlist", "local:..."
  settingsPage* = ""                     # "" the list; "spotify", "youtube", "appearance"
  youtubeOk* = 0                         # the key tried: 1 it works, -1 it does not, 0 not tried
  keyTesting = false
  idOpen, keyOpen, devicesOpen, aboutOpen*, lookOpen*, gIdOpen, gSecretOpen = false
  idText, keyText, gIdText, gSecretText = ""
  message* = ""

proc spotifyProvider(): OAuthProvider =
  OAuthProvider(name: "Spotify", authUrl: SpotifyAuth, tokenUrl: SpotifyToken, clientId: clientId,
                scopes: @SpotifyScopes, redirectHost: "127.0.0.1")

proc signedIn*(): bool = tokens.accessToken.len > 0

proc ownGoogle(): bool = googleId.len > 0 and googleSecret.len > 0
  ## (a Google client of your own given: it signs in, not the app's)

proc builtinGoogle*(): bool = builtinGoogleId.len > 0 and builtinGoogleSecret.len > 0
  ## This build has the app's own Google client: Sign In with Google, nothing to set up.

proc googleProviderOf(): OAuthProvider =
  if ownGoogle(): googleProvider(googleId, googleSecret, YouTubeScopes)
  else: googleProvider(builtinGoogleId, builtinGoogleSecret, YouTubeScopes)

proc googleIn*(): bool = gTokens.accessToken.len > 0
  ## Signed in with Google: YouTube's library, and its search without a key.

proc savedPath(): string = dataDir(AppKey) / "saved.json"

proc loadSettings*() =
  ## The client id, the key, the sign-in and the saved videos, as they were kept.
  clientId = loadSecret(AppKey, "spotify-client")
  youtubeKey = loadSecret(AppKey, "youtube-key")
  googleId = loadSecret(AppKey, "google-client")
  googleSecret = loadSecret(AppKey, "google-secret")
  let t = loadSecret(AppKey, "spotify-tokens")
  if t.len > 0:
    try: tokens = toTokens(parseJson(t)) except CatchableError: discard
  let g = loadSecret(AppKey, "google-tokens")
  if g.len > 0:
    try: gTokens = toTokens(parseJson(g)) except CatchableError: discard
  loadLibrary()
  loadOnline()
  loadTv()
  try:
    for it in parseJson(readFile(savedPath())).getElems:
      saved.add Track(source: srcYouTube, id: it{"id"}.getStr, uri: it{"uri"}.getStr,
                      title: it{"title"}.getStr, artist: it{"artist"}.getStr, cover: it{"cover"}.getStr)
  except CatchableError: discard

proc keepTokens() =
  discard saveSecret(AppKey, "spotify-tokens", $(%tokens))

proc keepGoogle() =
  discard saveSecret(AppKey, "google-tokens", if googleIn(): $(%gTokens) else: "")

proc keepSaved() =
  var a = newJArray()
  for t in saved: a.add %*{"id": t.id, "uri": t.uri, "title": t.title, "artist": t.artist, "cover": t.cover}
  try:
    createDir(dataDir(AppKey))
    writeFile(savedPath(), $a)
  except CatchableError: discard

# ---- requests ------------------------------------------------------------------------------------

proc ask(kind: ReqKind; url: string; meth = "GET"; body = ""; key = "") =
  ## (a request of Spotify's, with the account's token; YouTube's and LrcLib's without)
  var hs: seq[(string, string)]
  if url.startsWith(SpotifyApi): hs.add ("Authorization", "Bearer " & tokens.accessToken)
  elif url.startsWith(YouTubeApi) and googleIn() and "&key=" notin url:
    hs.add ("Authorization", "Bearer " & gTokens.accessToken)
  if body.len > 0: hs.add ("Content-Type", "application/json")
  pending.add Pending(kind: kind, key: key,
                      job: if onlineFetch != nil and meth == "GET": onlineFetch(url)
                           else: fetch(url, meth, hs, body, timeoutSec = 30))

proc spotify(kind: ReqKind; path: string; meth = "GET"; body = ""; key = "") =
  if not signedIn() or refreshing != nil: return
  ask(kind, SpotifyApi & path, meth, body, key)

proc command*(path: string; meth = "PUT"; body = "") =
  ## A Spotify Connect command (play, pause, next...); what plays is read again after it.
  spotify(rkCommand, path, meth, body, key = path)

proc youtube(kind: ReqKind; url: string; key = "") =
  ## (a request of YouTube's library: signed in with Google)
  if not googleIn() or gRefreshing != nil: return
  ask(kind, url, key = key)

proc ytSend(m: string) =
  ## (to YouTube's player in the app: "load:ID", "play", "pause", "seek:SECONDS")
  if ytPage.len > 0: webPost("youtube", m)

proc ytPlay*(at: int) =
  ## The queue's `at`-th song in YouTube's player (the player made the first time).
  if at < 0 or at >= ytQueue.len: return
  ytAt = at
  let t = ytQueue[at]
  youtubeNow = t
  ytTimeMs = 0
  ytLengthMs = t.durationMs
  ytPlaying = true
  if ytPage.len == 0:
    ytPage = playerPage(t.id, AppOrigin)
    ytReady = false
    ytMadeAt = ui.now
  elif ytReady: ytSend("load:" & t.id)
  else: ytWant = t.id

proc playTracks*(list: openArray[Track]; at: int) =
  ## Plays `list` from its `at`-th track: Spotify's on your device, a video in YouTube's player.
  if at < 0 or at >= list.len: return
  let t = list[at]
  if localActive:
    pauseLocal()
    localActive = false
  if t.source == srcYouTube:
    # (the YouTube songs of the list, from this one on: its queue in YouTube's player)
    ytQueue.setLen(0)
    var k = 0
    for i, x in list:
      if x.source == srcYouTube:
        if i == at: k = ytQueue.len
        ytQueue.add x
    ytPlay(k)
    if isCompact(): nowOpen = true
    return
  var uris: seq[string]
  for x in list:
    if x.source == srcSpotify: uris.add x.uri
  let path = if devices.len > 0 and not playback.device.active and devices[0].id.len > 0:
               "/me/player/play?device_id=" & devices[0].id
             else: "/me/player/play"
  command(path, "PUT", playBody(uris, offset = at))
  youtubeNow = Track()
  playback.track = t
  playback.playing = true
  playback.progressMs = 0
  playbackAt = ui.now

proc cover*(url: string): Bitmap =
  ## A cover's picture, asked for once (nil until it came).
  if url.len == 0: return nil
  if url in covers: return covers[url]
  if url notin coverAsked and pending.len < 24:
    coverAsked[url] = true
    ask(rkCover, url, key = url)
  nil

proc keyProblem*(status: int; body: string): string =
  ## (what a YouTube key's failed answer means, in a sentence)
  var reason = ""
  try:
    let j = parseJson(body)
    for e in j{"error", "errors"}.getElems: reason = e{"reason"}.getStr
    if reason.len == 0: reason = j{"error", "status"}.getStr
  except CatchableError: discard
  if status == 0: "no answer -- is the phone online?"
  elif reason in ["keyInvalid", "badRequest"] or status == 400: "the key isn't right -- paste it again"
  elif reason in ["accessNotConfigured", "SERVICE_DISABLED"]:
    "the YouTube Data API v3 isn't on in the key's project (step 2)"
  elif reason in ["quotaExceeded", "dailyLimitExceeded"]: "today's searches are used up -- tomorrow again"
  elif status == 403: "the key isn't allowed to search YouTube -- check its restrictions (step 3)"
  else: $status

proc testYoutubeKey*() =
  ## Tries the key with a search of one video.
  if youtubeKey.len == 0: return
  keyTesting = true
  youtubeOk = 0
  ask(rkKeyTest, youtubeSearchUrl("music", youtubeKey, limit = 1))

proc pollServices*() =
  ## Every frame: the answers that came; what plays read every 3 seconds; the token renewed.
  if refreshing != nil and refreshing.ended:
    if refreshing.done and refreshing.value.accessToken.len > 0:
      tokens = refreshing.value
      keepTokens()
    else: message = "Spotify: sign in again (Settings)"
    refreshing = nil
  if signedIn() and refreshing == nil and tokens.expiresAt > 0 and tokens.expiresAt - epochTime() < 60:
    let p = spotifyProvider()
    let t = tokens
    refreshing = job(proc (): OAuthTokens {.gcsafe.} =
      var x = t
      if refresh(p, x).len == 0: x else: OAuthTokens())
  if gRefreshing != nil and gRefreshing.ended:
    if gRefreshing.done and gRefreshing.value.accessToken.len > 0:
      gTokens = gRefreshing.value
      keepGoogle()
    else: message = "YouTube: sign in with Google again (Settings)"
    gRefreshing = nil
  if googleIn() and gRefreshing == nil and gTokens.expiresAt > 0 and gTokens.expiresAt - epochTime() < 60 and
     gTokens.refreshToken.len > 0:
    let p = googleProviderOf()
    let t = gTokens
    gRefreshing = job(proc (): OAuthTokens {.gcsafe.} =
      var x = t
      if refresh(p, x).len == 0: x else: OAuthTokens())
  if gSignIn != nil:
    case gSignIn.state
    of osDone:
      gTokens = gSignIn.tokens
      keepGoogle()
      gSignIn = nil
      message = "Signed in with Google: your YouTube Music is in Library"
      youtube(rkYtPlaylists, myPlaylistsUrl())
    of osFailed:
      message = "Google: " & gSignIn.error
      gSignIn = nil
    of osCancelled: gSignIn = nil
    of osWaiting: wakeIn(300)
  if signIn != nil:
    case signIn.state
    of osDone:
      tokens = signIn.tokens
      keepTokens()
      signIn = nil
      message = "Signed in to Spotify"
      spotify(rkPlaylists, "/me/playlists?limit=50")
      spotify(rkRecent, "/me/player/recently-played?limit=20")
    of osFailed:
      message = "Spotify: " & signIn.error
      signIn = nil
    of osCancelled: signIn = nil
    of osWaiting: wakeIn(300)
  if signedIn() and epochTime() - lastPoll > 3.0 and not ui.paused:
    lastPoll = epochTime()
    spotify(rkPlayback, "/me/player")
    spotify(rkDevices, "/me/player/devices")
  var i = 0
  while i < pending.len:
    let p = pending[i]
    if not p.job.ended:
      inc i
      continue
    pending.delete(i)
    let r = if p.job.done: p.job.value else: HttpResponse(error: p.job.error)
    if r.status == 401 and p.kind in {rkYtPlaylists, rkYtLiked, rkYtList}:
      message = "YouTube: sign in with Google again (Settings)"
    elif r.status == 401 and signedIn(): message = "Spotify: sign in again (Settings)"
    case p.kind
    of rkPlayback:
      if r.status in [200, 204]:
        playback = spotifyPlayback(r.body)
        playbackAt = ui.now
    of rkDevices:
      if r.ok: devices = spotifyDevices(r.body)
    of rkSearch: (if r.ok: results = spotifyTracks(r.body) else: message = "Search: " & $r.status & " " & r.error)
    of rkVideos:
      if r.ok:
        videos = youtubeVideos(r.body)
        ytFoundSongs = videos               # (YouTube Music's search, asked this way: no server answered)
      else: message = "YouTube: " & keyProblem(r.status, r.body)
    of rkYtPlaylists:
      if r.ok:
        if p.key.len == 0: ytPlaylists.setLen(0)
        ytPlaylists.add youtubePlaylists(r.body)
        let more = nextPage(r.body)
        if more.len > 0 and ytPlaylists.len < 500: youtube(rkYtPlaylists, myPlaylistsUrl(more), key = more)
      elif r.status != 401: message = "YouTube: " & keyProblem(r.status, r.body)
    of rkYtLiked:
      if r.ok:
        if p.key.len == 0: ytLiked.setLen(0)
        ytLiked.add youtubeVideos(r.body)
        let more = nextPage(r.body)
        if more.len > 0 and ytLiked.len < 1000: youtube(rkYtLiked, likedVideosUrl(more), key = more)
    of rkYtList:
      # (a playlist's songs, page after page, while it is the one open)
      let (id, page) = (p.key.split('\t')[0], if '\t' in p.key: p.key.split('\t')[1] else: "")
      if r.ok and id == ytListId:
        if page.len == 0: listTracks.setLen(0)
        listTracks.add youtubeVideos(r.body)
        let more = nextPage(r.body)
        if more.len > 0 and listTracks.len < 1000: youtube(rkYtList, playlistItemsUrl(id, more), key = id & "\t" & more)
    of rkPlaylists: (if r.ok: playlists = spotifyPlaylists(r.body))
    of rkLiked: (if r.ok: liked = spotifyTracks(r.body))
    of rkRecent: (if r.ok: recent = spotifyTracks(r.body))
    of rkListTracks: (if r.ok: listTracks = spotifyTracks(r.body))
    of rkCommand:
      if r.status == 404: message = "Spotify: no device playing -- open Spotify on one, or pick a device"
      elif r.status == 403: message = "Spotify: playing needs Premium"
      elif r.status >= 400: message = "Spotify: " & $r.status
      lastPoll = epochTime() - 2.5                # (what plays, read again soon)
    of rkLyrics:
      if p.key == lyricsFor:
        let (synced, plain) = lyricsOf(r.body)
        lyricLines = synced
        lyricText = if r.ok: plain else: ""
    of rkCover:
      if r.ok:
        # (a cover: JPEG mostly; a station's icon PNG; some thumbnails WebP)
        let b = try:
                  if r.body.startsWith("\x89PNG"): decodePng(r.body)
                  elif r.body.len > 12 and r.body[0 .. 3] == "RIFF" and r.body[8 .. 11] == "WEBP": decodeWebp(r.body)
                  else: decodeJpeg(r.body)
                except CatchableError: nil
        if b != nil: covers[p.key] = b
    of rkKeyTest:
      keyTesting = false
      youtubeOk = if r.ok: 1 else: -1
      message = if r.ok: "YouTube: connected" else: "YouTube: " & keyProblem(r.status, r.body)
    of rkRefresh: discard
    ui.redraw = true
  if pending.len > 0: wakeIn(100)

proc progressNow*(): int =
  ## How far the track is now (read, and gone on since).
  if playback.playing: min(playback.track.durationMs, playback.progressMs + (ui.now - playbackAt))
  else: playback.progressMs

proc wantLyrics(t: Track) =
  let k = t.source.`$` & t.id
  if k == lyricsFor or t.title.len == 0: return
  lyricsFor = k
  lyricLines.setLen(0)
  lyricText = ""
  ask(rkLyrics, lyricsUrl(t), key = k)

# ---- parts of the screens ------------------------------------------------------------------------

proc trackRows(list: openArray[Track]; key: string) =
  ## (tracks in rows: the cover, the title, the artist, the length; a tap plays from there)
  tableGroup(""):
    for i, t in list:
      let h = tableRow(t.title, if t.durationMs > 0: clock(t.durationMs) else: "", taNone,
                       subtitle = t.artist, picture = cover(t.cover), key = key & $i & t.id)
      if h.clicked: playTracks(list, i)

proc nowTrack*(): Track =
  if localActive: localTrack()
  elif youtubeNow.id.len > 0: youtubeNow
  else: playback.track

stopOthers = proc () =
  ## (a song of ours starts: YouTube's player and Spotify pause -- one player at a time)
  if ytPlaying:
    ytSend("pause")
    ytPlaying = false
  youtubeNow = Track()
  if playback.playing and signedIn():
    command("/me/player/pause")
    playback.playing = false

const
  Sections* = ["Home", "Search", "Library", "Settings", "YouTube Music", "Radio", "Audius",
               "Internet Archive", "My Server", "Spotify", "TV"]
  SecYouTube* = 4
  SecRadio* = 5
  SecAudius* = 6
  SecArchive* = 7
  SecServer* = 8
  SecSpotify* = 9
  SecTV* = 10

proc goSection*(i: int) =
  ## (one of the places, at its first page; the side menu in again)
  tab = i
  nowOpen = false
  libraryPage = ""
  settingsPage = ""
  onlinePage = ""
  tvPage = ""
  menuOpen = false

proc goLocal(page: string) =
  ## (one of the library's own pages)
  tab = 2
  nowOpen = false
  libraryPage = page

proc goSettings(page: string) = settingsPage = page

proc goOnline(page: string) =
  ## (a free source's page -- from Search, Home or Library too: in its own place)
  let s = if page.startsWith("yt:"): SecYouTube elif page.startsWith("radio:"): SecRadio
          elif page.startsWith("audius:"): SecAudius elif page.startsWith("archive:"): SecArchive
          elif page.startsWith("server:"): SecServer else: tab
  if s != tab: goSection(s)
  nowOpen = false
  onlinePage = page

proc onlineParent(page: string): string =
  if page == "audius:list": "audius:user" else: ""

const InAppYouTube = defined(android) or defined(ios) or defined(macosx)
  ## (where YouTube's player plays in the app: the system's web view, its page from the app's
  ## address; elsewhere YouTube Music opens in the browser)

var ytShownNow = false
var ytHidPaused = false

proc ytNews(m: string) =
  ## (what YouTube's player said: ready, playing or paused, where it is, an end, an error)
  let parts = m.split(':')
  case parts[0]
  of "ready":
    ytReady = true
    if ytWant.len > 0:
      ytSend("load:" & ytWant)
      ytWant = ""
  of "state":
    let st = (try: parseInt(parts[1]) except ValueError: -1)
    if st == 1: ytPlaying = true
    elif st == 2: ytPlaying = false
    elif st == 0:
      # (the song ended: the next one of the queue)
      if ytAt + 1 < ytQueue.len: ytPlay(ytAt + 1) else: ytPlaying = false
  of "time":
    if parts.len >= 3:
      ytTimeMs = (try: parseInt(parts[1]) except ValueError: ytTimeMs)
      let l = (try: parseInt(parts[2]) except ValueError: 0)
      if l > 0: ytLengthMs = l
  of "error":
    let code = (try: parseInt(parts[1]) except ValueError: 0)
    let name = "\"" & youtubeNow.title & "\""
    message = if code in [101, 150]: name & " plays only on YouTube (its owner's choice)"
              else: "YouTube could not play " & name & " (error " & $code & ")"
    if ytAt + 1 < ytQueue.len: ytPlay(ytAt + 1) else: ytPlaying = false
  else: discard
  ui.redraw = true

proc youtubePlayer(h: int) =
  ## YouTube's own player, `h` high, in the app (on a computer without a web view: YouTube Music
  ## in the browser). It plays while it is on the screen.
  if ytPage.len == 0: return
  when InAppYouTube:
    let ev = webView(ytPage, height = max(h, dp(200)), key = "youtube", engine = weSystem)
    ytShownNow = true
    for m in ev.messages: ytNews(m)
    if not ytReady and ytMadeAt > 0 and ui.now - ytMadeAt > 15_000 and message.len == 0:
      # (its page never said it was ready: YouTube's script did not come, or the page did not run)
      message = "YouTube's player did not start -- is the phone online?"
    elif not ytReady and ytMadeAt > 0: wakeIn(1000)
    if ytHidPaused:
      ytHidPaused = false
      ytSend("play")
    if ytPlaying or ytWant.len > 0: wakeIn(1000)
  else:
    if button("Open in YouTube &Music", isDefault = true): openUrl(youtubeNow.uri)
    label("YouTube's own player plays it: in the browser on a computer, in the app on a phone or a tablet.",
          color = ui.theme.gray)

proc youtubeControls() =
  ## (YouTube's song: how far, the previous, play or pause, the next; Save, Open in YouTube Music)
  let t = youtubeNow
  if ytLengthMs > 0:
    var at = ytTimeMs div 1000
    if slider(at, 0, max(1, ytLengthMs div 1000), ticks = 0):
      ytSend("seek:" & $at)
      ytTimeMs = at * 1000
    row:
      label(clock(ytTimeMs), color = ui.theme.gray)
      spring()
      label("-" & clock(ytLengthMs - ytTimeMs), color = ui.theme.gray)
  row:
    spring()
    if button("Previous", nfStepBackward, blIconOnly, enabled = ytAt > 0 or ytTimeMs > 3000):
      if ytTimeMs > 3000 or ytAt == 0:
        ytSend("seek:0")
        ytTimeMs = 0
      else: ytPlay(ytAt - 1)
    if ytPlaying:
      if button("Pause", nfPause, blIconOnly):
        ytSend("pause")
        ytPlaying = false
    elif button("Play", nfPlay, blIconOnly):
      ytSend("play")
      ytPlaying = true
    if button("Next", nfStepForward, blIconOnly, enabled = ytAt + 1 < ytQueue.len): ytPlay(ytAt + 1)
    spring()
  row:
    let isSaved = block:
      var f = false
      for s in saved:
        if s.id == t.id: f = true
      f
    if button(if isSaved: "Saved" else: "&Save", enabled = not isSaved):
      saved.add t
      keepSaved()
    if button("Open in YouTube &Music"): openUrl(t.uri)
  if ytQueue.len > 1:
    label("Song " & $(ytAt + 1) & " of " & $ytQueue.len, color = ui.theme.gray)

proc playerControls() =
  let t = nowTrack()
  if t.source == srcLocal:
    localControls()
    return
  if t.source == srcYouTube:
    youtubeControls()
    return
  if t.durationMs > 0:
    var at = progressNow() div 1000
    if slider(at, 0, max(1, t.durationMs div 1000), ticks = 0):
      command("/me/player/seek?position_ms=" & $(at * 1000))
      playback.progressMs = at * 1000
      playbackAt = ui.now
    row:
      label(clock(progressNow()), color = ui.theme.gray)
      spring()
      label("-" & clock(t.durationMs - progressNow()), color = ui.theme.gray)
  row:
    spring()
    let st = style(size = 1.6)
    if button("Previous", nfStepBackward, blIconOnly): command("/me/player/previous", "POST")
    if playback.playing:
      if button("Pause", nfPause, blIconOnly):
        command("/me/player/pause")
        playback.playing = false
        playback.progressMs = progressNow()
    elif button("Play", nfPlay, blIconOnly):
      command("/me/player/play")
      playback.playing = true
      playbackAt = ui.now
    if button("Next", nfStepForward, blIconOnly): command("/me/player/next", "POST")
    discard st
    spring()
  tableGroup(""):
    if tableRow("Playing on", if playback.device.name.len > 0: playback.device.name else: "Pick a device",
                taChevron, glyph = nfVolumeUp).clicked:
      devicesOpen = true

proc lyricsPart() =
  let t = nowTrack()
  if t.title.len == 0: return
  wantLyrics(t)
  if lyricLines.len > 0:
    let at = if t.source == srcSpotify: lineAt(lyricLines, progressNow())
             elif t.source == srcYouTube and ytTimeMs > 0: lineAt(lyricLines, ytTimeMs)
             elif t.source == srcLocal and localPos > 0: lineAt(lyricLines, localPos)
             else: -1
    tableGroup("Lyrics", "From LrcLib, timed."):
      discard
    for i, l in lyricLines:
      if l.text.len == 0: continue
      if i == at: label(l.text, bold = true, color = accentColor())
      else: label(l.text, color = if at >= 0 and i < at: ui.theme.gray else: ui.theme.text)
    if at >= 0: wakeIn(250)
  elif lyricText.len > 0:
    tableGroup("Lyrics", "From LrcLib."):
      discard
    paragraph(lyricText)

proc nowPlaying*() =
  ## The track playing: its cover, its name, the controls, where it plays, its lyrics.
  let t = nowTrack()
  if t.title.len == 0:
    emptyState(nfMusic, "Nothing plays", detail = "Play a song of yours (Library), search for one, or " &
                                                  "open Spotify on a device.")
    return
  if t.source == srcLocal:
    localNowPlaying(goLocal)
    lyricsPart()
    return
  if t.source == srcYouTube and isCompact() and ytPage.len > 0:
    # (a phone: the song's video here, in YouTube's player -- on a tablet it is under the sections)
    youtubePlayer(max(dp(200), cellRoom() * 9 div 16))
    heading(t.title, 2)
    label(t.artist, color = ui.theme.gray)
    playerControls()
    lyricsPart()
    return
  let side = min(cellRoom(), dp(300))
  let big = cover(t.cover)
  let r = place(side, side)
  if big != nil:
    masked(r, float(dp(8))):
      drawBitmap(r, big)
  else:
    # (no cover: artwork made from it, as for a song of yours)
    masked(r, float(dp(8))):
      drawArtwork(r, Song(title: t.title, artist: t.artist, album: t.album), words = false)
  heading(t.title, 2)
  label(t.artist & (if t.album.len > 0: " -- " & t.album else: ""), color = ui.theme.gray)
  playerControls()
  lyricsPart()

proc openPlaylist(p: Playlist; youtubeList: bool) =
  ## (a playlist's songs in Library: YouTube's or Spotify's)
  tab = 2
  nowOpen = false
  listName = p.name
  listTracks.setLen(0)
  if youtubeList:
    ytListId = p.id
    youtube(rkYtList, playlistItemsUrl(p.id), key = p.id)
  else:
    ytListId = ""
    spotify(rkListTracks, "/playlists/" & p.id & "/tracks?limit=50")
  libraryPage = "list"

proc homeScreen() =
  let t = nowTrack()
  if t.title.len > 0:
    tableGroup("Now Playing"):
      let pic = if t.source == srcLocal: coverOf(t.id) else: cover(t.cover)
      let on = if t.source == srcLocal: localPlaying else: playback.playing
      if tableRow(t.title, if on: "playing" else: "", taChevron, subtitle = t.artist, picture = pic).clicked:
        nowOpen = true
  if songs.len > 0:
    # (your own: the albums that came lately, on a shelf; what you played last)
    var cards: seq[ShelfCard]
    var keys: seq[string]
    var firsts: seq[int]
    for i in smartSongs(skAdded) & smartSongs(skPlayed):
      let k = albumKey(songs[i])
      if k in keys or keys.len >= 12: continue
      keys.add k
      firsts.add i
      cards.add (songs[i].album, songs[i].artist, coverOf(songs[i]), nfMusic)
    if cards.len > 0:
      label("On This Device", bold = true)
      # (an album with no cover: its artwork made from it, as on Now Playing)
      let k = cardShelf(cards, "local", art = proc (c: int; r: Rect) =
        drawArtwork(r, songs[firsts[c]], words = false))
      if k >= 0: goLocal("local:album:" & keys[k])
  elif musicAccess():
    tableGroup("", "Put songs in your Music folder, and they are here too: Library > On This Device."):
      if tableRow("Your Music", if scanningNow(): "looking..." else: "none yet", taChevron, glyph = nfMusic,
                  tint = color(250, 45, 85)).clicked: goLocal("local:songs")
  if favStations.len > 0:
    # (your stations on a shelf: a tap tunes in)
    label("Your Stations", bold = true)
    var cards: seq[ShelfCard]
    for st in favStations: cards.add (st.name, stationLine(st), cover(st.favicon), nfWifi)
    let k = cardShelf(cards, "stations")
    if k >= 0: playRemote(stationSongs(favStations), k)
  if ytKept.len > 0:
    label("Your YouTube Music", bold = true)
    var cards: seq[ShelfCard]
    for sh in ytKept: cards.add ((if sh.name.len > 0: sh.name else: "Playlist"), sh.owner, cover(sh.cover), nfPlay)
    let k = cardShelf(cards, "ytkept")
    if k >= 0:
      openYtList(ytKept[k].id, ytKept[k].name)
      goOnline("yt:list")
  tableGroup("Free to Listen", "No account, nothing to set up. Lyrics come from LrcLib by themselves."):
    for (sec, g, tint, detail) in [(SecYouTube, nfPlay, color(226, 30, 30), "songs, albums, playlists"),
                                   (SecRadio, nfWifi, color(240, 140, 20), "stations of the world"),
                                   (SecAudius, nfBolt, color(204, 31, 228), "its artists' own"),
                                   (SecArchive, nfArchive, color(110, 110, 118), "concerts, old records")]:
      if tableRow(Sections[sec], "", taChevron, subtitle = detail, glyph = g, tint = tint,
                  key = "home" & $sec).clicked: goSection(sec)
  if not server.ready or not signedIn():
    tableGroup("Your Accounts", "Your own music server (Navidrome, Airsonic, Gonic...), or Spotify " &
                                "on your Spotify apps and speakers (Premium)."):
      if not server.ready and tableRow("My Server", "Add", taChevron, glyph = nfServer,
                                       tint = color(30, 160, 90)).clicked: goSection(SecServer)
      if not signedIn() and tableRow("Spotify", "Connect", taChevron, glyph = nfMusic,
                                     tint = color(30, 185, 84)).clicked: goSection(SecSpotify)
  # (your playlists, YouTube Music's and Spotify's, on a shelf the finger slides)
  if googleIn() and not ytAsked.lists:
    ytAsked.lists = true
    youtube(rkYtPlaylists, myPlaylistsUrl())
  if ytPlaylists.len > 0 or playlists.len > 0:
    label("Your Playlists", bold = true)
    var cards: seq[ShelfCard]
    for p in ytPlaylists: cards.add (p.name, "YouTube Music", cover(p.cover), nfPlay)
    for p in playlists: cards.add (p.name, "Spotify", cover(p.cover), nfMusic)
    let k = cardShelf(cards, "playlists")
    if k >= 0 and k < ytPlaylists.len: openPlaylist(ytPlaylists[k], true)
    elif k >= ytPlaylists.len: openPlaylist(playlists[k - ytPlaylists.len], false)
  if recent.len > 0:
    label("Played Lately", bold = true)
    trackRows(recent, "recent")
  if saved.len > 0:
    label("Saved from YouTube", bold = true)
    trackRows(saved, "saved")

proc searchField() =
  ## (Search's bar: right under the navigation bar, from one side of the page to the other)
  if searchBar(query, "Songs, artists"): queryChanged = ui.now

const SearchNames* = ["YouTube Music", "This Device", "Radio", "Audius", "Archive", "My Server", "Spotify"]
  ## (what Search searches, `searchSource`: This Device with songs on it, My Server with one
  ## added, Spotify signed in)

template searchedIn(words: var string; body: untyped) =
  ## (a free source's page drawn for Search: its words Search's, its own search box not drawn --
  ## the page's own words as they were after)
  let own = words
  words = query
  searchOnly = true
  searchTyped = queryChanged == ui.now
  try:
    body
  finally:
    searchOnly = false
    words = own

proc searchScreen() =
  var shown: seq[int]
  for i in 0 ..< SearchNames.len:
    if (i == 1 and songs.len == 0) or (i == 5 and not server.ready) or (i == 6 and not signedIn()): continue
    shown.add i
  if searchSource notin shown: searchSource = 0
  var names: seq[string]
  var sel: seq[bool]
  for i in shown:
    names.add SearchNames[i]
    sel.add i == searchSource
  let ch = chips(names, sel)
  if ch.clicked >= 0:
    searchSource = shown[ch.clicked]
    searchedFor = ""
  let words = query.strip
  case searchSource
  of 0:
    searchedIn(ytWords):
      youtubePage("", goOnline)
  of 2:
    searchedIn(radioWords):
      radioPage("", goOnline)
  of 3:
    searchedIn(audiusWords):
      audiusPage("", goOnline)
  of 4:
    searchedIn(archiveWords):
      archivePage("", goOnline)
  of 5:
    searchedIn(serverWords):
      serverPage("", goOnline)
  of 1:
    # (your own songs: their titles, artists and albums)
    if words.len == 0:
      emptyState(nfSearch, "Search This Device", detail = "Your songs, their albums and artists.")
      return
    let w = words.toLowerAscii
    var idx: seq[int]
    for i, x in songs:
      if w in x.title.toLowerAscii or w in x.artist.toLowerAscii or w in x.album.toLowerAscii: idx.add i
      if idx.len >= 300: break
    if idx.len == 0: emptyState(nfSearch, "Nothing found")
    else: songRows(idx, "sq")
  else:
    # Spotify's (asked half a second after the typing stops, or at once on Enter)
    if words.len > 0 and words != searchedFor and (ui.now - queryChanged > 500 or keyHit(KeyEnter)):
      searchedFor = words
      spotify(rkSearch, "/search?q=" & encodeUrl(words, usePlus = false) & "&type=track&limit=20")
    elif words.len > 0 and words != searchedFor: wakeIn(520)
    if results.len == 0:
      emptyState(nfSearch, if words.len == 0: "Search Spotify" else: "Nothing found yet",
                 detail = "Spotify's songs, played on your Spotify device.")
    else: trackRows(results, "searchsp")


proc youtubeLibrary() =
  ## (Library's YouTube Music: the playlists and albums you added by their links; signed in with
  ## Google too, your own playlists and the songs you like)
  if googleIn() and not ytAsked.lists:
    ytAsked.lists = true
    youtube(rkYtPlaylists, myPlaylistsUrl())
  tableGroup("YouTube Music", if ytKept.len == 0 and not googleIn():
                                "A playlist's or an album's link from YouTube Music (Share > Copy link), " &
                                "pasted: it stays here."
                              else: ""):
    for sh in ytKept:
      if tableRow(if sh.name.len > 0: sh.name else: "Playlist", "", taChevron, subtitle = sh.owner,
                  picture = cover(sh.cover), key = "yk" & sh.id).clicked:
        openYtList(sh.id, sh.name)
        goOnline("yt:list")
    if googleIn():
      if tableRow("Liked Music", if ytLiked.len > 0: $ytLiked.len else: "", taChevron, glyph = nfHeart,
                  tint = color(226, 30, 30)).clicked:
        libraryPage = "ytliked"
        if not ytAsked.liked:
          ytAsked.liked = true
          youtube(rkYtLiked, likedVideosUrl())
      for p in ytPlaylists:
        let h = tableRow(p.name, $p.count, taChevron, subtitle = p.owner, picture = cover(p.cover), key = "yt" & p.id)
        if h.clicked: openPlaylist(p, true)
    if tableButton("Paste a Link") and pasteYtLink(): goOnline("yt:list")

proc spotifyLists() =
  ## (your Spotify: Liked Songs and your playlists)
  if playlists.len == 0 and pending.len == 0: spotify(rkPlaylists, "/me/playlists?limit=50")
  tableGroup("Spotify"):
    if tableRow("Liked Songs", "", taChevron, glyph = nfHeart).clicked: libraryPage = "liked"
    for p in playlists:
      let h = tableRow(p.name, $p.count, taChevron, subtitle = p.owner, picture = cover(p.cover), key = p.id)
      if h.clicked:
        listName = p.name
        ytListId = ""
        listTracks.setLen(0)
        spotify(rkListTracks, "/playlists/" & p.id & "/tracks?limit=50")
        libraryPage = "list"

proc libraryScreen() =
  if libraryPage.startsWith("local:"):
    localPage(libraryPage, goLocal)
    return
  case libraryPage
  of "liked":
    if liked.len == 0: spotify(rkLiked, "/me/tracks?limit=50")
    trackRows(liked, "liked")
  of "ytliked":
    if ytLiked.len == 0:
      emptyState(nfHeart, "Liked Music", detail = "The songs you like on YouTube Music come here.")
    else: trackRows(ytLiked, "ytliked")
  of "list":
    if listTracks.len == 0: emptyState(nfList, listName, detail = "Its songs are on their way.")
    else: trackRows(listTracks, "list")
  else:
    localLibraryGroup(goLocal)
    youtubeLibrary()
    if favStations.len > 0:
      tableGroup("Your Stations"):
        let favs = stationSongs(favStations)
        for n, st in favStations:
          if tableRow(st.name, if localActive and currentPath() == st.url: "playing" else: "", taNone,
                      subtitle = stationLine(st), picture = cover(st.favicon), key = "lf" & st.url).clicked:
            playRemote(favs, n)
    if signedIn(): spotifyLists()
    if saved.len > 0:
      tableGroup("Saved from YouTube"):
        for i, t in saved:
          if tableRow(t.title, "", taChevron, subtitle = t.artist, picture = cover(t.cover), key = "s" & t.id).clicked:
            playTracks(saved, i)

const
  SpotifyDashboard* = "https://developer.spotify.com/dashboard"
  SpotifyRedirect* = "http://127.0.0.1/"
  CloudProject* = "https://console.cloud.google.com/projectcreate"
  YouTubeApiPage* = "https://console.cloud.google.com/apis/library/youtube.googleapis.com"
  CloudKeys* = "https://console.cloud.google.com/apis/credentials"
  CloudAudience* = "https://console.cloud.google.com/auth/audience"
  CloudClients* = "https://console.cloud.google.com/auth/clients/create"

proc pasted(): string =
  ## (what the clipboard holds, its spaces and line ends cut off)
  getClipboardText().strip

proc note(s: string) =
  ## (a line or two of gray text in the middle of the page, as a table's footer)
  for ln in wrapLines(s, cellRoom()):
    let r = place(0, FontH + dp(1), fill = true)
    let ink = if glossLook() and lumaOfColor(ui.theme.window) >= 128: glossTone(0.30, 0.42) else: ui.theme.gray
    text(r.x + (r.w - textWidth(ln)) div 2, r.y, ln, ink)

proc spotifyGuide() =
  ## Connecting Spotify, step by step.
  tableGroup(""):
    discard tableRow("Spotify", if signedIn(): "Connected" elif clientId.len > 0: "Not signed in"
                                else: "Not connected", glyph = nfMusic, tint = color(30, 185, 84))
  tableGroup("1. Make an app of your own",
             "Sign in with your Spotify account, press Create app, and give it any name and " &
             "description."):
    if tableButton("Open Spotify for Developers"): openUrl(SpotifyDashboard)
  tableGroup("2. Give it this Redirect URI",
             "In the app's form, under Redirect URIs, add this one as it is (with its slash) and " &
             "press Add; tick Web API; Save."):
    discard tableRow("Redirect URI", SpotifyRedirect)
    if tableButton("Copy the Redirect URI"):
      putClipboardText(SpotifyRedirect)
      message = "Copied: " & SpotifyRedirect
  tableGroup("3. Its Client ID, here",
             "On your app's page, Settings: copy its Client ID, then paste it here. (Its Client " &
             "Secret isn't needed: keep it to yourself.)"):
    if tableRow("Client ID", if clientId.len > 0: clientId[0 ..< min(10, clientId.len)] & "..." else: "none",
                taChevron).clicked:
      idText = clientId
      idOpen = true
    if tableButton("Paste the Client ID"):
      let t = pasted()
      if t.len == 32 and t.allCharsInSet(HexDigits):
        clientId = t
        discard saveSecret(AppKey, "spotify-client", clientId)
        message = "Client ID saved -- now sign in (step 4)"
      else: message = "That isn't a Client ID (32 letters and digits): copy it again"
  tableGroup("4. Sign in",
             "Your browser opens Spotify's page: allow Retro Music. Music plays in your Spotify " &
             "app or speaker (Premium): open Spotify on one, and Retro Music is its remote. " &
             "Another person's account: add their email under the app's User Management first."):
    if signedIn():
      if tableButton("Sign Out", destructive = true):
        tokens = OAuthTokens()
        keepTokens()
        playlists.setLen(0)
        recent.setLen(0)
        liked.setLen(0)
    elif signIn != nil:
      discard tableRow("Signing in...", "in your browser")
      if tableButton("Cancel"): signIn.cancel()
    elif tableButton("Sign In to Spotify", enabled = clientId.len > 0):
      signIn = beginSignIn(spotifyProvider())

proc youtubeState(): string =
  ## (YouTube's row: how it is connected)
  if googleIn(): "Signed in"
  elif youtubeKey.len == 0: "Not connected"
  elif keyTesting: "Trying..."
  elif youtubeOk == 1: "Key works"
  elif youtubeOk == -1: "Key not working"
  else: "Key saved"

proc youtubeGuide() =
  ## YouTube Music: nothing to set up -- a Piped server of your own if you have one; and, for
  ## your own YouTube playlists and the songs you like, a Google account, step by step (or a key
  ## for YouTube's search when Piped's servers don't answer).
  tableGroup("", "YouTube Music plays here with nothing to set up: its songs, albums and playlists " &
                 "come through Piped's public servers (Invidious' when they don't answer), and play in " &
                 "YouTube's own player. A playlist's link pasted (Library) stays."):
    discard tableRow("YouTube Music", "Ready", glyph = nfPlay, tint = color(226, 30, 30))
  tableGroup("Piped Server", "Leave it as it is for the public ones; your own Piped server answers faster."):
    if tableRow("Server", if pipedOwn.len > 0: pipedOwn else: "The public ones", taChevron).clicked: askPiped()
  if builtinGoogle():
    # (this build has the app's own Google client: one tap, your browser, done)
    tableGroup("Your Google Account",
               "Your own YouTube playlists and the songs you like, in Library. Your browser opens " &
               "Google's page: sign in, and allow Retro Music to see your YouTube account."):
      discard tableRow("Google", youtubeState(), glyph = nfUser, tint = color(66, 133, 244))
      if googleIn():
        if tableButton("Sign Out", destructive = true):
          gTokens = OAuthTokens()
          keepGoogle()
          ytPlaylists.setLen(0)
          ytLiked.setLen(0)
          ytAsked = (false, false)
      elif gSignIn != nil:
        discard tableRow("Signing in...", "in your browser")
        if tableButton("Cancel"): gSignIn.cancel()
      elif tableButton("Sign In with Google"):
        gSignIn = beginSignIn(googleProviderOf())
  tableGroup(if builtinGoogle(): "Advanced: A Google Project of Your Own" else: "Advanced: Your Google Account",
             if builtinGoogle(): "Only when you want your own Google Cloud project to sign in with, not the app's."
             else: "Only for your own YouTube playlists and the songs you like in Library: it needs a Google " &
                   "Cloud project of your own, made once (free)."):
    if not builtinGoogle(): discard tableRow("Google", youtubeState())
    if tableButton(if ytAdvanced: "Hide the Steps" else: "Show the Steps"): ytAdvanced = not ytAdvanced
  if not ytAdvanced: return
  tableGroup("1. A Google Cloud project",
             "Sign in with your Google account and make a project -- any name -- or pick one " &
             "you have."):
    if tableButton("Open Google Cloud Console"): openUrl(CloudProject)
  tableGroup("2. Turn on the YouTube Data API v3",
             "In that project, on the API's page: press Enable."):
    if tableButton("Open the YouTube Data API"): openUrl(YouTubeApiPage)
  tableGroup("3. Let yourself sign in",
             "Google Auth Platform: give the app a name and your email (Get started), choose External, " &
             "then under Audience > Test users add your own Google account."):
    if tableButton("Open Audience"): openUrl(CloudAudience)
  tableGroup("4. A Desktop app client",
             "Clients > Create client: Application type Desktop app, any name, Create. Copy its " &
             "Client ID and its Client secret (a desktop app's secret isn't secret: Google wants it)."):
    if tableButton("Open Create Client"): openUrl(CloudClients)
  tableGroup("5. Its Client ID and secret, here", ""):
    if tableRow("Client ID", if googleId.len > 12: googleId[0 ..< 12] & "..." elif googleId.len > 0: "set"
                             else: "none", taChevron).clicked:
      gIdText = googleId
      gIdOpen = true
    if tableButton("Paste the Client ID"):
      let t = pasted()
      if t.endsWith(".apps.googleusercontent.com"):
        googleId = t
        discard saveSecret(AppKey, "google-client", googleId)
        message = "Client ID saved -- now its secret"
      else: message = "That isn't a Client ID (it ends in .apps.googleusercontent.com): copy it again"
    if tableRow("Client secret", if googleSecret.len > 0: "set" else: "none", taChevron).clicked:
      gSecretText = googleSecret
      gSecretOpen = true
    if tableButton("Paste the Client Secret"):
      let t = pasted()
      if t.len >= 20 and ' ' notin t:
        googleSecret = t
        discard saveSecret(AppKey, "google-secret", googleSecret)
        message = "Client secret saved -- now sign in (step 6)"
      else: message = "That isn't a client secret: copy it again"
  tableGroup("6. Sign in with Google",
             "Your browser opens Google's page. It says Google hasn't verified the app: it is your " &
             "own -- press Continue, and allow Retro Music to see your YouTube account. Then Library " &
             "has your playlists and Liked Music. (While the app is in Testing, Google asks you to " &
             "sign in again every 7 days.)"):
    if googleIn():
      if tableButton("Sign Out", destructive = true):
        gTokens = OAuthTokens()
        keepGoogle()
        ytPlaylists.setLen(0)
        ytLiked.setLen(0)
        ytAsked = (false, false)
    elif gSignIn != nil:
      discard tableRow("Signing in...", "in your browser")
      if tableButton("Cancel"): gSignIn.cancel()
    elif tableButton("Sign In with Google", enabled = googleId.len > 0 and googleSecret.len > 0):
      gSignIn = beginSignIn(googleProviderOf())
  tableGroup("Or search only, with a key",
             "Without signing in, an API key searches YouTube: Credentials > Create credentials > API " &
             "key, then paste it. It's free -- 10,000 units a day, a search takes 100."):
    if tableButton("Open Credentials"): openUrl(CloudKeys)
    if tableRow("API Key", if youtubeKey.len > 6: youtubeKey[0 ..< 6] & "..." elif youtubeKey.len > 0: "set"
                           else: "none", taChevron).clicked:
      keyText = youtubeKey
      keyOpen = true
    if tableButton("Paste the Key"):
      let t = pasted()
      if t.len >= 30 and t.allCharsInSet(Letters + Digits + {'-', '_'}):
        youtubeKey = t
        discard saveSecret(AppKey, "youtube-key", youtubeKey)
        testYoutubeKey()
      else: message = "That isn't an API key: copy it again"
    if youtubeKey.len > 0:
      if tableButton("Try the Key", enabled = not keyTesting): testYoutubeKey()
      if tableButton("Remove the Key", destructive = true):
        youtubeKey = ""
        youtubeOk = 0
        discard saveSecret(AppKey, "youtube-key", "")

proc settingsScreen() =
  case settingsPage
  of "spotify": spotifyGuide()
  of "youtube": youtubeGuide()
  of "eq": eqPage()
  of "folders": foldersPage()
  of "appearance":
    note("The look of the controls, its colors, the sizes, the font -- kept for next time.")
    discard appearanceSettings()
  else:
    tableGroup("Sources", "YouTube Music, the radio, Audius and the Internet Archive need nothing; your " &
                          "server its address, your name and password; Spotify plays on your Spotify apps " &
                          "and speakers (Premium). Lyrics come from LrcLib by themselves."):
      if tableRow("YouTube Music", if googleIn(): "Signed in" else: "Ready", taChevron, glyph = nfPlay,
                  tint = color(226, 30, 30)).clicked:
        settingsPage = "youtube"
      if tableRow("My Server", if serverOk == 1: "Signed in" elif server.ready: "Added" else: "Add", taChevron,
                  glyph = nfServer, tint = color(30, 160, 90)).clicked:
        goSection(SecServer)
      if tableRow("Spotify", if signedIn(): "Connected" elif clientId.len > 0: "Sign in" else: "Connect",
                  taChevron, glyph = nfMusic, tint = color(30, 185, 84)).clicked:
        settingsPage = "spotify"
    soundGroup(goSettings)
    tableGroup(""):
      if tableRow("Appearance", "", taChevron, glyph = nfPalette, tint = color(150, 90, 210)).clicked:
        settingsPage = "appearance"
      if tableRow("About Retro Music", "", taChevron, glyph = nfInfo, tint = color(128, 128, 136)).clicked:
        aboutOpen = true

proc dialogs*() =
  localDialogs()
  onlineDialogs()
  if idOpen and inputBox(idOpen, "Spotify Client ID", "Your app's Client ID (developer.spotify.com):", idText) == 1:
    clientId = idText.strip
    discard saveSecret(AppKey, "spotify-client", clientId)
  if gIdOpen and inputBox(gIdOpen, "Google Client ID", "Your Desktop app client's Client ID:", gIdText) == 1:
    googleId = gIdText.strip
    discard saveSecret(AppKey, "google-client", googleId)
  if gSecretOpen and inputBox(gSecretOpen, "Google Client Secret", "Its Client secret:", gSecretText) == 1:
    googleSecret = gSecretText.strip
    discard saveSecret(AppKey, "google-secret", googleSecret)
  if keyOpen and inputBox(keyOpen, "YouTube API Key", "A YouTube Data API v3 key:", keyText) == 1:
    youtubeKey = keyText.strip
    discard saveSecret(AppKey, "youtube-key", youtubeKey)
    testYoutubeKey()
  var names: seq[string]
  for d in devices: names.add d.name & (if d.active: " (playing)" else: "")
  let pick = actionSheet(devicesOpen, "Play on", names)
  if pick >= 0 and pick < devices.len and devices[pick].id.len > 0:
    command("/me/player", "PUT", transferBody(devices[pick].id))
  if lookOpen:
    dialog(lookOpen, "Appearance", 420):
      appearanceSettings()
      if button("Close", isDefault = true): lookOpen = false
  aboutBox(aboutOpen, "Retro Music", MusicVersion,
           ["Your own music and the free music of the world in one player: the songs on this " &
            "device with their albums, artists and playlists, the equalizer and a sleep timer; " &
            "YouTube Music in YouTube's own player, with nothing to set up; radio stations, Audius, " &
            "the Internet Archive, your own music server; Spotify Connect on your devices; lyrics " &
            "from LrcLib."],
           tagline = "Your music, and the world's, in one player", glyph = pxApp)

# ---- the window ----------------------------------------------------------------------------------

proc pageTitle*(): string =
  ## The page's title, as its navigation bar shows it.
  if nowOpen: "Now Playing"
  elif tab in [2, SecSpotify] and libraryPage == "liked": "Liked Songs"
  elif tab == 2 and libraryPage == "ytliked": "Liked Music"
  elif tab in [2, SecSpotify] and libraryPage == "list": listName
  elif tab == 2 and libraryPage.startsWith("local:"): localTitle(libraryPage)
  elif tab == 3 and settingsPage == "eq": "Equalizer"
  elif tab == 3 and settingsPage == "folders": "Music Folders"
  elif tab == 3 and settingsPage == "spotify": "Spotify"
  elif tab == 3 and settingsPage == "youtube": "YouTube Music"
  elif tab == 3 and settingsPage == "appearance": "Appearance"
  elif tab == SecTV: tvTitle()
  elif tab in SecYouTube .. SecServer and onlinePage.len > 0:
    if onlinePage == "yt:list" and ytShelfName.len > 0: ytShelfName
    elif onlineTitle(onlinePage).len > 0: onlineTitle(onlinePage)
    else: Sections[tab]
  else: Sections[tab]

proc backLabel(): string =
  ## (the navigation bar's Back: where it goes)
  if nowOpen and isCompact(): "Close"
  elif tab == 2 and libraryPage.startsWith("local:") and localParent(libraryPage).len > 0:
    localTitle(localParent(libraryPage))
  elif tab in [2, SecSpotify] and libraryPage.len > 0: Sections[tab]
  elif tab == 3 and settingsPage.len > 0: "Settings"
  elif tab == SecTV: tvBack()
  elif tab in SecYouTube .. SecServer and onlinePage.len > 0:
    let p = onlineParent(onlinePage)
    if p.len > 0: onlineTitle(p)
    elif tab == SecArchive: "Archive"
    elif tab == SecYouTube: "YouTube"
    else: Sections[tab]
  else: ""

proc goBack() =
  if nowOpen and isCompact(): nowOpen = false
  elif tab == 2: libraryPage = (if libraryPage.startsWith("local:"): localParent(libraryPage) else: "")
  elif tab == SecSpotify: libraryPage = ""
  elif tab in SecYouTube .. SecServer: onlinePage = onlineParent(onlinePage)
  elif tab == SecTV: tvPage = ""
  else: settingsPage = ""

proc spotifyScreen() =
  ## Spotify: your playlists and what played lately, signed in; the way to connect it, not.
  if libraryPage.len > 0:
    libraryScreen()
    return
  if not signedIn():
    spotifyGuide()
    return
  spotifyLists()
  if recent.len > 0:
    label("Played Lately", bold = true)
    trackRows(recent, "recent")
  tableGroup(""):
    if tableRow("Playing on", if playback.device.name.len > 0: playback.device.name else: "Pick a device",
                taChevron, glyph = nfVolumeUp).clicked:
      devicesOpen = true

proc page() =
  if nowOpen:
    nowPlaying()
    return
  case tab
  of 0: homeScreen()
  of 1: searchScreen()
  of 2: libraryScreen()
  of 3: settingsScreen()
  of SecYouTube: youtubePage(onlinePage, goOnline)
  of SecRadio: radioPage(onlinePage, goOnline)
  of SecAudius: audiusPage(onlinePage, goOnline)
  of SecArchive: archivePage(onlinePage, goOnline)
  of SecServer: serverPage(onlinePage, goOnline)
  of SecTV: tvScreen()
  else: spotifyScreen()

proc ourPlayer(area: Rect) =
  ## Now Playing for the app's own player -- your songs, a station, a free source's, your
  ## server's: drawn whole, the cover as wide as the screen, the lyrics over it.
  let live = currentSong().live
  if not live: wantLyrics(nowTrack())
  let none: seq[LyricLine] = @[]
  playerScreen(area, if live: none else: lyricLines, if live: "" else: lyricText,
               proc () = nowOpen = false, goLocal)

proc ourPlayerShown(): bool =
  ## (Now Playing open on one of the app's own player's songs)
  nowOpen and localActive and currentPath().len > 0

proc miniPlayer() =
  ## (a phone's: what plays, at the foot; a tap opens it)
  let t = nowTrack()
  if t.title.len == 0 or nowOpen or keyboardUp(): return
  let h = if fingers(): dp(52) else: dp(42)
  # (the bottom-most bar also covers the system's gesture area)
  let below = if ui.bottom >= ui.h - ui.safe.bottom: ui.h - ui.bottom else: 0
  let r = rect(ui.winX, ui.bottom - h, ui.w, h)
  let face = rect(r.x, r.y, r.w, h + below)
  if glossLook(): glossBarFill(face)
  else:
    fill(face, mixColor(ui.theme.window, ui.theme.face, 0.6))
    hline(r.x, r.y, r.w, mixColor(ui.theme.window, ui.theme.text, 0.15))
  ui.bottom = r.y
  let hit = interact(idOf("miniplayer"), r, focusable = false)
  let b = if t.source == srcLocal: coverOf(t.id) else: cover(t.cover)
  let d = h - dp(10)
  if b != nil: drawBitmap(rect(r.x + dp(8), r.y + dp(5), d, d), b)
  let ink = if glossLook(): color(255, 255, 255) else: ui.theme.text
  let x = r.x + dp(16) + d
  text(x, r.y + h div 2 - FontH, ellipsize(t.title, r.w - x - dp(60), style(bold = true)), ink, true)
  text(x, r.y + h div 2, ellipsize(t.artist, r.w - x - dp(60)), if glossLook(): ink else: ui.theme.gray)
  let pr = rect(r.x + r.w - dp(48), r.y, dp(44), h)
  let ph = interact(idOf("miniplay"), pr, focusable = false)
  let g = if (t.source == srcYouTube and ytPlaying) or (t.source == srcSpotify and playback.playing) or
             (t.source == srcLocal and localPlaying): nfPause
          else: nfPlay
  let gs = style(size = 1.4)
  text(pr.x + (pr.w - textWidth(g, gs)) div 2, pr.y + (h - lineHeight(gs)) div 2, g,
       if glossLook(): ink else: accentColor(), gs)
  if ph.clicked and t.source == srcLocal: toggleLocal()
  elif ph.clicked and t.source == srcSpotify:
    if playback.playing:
      command("/me/player/pause")
      playback.playing = false
    else:
      command("/me/player/play")
      playback.playing = true
      playbackAt = ui.now
  elif hit.clicked or ph.clicked: nowOpen = true   # (YouTube: its player there, where it plays)

proc libraryLoading(): bool =
  ## (playlists, likes or what played lately on their way)
  for p in pending:
    if p.kind in {rkPlaylists, rkRecent, rkLiked, rkYtPlaylists, rkYtLiked, rkYtList, rkListTracks}: return true

proc reloadLibrary() =
  ## (pulled down: your playlists, likes and what played lately asked again)
  if signedIn():
    spotify(rkPlaylists, "/me/playlists?limit=50")
    spotify(rkRecent, "/me/player/recently-played?limit=20")
  if googleIn():
    youtube(rkYtPlaylists, myPlaylistsUrl())
    if ytAsked.liked: youtube(rkYtLiked, likedVideosUrl())
    if libraryPage == "list" and ytListId.len > 0: youtube(rkYtList, playlistItemsUrl(ytListId), key = ytListId)

proc pageBody(margin: int) =
  ## (the page under its navigation bar, in a panel; its groups `margin` in from its sides; Search's
  ## bar over it, under the navigation bar; Home, Library and Spotify pulled down: asked again)
  if tab == 1 and not nowOpen:
    let g = ui.m.gap
    ui.m.gap = 0
    space(-g)
    searchField()
    ui.m.gap = g
  beginPanel(-1, "music:" & $tab & ":" & $nowOpen & libraryPage & settingsPage & onlinePage, plain = true)
  if not nowOpen and tab in [0, 2, SecSpotify] and pullRefresh(libraryLoading()): reloadLibrary()
  if not nowOpen and tab == SecTV and pullRefresh(tvState == 1): tvState = 0     # (the list asked again)
  if margin > 0:
    let (fx, _) = layoutOrigin()
    pushFrame(rect(fx + margin, layoutY() + dp(4), layoutWidth() - 2 * margin, 0))
  page()
  if margin > 0: discard place(0, popFrame() + dp(12))
  endPanel()

const MenuParts = [("Music", @[(0, nfHome), (1, nfSearch), (2, nfList)]),
                   ("Free to Listen", @[(SecYouTube, nfPlay), (SecRadio, nfWifi), (SecAudius, nfBolt),
                                        (SecArchive, nfArchive)]),
                   ("Free to Watch", @[(SecTV, nfVideo)]),
                   ("Your Accounts", @[(SecServer, nfServer), (SecSpotify, nfMusic)]),
                   ("Options", @[(3, nfCog)])]
  ## (the places, in the side menu's sections -- as the music apps of 2012 had them)

proc menuItems() =
  ## The app's places: a phone's side menu, a tablet's column down the left. A tap on the place
  ## shown takes it to its first page.
  for (head, items) in MenuParts:
    sideMenuHeader(head)
    for (sec, g) in items:
      let detail = if sec == SecServer and serverOk == 1: "on"
                   elif sec == SecSpotify and signedIn(): "on"
                   elif sec == SecRadio and favStations.len > 0: $favStations.len
                   elif sec == SecTV and tvFavs.len > 0: $tvFavs.len
                   else: ""
      if sideMenuItem(Sections[sec], g, detail, selected = tab == sec and not nowOpen, key = "sec" & $sec):
        goSection(sec)

proc nowPlayingItem() =
  ## (what plays, in the menu: a tap opens Now Playing)
  let t = nowTrack()
  if t.title.len == 0: return
  let playing = if t.source == srcYouTube: ytPlaying elif t.source == srcLocal: localPlaying
                else: playback.playing
  sideMenuHeader("Now Playing")
  if sideMenuItem(t.title, if playing: nfPlay else: nfPause, t.artist, selected = nowOpen, key = "nowplaying"):
    nowOpen = true
    menuOpen = false

proc sideColumn(r: Rect) =
  ## A tablet's or a computer's column down the left: the places, what plays and its controls.
  sideMenuBack(r)
  pushFrame(r)
  discard navBar("Retro Music")
  beginPanel(-1, "music:sections", plain = true)
  menuItems()
  nowPlayingItem()
  let t = nowTrack()
  if t.title.len > 0:
    let (fx, _) = layoutOrigin()
    pushFrame(rect(fx + dp(8), layoutY() + dp(6), layoutWidth() - dp(16), 0))
    # (YouTube's player here, under the places: it plays on while you go through them)
    if t.source == srcYouTube and ytPage.len > 0: youtubePlayer(dp(200))
    if t.source == srcLocal: localControls()
    if t.source == srcSpotify:
      # (the controls under it, as a remote's)
      let room = cellRoom()
      let bw = (room - 2 * Gap) div 3
      let bh = if fingers(): dp(40) else: 0
      row:
        if button("Previous", nfStepBackward, blIconOnly, w = bw, h = bh): command("/me/player/previous", "POST")
        if button(if playback.playing: "Pause" else: "Play", if playback.playing: nfPause else: nfPlay,
                  blIconOnly, w = bw, h = bh, isDefault = true):
          if playback.playing:
            command("/me/player/pause")
            playback.playing = false
          else:
            command("/me/player/play")
            playback.playing = true
            playbackAt = ui.now
        if button("Next", nfStepForward, blIconOnly, w = bw, h = bh): command("/me/player/next", "POST")
    discard place(0, popFrame() + dp(12))
  endPanel()
  discard popFrame()

proc splitView() =
  ## A tablet's or a computer's: the places and what plays in a column down the left, the page
  ## beside it under its own navigation bar -- as tablets showed them then.
  let top = ui.barY
  let h = ui.bottom - top
  let x0 = ui.winX + ui.safe.left
  let w = ui.w - ui.safe.left - ui.safe.right
  let mw = min(dp(300), w * 2 div 5)
  sideColumn(rect(x0, top, mw, h))
  vline(x0 + mw, top, h, if glossLook() or lumaOfColor(ui.theme.window) < 128: color(0, 0, 0)
                         else: mixColor(ui.theme.window, ui.theme.text, 0.2))
  let right = rect(x0 + mw + 1, top, w - mw - 1, h)
  if tvOpen:
    tvPlayer(right)
    return
  if ourPlayerShown():
    ourPlayer(right)
    return
  pushFrame(right)
  if navBar(pageTitle(), back = backLabel()) == npBack: goBack()
  pageBody(dp(24))
  discard popFrame()

proc phoneView() =
  ## A phone's: one page under its navigation bar -- at a place's first page the menu button,
  ## the side menu sliding out --, what plays at the foot; our own player's Now Playing drawn
  ## whole.
  if tvOpen or ourPlayerShown():
    # (the status bar's band and the gesture area black, as the player is)
    fill(rect(ui.winX, 0, ui.w, ui.barY), color(0, 0, 0))
    fill(rect(ui.winX, ui.bottom, ui.w, ui.h - ui.bottom), color(0, 0, 0))
    if tvOpen: tvPlayer(rect(ui.winX, ui.barY, ui.w, ui.bottom - ui.barY))
    else: ourPlayer(rect(ui.winX, ui.barY, ui.w, ui.bottom - ui.barY))
  else:
    miniPlayer()
    let back = backLabel()
    let atRoot = back.len == 0
    if navBar(pageTitle(), back = back, menu = atRoot) == npBack:
      if atRoot: menuOpen = true else: goBack()
    pageBody(0)
  sideMenu(menuOpen, 280):
    beginPanel(-1, "music:menu", plain = true)
    menuItems()
    nowPlayingItem()
    endPanel()

proc musicView*() =
  ## The whole window, every frame.
  pollServices()
  pollOnline()
  pollTv()
  localFrame()
  if onlineNote.len > 0:
    message = onlineNote
    onlineNote = ""
  if ytOpened:
    # (a YouTube link pasted in its box: its playlist open)
    ytOpened = false
    goOnline("yt:list")
  ytShownNow = false
  if isCompact(): phoneView()
  else:
    if not ui.touch:
      statusbar(if message.len > 0: message elif localActive and currentPath().len > 0: currentSong().title
                elif signedIn(): "Spotify: signed in" else: "",
                if playback.device.name.len > 0: "Playing on " & playback.device.name else: "")
    splitView()
  dialogs()
  # (YouTube's player not on the screen any more: paused, as YouTube's rules ask -- it goes on
  # when it is shown again)
  if ytShown and not ytShownNow and ytPlaying:
    ytSend("pause")
    ytPlaying = false
    ytHidPaused = true
  ytShown = ytShownNow
  if message.len > 0 and (isCompact() or ui.touch):
    toast(message)
    message = ""

# ---- the free sources' ties to the app --------------------------------------------------------------

onlineCover = proc (url: string): Bitmap = cover(url)
remoteCover = proc (url: string): Bitmap = cover(url)
playYouTube = proc (list: seq[Track]; at: int) = playTracks(list, at)
ytFailed = proc (words: string): bool =
  ## (no YouTube server answered a search: YouTube's own search, signed in with Google or with a key)
  if googleIn(): ask(rkVideos, youtubeSearchUrl(words, ""))
  elif youtubeKey.len > 0: ask(rkVideos, youtubeSearchUrl(words, youtubeKey))
  else: return false
  true

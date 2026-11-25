## Retro Music's screens: Home, Search, Library, Now Playing and Settings -- a tab bar and pages on
## a phone; on a tablet or a computer the sections in a list down the left, the page beside it;
## in every look (Gloss its own). Settings walks you through connecting Spotify and YouTube, step
## by step, and has the Appearance settings. (examples/music.nim opens the window;
## tests/test_music.nim draws them.)

import std/[json, strutils, tables, times, os, uri]
import retroui
import retroui/[oauth, secrets, jobs, http, jpeg]
import retroui/uirelays/input
import api

const
  AppKey* = "RetroMusic"
  MusicVersion* = "1.1"

type
  ReqKind = enum
    rkPlayback, rkDevices, rkSearch, rkVideos, rkPlaylists, rkLiked, rkRecent, rkListTracks,
    rkCommand, rkLyrics, rkCover, rkRefresh, rkKeyTest
  Pending = object
    kind: ReqKind
    key: string                          # (a cover's address, a command's name)
    job: Job[HttpResponse]

var
  # accounts and settings (kept with retroui/secrets)
  clientId* = ""
  youtubeKey* = ""
  tokens*: OAuthTokens
  signIn: OAuthFlow
  refreshing: Job[OAuthTokens]
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
  lyricLines*: seq[LyricLine]
  lyricText* = ""
  lyricsFor = ""
  covers: Table[string, Bitmap]
  coverAsked: Table[string, bool]
  pending: seq[Pending]
  lastPoll = 0.0
  # the screens
  tab* = 0                               # Home, Search, Library, Settings
  nowOpen* = false                       # Now Playing over them
  youtubeNow*: Track                     # the video playing in YouTube's player
  query* = ""
  searchSource* = 0                      # Spotify, YouTube
  searchedFor = ""
  queryChanged = 0
  libraryPage = ""                       # "" the list; "liked", "list"
  settingsPage* = ""                     # "" the list; "spotify", "youtube", "appearance"
  youtubeOk* = 0                         # the key tried: 1 it works, -1 it does not, 0 not tried
  keyTesting = false
  idOpen, keyOpen, devicesOpen, aboutOpen*, lookOpen* = false
  idText, keyText = ""
  message* = ""

proc spotifyProvider(): OAuthProvider =
  OAuthProvider(name: "Spotify", authUrl: SpotifyAuth, tokenUrl: SpotifyToken, clientId: clientId,
                scopes: @SpotifyScopes, redirectHost: "127.0.0.1")

proc signedIn*(): bool = tokens.accessToken.len > 0

proc savedPath(): string = dataDir(AppKey) / "saved.json"

proc loadSettings*() =
  ## The client id, the key, the sign-in and the saved videos, as they were kept.
  clientId = loadSecret(AppKey, "spotify-client")
  youtubeKey = loadSecret(AppKey, "youtube-key")
  let t = loadSecret(AppKey, "spotify-tokens")
  if t.len > 0:
    try: tokens = toTokens(parseJson(t)) except CatchableError: discard
  try:
    for it in parseJson(readFile(savedPath())).getElems:
      saved.add Track(source: srcYouTube, id: it{"id"}.getStr, uri: it{"uri"}.getStr,
                      title: it{"title"}.getStr, artist: it{"artist"}.getStr, cover: it{"cover"}.getStr)
  except CatchableError: discard

proc keepTokens() =
  discard saveSecret(AppKey, "spotify-tokens", $(%tokens))

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
  if body.len > 0: hs.add ("Content-Type", "application/json")
  pending.add Pending(kind: kind, key: key, job: fetch(url, meth, hs, body, timeoutSec = 30))

proc spotify(kind: ReqKind; path: string; meth = "GET"; body = ""; key = "") =
  if not signedIn() or refreshing != nil: return
  ask(kind, SpotifyApi & path, meth, body, key)

proc command*(path: string; meth = "PUT"; body = "") =
  ## A Spotify Connect command (play, pause, next...); what plays is read again after it.
  spotify(rkCommand, path, meth, body, key = path)

proc playTracks*(list: openArray[Track]; at: int) =
  ## Plays `list` from its `at`-th track: Spotify's on your device, a video in YouTube's player.
  if at < 0 or at >= list.len: return
  let t = list[at]
  if t.source == srcYouTube:
    youtubeNow = t
    nowOpen = true
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
    if r.status == 401 and signedIn(): message = "Spotify: sign in again (Settings)"
    case p.kind
    of rkPlayback:
      if r.status in [200, 204]:
        playback = spotifyPlayback(r.body)
        playbackAt = ui.now
    of rkDevices:
      if r.ok: devices = spotifyDevices(r.body)
    of rkSearch: (if r.ok: results = spotifyTracks(r.body) else: message = "Search: " & $r.status & " " & r.error)
    of rkVideos:
      if r.ok: videos = youtubeVideos(r.body)
      else: message = "YouTube: " & (if r.status == 403: "the key is not allowed (Settings)" else: $r.status & " " & r.error)
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
        let b = try: decodeJpeg(r.body) except CatchableError: nil
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
  if youtubeNow.id.len > 0: youtubeNow else: playback.track

proc playerControls() =
  let t = nowTrack()
  if t.source == srcYouTube:
    when defined(android) or defined(ios):
      discard webView(embedPage(t.id), height = dp(220), key = "youtube")
    else:
      if button("Open in YouTube &Music", isDefault = true): openUrl(t.uri)
      label("YouTube's own player plays it: in the browser here, in the app on a phone.",
            color = ui.theme.gray)
    row:
      let isSaved = block:
        var f = false
        for s in saved:
          if s.id == t.id: f = true
        f
      if button(if isSaved: "Saved" else: "&Save", enabled = not isSaved):
        saved.add t
        keepSaved()
      if button("Open in &YouTube"): openUrl("https://www.youtube.com/watch?v=" & t.id)
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
    let at = if t.source == srcSpotify: lineAt(lyricLines, progressNow()) else: -1
    tableGroup("Lyrics", "From LrcLib, timed."):
      discard
    for i, l in lyricLines:
      if l.text.len == 0: continue
      if i == at: label(l.text, bold = true, color = accentColor())
      else: label(l.text, color = if at >= 0 and i < at: ui.theme.gray else: ui.theme.text)
    if t.source == srcSpotify: wakeIn(250)
  elif lyricText.len > 0:
    tableGroup("Lyrics", "From LrcLib."):
      discard
    paragraph(lyricText)

proc nowPlaying*() =
  ## The track playing: its cover, its name, the controls, where it plays, its lyrics.
  let t = nowTrack()
  if t.title.len == 0:
    emptyState(nfMusic, "Nothing plays", detail = "Search for a song, or open Spotify on a device.")
    return
  let side = min(cellRoom(), dp(300))
  let big = cover(t.cover)
  let r = place(side, side)
  if big != nil:
    masked(r, float(dp(8))):
      drawBitmap(r, big)
  else:
    roundRect(r, float(dp(8)), mixColor(ui.theme.window, ui.theme.text, 0.1))
    text(r.x + (r.w - textWidth(nfMusic, style(size = 3.0))) div 2,
         r.y + (r.h - lineHeight(style(size = 3.0))) div 2, nfMusic, ui.theme.gray, style(size = 3.0))
  heading(t.title, 2)
  label(t.artist & (if t.album.len > 0: " -- " & t.album else: ""), color = ui.theme.gray)
  playerControls()
  lyricsPart()

proc homeScreen() =
  let t = nowTrack()
  if t.title.len > 0:
    tableGroup("Now Playing"):
      if tableRow(t.title, if playback.playing: "playing" else: "", taChevron, subtitle = t.artist,
                  picture = cover(t.cover)).clicked:
        nowOpen = true
  if not signedIn() and youtubeKey.len == 0:
    tableGroup("", "Spotify plays in your Spotify apps and speakers (Premium); YouTube in its own " &
                   "player. Lyrics come from LrcLib."):
      if tableRow("Connect Spotify", "", taChevron, glyph = nfMusic, tint = color(30, 185, 84)).clicked:
        tab = 3
        settingsPage = "spotify"
      if tableRow("Connect YouTube", "", taChevron, glyph = nfPlay, tint = color(226, 30, 30)).clicked:
        tab = 3
        settingsPage = "youtube"
  if recent.len > 0:
    label("Played Lately", bold = true)
    trackRows(recent, "recent")
  if saved.len > 0:
    label("Saved from YouTube", bold = true)
    trackRows(saved, "saved")

proc searchScreen() =
  if searchBar(query, "Songs, artists"): queryChanged = ui.now
  if segmented(["Spotify", "YouTube"], searchSource): searchedFor = ""
  # (asked half a second after the typing stops, or at once on Enter)
  let words = query.strip
  if words.len > 0 and words & $searchSource != searchedFor and
     (ui.now - queryChanged > 500 or keyHit(KeyEnter)):
    searchedFor = words & $searchSource
    if searchSource == 0:
      if signedIn(): spotify(rkSearch, "/search?q=" & encodeUrl(words, usePlus = false) & "&type=track&limit=20")
      else: message = "Sign in to Spotify first (Settings)"
    else:
      if youtubeKey.len > 0: ask(rkVideos, youtubeSearchUrl(words, youtubeKey))
      else: message = "Add a YouTube key first (Settings)"
  elif words.len > 0 and words & $searchSource != searchedFor: wakeIn(520)
  let list = if searchSource == 0: results else: videos
  if list.len == 0:
    emptyState(nfSearch, if words.len == 0: "Search" else: "Nothing found yet",
               detail = if searchSource == 0: "Spotify's songs" else: "YouTube's music videos")
  else: trackRows(list, "search" & $searchSource)

proc libraryScreen() =
  case libraryPage
  of "liked":
    if liked.len == 0: spotify(rkLiked, "/me/tracks?limit=50")
    trackRows(liked, "liked")
  of "list": trackRows(listTracks, "list")
  else:
    if not signedIn():
      emptyState(nfList, "Your library", detail = "Sign in to Spotify (Settings) for your playlists.")
    else:
      if playlists.len == 0 and pending.len == 0: spotify(rkPlaylists, "/me/playlists?limit=50")
      tableGroup("Spotify"):
        if tableRow("Liked Songs", "", taChevron, glyph = nfHeart).clicked: libraryPage = "liked"
        for p in playlists:
          let h = tableRow(p.name, $p.count, taChevron, subtitle = p.owner, picture = cover(p.cover), key = p.id)
          if h.clicked:
            listName = p.name
            listTracks.setLen(0)
            spotify(rkListTracks, "/playlists/" & p.id & "/tracks?limit=50")
            libraryPage = "list"
    if saved.len > 0:
      tableGroup("YouTube"):
        for i, t in saved:
          if tableRow(t.title, "", taChevron, subtitle = t.artist, picture = cover(t.cover), key = "s" & t.id).clicked:
            playTracks(saved, i)

const
  SpotifyDashboard* = "https://developer.spotify.com/dashboard"
  SpotifyRedirect* = "http://127.0.0.1/"
  CloudProject* = "https://console.cloud.google.com/projectcreate"
  YouTubeApiPage* = "https://console.cloud.google.com/apis/library/youtube.googleapis.com"
  CloudKeys* = "https://console.cloud.google.com/apis/credentials"

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

proc youtubeGuide() =
  ## Connecting YouTube with a key, step by step.
  tableGroup("", "YouTube Music has no API of its own for apps: Retro Music finds its music with " &
                 "YouTube's (the YouTube Data API) and plays it in YouTube's own player, or " &
                 "opens it in YouTube Music."):
    discard tableRow("YouTube", if youtubeKey.len == 0: "Not connected" elif keyTesting: "Trying..."
                                elif youtubeOk == 1: "Connected" elif youtubeOk == -1: "Key not working"
                                else: "Key saved", glyph = nfPlay, tint = color(226, 30, 30))
  tableGroup("1. A Google Cloud project",
             "Sign in with your Google account and make a project -- any name -- or pick one " &
             "you have."):
    if tableButton("Open Google Cloud Console"): openUrl(CloudProject)
  tableGroup("2. Turn on the YouTube Data API v3",
             "In that project, on the API's page: press Enable."):
    if tableButton("Open the YouTube Data API"): openUrl(YouTubeApiPage)
  tableGroup("3. Make an API key",
             "Credentials > Create credentials > API key, then copy it. Best: edit the key and " &
             "under API restrictions allow only the YouTube Data API v3."):
    if tableButton("Open Credentials"): openUrl(CloudKeys)
  tableGroup("4. The key, here",
             "Paste it: Retro Music tries it with a search. It's free -- 10,000 units a day, a " &
             "search takes 100: about 100 searches a day."):
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
      else: message = "That isn't an API key: copy it again (step 3)"
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
  of "appearance":
    note("The look of the controls, its colors, the sizes, the font -- kept for next time.")
    discard appearanceSettings()
  else:
    tableGroup("Services", "Spotify plays in your Spotify apps and speakers; YouTube in its own " &
                           "player. Lyrics come from LrcLib by themselves."):
      if tableRow("Spotify", if signedIn(): "Connected" elif clientId.len > 0: "Sign in" else: "Connect",
                  taChevron, glyph = nfMusic, tint = color(30, 185, 84)).clicked:
        settingsPage = "spotify"
      if tableRow("YouTube", if youtubeKey.len == 0: "Connect" elif youtubeOk == -1: "Key not working"
                             else: "Connected", taChevron, glyph = nfPlay, tint = color(226, 30, 30)).clicked:
        settingsPage = "youtube"
    tableGroup(""):
      if tableRow("Appearance", "", taChevron, glyph = nfPalette, tint = color(150, 90, 210)).clicked:
        settingsPage = "appearance"
      if tableRow("About Retro Music", "", taChevron, glyph = nfInfo, tint = color(128, 128, 136)).clicked:
        aboutOpen = true

proc dialogs*() =
  if idOpen and inputBox(idOpen, "Spotify Client ID", "Your app's Client ID (developer.spotify.com):", idText) == 1:
    clientId = idText.strip
    discard saveSecret(AppKey, "spotify-client", clientId)
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
           ["Spotify and YouTube in one player, through their own services: Spotify Connect " &
            "plays on your devices, YouTube's player plays its videos; lyrics from LrcLib."],
           tagline = "Spotify and YouTube, one player", glyph = pxApp)

# ---- the window ----------------------------------------------------------------------------------

const Sections = ["Home", "Search", "Library", "Settings"]

proc pageTitle(): string =
  if nowOpen: "Now Playing"
  elif tab == 2 and libraryPage == "liked": "Liked Songs"
  elif tab == 2 and libraryPage == "list": listName
  elif tab == 3 and settingsPage == "spotify": "Spotify"
  elif tab == 3 and settingsPage == "youtube": "YouTube"
  elif tab == 3 and settingsPage == "appearance": "Appearance"
  else: Sections[tab]

proc backLabel(): string =
  ## (the navigation bar's Back: where it goes)
  if nowOpen and isCompact(): "Close"
  elif tab == 2 and libraryPage.len > 0: "Library"
  elif tab == 3 and settingsPage.len > 0: "Settings"
  else: ""

proc goBack() =
  if nowOpen and isCompact(): nowOpen = false
  elif tab == 2: libraryPage = ""
  else: settingsPage = ""

proc page() =
  if nowOpen:
    nowPlaying()
    return
  case tab
  of 0: homeScreen()
  of 1: searchScreen()
  of 2: libraryScreen()
  else: settingsScreen()

proc miniPlayer() =
  ## (a phone's: what plays, over the tab bar; a tap opens it)
  let t = nowTrack()
  if t.title.len == 0 or nowOpen: return
  let h = if fingers(): dp(52) else: dp(42)
  let r = rect(ui.winX, ui.bottom - h, ui.w, h)
  if glossLook(): glossBarFill(r)
  else:
    fill(r, mixColor(ui.theme.window, ui.theme.face, 0.6))
    hline(r.x, r.y, r.w, mixColor(ui.theme.window, ui.theme.text, 0.15))
  ui.bottom = r.y
  let hit = interact(idOf("miniplayer"), r, focusable = false)
  let b = cover(t.cover)
  let d = h - dp(10)
  if b != nil: drawBitmap(rect(r.x + dp(8), r.y + dp(5), d, d), b)
  let ink = if glossLook(): color(255, 255, 255) else: ui.theme.text
  let x = r.x + dp(16) + d
  text(x, r.y + h div 2 - FontH, ellipsize(t.title, r.w - x - dp(60), style(bold = true)), ink, true)
  text(x, r.y + h div 2, ellipsize(t.artist, r.w - x - dp(60)), if glossLook(): ink else: ui.theme.gray)
  let pr = rect(r.x + r.w - dp(48), r.y, dp(44), h)
  let ph = interact(idOf("miniplay"), pr, focusable = false)
  let g = if playback.playing: nfPause else: nfPlay
  let gs = style(size = 1.4)
  text(pr.x + (pr.w - textWidth(g, gs)) div 2, pr.y + (h - lineHeight(gs)) div 2, g,
       if glossLook(): ink else: accentColor(), gs)
  if ph.clicked and t.source == srcSpotify:
    if playback.playing:
      command("/me/player/pause")
      playback.playing = false
    else:
      command("/me/player/play")
      playback.playing = true
      playbackAt = ui.now
  elif hit.clicked: nowOpen = true

proc pageBody(margin: int) =
  ## (the page under its navigation bar, in a panel; its groups `margin` in from its sides)
  beginPanel(-1, "music:" & $tab & ":" & $nowOpen & libraryPage & settingsPage, plain = true)
  if margin > 0:
    let (fx, _) = layoutOrigin()
    pushFrame(rect(fx + margin, layoutY() + dp(4), layoutWidth() - 2 * margin, 0))
  page()
  if margin > 0: discard place(0, popFrame() + dp(12))
  endPanel()

const SectionRows = [(nfHome, "Home", color(36, 110, 220)), (nfSearch, "Search", color(96, 104, 120)),
                     (nfList, "Library", color(236, 140, 20)), (nfCog, "Settings", color(128, 128, 136))]

proc splitView() =
  ## A tablet's or a computer's: the sections and what plays in a list down the left under the
  ## app's navigation bar, the page beside it under its own -- as tablets showed them then.
  let top = ui.barY
  let h = ui.bottom - top
  let x0 = ui.winX + ui.safe.left
  let w = ui.w - ui.safe.left - ui.safe.right
  let mw = min(dp(300), w * 2 div 5)
  pushFrame(rect(x0, top, mw, h))
  discard navBar("Retro Music")
  beginPanel(-1, "music:sections", plain = true)
  let (fx, _) = layoutOrigin()
  pushFrame(rect(fx + dp(8), layoutY() + dp(6), layoutWidth() - dp(16), 0))
  tableGroup(""):
    for i, (g, name, tint) in SectionRows:
      if tableRow(name, "", taChevron, glyph = g, tint = tint, selected = tab == i and not nowOpen).clicked:
        if tab == i:
          libraryPage = ""
          settingsPage = ""
        tab = i
        nowOpen = false
  let t = nowTrack()
  if t.title.len > 0:
    tableGroup("Now Playing"):
      if tableRow(t.title, if playback.playing: "playing" else: "", taChevron, subtitle = t.artist,
                  picture = cover(t.cover), selected = nowOpen).clicked:
        nowOpen = true
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
  vline(x0 + mw, top, h, if glossLook() or lumaOfColor(ui.theme.window) < 128: color(0, 0, 0)
                         else: mixColor(ui.theme.window, ui.theme.text, 0.2))
  pushFrame(rect(x0 + mw + 1, top, w - mw - 1, h))
  let back = backLabel()
  if navBar(pageTitle(), back = back) == npBack: goBack()
  pageBody(dp(24))
  discard popFrame()

proc musicView*() =
  ## The whole window, every frame.
  pollServices()
  if isCompact():
    let before = tab
    discard bottomNav([(nfHome, "Home"), (nfSearch, "Search"), (nfList, "Library"), (nfCog, "Settings")], tab)
    if tab != before:
      nowOpen = false
      libraryPage = ""
      settingsPage = ""
    miniPlayer()
    if navBar(pageTitle(), back = backLabel()) == npBack: goBack()
    pageBody(0)
  else:
    if not ui.touch:
      statusbar(if message.len > 0: message elif signedIn(): "Spotify: signed in" else: "Spotify: not signed in",
                if playback.device.name.len > 0: "Playing on " & playback.device.name else: "")
    splitView()
  dialogs()
  if message.len > 0 and (isCompact() or ui.touch):
    toast(message)
    message = ""

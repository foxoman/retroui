## Retro Music's screens: Home, Search, Library, Now Playing and Settings -- a tab bar and pages on
## a phone, a list of them beside the page on a computer; in every look. (examples/music.nim
## opens the window; tests/test_music.nim draws them.)

import std/[json, strutils, tables, times, os, uri]
import retroui
import retroui/[oauth, secrets, jobs, http, jpeg]
import api

const AppKey* = "RetroMusic"

type
  ReqKind = enum
    rkPlayback, rkDevices, rkSearch, rkVideos, rkPlaylists, rkLiked, rkRecent, rkListTracks,
    rkCommand, rkLyrics, rkCover, rkRefresh
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
      if tableRow("Sign in to Spotify", "", taChevron, glyph = nfMusic).clicked: tab = 3
      if tableRow("Add a YouTube key", "", taChevron, glyph = nfPlay).clicked: tab = 3
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

proc settingsScreen() =
  tableGroup("Spotify", "Make an app of your own at developer.spotify.com (its Redirect URI " &
                        "http://127.0.0.1), and give its Client ID here. Spotify plays in your " &
                        "Spotify apps and speakers, which need Premium; this is their remote."):
    if tableRow("Client ID", if clientId.len > 0: clientId[0 ..< min(8, clientId.len)] & "..." else: "none",
                taChevron).clicked:
      idText = clientId
      idOpen = true
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
    elif tableButton("Sign In", enabled = clientId.len > 0):
      signIn = beginSignIn(spotifyProvider())
  tableGroup("YouTube", "A key from Google Cloud's console with the YouTube Data API v3 on: it " &
                        "searches. YouTube's own player plays the videos."):
    if tableRow("API Key", if youtubeKey.len > 0: "set" else: "none", taChevron).clicked:
      keyText = youtubeKey
      keyOpen = true
  tableGroup(""):
    if tableRow("Appearance", "", taChevron).clicked: lookOpen = true
    if tableRow("About Retro Music", "", taChevron).clicked: aboutOpen = true

proc dialogs*() =
  if idOpen and inputBox(idOpen, "Spotify Client ID", "Your app's Client ID (developer.spotify.com):", idText) == 1:
    clientId = idText.strip
    discard saveSecret(AppKey, "spotify-client", clientId)
  if keyOpen and inputBox(keyOpen, "YouTube API Key", "A YouTube Data API v3 key:", keyText) == 1:
    youtubeKey = keyText.strip
    discard saveSecret(AppKey, "youtube-key", youtubeKey)
  var names: seq[string]
  for d in devices: names.add d.name & (if d.active: " (playing)" else: "")
  let pick = actionSheet(devicesOpen, "Play on", names)
  if pick >= 0 and pick < devices.len and devices[pick].id.len > 0:
    command("/me/player", "PUT", transferBody(devices[pick].id))
  if lookOpen:
    dialog(lookOpen, "Appearance", 420):
      appearanceSettings()
      if button("Close", isDefault = true): lookOpen = false
  aboutBox(aboutOpen, "Retro Music", "1.0",
           ["Spotify and YouTube in one player, through their own services: Spotify Connect " &
            "plays on your devices, YouTube's player plays its videos; lyrics from LrcLib."],
           tagline = "Spotify and YouTube, one player", glyph = pxApp)

# ---- the window ----------------------------------------------------------------------------------

const Sections = ["Home", "Search", "Library", "Settings"]

proc pageTitle(): string =
  if nowOpen: "Now Playing"
  elif tab == 2 and libraryPage == "liked": "Liked Songs"
  elif tab == 2 and libraryPage == "list": listName
  else: Sections[tab]

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

proc musicView*() =
  ## The whole window, every frame.
  pollServices()
  if isCompact():
    let before = tab
    discard bottomNav([(nfHome, "Home"), (nfSearch, "Search"), (nfList, "Library"), (nfCog, "Settings")], tab)
    if tab != before:
      nowOpen = false
      libraryPage = ""
    miniPlayer()
    let back = if nowOpen: "Close" elif tab == 2 and libraryPage.len > 0: "Library" else: ""
    if navBar(pageTitle(), back = back) == npBack:
      if nowOpen: nowOpen = false else: libraryPage = ""
    beginPanel(-1, "music:" & $tab & ":" & $nowOpen & libraryPage, plain = true)
    page()
    endPanel()
  else:
    statusbar(if message.len > 0: message elif signedIn(): "Spotify: signed in" else: "Spotify: not signed in",
              if playback.device.name.len > 0: "Playing on " & playback.device.name else: "")
    var sel = if nowOpen: 4 else: tab
    row([dp(190), -1]):
      col:
        if listbox(["Home", "Search", "Library", "Settings", "Now Playing"], sel, rows = 5):
          nowOpen = sel == 4
          if sel < 4: tab = sel
          libraryPage = ""
        let t = nowTrack()
        if t.title.len > 0:
          space(dp(8))
          let b = cover(t.cover)
          let r = place(dp(160), dp(160))
          if b != nil: drawBitmap(r, b)
          label(t.title, bold = true)
          label(t.artist, color = ui.theme.gray)
          if t.source == srcSpotify:
            row:
              if button("Previous", nfStepBackward, blIconOnly): command("/me/player/previous", "POST")
              if button(if playback.playing: "Pause" else: "Play", if playback.playing: nfPause else: nfPlay,
                        blIconOnly):
                if playback.playing:
                  command("/me/player/pause")
                  playback.playing = false
                else:
                  command("/me/player/play")
                  playback.playing = true
                  playbackAt = ui.now
              if button("Next", nfStepForward, blIconOnly): command("/me/player/next", "POST")
      col:
        panel:
          heading(pageTitle(), 2)
          if tab == 2 and libraryPage.len > 0 and not nowOpen and button("< Library"): libraryPage = ""
          page()
  dialogs()
  if message.len > 0 and isCompact():
    toast(message)
    message = ""

## Retro Music's services, without a window: Spotify's Web API (search, your playlists and
## liked songs, what plays where -- Spotify Connect: play, pause, next, seek, a device), the
## YouTube Data API (search), LrcLib (lyrics, timed) -- the requests they take and what their
## answers hold. Nothing here plays sound: Spotify plays in your own Spotify apps and speakers
## (Premium), YouTube in its own embedded player.

import std/[json, strutils, uri]

type
  Source* = enum
    srcSpotify = "Spotify"
    srcYouTube = "YouTube"
  Track* = object
    source*: Source
    id*, uri*: string          ## Spotify's id and spotify:track:... uri; YouTube's video id
    title*, artist*, album*: string
    cover*: string             ## the address of its cover (a small one)
    durationMs*: int
  Playlist* = object
    id*, uri*, name*, owner*, cover*: string
    count*: int
  Device* = object
    id*, name*, kind*: string
    active*: bool
    volume*: int
  Playback* = object
    ## What plays on the account now (Spotify).
    playing*: bool
    track*: Track
    progressMs*: int
    device*: Device
    shuffle*: bool
    repeat*: string            ## "off", "context", "track"
  LyricLine* = tuple[ms: int; text: string]

const
  SpotifyApi* = "https://api.spotify.com/v1"
  SpotifyAuth* = "https://accounts.spotify.com/authorize"
  SpotifyToken* = "https://accounts.spotify.com/api/token"
  SpotifyScopes* = ["user-read-playback-state", "user-modify-playback-state",
                    "user-read-currently-playing", "user-library-read", "playlist-read-private",
                    "user-read-recently-played"]
  YouTubeApi* = "https://www.googleapis.com/youtube/v3"
  LrcLibApi* = "https://lrclib.net/api"

proc q(s: string): string = encodeUrl(s, usePlus = false)

# ---- reading Spotify's answers ---------------------------------------------------------------------

proc str(j: JsonNode; key: string): string =
  if j != nil and j.kind == JObject and j.hasKey(key) and j[key].kind == JString: j[key].getStr else: ""

proc smallest(images: JsonNode): string =
  ## (the smallest picture of a list of them that is at least 64 pixels: a row's cover)
  if images == nil or images.kind != JArray or images.len == 0: return ""
  var best = images[0].str("url")
  var bestW = high(int)
  for im in images:
    let w = im{"width"}.getInt(0)
    if w >= 64 and w < bestW:
      bestW = w
      best = im.str("url")
  best

proc largest*(images: JsonNode): string =
  ## The largest picture's address (the player's cover).
  if images == nil or images.kind != JArray or images.len == 0: return ""
  var best = images[0].str("url")
  var bestW = -1
  for im in images:
    let w = im{"width"}.getInt(0)
    if w > bestW:
      bestW = w
      best = im.str("url")
  best

proc spotifyTrack*(j: JsonNode): Track =
  ## A track of Spotify's (a search's, a playlist's item's `track`, what plays).
  if j == nil or j.kind != JObject: return
  result.source = srcSpotify
  result.id = j.str("id")
  result.uri = j.str("uri")
  result.title = j.str("name")
  var names: seq[string]
  for a in j{"artists"}.getElems: names.add a.str("name")
  result.artist = names.join(", ")
  result.album = j{"album"}.str("name")
  result.cover = smallest(j{"album", "images"})
  result.durationMs = j{"duration_ms"}.getInt(0)

proc spotifyTracks*(body: string): seq[Track] =
  ## The tracks of an answer: a search's (`tracks.items`), a playlist's or the liked songs'
  ## (`items[].track`), the recently played (`items[].track`).
  let j = try: parseJson(body) except CatchableError: return
  let items = if j{"tracks", "items"} != nil: j{"tracks", "items"} else: j{"items"}
  for it in items.getElems:
    let t = if it.hasKey("track"): it["track"] else: it
    if t != nil and t.kind == JObject and t.str("uri").len > 0: result.add spotifyTrack(t)

proc spotifyPlaylists*(body: string): seq[Playlist] =
  ## Your playlists (`items`), or a search's (`playlists.items`).
  let j = try: parseJson(body) except CatchableError: return
  let items = if j{"playlists", "items"} != nil: j{"playlists", "items"} else: j{"items"}
  for p in items.getElems:
    if p == nil or p.kind != JObject: continue
    result.add Playlist(id: p.str("id"), uri: p.str("uri"), name: p.str("name"),
                        owner: p{"owner"}.str("display_name"), cover: smallest(p{"images"}),
                        count: p{"tracks", "total"}.getInt(0))

proc spotifyDevices*(body: string): seq[Device] =
  ## Where Spotify can play (your phone's app, a computer, a speaker).
  let j = try: parseJson(body) except CatchableError: return
  for d in j{"devices"}.getElems:
    result.add Device(id: d.str("id"), name: d.str("name"), kind: d.str("type"),
                      active: d{"is_active"}.getBool(false), volume: d{"volume_percent"}.getInt(-1))

proc spotifyPlayback*(body: string): Playback =
  ## What plays now (none: an empty answer, 204).
  if body.strip.len == 0: return
  let j = try: parseJson(body) except CatchableError: return
  result.playing = j{"is_playing"}.getBool(false)
  result.progressMs = j{"progress_ms"}.getInt(0)
  result.shuffle = j{"shuffle_state"}.getBool(false)
  result.repeat = j.str("repeat_state")
  if j{"item"} != nil: result.track = spotifyTrack(j["item"])
  let d = j{"device"}
  if d != nil and d.kind == JObject:
    result.device = Device(id: d.str("id"), name: d.str("name"), kind: d.str("type"),
                           active: d{"is_active"}.getBool(false), volume: d{"volume_percent"}.getInt(-1))

# ---- Spotify's requests ----------------------------------------------------------------------------

proc searchUrl*(words: string; kinds = "track"; limit = 20): string =
  SpotifyApi & "/search?q=" & q(words) & "&type=" & kinds & "&limit=" & $limit

proc playlistTracksUrl*(id: string; limit = 50): string =
  SpotifyApi & "/playlists/" & id & "/tracks?limit=" & $limit

proc playBody*(uris: openArray[string] = []; context = ""; offset = 0): string =
  ## What `PUT /me/player/play` takes: tracks to play, or a playlist (`context`) from one.
  var j = newJObject()
  if context.len > 0:
    j["context_uri"] = %context
    j["offset"] = %*{"position": offset}
  elif uris.len > 0:
    j["uris"] = %(@uris)
    if offset > 0: j["offset"] = %*{"position": offset}
  $j

proc transferBody*(deviceId: string; play = true): string =
  $(%*{"device_ids": [deviceId], "play": play})

# ---- YouTube ---------------------------------------------------------------------------------------

proc youtubeSearchUrl*(words, key: string; limit = 20): string =
  ## Videos of music (category 10) that match `words`.
  YouTubeApi & "/search?part=snippet&type=video&videoCategoryId=10&maxResults=" & $limit &
    "&q=" & q(words) & "&key=" & q(key)

proc youtubeVideos*(body: string): seq[Track] =
  ## The videos of a search's answer.
  let j = try: parseJson(body) except CatchableError: return
  for it in j{"items"}.getElems:
    let id = it{"id"}.str("videoId")
    if id.len == 0: continue
    let sn = it{"snippet"}
    var t = Track(source: srcYouTube, id: id, uri: "https://music.youtube.com/watch?v=" & id,
                  title: sn.str("title"), artist: sn.str("channelTitle"))
    t.cover = sn{"thumbnails", "medium"}.str("url")
    if t.cover.len == 0: t.cover = sn{"thumbnails", "default"}.str("url")
    # (titles come with HTML's entities)
    t.title = t.title.multiReplace(("&amp;", "&"), ("&#39;", "'"), ("&quot;", "\""), ("&lt;", "<"), ("&gt;", ">"))
    result.add t

proc embedPage*(videoId: string): string =
  ## A page with YouTube's own embedded player, playing the video (a web view shows it).
  "html:<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>" &
    "<style>html,body{margin:0;background:#000;height:100%}iframe{border:0;width:100%;height:100%}</style>" &
    "<iframe src='https://www.youtube.com/embed/" & videoId &
    "?autoplay=1&playsinline=1' allow='autoplay; encrypted-media; picture-in-picture' allowfullscreen></iframe>"

# ---- lyrics: LrcLib, and LRC's timed lines ---------------------------------------------------------

proc lyricsUrl*(t: Track): string =
  result = LrcLibApi & "/get?track_name=" & q(t.title) & "&artist_name=" & q(t.artist)
  if t.album.len > 0: result &= "&album_name=" & q(t.album)
  if t.durationMs > 0: result &= "&duration=" & $(t.durationMs div 1000)

proc parseLrc*(text: string): seq[LyricLine] =
  ## The timed lines of LRC text ("[01:02.50]A line"; a line with several times, once each).
  for raw in text.splitLines:
    var line = raw.strip
    var times: seq[int]
    while line.startsWith("[") and line.find(']') > 0:
      let tag = line[1 ..< line.find(']')]
      line = line[line.find(']') + 1 .. ^1]
      let parts = tag.split(':')
      if parts.len == 2:
        try:
          let m = parseInt(parts[0])
          let sec = parseFloat(parts[1])
          times.add m * 60_000 + int(sec * 1000 + 0.5)
        except ValueError: discard
    for t in times: result.add (t, line.strip)
  # (in time order)
  for i in 1 ..< result.len:
    var k = i
    while k > 0 and result[k - 1].ms > result[k].ms:
      swap(result[k - 1], result[k])
      dec k

proc lineAt*(lines: openArray[LyricLine]; ms: int): int =
  ## The line sung at `ms` (-1 before the first).
  result = -1
  for i, l in lines:
    if l.ms <= ms: result = i else: break

proc lyricsOf*(body: string): tuple[synced: seq[LyricLine]; plain: string] =
  ## LrcLib's answer: its timed lines, and the plain text.
  let j = try: parseJson(body) except CatchableError: return
  result.synced = parseLrc(j.str("syncedLyrics"))
  result.plain = j.str("plainLyrics")

proc clock*(ms: int): string =
  ## "3:07"
  let s = max(0, ms) div 1000
  $(s div 60) & ":" & (if s mod 60 < 10: "0" else: "") & $(s mod 60)

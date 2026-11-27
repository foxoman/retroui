## Retro Music's free sources, without a window: the requests they take and what their answers
## hold -- none needs a developer's key or an account made on a developer's page:
##
## - **YouTube Music** through Piped or Invidious, open-source services in front of YouTube
##   (any of their public servers, or your own): songs, albums and playlists searched; a
##   playlist's or an album's songs from its link. They play in YouTube's own player.
## - **Radio** from Radio Browser's directory: tens of thousands of stations, by name, country
##   or genre.
## - **Audius**: free music its artists put there whole -- trending, a search, an artist's or
##   your own handle's tracks and playlists.
## - **The Internet Archive**: live concerts, netlabels, old 78s.
## - **Your own server**: Navidrome, Airsonic, Gonic and any other Subsonic server, signed in
##   with your name and password.

import std/[json, strutils, uri, random, algorithm, sequtils]
import retroui/ntlm
import api

type
  Station* = object
    ## A radio station of Radio Browser's.
    id*, name*, url*, favicon*, tags*, country*, countryCode*, codec*: string
    bitrate*: int
  Shelf* = object
    ## An album or a playlist found (YouTube's, Audius', a server's, the Archive's).
    id*, name*, owner*, cover*: string
    count*: int
  ArchiveFile* = object
    ## A song of an Internet Archive item.
    name*, title*, artist*: string
    track*, durationMs*: int

const
  PipedServers* = ["https://pipedapi.kavin.rocks", "https://pipedapi.adminforge.de",
                   "https://api.piped.private.coffee", "https://pipedapi.leptons.xyz"]
    ## (Piped's public servers, tried in turn: one that does not answer, the next)
  InvidiousServers* = ["https://inv.nadeko.net", "https://invidious.nerdvpn.de", "https://yewtu.be"]
  RadioServers* = ["https://de1.api.radio-browser.info", "https://nl1.api.radio-browser.info",
                   "https://at1.api.radio-browser.info"]
  AudiusApi* = "https://api.audius.co"
  AudiusHost* = "https://discoveryprovider.audius.co"
  AppName* = "RetroMusic"
  ArchiveApi* = "https://archive.org"
  ArchiveCollections* = [("Live Music Archive", "etree"), ("Netlabels", "netlabels"),
                         ("78 RPM Records", "78rpm"), ("Old Time Radio", "oldtimeradio")]

proc q(s: string): string = encodeUrl(s, usePlus = false)

proc str(j: JsonNode; key: string): string =
  if j != nil and j.kind == JObject and j.hasKey(key):
    let v = j[key]
    case v.kind
    of JString: v.getStr
    of JInt: $v.getInt
    of JFloat: $v.getFloat
    else: ""
  else: ""

proc num(j: JsonNode; key: string): int =
  if j != nil and j.kind == JObject and j.hasKey(key):
    let v = j[key]
    case v.kind
    of JInt: v.getInt
    of JFloat: int(v.getFloat)
    of JString: (try: int(parseFloat(v.getStr)) except ValueError: 0)
    else: 0
  else: 0

proc parsed(body: string): JsonNode =
  try: parseJson(body) except CatchableError: newJNull()

# ---- YouTube Music, with no key: Piped and Invidious --------------------------------------------------

type YouTubeLink* = object
  ## What a YouTube or YouTube Music link points at.
  video*, list*: string

proc youtubeLink*(link: string): YouTubeLink =
  ## A link's video and playlist (an album's link is a playlist's: Share > Copy link): from
  ## music.youtube.com, youtube.com, youtu.be, m.youtube.com; a bare playlist id too.
  let t = link.strip
  if t.len > 0 and not t.contains("/") and not t.contains("?") and
     (t.startsWith("PL") or t.startsWith("OLAK5uy_") or t.startsWith("RD") or t.startsWith("UU") or
      t.startsWith("LL") or t.startsWith("VL")):
    result.list = (if t.startsWith("VL"): t[2 .. ^1] else: t)
    return
  var u: Uri
  try: u = parseUri(t) except CatchableError: return
  let host = u.hostname.toLowerAscii
  if not (host.endsWith("youtube.com") or host == "youtu.be" or host.endsWith("youtube-nocookie.com")):
    return
  for (k, v) in decodeQuery(u.query):
    if k == "v": result.video = v
    elif k == "list": result.list = v
  if host == "youtu.be" and u.path.len > 1: result.video = u.path[1 .. ^1].split('/')[0]
  elif u.path.startsWith("/shorts/") or u.path.startsWith("/embed/"):
    result.video = u.path.split('/')[2]
  elif u.path.startsWith("/browse/VL"): result.list = u.path[len("/browse/VL") .. ^1]

proc pipedSearchUrl*(server, words: string; filter = "music_songs"): string =
  ## (Piped's search: music_songs, music_albums, music_playlists, videos)
  server & "/search?q=" & q(words) & "&filter=" & filter

proc pipedPlaylistUrl*(server, id: string): string = server & "/playlists/" & q(id)

proc idOfWatch(url: string): string =
  ## ("/watch?v=ID" -> ID)
  let i = url.find("v=")
  if i < 0: "" else: url[i + 2 .. ^1].split('&')[0]

proc listOfUrl(url: string): string =
  let i = url.find("list=")
  if i < 0: "" else: url[i + 5 .. ^1].split('&')[0]

proc artistOf(uploader: string): string =
  ## (an artist's "- Topic" channel: the artist)
  if uploader.endsWith(" - Topic"): uploader[0 ..< ^8] else: uploader

proc ytTrack(id, title, uploader, thumb: string; secs: int): Track =
  Track(source: srcYouTube, id: id, uri: "https://music.youtube.com/watch?v=" & id, title: title,
        artist: artistOf(uploader), cover: thumb, durationMs: max(0, secs) * 1000)

proc pipedSongs*(body: string): seq[Track] =
  ## The songs of a Piped answer: a search's `items` or a playlist's `relatedStreams`.
  let j = parsed(body)
  let items = if j{"items"} != nil: j{"items"} elif j{"relatedStreams"} != nil: j{"relatedStreams"}
              else: newJArray()
  for it in items.getElems:
    if it.str("type") notin ["", "stream"]: continue
    let id = idOfWatch(it.str("url"))
    if id.len == 0: continue
    result.add ytTrack(id, it.str("title"), it.str("uploaderName"), it.str("thumbnail"), it.num("duration"))

proc pipedShelves*(body: string): seq[Shelf] =
  ## The albums or playlists of a Piped search.
  for it in parsed(body){"items"}.getElems:
    if it.str("type") != "playlist": continue
    let id = listOfUrl(it.str("url"))
    if id.len == 0: continue
    result.add Shelf(id: id, name: it.str("name"), owner: artistOf(it.str("uploaderName")),
                     cover: it.str("thumbnail"), count: it.num("videos"))

proc pipedPlaylistName*(body: string): string = parsed(body).str("name")

proc invidiousSearchUrl*(server, words: string): string =
  server & "/api/v1/search?q=" & q(words) & "&type=video"

proc invidiousPlaylistUrl*(server, id: string): string = server & "/api/v1/playlists/" & q(id)

proc thumbOf(j: JsonNode): string =
  for t in j{"videoThumbnails"}.getElems:
    if t.str("quality") in ["medium", "mqdefault", "default"]: return t.str("url")
  for t in j{"videoThumbnails"}.getElems: return t.str("url")

proc invidiousSongs*(body: string): seq[Track] =
  ## The songs of an Invidious answer: a search's, or a playlist's `videos`.
  let j = parsed(body)
  let items = if j.kind == JArray: j elif j{"videos"} != nil: j{"videos"} else: newJArray()
  for it in items.getElems:
    if it.str("type") notin ["", "video"]: continue
    let id = it.str("videoId")
    if id.len == 0: continue
    result.add ytTrack(id, it.str("title"), it.str("author"), thumbOf(it), it.num("lengthSeconds"))

proc invidiousPlaylistName*(body: string): string = parsed(body).str("title")

# ---- radio: Radio Browser ---------------------------------------------------------------------------

proc radioTopUrl*(server: string; limit = 60): string =
  server & "/json/stations/topclick/" & $limit & "?hidebroken=true"

proc radioSearchUrl*(server, words: string; limit = 60): string =
  server & "/json/stations/search?name=" & q(words) & "&limit=" & $limit &
    "&hidebroken=true&order=clickcount&reverse=true"

proc radioTagUrl*(server, tag: string; limit = 60): string =
  server & "/json/stations/search?tag=" & q(tag) & "&limit=" & $limit &
    "&hidebroken=true&order=clickcount&reverse=true"

proc radioCountryUrl*(server, code: string; limit = 80): string =
  server & "/json/stations/search?countrycode=" & q(code) & "&limit=" & $limit &
    "&hidebroken=true&order=clickcount&reverse=true"

proc radioStations*(body: string): seq[Station] =
  ## The stations of Radio Browser's answer (those with an address to play).
  for it in parsed(body).getElems:
    let url = if it.str("url_resolved").len > 0: it.str("url_resolved") else: it.str("url")
    if url.len == 0: continue
    result.add Station(id: it.str("stationuuid"), name: it.str("name").strip, url: url,
                       favicon: it.str("favicon"), tags: it.str("tags"), country: it.str("country"),
                       countryCode: it.str("countrycode"), codec: it.str("codec"), bitrate: it.num("bitrate"))

proc stationLine*(s: Station): string =
  ## ("Oman -- pop, arabic -- 128 kbps")
  var parts: seq[string]
  if s.country.len > 0: parts.add s.country
  let tags = s.tags.split(',')
  if tags.len > 0 and tags[0].len > 0: parts.add tags[0 ..< min(2, tags.len)].join(", ")
  if s.bitrate > 0: parts.add $s.bitrate & " kbps"
  parts.join(" -- ")

# ---- Audius ------------------------------------------------------------------------------------------

proc audiusHosts*(body: string): seq[string] =
  ## (api.audius.co's answer: the servers to ask)
  for h in parsed(body){"data"}.getElems:
    if h.kind == JString and h.getStr.startsWith("https://"): result.add h.getStr

proc audiusTrendingUrl*(host: string; genre = ""): string =
  host & "/v1/tracks/trending?app_name=" & AppName & (if genre.len > 0: "&genre=" & q(genre) else: "")

proc audiusSearchUrl*(host, words: string): string =
  host & "/v1/tracks/search?query=" & q(words) & "&app_name=" & AppName

proc audiusUserUrl*(host, handle: string): string =
  host & "/v1/users/handle/" & q(handle.strip(chars = {'@', ' '})) & "?app_name=" & AppName

proc audiusUserTracksUrl*(host, userId: string): string =
  host & "/v1/users/" & q(userId) & "/tracks?app_name=" & AppName & "&limit=100"

proc audiusUserPlaylistsUrl*(host, userId: string): string =
  host & "/v1/users/" & q(userId) & "/playlists?app_name=" & AppName

proc audiusPlaylistTracksUrl*(host, id: string): string =
  host & "/v1/playlists/" & q(id) & "/tracks?app_name=" & AppName

proc audiusStreamUrl*(host, id: string): string =
  host & "/v1/tracks/" & q(id) & "/stream?app_name=" & AppName

proc audiusArt(j: JsonNode): string =
  for k in ["480x480", "150x150", "1000x1000"]:
    let a = j{"artwork"}.str(k)
    if a.len > 0: return a

proc audiusTracks*(body: string): seq[tuple[id, title, artist, cover, genre: string; durationMs: int]] =
  ## The tracks of an Audius answer (those that may be streamed).
  for it in parsed(body){"data"}.getElems:
    if it.kind != JObject or it.str("id").len == 0: continue
    if it{"is_streamable"} != nil and it{"is_streamable"}.kind == JBool and not it{"is_streamable"}.getBool: continue
    result.add (it.str("id"), it.str("title"), it{"user"}.str("name"), audiusArt(it), it.str("genre"),
                it.num("duration") * 1000)

proc audiusUserId*(body: string): tuple[id, name: string] =
  let d = parsed(body){"data"}
  (d.str("id"), d.str("name"))

proc audiusPlaylists*(body: string): seq[Shelf] =
  for it in parsed(body){"data"}.getElems:
    if it.str("id").len == 0: continue
    result.add Shelf(id: it.str("id"), name: it.str("playlist_name"), owner: it{"user"}.str("name"),
                     cover: audiusArt(it), count: it.num("track_count"))

# ---- the Internet Archive ----------------------------------------------------------------------------

proc archiveSearchUrl*(words: string; collection = ""; rows = 40): string =
  ## (its items of sound, the most downloaded first: words, a collection, or both)
  var query = "mediatype:(audio)"
  if collection.len > 0: query.add " AND collection:(" & collection & ")"
  if words.strip.len > 0: query.add " AND (" & words.strip & ")"
  ArchiveApi & "/advancedsearch.php?q=" & q(query) &
    "&fl[]=identifier&fl[]=title&fl[]=creator&fl[]=date&sort[]=downloads+desc&rows=" & $rows & "&output=json"

proc archiveItems*(body: string): seq[Shelf] =
  for d in parsed(body){"response", "docs"}.getElems:
    let id = d.str("identifier")
    if id.len == 0: continue
    var creator = d.str("creator")
    if creator.len == 0 and d{"creator"} != nil and d{"creator"}.kind == JArray and d{"creator"}.len > 0:
      creator = d{"creator"}[0].getStr
    result.add Shelf(id: id, name: d.str("title"), owner: creator, cover: ArchiveApi & "/services/img/" & id)

proc archiveMetadataUrl*(id: string): string = ArchiveApi & "/metadata/" & q(id)

proc archiveFileUrl*(id, name: string): string =
  ArchiveApi & "/download/" & q(id) & "/" & name.split('/').mapIt(q(it)).join("/")

proc lengthMs(s: string): int =
  ## ("225.4" or "3:45" or "1:02:03" -> ms)
  if ':' in s:
    var total = 0.0
    for p in s.split(':'):
      total = total * 60 + (try: parseFloat(p) except ValueError: 0.0)
    int(total * 1000)
  else: (try: int(parseFloat(s) * 1000) except ValueError: 0)

proc archiveSongs*(body: string): seq[ArchiveFile] =
  ## An item's songs: its MP3s (the VBR ones, else any), in their track order.
  let files = parsed(body){"files"}.getElems
  var mp3s: seq[JsonNode]
  for f in files:
    if f.str("format") == "VBR MP3": mp3s.add f
  if mp3s.len == 0:
    for f in files:
      if f.str("name").toLowerAscii.endsWith(".mp3"): mp3s.add f
  for f in mp3s:
    let name = f.str("name")
    var title = f.str("title")
    if title.len == 0:
      # (its file's name, the track's number before it cut off: "03 Third.mp3", "03 - Third.mp3")
      title = name.split('/')[^1].rsplit('.', 1)[0]
      var k = 0
      while k < title.len and title[k] in Digits: inc k
      if k > 0 and k < title.len and title[k] in {' ', '-', '.', '_'}:
        let rest = title[k .. ^1].strip(chars = {' ', '-', '.', '_'})
        if rest.len > 0: title = rest
    result.add ArchiveFile(name: name, title: title, artist: f.str("creator"),
                           track: (try: parseInt(f.str("track").split('/')[0]) except ValueError: 0),
                           durationMs: lengthMs(f.str("length")))
  result.sort(proc (a, b: ArchiveFile): int =
    result = cmp(a.track, b.track)
    if result == 0: result = cmp(a.name, b.name))

proc archiveItemTitle*(body: string): tuple[title, creator: string] =
  let m = parsed(body){"metadata"}
  (m.str("title"), m.str("creator"))

# ---- your own server: the Subsonic API ---------------------------------------------------------------

type Server* = object
  ## A Subsonic server (Navidrome, Airsonic, Gonic...) and who signs in to it.
  url*, user*, password*: string

proc ready*(s: Server): bool = s.url.len > 0 and s.user.len > 0 and s.password.len > 0

proc base(s: Server): string =
  var u = s.url.strip
  while u.endsWith("/"): u.setLen(u.len - 1)
  if not (u.startsWith("http://") or u.startsWith("https://")): u = "https://" & u
  u

proc subsonicUrl*(s: Server; meth: string; params: openArray[(string, string)] = [];
                  salt = ""): string =
  ## A request of the Subsonic API: the password never sent, its salted hash instead.
  let sl = if salt.len > 0: salt else: $rand(100_000_000 .. 999_999_999)
  result = base(s) & "/rest/" & meth & ".view?u=" & q(s.user) & "&t=" & toHex(md5(s.password & sl)).toLowerAscii &
           "&s=" & sl & "&v=1.16.1&c=" & AppName & "&f=json"
  for (k, v) in params: result.add "&" & k & "=" & q(v)

proc subsonicError*(body: string): string =
  ## "" when the server said ok; else what it said ("Wrong username or password").
  let r = parsed(body){"subsonic-response"}
  if r == nil: return "not a Subsonic server's answer"
  if r.str("status") == "ok": return ""
  let e = r{"error"}
  if e != nil and e.str("message").len > 0: e.str("message") else: "the server said no"

proc subsonicSongs*(s: Server; body: string): seq[tuple[id, title, artist, album, cover: string; durationMs: int]] =
  ## The songs of a Subsonic answer: an album's, a playlist's, a search's.
  let r = parsed(body){"subsonic-response"}
  if r == nil: return
  var list: seq[JsonNode]
  if r{"album", "song"} != nil: list = r{"album", "song"}.getElems
  elif r{"playlist", "entry"} != nil: list = r{"playlist", "entry"}.getElems
  elif r{"searchResult3", "song"} != nil: list = r{"searchResult3", "song"}.getElems
  elif r{"randomSongs", "song"} != nil: list = r{"randomSongs", "song"}.getElems
  for it in list:
    if it.str("id").len == 0: continue
    let art = it.str("coverArt")
    result.add (it.str("id"), it.str("title"), it.str("artist"), it.str("album"),
                (if art.len > 0: subsonicUrl(s, "getCoverArt", [("id", art), ("size", "300")]) else: ""),
                it.num("duration") * 1000)

proc subsonicAlbums*(s: Server; body: string): seq[Shelf] =
  ## The albums of a Subsonic answer: a list of them, an artist's, a search's.
  let r = parsed(body){"subsonic-response"}
  if r == nil: return
  var list: seq[JsonNode]
  if r{"albumList2", "album"} != nil: list = r{"albumList2", "album"}.getElems
  elif r{"artist", "album"} != nil: list = r{"artist", "album"}.getElems
  elif r{"searchResult3", "album"} != nil: list = r{"searchResult3", "album"}.getElems
  for it in list:
    let art = it.str("coverArt")
    result.add Shelf(id: it.str("id"), name: it.str("name"), owner: it.str("artist"), count: it.num("songCount"),
                     cover: (if art.len > 0: subsonicUrl(s, "getCoverArt", [("id", art), ("size", "300")]) else: ""))

proc subsonicPlaylists*(body: string): seq[Shelf] =
  for it in parsed(body){"subsonic-response", "playlists", "playlist"}.getElems:
    result.add Shelf(id: it.str("id"), name: it.str("name"), owner: it.str("owner"), count: it.num("songCount"))

proc subsonicStreamUrl*(s: Server; id: string): string = subsonicUrl(s, "stream", [("id", id)])

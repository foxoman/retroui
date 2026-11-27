## Retro Music's free sources in the app: YouTube Music with nothing to set up, radio stations,
## Audius, the Internet Archive and your own Subsonic server -- their pages, the requests they
## make (each server tried in turn when one does not answer) and what is kept: the YouTube
## playlists and albums you added by their links, your favorite stations, your Audius handle,
## your server (its password with retroui/secrets). Their songs play in the app's own player
## (examples/music/local.nim) -- YouTube's in YouTube's own player (examples/music/screens.nim).

import std/[json, strutils, os, random, sequtils]
import retroui
import retroui/[jobs, http, secrets]
import api, sources, local

type
  OKind = enum
    okYtSongs, okYtShelves, okYtList, okRadio, okAudiusHosts, okAudius, okAudiusUser, okAudiusUserTracks,
    okAudiusLists, okAudiusList, okArchive, okArchiveItem, okServerPing, okServerAlbums, okServerAlbum,
    okServerLists, okServerList, okServerSearch, okServerRandom
  OReq = object
    kind: OKind
    key: string                          # (what it is for: an id, the words)
    rest: seq[string]                    # (the next servers to ask, when this one does not answer)
    job: Job[HttpResponse]

const KeepFile = "online.json"

var
  reqs: seq[OReq]
  onlineCover*: proc (url: string): Bitmap {.closure.}
    ## (set by the app: a cover from the network, fetched once)
  playYouTube*: proc (list: seq[Track]; at: int) {.closure.}
    ## (set by the app: YouTube's songs in YouTube's own player)
  ytFailed*: proc (words: string): bool {.closure.}
    ## (set by the app: no YouTube server answered a search -- true when it asks another way)
  onlineFetch*: proc (url: string): Job[HttpResponse] {.closure.}
    ## (nil: the network; the tests' canned answers -- the app's other GET requests too)
  ytOpened* = false                      ## (a link pasted in its box: its playlist open -- the app goes there)
  searchOnly* = false                    ## (Search's: the words from its own bar, the page's not drawn)
  searchTyped* = false                   ## (its words changed this frame)
  onlineNote* = ""                       ## (what went wrong, said once by the app)
  # YouTube Music
  ytWords* = ""
  ytKind* = 0                            ## Songs, Albums, Playlists
  ytAskedFor = ""
  ytFoundSongs*: seq[Track]
  ytFoundShelves*: seq[Shelf]
  ytShelfId* = ""                        ## (the playlist or album open)
  ytShelfName* = ""
  ytShelfSongs*: seq[Track]
  ytKept*: seq[Shelf]                    ## playlists and albums added by their links
  pipedOwn* = ""                         ## a Piped server of your own ("" the public ones)
  linkOpen, handleOpen, pipedOpen* = false
  linkText, handleText, pipedText = ""
  # radio
  radioWords* = ""
  radioKind* = 0                         ## Top, a genre's...
  radioAskedFor = ""
  stations*: seq[Station]
  favStations*: seq[Station]
  # Audius
  audiusHost = ""
  audiusWords* = ""
  audiusAskedFor = ""
  audiusFound*: seq[Song]
  audiusHandle* = ""
  audiusUserId = ""
  audiusUserName* = ""
  audiusUserSongs*: seq[Song]
  audiusLists*: seq[Shelf]
  audiusListId* = ""
  audiusListSongs*: seq[Song]
  # the Internet Archive
  archiveWords* = ""
  archiveKind* = 0
  archiveAskedFor = ""
  archiveFound*: seq[Shelf]
  archiveItemId* = ""
  archiveItemName* = ""
  archiveSongsNow*: seq[Song]
  # your server
  server*: Server
  serverOk* = 0                          ## 1 signed in, -1 it said no, 0 not tried
  serverAlbums*: seq[Shelf]
  serverLists*: seq[Shelf]
  serverSongs*: seq[Song]                ## (an album's, a playlist's, a search's, random ones)
  serverTitle* = ""
  serverWords* = ""
  serverAskedFor = ""
  urlOpen, userOpen, passOpen = false
  urlText, userText, passText = ""

const
  RadioKinds* = ["Top", "Pop", "Arabic", "Rock", "Jazz", "Classical", "News", "Quran", "Chill"]
  YtKinds* = ["Songs", "Albums", "Playlists"]

# ---- kept ----------------------------------------------------------------------------------------

proc keepPath(): string = dataDir("RetroMusic") / KeepFile

proc saveOnline*() =
  var lists = newJArray()
  for s in ytKept: lists.add %*{"id": s.id, "name": s.name, "owner": s.owner, "cover": s.cover}
  var favs = newJArray()
  for st in favStations:
    favs.add %*{"id": st.id, "name": st.name, "url": st.url, "favicon": st.favicon, "tags": st.tags,
                "country": st.country, "bitrate": st.bitrate}
  try:
    createDir(dataDir("RetroMusic"))
    writeFile(keepPath(), $(%*{"yt": lists, "stations": favs, "audius": audiusHandle, "piped": pipedOwn,
                               "server": server.url, "serverUser": server.user}))
  except CatchableError: discard
  discard saveSecret("RetroMusic", "server-password", server.password)

proc loadOnline*() =
  randomize()                            # (a server's salts, a station's server: not the same each time)
  try:
    let j = parseJson(readFile(keepPath()))
    ytKept.setLen(0)
    for s in j{"yt"}.getElems:
      ytKept.add Shelf(id: s{"id"}.getStr, name: s{"name"}.getStr, owner: s{"owner"}.getStr, cover: s{"cover"}.getStr)
    favStations.setLen(0)
    for s in j{"stations"}.getElems:
      favStations.add Station(id: s{"id"}.getStr, name: s{"name"}.getStr, url: s{"url"}.getStr,
                              favicon: s{"favicon"}.getStr, tags: s{"tags"}.getStr,
                              country: s{"country"}.getStr, bitrate: s{"bitrate"}.getInt)
    audiusHandle = j{"audius"}.getStr
    pipedOwn = j{"piped"}.getStr
    server.url = j{"server"}.getStr
    server.user = j{"serverUser"}.getStr
  except CatchableError: discard
  server.password = loadSecret("RetroMusic", "server-password")

# ---- requests: each server in turn -----------------------------------------------------------------

proc get(url: string): Job[HttpResponse] =
  if onlineFetch != nil: onlineFetch(url) else: fetch(url, timeoutSec = 20)

proc ask(kind: OKind; urls: seq[string]; key = "") =
  if urls.len == 0: return
  reqs.add OReq(kind: kind, key: key, rest: urls[1 .. ^1], job: get(urls[0]))

proc pipeds(): seq[string] =
  if pipedOwn.strip.len > 0: @[pipedOwn.strip(chars = {' ', '/'})] else: @PipedServers

proc ytAsk(kind: OKind; words: string; filter = "") =
  ## (YouTube through Piped's servers, then Invidious' -- songs only there)
  var urls: seq[string]
  for p in pipeds(): urls.add pipedSearchUrl(p, words, filter)
  if filter == "music_songs":
    for i in InvidiousServers: urls.add invidiousSearchUrl(i, words)
  ask(kind, urls, words & "\t" & $ytKind)     # (its answer kept while these are the words asked)

proc openYtList*(id, name: string) =
  ## A YouTube playlist's or album's songs, asked for.
  ytShelfId = id
  ytShelfName = name
  ytShelfSongs.setLen(0)
  var urls: seq[string]
  for p in pipeds(): urls.add pipedPlaylistUrl(p, id)
  for i in InvidiousServers: urls.add invidiousPlaylistUrl(i, id)
  ask(okYtList, urls, id)

proc radioAsk*() =
  let w = radioWords.strip
  var urls: seq[string]
  for s in RadioServers:
    urls.add(if w.len > 0: radioSearchUrl(s, w)
             elif radioKind == 0: radioTopUrl(s)
             else: radioTagUrl(s, RadioKinds[radioKind].toLowerAscii))
  ask(okRadio, urls)

proc audiusReady(): bool = audiusHost.len > 0

proc audiusAsk*() =
  if not audiusReady():
    if not reqs.anyIt(it.kind == okAudiusHosts): ask(okAudiusHosts, @[AudiusApi])
    return
  let w = audiusWords.strip
  ask(okAudius, @[if w.len > 0: audiusSearchUrl(audiusHost, w) else: audiusTrendingUrl(audiusHost)])

proc audiusOpenUser*() =
  if audiusHandle.strip.len == 0 or not audiusReady(): return
  ask(okAudiusUser, @[audiusUserUrl(audiusHost, audiusHandle)])

proc archiveAsk*() =
  let col = if archiveKind < ArchiveCollections.len: ArchiveCollections[archiveKind][1] else: ""
  ask(okArchive, @[archiveSearchUrl(archiveWords, col)])

proc openArchiveItem*(id, name: string) =
  archiveItemId = id
  archiveItemName = name
  archiveSongsNow.setLen(0)
  ask(okArchiveItem, @[archiveMetadataUrl(id)], id)

proc serverAsk(kind: OKind; meth: string; params: openArray[(string, string)] = []; key = "") =
  if not server.ready: return
  ask(kind, @[subsonicUrl(server, meth, params)], key)

proc serverSignIn*() =
  serverOk = 0
  serverAsk(okServerPing, "ping")

proc serverHome*() =
  serverAsk(okServerAlbums, "getAlbumList2", [("type", "newest"), ("size", "40")])
  serverAsk(okServerLists, "getPlaylists")

proc songsOfAudius(list: seq[tuple[id, title, artist, cover, genre: string; durationMs: int]]): seq[Song] =
  for t in list:
    result.add Song(path: audiusStreamUrl(audiusHost, t.id), title: t.title, artist: t.artist,
                    album: t.genre, durationMs: t.durationMs, coverUrl: t.cover, origin: "Audius")

proc pollOnline*() =
  ## Every frame: the answers that came (a server that did not answer: the next one asked).
  var i = 0
  while i < reqs.len:
    let r = reqs[i]
    if not r.job.ended:
      inc i
      continue
    reqs.delete(i)
    let resp = if r.job.done: r.job.value else: HttpResponse(error: r.job.error)
    let bad = resp.status == 0 or resp.status >= 500 or resp.status == 429 or
              (resp.status != 200 and r.kind in {okYtSongs, okYtShelves, okYtList}) or
              (resp.body.len > 0 and resp.body[0] == '<' and r.kind != okServerPing)
    if bad and r.rest.len > 0:
      reqs.add OReq(kind: r.kind, key: r.key, rest: r.rest[1 .. ^1], job: get(r.rest[0]))
      continue
    if (bad or resp.status >= 400) and r.kind == okYtSongs and ytFailed != nil and ytFailed(r.key.split('\t')[0]):
      continue
    if bad or resp.status >= 400:
      onlineNote = case r.kind
        of okYtSongs, okYtShelves, okYtList: "YouTube's servers did not answer -- try again, or set one in Settings > YouTube Music"
        of okRadio: "The radio directory did not answer -- is the phone online?"
        of okAudiusHosts, okAudius, okAudiusUser, okAudiusUserTracks, okAudiusLists, okAudiusList:
          (if r.kind == okAudiusUser: "Audius has no one called " & audiusHandle else: "Audius did not answer")
        of okArchive, okArchiveItem: "The Internet Archive did not answer"
        else: "Your server did not answer: " & (if resp.error.len > 0: resp.error else: $resp.status)
      if r.kind == okServerPing: serverOk = -1
      if r.kind == okYtSongs: ytFoundSongs.setLen(0)      # (not the songs of other words)
      if r.kind == okAudiusHosts and audiusHost.len == 0:
        audiusHost = AudiusHost                         # (its list of servers did not come: the known one)
      ui.redraw = true
      continue
    case r.kind
    of okYtSongs:
      if r.key == ytAskedFor:
        ytFoundSongs = pipedSongs(resp.body)
        if ytFoundSongs.len == 0: ytFoundSongs = invidiousSongs(resp.body)
    of okYtShelves:
      if r.key == ytAskedFor: ytFoundShelves = pipedShelves(resp.body)
    of okYtList:
      if r.key == ytShelfId:
        ytShelfSongs = pipedSongs(resp.body)
        var name = pipedPlaylistName(resp.body)
        if ytShelfSongs.len == 0:
          ytShelfSongs = invidiousSongs(resp.body)
          name = invidiousPlaylistName(resp.body)
        if name.len > 0 and ytShelfName.len == 0: ytShelfName = name
    of okRadio: stations = radioStations(resp.body)
    of okAudiusHosts:
      let hs = audiusHosts(resp.body)
      audiusHost = if hs.len > 0: sample(hs) else: AudiusHost
      audiusAsk()
      if audiusHandle.len > 0: audiusOpenUser()
    of okAudius: audiusFound = songsOfAudius(audiusTracks(resp.body))
    of okAudiusUser:
      let (id, name) = audiusUserId(resp.body)
      audiusUserId = id
      audiusUserName = name
      if id.len > 0:
        ask(okAudiusUserTracks, @[audiusUserTracksUrl(audiusHost, id)])
        ask(okAudiusLists, @[audiusUserPlaylistsUrl(audiusHost, id)])
    of okAudiusUserTracks: audiusUserSongs = songsOfAudius(audiusTracks(resp.body))
    of okAudiusLists: audiusLists = audiusPlaylists(resp.body)
    of okAudiusList:
      if r.key == audiusListId: audiusListSongs = songsOfAudius(audiusTracks(resp.body))
    of okArchive: archiveFound = archiveItems(resp.body)
    of okArchiveItem:
      if r.key == archiveItemId:
        let (title, creator) = archiveItemTitle(resp.body)
        if title.len > 0: archiveItemName = title
        archiveSongsNow.setLen(0)
        for f in archiveSongs(resp.body):
          archiveSongsNow.add Song(path: archiveFileUrl(r.key, f.name), title: f.title,
                                   artist: (if f.artist.len > 0: f.artist else: creator), album: archiveItemName,
                                   durationMs: f.durationMs, coverUrl: ArchiveApi & "/services/img/" & r.key,
                                   origin: "Internet Archive")
    of okServerPing:
      let e = subsonicError(resp.body)
      serverOk = if e.len == 0: 1 else: -1
      if e.len > 0: onlineNote = "Your server: " & e
      else: serverHome()
    of okServerAlbums: serverAlbums = subsonicAlbums(server, resp.body)
    of okServerLists: serverLists = subsonicPlaylists(resp.body)
    of okServerAlbum, okServerList, okServerSearch, okServerRandom:
      serverSongs.setLen(0)
      for t in subsonicSongs(server, resp.body):
        serverSongs.add Song(path: subsonicStreamUrl(server, t.id), title: t.title, artist: t.artist,
                             album: t.album, durationMs: t.durationMs, coverUrl: t.cover, origin: "My Server")
      if r.kind == okServerSearch:
        let a = subsonicAlbums(server, resp.body)
        if a.len > 0: serverAlbums = a
    ui.redraw = true
  if reqs.len > 0: wakeIn(100)

proc onlineLoading*(): bool = reqs.len > 0

# ---- the pages ------------------------------------------------------------------------------------

var typedAt = 0                           ## (when a search's words last changed: asked half a second after)

proc settled(changed: bool): bool =
  ## (a search box's words: asked for once the typing stops for half a second, or at Enter)
  if changed: typedAt = ui.now
  if ui.now - typedAt > 550 or keyHit(KeyEnter): true
  else:
    wakeIn(600)
    false

proc sourceNote(s: string) =
  ## (a line or two of gray text under the groups)
  for ln in wrapLines(s, cellRoom()):
    let r = place(0, FontH + dp(1), fill = true)
    text(r.x + (r.w - textWidth(ln)) div 2, r.y, ln, ui.theme.gray)

proc wordsBar(words: var string; hint: string): bool =
  ## (a page's search box -- in Search, its words come from Search's own)
  if searchOnly: searchTyped else: searchBar(words, hint)

proc nothingAsked(name, detail: string): bool =
  ## (Search with no words yet: what it searches)
  emptyState(nfSearch, "Search " & name, detail = detail)
  true

proc pic(url: string): Bitmap =
  if url.len > 0 and onlineCover != nil: onlineCover(url) else: nil

proc songList(list: seq[Song]; key: string; numbers = false) =
  ## (songs from the network in rows: a tap plays them from there)
  tableGroup(""):
    for n, s in list:
      let playing = localActive and currentPath() == s.path
      let h = tableRow((if numbers: $(n + 1) & ". " else: "") & s.title,
                       if playing: (if localPlaying: "playing" else: "paused")
                       elif s.durationMs > 0: clock(s.durationMs) else: "", taNone,
                       subtitle = s.artist, picture = (if numbers: nil else: pic(s.coverUrl)),
                       key = key & $n & s.path)
      if h.clicked: playRemote(list, n)

proc ytRows(list: seq[Track]; key: string) =
  tableGroup(""):
    for n, t in list:
      if tableRow(t.title, if t.durationMs > 0: clock(t.durationMs) else: "", taNone, subtitle = t.artist,
                  picture = pic(t.cover), key = key & $n & t.id).clicked:
        if playYouTube != nil: playYouTube(list, n)

proc keptYt(id: string): int =
  for i, s in ytKept:
    if s.id == id: return i
  -1

proc addYtLink*(link: string): bool =
  ## A YouTube or YouTube Music link pasted: its playlist (or album) kept in Library and opened;
  ## a song's alone played. False when it is not one.
  let l = youtubeLink(link)
  if l.list.len > 0:
    if keptYt(l.list) < 0:
      ytKept.add Shelf(id: l.list, name: "")
      saveOnline()
    openYtList(l.list, "")
    ytOpened = true
    return true
  if l.video.len > 0:
    if playYouTube != nil:
      playYouTube(@[Track(source: srcYouTube, id: l.video, uri: "https://music.youtube.com/watch?v=" & l.video,
                          title: "YouTube")], 0)
    return true
  false

proc pasteYtLink*(): bool =
  ## Paste a Link: the clipboard's YouTube link added (true), or the box to paste it in opened.
  let t = getClipboardText().strip
  if t.len > 0 and addYtLink(t): return true
  linkText = t
  linkOpen = true

proc youtubePage*(page: string; goTo: proc (page: string)) =
  ## YouTube Music with nothing to set up: search, your playlists and albums added by their
  ## links; "yt:list" the one open.
  if page == "yt:list":
    if ytShelfSongs.len == 0:
      emptyState(nfPlay, if ytShelfName.len > 0: ytShelfName else: "Its songs are on their way",
                 detail = if onlineLoading(): "" else: "Nothing in it, or YouTube's servers did not answer.")
    else:
      row:
        if button("Play", nfPlay, isDefault = true) and playYouTube != nil: playYouTube(ytShelfSongs, 0)
        if button("Shuffle", nfRandom) and playYouTube != nil:
          var l = ytShelfSongs
          l.shuffle()
          playYouTube(l, 0)
      ytRows(ytShelfSongs, "yl")
    let k = keptYt(ytShelfId)
    tableGroup(""):
      if k < 0:
        if tableButton("Keep in Library"):
          ytKept.add Shelf(id: ytShelfId, name: ytShelfName, cover: (if ytShelfSongs.len > 0: ytShelfSongs[0].cover else: ""))
          saveOnline()
      else:
        if ytKept[k].name.len == 0 and ytShelfName.len > 0:
          ytKept[k].name = ytShelfName
          if ytShelfSongs.len > 0: ytKept[k].cover = ytShelfSongs[0].cover
          saveOnline()
        if tableButton("Take Out of Library", destructive = true):
          ytKept.delete(k)
          saveOnline()
    return
  let typed = wordsBar(ytWords, "Songs, albums, artists")
  if segmented(YtKinds, ytKind): ytAskedFor = ""
  let w = ytWords.strip
  if searchOnly and w.len == 0 and nothingAsked("YouTube Music", "Its songs, albums and playlists."): return
  if w.len > 0 and w & "\t" & $ytKind != ytAskedFor and settled(typed):
    ytAskedFor = w & "\t" & $ytKind
    if ytKind == 0: ytAsk(okYtSongs, w, "music_songs")
    else: ytAsk(okYtShelves, w, if ytKind == 1: "music_albums" else: "music_playlists")
  if w.len > 0:
    if ytKind == 0:
      if ytFoundSongs.len > 0: ytRows(ytFoundSongs, "ys")
      elif onlineLoading(): emptyState(nfSearch, "Searching YouTube Music...")
    else:
      tableGroup(""):
        for n, s in ytFoundShelves:
          if tableRow(s.name, if s.count > 0: $s.count else: "", taChevron, subtitle = s.owner, picture = pic(s.cover),
                      key = "ysh" & $n & s.id).clicked:
            openYtList(s.id, s.name)
            goTo("yt:list")
    return
  tableGroup("Your YouTube Music", "Copy a playlist's or an album's link in YouTube Music (Share > Copy " &
                                   "link), then paste it here: it stays in Library. No account, no setup."):
    for s in ytKept:
      if tableRow(if s.name.len > 0: s.name else: "Playlist", "", taChevron, subtitle = s.owner,
                  picture = pic(s.cover), key = "yk" & s.id).clicked:
        openYtList(s.id, s.name)
        goTo("yt:list")
    if tableButton("Paste a Link") and pasteYtLink(): goTo("yt:list")
  sourceNote("Search and links go through Piped's public servers (Invidious' when they do not answer); " &
             "the songs play in YouTube's own player.")

proc stationSongs*(list: openArray[Station]): seq[Song] =
  ## Stations as songs of the app's player: live, their icon the cover.
  for s in list:
    result.add Song(path: s.url, title: s.name, artist: stationLine(s), album: s.country, coverUrl: s.favicon,
                    origin: "Radio", live: true)

proc radioPage*(page: string; goTo: proc (page: string)) =
  ## Radio stations: your favorites, then the top ones, a genre's, or those found by name.
  let typed = wordsBar(radioWords, "Stations, by name")
  if searchOnly and radioWords.strip.len == 0 and nothingAsked("the Radio", "Stations, by their names."): return
  if radioWords.strip.len == 0:
    let ck = radioKind
    var sel: seq[bool]
    for i in 0 ..< RadioKinds.len: sel.add i == radioKind
    let ch = chips(RadioKinds, sel)
    if ch.clicked >= 0: radioKind = ch.clicked
    if ck != radioKind: radioAskedFor = ""
  let want = radioWords.strip & "|" & $radioKind
  if want != radioAskedFor and settled(typed):
    radioAskedFor = want
    radioAsk()
  if favStations.len > 0 and radioWords.strip.len == 0:
    tableGroup("Your Stations"):
      let favs = stationSongs(favStations)
      for n, s in favStations:
        let h = tableRow(s.name, if localActive and currentPath() == s.url: "playing" else: "", taInfo,
                         subtitle = stationLine(s), picture = pic(s.favicon), key = "fs" & $n & s.url)
        if h.info:
          favStations.delete(n)
          saveOnline()
          break
        elif h.clicked: playRemote(favs, n)
  if stations.len == 0:
    emptyState(nfWifi, if onlineLoading(): "Tuning in..." else: "No stations found")
    return
  tableGroup(if radioWords.strip.len > 0: "Found" else: RadioKinds[radioKind],
             "The info button keeps a station in Your Stations (and takes it out again)."):
    let list = stationSongs(stations)
    for n, s in stations:
      var fav = false
      for f in favStations:
        if f.url == s.url: fav = true
      let h = tableRow(s.name, if fav: "kept" else: "", taInfo, subtitle = stationLine(s),
                       picture = pic(s.favicon), key = "st" & $n & s.url)
      if h.info:
        if fav:
          for k in countdown(favStations.high, 0):
            if favStations[k].url == s.url: favStations.delete(k)
        else: favStations.add s
        saveOnline()
      elif h.clicked: playRemote(list, n)

proc audiusPage*(page: string; goTo: proc (page: string)) =
  ## Audius: trending, a search, your handle's (or any artist's) tracks and playlists.
  if page == "audius:user":
    if audiusUserSongs.len > 0:
      label("Tracks", bold = true)
      songList(audiusUserSongs, "au")
    if audiusLists.len > 0:
      tableGroup("Playlists"):
        for n, l in audiusLists:
          if tableRow(l.name, if l.count > 0: $l.count else: "", taChevron, picture = pic(l.cover),
                      key = "al" & l.id).clicked:
            audiusListId = l.id
            audiusListSongs.setLen(0)
            ask(okAudiusList, @[audiusPlaylistTracksUrl(audiusHost, l.id)], l.id)
            goTo("audius:list")
    if audiusUserSongs.len == 0 and audiusLists.len == 0:
      emptyState(nfBolt, if onlineLoading(): "Asking Audius..." else: "Nothing there yet")
    return
  if page == "audius:list":
    if audiusListSongs.len == 0: emptyState(nfBolt, "Its tracks are on their way")
    else: songList(audiusListSongs, "aul", numbers = true)
    return
  let typed = wordsBar(audiusWords, "Tracks, artists")
  let want = audiusWords.strip
  if searchOnly and want.len == 0 and nothingAsked("Audius", "Its artists' tracks."): return
  if (want != audiusAskedFor or (audiusFound.len == 0 and not audiusReady())) and not onlineLoading() and
     settled(typed):
    audiusAskedFor = want
    audiusAsk()
  if not searchOnly:
    tableGroup("", "Free music its artists put on Audius whole. Your Audius handle (or an artist's) " &
                   "brings their tracks and playlists."):
      if tableRow(if audiusHandle.len > 0: "@" & audiusHandle else: "Your Audius",
                  if audiusHandle.len > 0: "" else: "Add", taChevron, glyph = nfUser,
                  tint = color(204, 31, 228)).clicked:
        if audiusHandle.len > 0:
          audiusOpenUser()
          goTo("audius:user")
        else:
          handleText = ""
          handleOpen = true
  if audiusFound.len == 0:
    emptyState(nfBolt, if onlineLoading(): "Asking Audius..." else: "Nothing found")
  else:
    label(if want.len > 0: "Found" else: "Trending", bold = true)
    songList(audiusFound, "af")

proc archivePage*(page: string; goTo: proc (page: string)) =
  ## The Internet Archive: live concerts, netlabels, old records; an item's songs.
  if page == "archive:item":
    if archiveSongsNow.len == 0:
      emptyState(nfArchive, if onlineLoading(): "Its songs are on their way" else: "No songs in it")
    else:
      row:
        if button("Play", nfPlay, isDefault = true): playRemote(archiveSongsNow, 0)
      songList(archiveSongsNow, "ai", numbers = true)
    return
  let typed = wordsBar(archiveWords, "Concerts, artists, records")
  if searchOnly and archiveWords.strip.len == 0 and
     nothingAsked("the Internet Archive", "Live concerts, netlabels, old records."): return
  if not searchOnly:
    var names: seq[string]
    for (n, _) in ArchiveCollections: names.add n
    var sel: seq[bool]
    for i in 0 ..< names.len: sel.add i == archiveKind
    let ch = chips(names, sel)
    if ch.clicked >= 0: archiveKind = ch.clicked
  let want = archiveWords.strip & "|" & $archiveKind
  if want != archiveAskedFor and settled(typed):
    archiveAskedFor = want
    archiveAsk()
  if archiveFound.len == 0:
    emptyState(nfArchive, if onlineLoading(): "Asking the Archive..." else: "Nothing found")
    return
  tableGroup(ArchiveCollections[archiveKind][0], "Free to hear: the Internet Archive's own."):
    for n, it in archiveFound:
      if tableRow(it.name, "", taChevron, subtitle = it.owner, picture = pic(it.cover), key = "ar" & it.id).clicked:
        openArchiveItem(it.id, it.name)
        goTo("archive:item")

proc serverPage*(page: string; goTo: proc (page: string)) =
  ## Your own server -- Navidrome, Airsonic, Gonic, any Subsonic one: its address, your name and
  ## password; then its newest albums, your playlists, random songs, a search.
  if not server.ready or serverOk == -1:
    tableGroup("Your Music Server", "Navidrome, Airsonic, Gonic, Ampache or any server that speaks " &
                                    "Subsonic: its address, your name and your password, as you sign " &
                                    "in to it in a browser."):
      if tableRow("Address", if server.url.len > 0: server.url else: "https://music.example.com", taChevron).clicked:
        urlText = server.url
        urlOpen = true
      if tableRow("Name", server.user, taChevron).clicked:
        userText = server.user
        userOpen = true
      if tableRow("Password", if server.password.len > 0: "set" else: "", taChevron).clicked:
        passText = ""
        passOpen = true
      if tableButton("Sign In", enabled = server.ready):
        saveOnline()
        serverSignIn()
    if serverOk == -1: label("It said no: check the address, the name and the password.", color = badColor())
    return
  if serverOk == 0 and not onlineLoading(): serverSignIn()
  case page
  of "server:songs":
    if serverSongs.len == 0: emptyState(nfServer, "Its songs are on their way")
    else:
      row:
        if button("Play", nfPlay, isDefault = true): playRemote(serverSongs, 0)
        if button("Shuffle", nfRandom):
          var l = serverSongs
          l.shuffle()
          playRemote(l, 0)
      songList(serverSongs, "ss", numbers = true)
    return
  else: discard
  let typed = wordsBar(serverWords, "Songs, albums, artists")
  let w = serverWords.strip
  if searchOnly and w.len == 0 and nothingAsked("Your Server", "Its songs, albums and artists."): return
  if w.len > 0 and w != serverAskedFor and settled(typed):
    serverAskedFor = w
    serverAsk(okServerSearch, "search3", [("query", w), ("songCount", "50"), ("albumCount", "20")])
  if w.len > 0:
    if serverSongs.len > 0: songList(serverSongs, "sr")
    return
  tableGroup(""):
    if tableRow("Random Songs", "", taChevron, glyph = nfRandom, tint = color(30, 160, 90)).clicked:
      serverTitle = "Random Songs"
      serverSongs.setLen(0)
      serverAsk(okServerRandom, "getRandomSongs", [("size", "50")])
      goTo("server:songs")
  if serverLists.len > 0:
    tableGroup("Playlists"):
      for l in serverLists:
        if tableRow(l.name, if l.count > 0: $l.count else: "", taChevron, key = "sl" & l.id).clicked:
          serverTitle = l.name
          serverSongs.setLen(0)
          serverAsk(okServerList, "getPlaylist", [("id", l.id)])
          goTo("server:songs")
  if serverAlbums.len > 0:
    tableGroup("Newest Albums"):
      for a in serverAlbums:
        if tableRow(a.name, if a.count > 0: $a.count else: "", taChevron, subtitle = a.owner, picture = pic(a.cover),
                    key = "sa" & a.id).clicked:
          serverTitle = a.name
          serverSongs.setLen(0)
          serverAsk(okServerAlbum, "getAlbum", [("id", a.id)])
          goTo("server:songs")
  tableGroup(""):
    if tableButton("Sign Out", destructive = true):
      server.password = ""
      serverOk = 0
      serverAlbums.setLen(0)
      serverLists.setLen(0)
      saveOnline()

proc onlineTitle*(page: string): string =
  case page
  of "yt:list": "Playlist"
  of "audius:user": (if audiusUserName.len > 0: audiusUserName else: "@" & audiusHandle)
  of "audius:list": "Playlist"
  of "archive:item": (if archiveItemName.len > 0: archiveItemName else: "Recording")
  of "server:songs": serverTitle
  else: ""

proc askPiped*() =
  ## (Settings: the box for a Piped server of your own)
  pipedText = pipedOwn
  pipedOpen = true

proc onlineDialogs*() =
  ## (their dialogs: a link, a handle, the server's address, name and password)
  if linkOpen and inputBox(linkOpen, "A YouTube Music Link", "A playlist's or an album's link (Share > Copy link):",
                           linkText) == 1:
    if not addYtLink(linkText): onlineNote = "That isn't a YouTube playlist's or album's link"
  if handleOpen and inputBox(handleOpen, "Your Audius", "Your Audius handle (or an artist's):", handleText) == 1:
    audiusHandle = handleText.strip(chars = {' ', '@'})
    saveOnline()
    audiusOpenUser()
  if urlOpen and inputBox(urlOpen, "Your Server", "Its address (https://...):", urlText) == 1:
    server.url = urlText.strip
    serverOk = 0
    saveOnline()
  if userOpen and inputBox(userOpen, "Your Server", "Your name on it:", userText) == 1:
    server.user = userText.strip
    serverOk = 0
    saveOnline()
  if pipedOpen and inputBox(pipedOpen, "A Piped Server", "Its address (https://...), or nothing for the " &
                           "public ones:", pipedText) == 1:
    pipedOwn = pipedText.strip
    saveOnline()
  if passOpen and inputBox(passOpen, "Your Server", "Your password on it:", passText, password = true) == 1:
    server.password = passText
    serverOk = 0
    saveOnline()

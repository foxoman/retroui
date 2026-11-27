## Tests of Retro Music's free sources (examples/music/sources, online): what YouTube Music's
## servers (Piped's, Invidious'), Radio Browser, Audius, the Internet Archive and a Subsonic
## server say, read; a YouTube link's playlist and song; the Subsonic token -- and the app with
## them, its answers made up (tests/musicanswers.nim): a search with each, a server that does not
## answer and the next one asked, a playlist kept by its link, a station kept and played, an
## artist's Audius, an Archive recording, your server signed in and its "no"; Search over them;
## the side menu on a phone (its button, a place chosen, a tap beside it); the places down the
## left on a tablet; the player's Now Playing on both; every place in every look.

import std/[os, strutils, sequtils]
import retroui
import retroui/uirelays/[services, coords, screen, input]
import ../examples/music/[api, sources, screens, local]
import harness, musicanswers

let home = getTempDir() / "retro-musicsources"
removeDir(home)
createDir(home)
putEnv("HOME", home)
putEnv("XDG_DATA_HOME", home / ".local" / "share")
putEnv("XDG_CONFIG_HOME", home / ".config")
putEnv("RETRO_TOUCH", "1")

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

# ---- what they say, read -----------------------------------------------------------------------------

let ps = pipedSongs(PipedSongsBody)
check ps.len == 3 and ps[0].id == "vidHarbour1" and ps[0].artist == "Harbour" and ps[0].durationMs == 214000,
      "Piped's songs: a channel left out, an artist's Topic channel the artist"
check ps[0].source == srcYouTube and ps[0].uri == "https://music.youtube.com/watch?v=vidHarbour1",
      "a Piped song plays in YouTube's player"
let sh = pipedShelves(PipedShelvesBody)
check sh.len == 1 and sh[0].id == "OLAK5uy_harbour" and sh[0].count == 9, "Piped's albums: the list's id"
check pipedSongs(PipedListBody).len == 2 and pipedPlaylistName(PipedListBody) == "Harbour", "a Piped playlist"
let iv = invidiousSongs(InvidiousSongsBody)
check iv.len == 1 and iv[0].id == "vidInv1" and iv[0].cover == "m.jpg" and iv[0].durationMs == 251000,
      "Invidious' songs: the medium thumbnail"
check invidiousSongs(InvidiousListBody).len == 1 and invidiousPlaylistName(InvidiousListBody) == "Roads",
      "an Invidious playlist"
check pipedSongs("not json").len == 0 and radioStations("<html>").len == 0 and audiusTracks("").len == 0,
      "nonsense answers: nothing"
check youtubeLink("https://music.youtube.com/playlist?list=OLAK5uy_abc").list == "OLAK5uy_abc",
      "a YouTube Music album's link"
check youtubeLink("https://youtu.be/dQw4w9WgXcQ?si=x").video == "dQw4w9WgXcQ", "a short link's song"
let both = youtubeLink("https://www.youtube.com/watch?v=v1&list=PLx&index=3")
check both.video == "v1" and both.list == "PLx", "a song in a playlist"
check youtubeLink("https://music.youtube.com/browse/VLPLabc").list == "PLabc", "a playlist's browse link"
check youtubeLink("PLabc123").list == "PLabc123" and youtubeLink("https://example.com/watch?v=x").video == "",
      "a bare playlist id; another site's link: nothing"
let st = radioStations(RadioBody)
check st.len == 2 and st[0].name == "Coast FM" and st[0].url == "http://coast.test/live.mp3",
      "stations: the resolved address, names trimmed, one with none left out"
check st[1].url == "https://jazz.test/aac" and stationLine(st[0]) == "Oman -- pop, arabic -- 128 kbps",
      "a station's line"
check audiusHosts(AudiusHostsBody) == @["https://audius.test"], "Audius' servers"
let at = audiusTracks(AudiusTracksBody)
check at.len == 2 and at[0].artist == "Dunes" and at[0].durationMs == 201000 and at[0].cover.len > 0,
      "Audius' tracks: one that can't be streamed left out"
check audiusUserId(AudiusUserBody) == ("uDunes", "Dunes") and audiusPlaylists(AudiusListsBody)[0].count == 4,
      "an Audius artist and their playlists"
check audiusStreamUrl("https://h", "aT1") == "https://h/v1/tracks/aT1/stream?app_name=RetroMusic", "a stream"
let ai = archiveItems(ArchiveSearchBody)
check ai.len == 2 and ai[1].owner == "Someone" and ai[0].cover == "https://archive.org/services/img/hall1977",
      "the Archive's items: a creator from a list, the item's picture"
let af = archiveSongs(ArchiveItemBody)
check af.len == 3 and af[0].title == "First" and af[1].title == "Second" and af[2].title == "Third",
      "an item's songs: its MP3s in track order, a missing title its file's name"
check af[0].durationMs == 225400 and af[1].durationMs == 225000 and af[2].durationMs == 3723000,
      "lengths in seconds and in minutes"
check archiveFileUrl("hall1977", "set/01 First.mp3") == "https://archive.org/download/hall1977/set/01%20First.mp3",
      "a file's address"
let srv = Server(url: "music.test/", user: "sultan", password: "sesame")
let u = subsonicUrl(srv, "ping", salt = "abc123")
check u.startsWith("https://music.test/rest/ping.view?u=sultan&t=7600940f0a03c5bd5564126c7cd9080e&s=abc123"),
      "Subsonic: the password's salted MD5, never the password (" & u & ")"
check "sesame" notin u and "&f=json" in u, "the password not in the address"
check subsonicError(SubsonicPingBody) == "" and subsonicError(SubsonicWrongBody) == "Wrong username or password",
      "the server's yes and no"
check subsonicError("<html>") == "not a Subsonic server's answer", "a page that isn't a server's"
check subsonicSongs(srv, SubsonicAlbumBody).len == 2 and subsonicAlbums(srv, SubsonicAlbumsBody).len == 2,
      "an album's songs, the newest albums"
check "getCoverArt.view" in subsonicAlbums(srv, SubsonicAlbumsBody)[0].cover and
      subsonicPlaylists(SubsonicListsBody)[0].name == "Drive", "a cover's address; your playlists"

# ---- the app, its answers made up ------------------------------------------------------------------

var winW = 390
var winH = 760
var shot = newSeq[uint32](winW * winH)
var calls: seq[string]
var state = "0\t0\t0\t0"
systemRelays.call = proc (name, arg: string): string {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    calls.add name & "|" & arg
    case name
    of "media.videoState": state
    of "media.videoShow":
      state = "1\t0\t0\t0"
      "1"
    else: "1"
fakeDriver()
windowRelays.createWindow = proc (l: var ScreenLayout; icon: pointer; iconLen: int) =
  l.width = winW; l.height = winH; l.scaleX = 1; l.scaleY = 1; l.uiScale = 100
windowRelays.getWindowLayout = proc (): ScreenLayout =
  ScreenLayout(width: winW, height: winH, scaleX: 1, scaleY: 1, uiScale: 100)
drawRelays.blitRGBA = proc (p: ptr UncheckedArray[uint32]; w, h: int; dst: Rect; f: RGBAFormat): bool =
  for y in 0 ..< h:
    for x in 0 ..< w:
      if dst.y + y < winH and dst.x + x < winW: shot[(dst.y + y) * winW + dst.x + x] = p[y * w + x]
  true
onlineFetch = cannedFetch
startApp("musicsources", winW, winH)
mediaThroughSystem = true
accessKeep = true
loadSettings()
view = proc () = musicView()
run(2)

proc settle(frames = 40) =
  ## (frames, time going on: a search's words asked after half a second, the answers in)
  for _ in 0 ..< frames:
    ticks += 30
    run(1)
    os.sleep(1)

let shots = getEnv("MUSICSHOTS")
proc save(name: string) =
  ## (MUSICSHOTS=folder: the screen as a picture, to look at)
  if shots.len == 0: return
  var b = newBitmap(winW, winH)
  for i in 0 ..< winW * winH: b.px[i] = 0xFF000000'u32 or shot[i]
  createDir(shots)
  writeFile(shots / name & ".png", encodePng(b))

proc tapNode(name: string; roles: set[AccessRole] = {}) =
  let n = findNode(accessLast, name, roles)
  doAssert n >= 0, "no " & name & " on the screen"
  click(nodeRect(accessLast[n]), dx = nodeRect(accessLast[n]).w div 2)
  settle(4)

proc has(name: string; roles: set[AccessRole] = {}): bool = findNode(accessLast, name, roles) >= 0

proc holdNode(name: string; roles: set[AccessRole] = {}) =
  ## (a right click: a finger held)
  let n = findNode(accessLast, name, roles)
  doAssert n >= 0, "no " & name & " on the screen"
  let r = nodeRect(accessLast[n])
  harness.queue.add Event(kind: MouseMoveEvent, x: r.x + r.w div 2, y: r.y + r.h div 2)
  harness.queue.add Event(kind: MouseDownEvent, x: r.x + r.w div 2, y: r.y + r.h div 2, button: RightButton)
  harness.queue.add Event(kind: MouseUpEvent, x: r.x + r.w div 2, y: r.y + r.h div 2, button: RightButton)
  settle(4)

check isCompact(), "a phone's window"
save("phone-home")
# the side menu: its button at Home, a place chosen in it
tapNode("Menu", {arButton})
check menuOpen, "the navigation bar's menu button: the side menu out"
settle(10)
save("phone-menu")
tapNode("Radio", {arButton})
check tab == SecRadio and not menuOpen, "a place in the menu: it, the menu in"
settle()
check stations.len == 2, "Radio: the top stations asked and come"
save("phone-radio")
tapNode("Menu", {arButton})
settle(10)
click(rect(winW - 30, winH div 2, 10, 10))
settle(10)
check not menuOpen and tab == SecRadio, "a tap beside the menu: in again, the page as it was"
tapNode("Menu", {arButton})
key(KeyEsc)
settle(10)
check not menuOpen, "Esc (the phone's Back): the menu in"

# the radio: a station kept, played -- live, in our player
favStations.add stations[0]
saveOnline()
playRemote(stationSongs(favStations), 0)
settle(6)
check localActive and currentSong().live and currentPath() == "http://coast.test/live.mp3",
      "a station tapped: our player plays its stream, live"
nowOpen = true
settle(6)
check nowOpen, "Now Playing"
save("phone-nowplaying")
nowOpen = false
favStations.setLen(0)
loadOnline()
check favStations.len == 1 and favStations[0].name == "Coast FM", "your stations kept and read back"

# YouTube Music: a search (Piped), its albums, a playlist; a server down, the next asked
goSection(SecYouTube)
ytWords = "harbour"
settle()
check ytFoundSongs.len == 3, "YouTube Music: songs found through Piped (" & $ytFoundSongs.len & ")"
save("phone-youtube")
ytKind = 1
settle()
check ytFoundShelves.len == 1 and ytFoundShelves[0].name == "Harbour", "its albums"
openYtList(ytFoundShelves[0].id, ytFoundShelves[0].name)
onlinePage = "yt:list"
settle()
check ytShelfSongs.len == 2 and pageTitle() == "Harbour", "an album's songs, its name the page's"
save("phone-ytlist")
goSection(SecYouTube)
ytKind = 0
downServers = @PipedServers
asked.setLen(0)
ytWords = "night drive"
settle()
check ytFoundSongs.len == 1 and ytFoundSongs[0].id == "vidInv1",
      "Piped's servers not answering: Invidious' asked, its songs"
var piped = 0
for a in asked:
  if "/search?q=night" in a and "/api/v1/" notin a: inc piped
check piped == PipedServers.len, "each Piped server asked once, in turn"
downServers = @PipedServers & @InvidiousServers
ytWords = "nothing answers"
settle()
check ytFoundSongs.len == 0 and onlineNote.len == 0, "no server answering: nothing shown, the note said once"
downServers.setLen(0)
ytWords = ""
# a playlist's link pasted: kept in Library, opened
putClipboardText("https://music.youtube.com/playlist?list=OLAK5uy_roads&si=abc")
goSection(2)
settle(4)
tapNode("Paste a Link", {arButton})
settle()
check ytKept.len == 1 and ytKept[0].id == "OLAK5uy_roads" and tab == SecYouTube and onlinePage == "yt:list",
      "a playlist's link pasted (Library): kept, and opened in YouTube Music"
settle()
check ytKept[0].name.len > 0, "its name kept once its songs came"
ytKept.setLen(0)
loadOnline()
check ytKept.len == 1, "kept in a file"
# Audius: its servers, what trends, an artist
goSection(SecAudius)
settle()
check audiusFound.len == 2, "Audius: its servers asked, then what trends"
audiusHandle = "dunes"
audiusOpenUser()
onlinePage = "audius:user"
settle()
check audiusUserName == "Dunes" and audiusUserSongs.len == 2 and audiusLists.len == 1,
      "an artist's handle: their tracks and playlists"
save("phone-audius")
playRemote(audiusUserSongs, 0)
settle(4)
check currentPath() == "https://audius.test/v1/tracks/aT1/stream?app_name=RetroMusic" and not currentSong().live,
      "an Audius track in our player"
# the Internet Archive
goSection(SecArchive)
settle()
check archiveFound.len == 2, "the Archive: its items"
openArchiveItem(archiveFound[0].id, archiveFound[0].name)
onlinePage = "archive:item"
settle()
check archiveSongsNow.len == 3 and archiveSongsNow[0].album == "Live at the Hall, 1977", "a recording's songs"
save("phone-archive")
# your server: its "no", then signed in
goSection(SecServer)
settle(4)
save("phone-server-empty")
server = Server(url: "music.test", user: "sultan", password: "wrong")
serverWrong = true
serverSignIn()
settle()
check serverOk == -1, "the server's no: the fields again"
serverWrong = false
server.password = "sesame"
serverSignIn()
settle()
check serverOk == 1 and serverAlbums.len == 2 and serverLists.len == 1,
      "signed in: the newest albums, your playlists"
save("phone-server")
saveOnline()
server.password = ""
loadOnline()
check server.password == "sesame" and server.user == "sultan", "the server kept, its password with the secrets"
var sawPassword = false
for a in asked:
  if "sesame" in a: sawPassword = true
check not sawPassword, "the password never in an address"
# Search over them
goSection(1)
query = "harbour"
searchSource = 0
settle()
check ytFoundSongs.len == 3, "Search, YouTube Music: Search's words, YouTube's songs"
save("phone-search")
searchSource = 2
settle()
check stations.len == 2, "Search, Radio"
searchSource = 5
settle()
check serverSongs.len == 1 and serverSongs[0].title == "Found", "Search, My Server: its songs found"
query = ""

# ---- TV: the free channels' list, a channel played, its sound on when left ------------------------------

let chs = parseM3u(TvBody)
check chs.len == 3 and chs[0].name == "Sea One HD" and chs[0].logo == "https://img.test/sea.png" and
      chs[0].country == "Oman" and chs[0].url == "https://tv.test/sea/index.m3u8",
      "an M3U list read: its name, logo, country, address"
check chs[1].name == "Dune, Live" and chs[1].geo, "a name with a comma; Free-TV's mark: in its country only"
check chs.allIt("youtube" notin it.url), "a YouTube page left out: no stream in it"
check countries(chs) == @[(name: "Oman", count: 2), (name: "Norway", count: 1)], "its countries, in order"
check findChannels(chs, "fjord").len == 1 and findChannels(chs, "oman live").len == 1, "a search over them"
tvFavs.setLen(0)
goSection(SecTV)
settle()
check tvState == 2 and tvChannels.len == 3, "TV: the list asked and come"
save("phone-tv")
tapNode("Oman", {arButton, arListItem})
check tvPage == "c:Oman" and pageTitle() == "Oman", "a country tapped: its channels"
holdNode("Sea One HD")
check tvFavs.len == 1 and tvFavs[0].url == chs[0].url, "a channel held: in Your Channels"
calls.setLen(0)
tapNode("Dune, Live", {arButton, arListItem})
settle(6)
check tvOpen and calls.anyIt(it.startsWith("media.videoShow|tv\t") and "https://tv.test/dune.m3u8" in it),
      "a channel tapped: played on the screen"
save("phone-tvplayer")
tapNode("The channel before", {arButton})
settle(4)
check calls.anyIt("https://tv.test/sea/index.m3u8" in it), "the channel before: the list's one before"
calls.setLen(0)
tapNode("Full Screen", {arButton})
settle(4)
check "media.videoFull|tv\t1" in calls and has("Leave Full Screen", {arButton}) and not has("Done", {arButton}),
      "Full Screen: the phone on its side, the picture the whole screen, no bars"
check calls.anyIt(it.startsWith("media.videoShow|tv\t0\t0\t" & $winW & "\t" & $winH & "\t")),
      "... the picture as big as the window"
save("phone-tvfull")
tapNode("Leave Full Screen", {arButton})
settle(4)
check "media.videoFull|tv\t0" in calls and has("Done", {arButton}), "a tap: as it was"
tapNode("Done", {arButton})
settle(4)
check not tvOpen and localActive and currentSong().live and currentSong().origin == "TV" and
      currentPath() == "https://tv.test/sea/index.m3u8", "Done while it plays: its sound goes on in our player"
pauseLocal()
loadTv()
check tvFavs.len == 1, "Your Channels kept"
goSection(0)

# every place, every look, on the phone
for look in [lookClassic, lookGlass, lookMatte, lookGloss]:
  uiLook = look
  for t in 0 .. 10:
    goSection(t)
    settle(3)
    if look == lookGloss: save("gloss-" & $t)
  menuOpen = true
  settle(12)
  if look in [lookGloss, lookGlass]: save("menu-" & $look)
  menuOpen = false
  nowOpen = true
  settle(3)
  nowOpen = false
uiLook = lookGloss
check true, "every place drawn in every look on a phone"

# ---- a tablet: the places down the left, the page beside -------------------------------------------

winW = 1024
winH = 768
shot = newSeq[uint32](winW * winH)
harness.queue.add Event(kind: WindowResizeEvent, x: winW, y: winH)
settle(4)
check not isCompact(), "a tablet's window"
goSection(SecRadio)
settle()
save("tablet-radio")
tapNode("Internet Archive", {arButton})
check tab == SecArchive, "the column's place tapped: its page beside"
settle()
save("tablet-archive")
nowOpen = true
settle(4)
save("tablet-nowplaying")
nowOpen = false
for look in [lookClassic, lookGlass, lookMatte, lookGloss]:
  uiLook = look
  for t in 0 .. 10:
    goSection(t)
    settle(3)
  nowOpen = true
  settle(3)
  nowOpen = false
uiLook = lookClassic
check true, "every place drawn in every look on a tablet"

# ---- a music video's picture; artwork made for a song with no cover --------------------------------------

let vdir = home / "videos"
createDir(vdir)
proc fakeMp4(name, handler: string): string =
  ## (an MP4's start: its kind, a track's handler -- "vide" a picture's, "soun" sound's)
  result = vdir / name
  writeFile(result, "\0\0\0\x18ftypisom" & repeat('\0', 12) & "\0\0\0\x2Dhdlr" & repeat('\0', 8) & handler &
                    repeat('\0', 3000))
let clip = fakeMp4("clip.mp4", "vide")
check isVideo(clip) and not isVideo(fakeMp4("song.mp4", "soun")) and not isVideo(vdir / "none.mp4"),
      "an MP4 with a picture: a video; with sound alone, a song"
calls.setLen(0)
playSongs([clip], 0)
nowOpen = true
settle(6)
check calls.anyIt(it.startsWith("media.videoShow|" & VideoKey)), "a video playing: its picture on Now Playing"
nowOpen = false
goSection(0)
settle(6)
check calls.anyIt(it.startsWith("media.videoClose|" & VideoKey)), "Now Playing left: the picture let go, the sound on"
pauseLocal()
var artAt: Rect
var artSong = Song(title: "Evening Tide", artist: "Sultan Trio", album: "Muscat Nights")
view = proc () =
  artAt = place(0, 300, fill = true)
  drawArtwork(artAt, artSong)
run(2)
let artPx = shot[(artAt.y + 20) * winW + artAt.x + 6]
artSong.title = "Desert Road"
run(2)
let samePx = shot[(artAt.y + 20) * winW + artAt.x + 6]
artSong.album = "Another Album"
run(2)
check artPx == samePx and shot[(artAt.y + 20) * winW + artAt.x + 6] != artPx,
      "artwork: an album's songs the same colors, another album's other ones"
view = proc () = musicView()
echo "musicsources: ", passed, " ok"

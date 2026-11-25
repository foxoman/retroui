## Tests of Retro Music (examples/music): Spotify's answers read (a search, a playlist's items,
## your playlists, the devices, what plays), YouTube's (a search, its HTML entities; your
## playlists, a playlist's songs, the ones you like, lengths; the player's page), LrcLib's
## timed lines (LRC, several times a line, the line at a time), the requests' bodies -- and its
## screens drawn with no account, in every look, on a phone and a computer.

import std/[json, strutils]
import retroui
import ../examples/music/[api, screens]
import harness

# ---- Spotify -------------------------------------------------------------------------------------

let search = """{"tracks": {"items": [
  {"id": "t1", "uri": "spotify:track:t1", "name": "Ya Salam", "duration_ms": 187000,
   "artists": [{"name": "Balqees"}, {"name": "Guest"}],
   "album": {"name": "Arabian Nights", "images": [{"url": "big", "width": 640}, {"url": "mid", "width": 300},
             {"url": "tiny", "width": 64}]}},
  {"id": "t2", "uri": "spotify:track:t2", "name": "Two", "duration_ms": 60000, "artists": [], "album": {}}]}}"""
let ts = spotifyTracks(search)
doAssert ts.len == 2 and ts[0].title == "Ya Salam" and ts[0].artist == "Balqees, Guest"
doAssert ts[0].album == "Arabian Nights" and ts[0].cover == "tiny" and ts[0].durationMs == 187000
doAssert ts[0].source == srcSpotify and ts[0].uri == "spotify:track:t1"
let items = """{"items": [{"track": {"id": "a", "uri": "spotify:track:a", "name": "A", "artists": [{"name": "X"}]}},
                          {"track": null}, {"track": {"id": "b", "uri": "", "name": "local file"}}]}"""
doAssert spotifyTracks(items).len == 1, "a playlist's items: a missing track and a local file left out"
let pls = spotifyPlaylists("""{"items": [{"id": "p", "uri": "spotify:playlist:p", "name": "Drive",
  "owner": {"display_name": "Sultan"}, "images": [{"url": "c", "width": 300}], "tracks": {"total": 42}}]}""")
doAssert pls.len == 1 and pls[0].owner == "Sultan" and pls[0].count == 42 and pls[0].cover == "c"
let ds = spotifyDevices("""{"devices": [{"id": "d1", "name": "Pixel", "type": "Smartphone", "is_active": true,
                                          "volume_percent": 70}, {"id": "d2", "name": "Den", "type": "Speaker"}]}""")
doAssert ds.len == 2 and ds[0].active and ds[0].volume == 70 and not ds[1].active
let pb = spotifyPlayback("""{"is_playing": true, "progress_ms": 61000, "shuffle_state": false,
  "repeat_state": "off", "device": {"id": "d1", "name": "Pixel", "type": "Smartphone", "is_active": true},
  "item": {"id": "t1", "uri": "spotify:track:t1", "name": "Ya Salam", "duration_ms": 187000,
           "artists": [{"name": "Balqees"}], "album": {"name": "AN", "images": []}}}""")
doAssert pb.playing and pb.progressMs == 61000 and pb.track.title == "Ya Salam" and pb.device.name == "Pixel"
doAssert not spotifyPlayback("").playing, "nothing plays: an empty answer"
doAssert parseJson(playBody(["spotify:track:a", "spotify:track:b"], offset = 1))["offset"]["position"].getInt == 1
doAssert parseJson(playBody(context = "spotify:playlist:p"))["context_uri"].getStr == "spotify:playlist:p"
doAssert parseJson(transferBody("d2"))["device_ids"][0].getStr == "d2"
doAssert searchUrl("ya salam") == SpotifyApi & "/search?q=ya%20salam&type=track&limit=20"

# ---- YouTube -------------------------------------------------------------------------------------

let vids = youtubeVideos("""{"items": [{"id": {"kind": "youtube#video", "videoId": "v1"},
  "snippet": {"title": "Tom &amp; Jerry&#39;s song", "channelTitle": "Music",
              "thumbnails": {"medium": {"url": "m.jpg"}}}}, {"id": {"kind": "youtube#channel"}}]}""")
doAssert vids.len == 1 and vids[0].title == "Tom & Jerry's song" and vids[0].cover == "m.jpg"
doAssert vids[0].source == srcYouTube and vids[0].uri.endsWith("v=v1")
doAssert "videoCategoryId=10" in youtubeSearchUrl("x y", "KEY") and "q=x%20y" in youtubeSearchUrl("x y", "KEY")
doAssert "key=" notin youtubeSearchUrl("x", ""), "signed in: no key, the token instead"
# signed in with Google: your playlists (YouTube Music's), a playlist's songs, the ones you like
let ypl = youtubePlaylists("""{"nextPageToken": "N2", "items": [{"kind": "youtube#playlist", "id": "PL1",
  "snippet": {"title": "Drive &amp; Ride", "channelTitle": "Sultan", "thumbnails": {"medium": {"url": "p.jpg"}}},
  "contentDetails": {"itemCount": 27}}]}""")
doAssert ypl.len == 1 and ypl[0].id == "PL1" and ypl[0].name == "Drive & Ride" and ypl[0].count == 27 and
         ypl[0].cover == "p.jpg"
doAssert nextPage("""{"nextPageToken": "N2", "items": []}""") == "N2" and nextPage("{}") == ""
let yitems = youtubeVideos("""{"items": [
  {"kind": "youtube#playlistItem", "snippet": {"title": "Ya Salam", "videoOwnerChannelTitle": "Balqees - Topic",
   "thumbnails": {"default": {"url": "d.jpg"}}}, "contentDetails": {"videoId": "vA"}},
  {"kind": "youtube#playlistItem", "snippet": {"title": "Deleted video"}, "contentDetails": {"videoId": "vB"}}]}""")
doAssert yitems.len == 1 and yitems[0].id == "vA" and yitems[0].artist == "Balqees" and yitems[0].cover == "d.jpg",
         "a playlist's songs: a deleted one left out, an artist's Topic channel as the artist"
let yliked = youtubeVideos("""{"items": [{"kind": "youtube#video", "id": "vL",
  "snippet": {"title": "Liked", "channelTitle": "C"}, "contentDetails": {"duration": "PT3M27S"}}]}""")
doAssert yliked.len == 1 and yliked[0].id == "vL" and yliked[0].durationMs == 207000
doAssert youtubeDuration("PT1H2M3S") == 3723000 and youtubeDuration("PT45S") == 45000
doAssert "mine=true" in myPlaylistsUrl() and "pageToken=N2" in myPlaylistsUrl("N2")
doAssert "playlistId=PL1" in playlistItemsUrl("PL1") and "myRating=like" in likedVideosUrl()
# YouTube's player in the app: its page from the app's address, the song in it, what it tells
let pg = playerPage("vA", AppOrigin & "/")
doAssert pg.startsWith("html:") and "videoId:'vA'" in pg and "origin:'https://net.foxoman.retromusic'" in pg and
         "iframe_api" in pg and "retro.post" in pg

# ---- lyrics ---------------------------------------------------------------------------------------

let lines = parseLrc("[ar:Someone]\n[00:12.50]First\n[00:20.00][01:05.00]Chorus\n[00:30.10]Third\nno time")
doAssert lines.len == 4, $lines
doAssert lines[0] == (12500, "First") and lines[1] == (20000, "Chorus") and lines[3] == (65000, "Chorus")
doAssert lineAt(lines, 5000) == -1 and lineAt(lines, 12500) == 0 and lineAt(lines, 25000) == 1
doAssert lineAt(lines, 99999) == 3
let ly = lyricsOf("""{"syncedLyrics": "[00:01.00]Hi", "plainLyrics": "Hi"}""")
doAssert ly.synced.len == 1 and ly.plain == "Hi"
doAssert lyricsUrl(Track(title: "A B", artist: "C", durationMs: 187000)).endsWith("duration=187")
doAssert clock(187000) == "3:07" and clock(5000) == "0:05"

# ---- its screens, with no account: every page, every look, a phone and a computer --------------

fakeDriver()
startApp("music", W, H)
var frames = 0
view = proc () =
  musicView()
  inc frames
for look in [lookClassic, lookGlass, lookMatte, lookGloss]:
  uiLook = look
  for t in 0 .. 3:
    tab = t
    run(3)
  nowOpen = true
  run(3)
  nowOpen = false
playback.track = ts[0]
playback.playing = true
nowOpen = true
run(5)
doAssert nowTrack().title == "Ya Salam"
nowOpen = false
# a YouTube playlist's song tapped: its songs from there on are the queue, the player's page made
playTracks(@[yitems[0], ts[1], yliked[0]], 0)
doAssert ytQueue.len == 2 and ytAt == 0 and youtubeNow.id == "vA" and ytPage.len > 0, "the YouTube songs queued"
run(3)
ytPlay(1)
doAssert youtubeNow.id == "vL" and ytAt == 1
youtubeNow = Track()
ytQueue.setLen(0)
# Library and Settings > YouTube with no Google account: the way to sign in
tab = 2
run(3)
tab = 3
settingsPage = "youtube"
run(3)
settingsPage = ""
uiLook = lookClassic
doAssert frames > 40
echo "music ok"

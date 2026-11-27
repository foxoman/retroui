## Canned answers for Retro Music's free sources (tests/test_musicsources.nim): what Piped,
## Invidious, Radio Browser, Audius, the Internet Archive and a Subsonic server say, made up --
## and a cover, the music tests' PNG. `cannedFetch` answers a request by its address, at once.

import std/[strutils, os]
import retroui/[jobs, http]

const
  PipedSongsBody* = """{"items": [
    {"type": "stream", "url": "/watch?v=vidHarbour1", "title": "Morning Light", "uploaderName": "Harbour - Topic",
     "thumbnail": "https://img.test/c1.png", "duration": 214},
    {"type": "stream", "url": "/watch?v=vidHarbour2", "title": "Tide", "uploaderName": "Harbour - Topic",
     "thumbnail": "https://img.test/c2.png", "duration": 187},
    {"type": "channel", "url": "/channel/UC1", "name": "Harbour"},
    {"type": "stream", "url": "/watch?v=vidDunes1", "title": "Night Drive", "uploaderName": "Dunes",
     "thumbnail": "", "duration": 251}]}"""
  PipedShelvesBody* = """{"items": [
    {"type": "playlist", "url": "/playlist?list=OLAK5uy_harbour", "name": "Harbour", "uploaderName": "Harbour - Topic",
     "thumbnail": "https://img.test/c1.png", "videos": 9},
    {"type": "stream", "url": "/watch?v=x", "title": "not a shelf"}]}"""
  PipedListBody* = """{"name": "Harbour", "uploader": "Harbour - Topic", "relatedStreams": [
    {"type": "stream", "url": "/watch?v=vidHarbour1", "title": "Morning Light", "uploaderName": "Harbour - Topic",
     "thumbnail": "https://img.test/c1.png", "duration": 214},
    {"type": "stream", "url": "/watch?v=vidHarbour2", "title": "Tide", "uploaderName": "Harbour - Topic",
     "thumbnail": "https://img.test/c2.png", "duration": 187}]}"""
  InvidiousSongsBody* = """[
    {"type": "video", "videoId": "vidInv1", "title": "Night Drive", "author": "Dunes", "lengthSeconds": 251,
     "videoThumbnails": [{"quality": "high", "url": "h.jpg"}, {"quality": "medium", "url": "m.jpg"}]},
    {"type": "channel", "author": "Someone"}]"""
  InvidiousListBody* = """{"title": "Roads", "videos": [
    {"videoId": "vidInv2", "title": "Dunes", "author": "Roads - Topic", "lengthSeconds": 200}]}"""
  RadioBody* = """[
    {"stationuuid": "s1", "name": " Coast FM ", "url": "http://coast.test/live", "url_resolved": "http://coast.test/live.mp3",
     "favicon": "https://img.test/c2.png", "tags": "pop,arabic,news", "country": "Oman", "countrycode": "OM",
     "codec": "MP3", "bitrate": 128},
    {"stationuuid": "s2", "name": "Jazz Night", "url": "https://jazz.test/aac", "url_resolved": "", "favicon": "",
     "tags": "jazz", "country": "Netherlands", "countrycode": "NL", "codec": "AAC", "bitrate": 64},
    {"stationuuid": "s3", "name": "No Address", "url": "", "url_resolved": ""}]"""
  AudiusHostsBody* = """{"data": ["https://audius.test", "not a host"]}"""
  AudiusTracksBody* = """{"data": [
    {"id": "aT1", "title": "Night Drive", "user": {"name": "Dunes", "handle": "dunes"}, "genre": "Electronic",
     "duration": 201, "is_streamable": true, "artwork": {"150x150": "https://img.test/c1.png"}},
    {"id": "aT2", "title": "Gated", "user": {"name": "X"}, "duration": 99, "is_streamable": false},
    {"id": "aT3", "title": "Sand", "user": {"name": "Dunes"}, "genre": "Ambient", "duration": 312}]}"""
  AudiusUserBody* = """{"data": {"id": "uDunes", "name": "Dunes", "handle": "dunes"}}"""
  AudiusListsBody* = """{"data": [{"id": "pLate", "playlist_name": "Late", "user": {"name": "Dunes"},
                                    "track_count": 4, "artwork": {}}]}"""
  ArchiveSearchBody* = """{"response": {"numFound": 2, "docs": [
    {"identifier": "hall1977", "title": "Live at the Hall, 1977", "creator": "The Band"},
    {"identifier": "netlabel42", "title": "Quiet Things", "creator": ["Someone", "Other"]}]}}"""
  ArchiveItemBody* = """{"metadata": {"title": "Live at the Hall, 1977", "creator": "The Band"}, "files": [
    {"name": "set/02 Second.mp3", "format": "VBR MP3", "title": "Second", "track": "2/3", "length": "3:45"},
    {"name": "set/01 First.mp3", "format": "VBR MP3", "title": "First", "track": "1/3", "length": "225.4"},
    {"name": "set/01 First.flac", "format": "Flac", "title": "First", "track": "1"},
    {"name": "set/03 Third.mp3", "format": "VBR MP3", "track": "3", "length": "1:02:03"}]}"""
  SubsonicPingBody* = """{"subsonic-response": {"status": "ok", "version": "1.16.1"}}"""
  SubsonicWrongBody* = """{"subsonic-response": {"status": "failed",
                            "error": {"code": 40, "message": "Wrong username or password"}}}"""
  SubsonicAlbumsBody* = """{"subsonic-response": {"status": "ok", "albumList2": {"album": [
    {"id": "al1", "name": "Harbour", "artist": "Harbour", "songCount": 9, "coverArt": "al-1"},
    {"id": "al2", "name": "Roads", "artist": "Roads", "songCount": 2}]}}}"""
  SubsonicListsBody* = """{"subsonic-response": {"status": "ok", "playlists": {"playlist": [
    {"id": "pl1", "name": "Drive", "owner": "sultan", "songCount": 12}]}}}"""
  SubsonicAlbumBody* = """{"subsonic-response": {"status": "ok", "album": {"id": "al1", "name": "Harbour", "song": [
    {"id": "so1", "title": "Morning", "artist": "Harbour", "album": "Harbour", "duration": 214, "coverArt": "al-1"},
    {"id": "so2", "title": "Tide", "artist": "Harbour", "album": "Harbour", "duration": 187}]}}}"""
  SubsonicSearchBody* = """{"subsonic-response": {"status": "ok", "searchResult3": {"song": [
    {"id": "so9", "title": "Found", "artist": "Harbour", "album": "Harbour", "duration": 100}], "album": []}}}"""

var
  asked*: seq[string]                    ## (every address asked, in turn)
  serverWrong* = false                   ## (the server says the password is wrong)
  downServers*: seq[string]              ## (servers that do not answer: their addresses' starts)

proc cannedAnswer*(url: string): HttpResponse =
  ## What the made-up servers say to `url`.
  for d in downServers:
    if url.startsWith(d): return HttpResponse(status: 0, error: "no answer")
  let ok = proc (b: string): HttpResponse = HttpResponse(status: 200, body: b)
  if url.startsWith("https://img.test/"):
    return ok(readFile(currentSourcePath().parentDir / "data" / "music" / "cover.png"))
  if "/search?q=" in url and "filter=music_songs" in url: return ok(PipedSongsBody)
  if "/search?q=" in url and "filter=music_" in url: return ok(PipedShelvesBody)
  if "/api/v1/search" in url: return ok(InvidiousSongsBody)
  if "/api/v1/playlists/" in url: return ok(InvidiousListBody)
  if "/playlists/" in url and "audius" notin url: return ok(PipedListBody)
  if "/json/stations/" in url: return ok(RadioBody)
  if url == "https://api.audius.co": return ok(AudiusHostsBody)
  if "audius.test/v1/users/handle/" in url: return ok(AudiusUserBody)
  if "audius.test/v1/users/" in url and "/playlists" in url: return ok(AudiusListsBody)
  if "audius.test/v1/" in url and ("/tracks" in url): return ok(AudiusTracksBody)
  if url.startsWith("https://archive.org/advancedsearch.php"): return ok(ArchiveSearchBody)
  if url.startsWith("https://archive.org/metadata/"): return ok(ArchiveItemBody)
  if "/rest/ping.view" in url: return ok(if serverWrong: SubsonicWrongBody else: SubsonicPingBody)
  if "/rest/getAlbumList2.view" in url: return ok(SubsonicAlbumsBody)
  if "/rest/getPlaylists.view" in url: return ok(SubsonicListsBody)
  if "/rest/getAlbum.view" in url or "/rest/getRandomSongs.view" in url: return ok(SubsonicAlbumBody)
  if "/rest/search3.view" in url: return ok(SubsonicSearchBody)
  if "/rest/getCoverArt.view" in url: return cannedAnswer("https://img.test/c1.png")
  HttpResponse(status: 404, body: "{}")

proc cannedFetch*(url: string): Job[HttpResponse] =
  ## (a job that answers at once, as the network would)
  asked.add url
  let r = cannedAnswer(url)
  job(proc (): HttpResponse {.gcsafe.} = r)

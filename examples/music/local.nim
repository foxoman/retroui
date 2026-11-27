## Retro Music's own music: the songs on the phone or the computer. The library -- the music
## folders looked through on a worker thread, each song's tags read (`retroui/audiotags`): its
## title, artist, album, track, cover, length, ReplayGain --, kept with how often each song was
## played, when, and its stars; albums, artists, genres; your playlists, and lists made by
## themselves (Favorites, Most Played, Recently Added, Recently Played). The player: the queue
## (Up Next -- put in order, songs taken out, Play Next, Add to Queue), shuffle, repeat, the
## equalizer (presets and 10 bands of your own), songs played at one loudness, a sleep timer; it
## plays on in the background, the system's controls -- the lock screen, the notification,
## headset keys -- showing it and working it (`retroui/mediasession`). Its pages are drawn by
## the procs at the end; examples/music/screens.nim puts them in the app.

import std/[json, os, strutils, tables, times, random, algorithm, math, hashes]
import retroui
import retroui/[jobs, audiotags, jpeg, mediasession]
import api

const
  PlayerKey* = "music-local"     ## (the player's name for retroui/media)
  VideoKey* = "music-video"      ## (a video's, while Now Playing shows its picture)
  VideoExts = [".mp4", ".m4v", ".mov", ".3gp", ".mkv", ".webm"]
    ## (files that may be videos: music videos play with their picture)
  UnknownArtist* = "Unknown Artist"
  UnknownAlbum* = "Unknown Album"

type
  Song* = object
    path*, title*, artist*, album*, albumArtist*, genre*, year*, composer*: string
    track*, disc*, durationMs*: int
    size*: int64
    mtime*: float
    added*: float              ## when it came into the library (seconds since 1970)
    plays*: int
    lastPlayed*: float
    rating*: int               ## 0..5 stars
    gainDb*, albumGainDb*: float
    hasGain*: bool
    coverUrl*: string          ## a song from the network: its cover's address
    origin*: string            ## ... where it came from ("Radio", "Audius", "Internet Archive")
    live*: bool                ## ... a station: no length, no end
  RepeatMode* = enum
    rpOff = "Off", rpAll = "All", rpOne = "One"
  UserList* = object
    name*: string
    paths*: seq[string]
  SmartKind* = enum
    skFavorites = "Favorites", skMost = "Most Played", skAdded = "Recently Added",
    skPlayed = "Recently Played"

const
  EqPresets* = [
    ("Flat", [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ("Acoustic", [4, 4, 3, 1, 2, 2, 3, 4, 3, 2]),
    ("Bass Booster", [6, 5, 4, 2, 1, 0, 0, 0, 0, 0]),
    ("Bass Reducer", [-6, -5, -4, -2, -1, 0, 0, 0, 0, 0]),
    ("Classical", [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
    ("Dance", [3, 6, 4, 0, 1, 3, 5, 4, 3, 0]),
    ("Electronic", [4, 3, 1, 0, -2, 2, 1, 1, 4, 5]),
    ("Hip-Hop", [5, 4, 1, 3, -1, -1, 1, -1, 2, 3]),
    ("Jazz", [4, 3, 1, 2, -2, -2, 0, 1, 3, 4]),
    ("Late Night", [3, 2, 1, 0, -1, -1, 0, 1, 2, 2]),
    ("Loudness", [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
    ("Pop", [-1, -1, 0, 2, 4, 4, 2, 0, -1, -2]),
    ("Rock", [5, 4, 3, 1, -1, -1, 1, 3, 4, 5]),
    ("Small Speakers", [5, 4, 4, 3, 2, 0, -2, -3, -4, -4]),
    ("Spoken Word", [-3, -1, 0, 1, 4, 4, 4, 3, 1, -2]),
    ("Treble Booster", [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
    ("Treble Reducer", [0, 0, 0, 0, 0, -1, -2, -4, -5, -6]),
    ("Vocal Booster", [-2, -3, -3, 1, 4, 4, 3, 1, 0, -2])]
    ## (the equalizer's presets: the gain of each of its 10 bands, dB)
  BandNames* = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

var
  songs*: seq[Song]                      ## the library, by title
  remoteSongs*: Table[string, Song]      ## songs from the network the queue holds, by address
  byPath: Table[string, int]
  folders*: seq[string]                  ## where the music is looked for
  scanning: Job[seq[Song]]
  scanAsked = false
  scanNote* = ""                         ## ("Looking through 3 folders...", "1,204 songs")
  userLists*: seq[UserList]
  # the player
  queue*: seq[string]                    ## what plays, in order (paths)
  qAt* = 0
  plainOrder: seq[string]                ## (the queue before Shuffle: back to it when off)
  shuffleOn*, levelOn* = false
  repeatMode* = rpOff
  localActive* = false                   ## our songs are what plays (not Spotify's, not YouTube's)
  wantPlay = false
  localPlaying*: bool
  localPos*, localDur*: int
  localError*: string
  countedFor = ""                        ## (the song whose play was counted)
  sleepAt* = 0.0                         ## (the sleep timer: when it pauses; 0 off)
  sleepEndOfSong* = false
  eqOn* = false
  eqPreset* = 0                          ## (a preset, or -1: your own bands)
  eqOwn*: array[10, int]
  dirty = false
  savedAt = 0.0
  # covers
  covers: Table[string, Bitmap]
  coverJobs: Table[string, Job[Bitmap]]
  artFile = ""                           ## (the playing song's cover in a file, for the system)
  artFor = ""
  # the pages' own state
  libFilter* = ""
  addOpen*, sleepOpen*, newListOpen*, folderOpen*, songMenuOpen* = false
  addPath = ""                           ## (the song "Add to Playlist" is for)
  menuPath = ""                          ## (the song whose menu is open)
  newListName = ""
  pickedFolder = ""
  flowAt = 0                             ## (Cover Flow's album)
  accessAsked* = false
  userVolume* = 100                      ## (the player's volume slider, 0..100)
  showList* = false                      ## (Now Playing: the queue's songs instead of the cover)
  videoOn = false                        ## (a video plays with its picture: Now Playing shows it)
  videoShownAt = -10                     ## (... the frame it was last shown in)
  videoKinds: Table[string, bool]        ## (a file is a video, or sound alone: looked at once)

proc appDir(): string = dataDir("RetroMusic")

# ---- what is kept ---------------------------------------------------------------------------------

proc toJson(s: Song): JsonNode =
  %*{"path": s.path, "title": s.title, "artist": s.artist, "album": s.album, "albumArtist": s.albumArtist,
     "genre": s.genre, "year": s.year, "composer": s.composer, "track": s.track, "disc": s.disc,
     "ms": s.durationMs, "size": s.size, "mtime": s.mtime, "added": s.added, "plays": s.plays,
     "last": s.lastPlayed, "stars": s.rating, "gain": s.gainDb, "albumGain": s.albumGainDb,
     "hasGain": s.hasGain}

proc songOf(j: JsonNode): Song =
  Song(path: j{"path"}.getStr, title: j{"title"}.getStr, artist: j{"artist"}.getStr,
       album: j{"album"}.getStr, albumArtist: j{"albumArtist"}.getStr, genre: j{"genre"}.getStr,
       year: j{"year"}.getStr, composer: j{"composer"}.getStr, track: j{"track"}.getInt,
       disc: j{"disc"}.getInt, durationMs: j{"ms"}.getInt, size: j{"size"}.getBiggestInt,
       mtime: j{"mtime"}.getFloat, added: j{"added"}.getFloat, plays: j{"plays"}.getInt,
       lastPlayed: j{"last"}.getFloat, rating: j{"stars"}.getInt, gainDb: j{"gain"}.getFloat,
       albumGainDb: j{"albumGain"}.getFloat, hasGain: j{"hasGain"}.getBool)

proc reindex() =
  songs.sort(proc (a, b: Song): int = cmp(a.title.toLowerAscii, b.title.toLowerAscii))
  byPath.clear()
  for i, s in songs: byPath[s.path] = i

proc saveLibrary*() =
  ## The library, your playlists and the player's settings, in the app's folder.
  var a = newJArray()
  for s in songs: a.add toJson(s)
  var ls = newJArray()
  for l in userLists: ls.add %*{"name": l.name, "paths": l.paths}
  var remote = newJArray()
  for p in queue:
    if p in remoteSongs:
      let r = remoteSongs[p]
      remote.add %*{"path": p, "title": r.title, "artist": r.artist, "album": r.album, "ms": r.durationMs,
                    "cover": r.coverUrl, "origin": r.origin, "live": r.live}
  let st = %*{"folders": folders, "shuffle": shuffleOn, "repeat": ord(repeatMode), "level": levelOn,
              "eq": eqOn, "preset": eqPreset, "own": @eqOwn, "queue": queue, "at": qAt, "remote": remote}
  try:
    createDir(appDir())
    writeFile(appDir() / "library.json", $a)
    writeFile(appDir() / "playlists.json", $ls)
    writeFile(appDir() / "player.json", $st)
  except CatchableError: discard
  dirty = false
  savedAt = epochTime()

proc loadLibrary*() =
  ## The library as it was kept (then looked through again by itself, for what changed).
  songs.setLen(0)
  try:
    for j in parseJson(readFile(appDir() / "library.json")).getElems: songs.add songOf(j)
  except CatchableError: discard
  reindex()
  userLists.setLen(0)
  try:
    for j in parseJson(readFile(appDir() / "playlists.json")).getElems:
      var l = UserList(name: j{"name"}.getStr)
      for p in j{"paths"}.getElems: l.paths.add p.getStr
      userLists.add l
  except CatchableError: discard
  try:
    let st = parseJson(readFile(appDir() / "player.json"))
    folders.setLen(0)
    for f in st{"folders"}.getElems: folders.add f.getStr
    shuffleOn = st{"shuffle"}.getBool
    repeatMode = RepeatMode(clamp(st{"repeat"}.getInt, 0, 2))
    levelOn = st{"level"}.getBool
    eqOn = st{"eq"}.getBool
    eqPreset = clamp(st{"preset"}.getInt, -1, EqPresets.high)
    for i, g in st{"own"}.getElems:
      if i < 10: eqOwn[i] = clamp(g.getInt, -12, 12)
    for p in st{"queue"}.getElems: queue.add p.getStr
    for r in st{"remote"}.getElems:
      remoteSongs[r{"path"}.getStr] = Song(path: r{"path"}.getStr, title: r{"title"}.getStr,
                                           artist: r{"artist"}.getStr, album: r{"album"}.getStr,
                                           durationMs: r{"ms"}.getInt, coverUrl: r{"cover"}.getStr,
                                           origin: r{"origin"}.getStr, live: r{"live"}.getBool)
    qAt = clamp(st{"at"}.getInt, 0, max(0, queue.len - 1))
  except CatchableError: discard
  if folders.len == 0: folders = musicFolders()

proc changed() =
  dirty = true

# ---- looking through the folders ------------------------------------------------------------------

proc nameOf(path: string): string =
  ## ("03 - Intro.mp3" -> "Intro": a song's name from its file's, when it has no title)
  var n = path.splitFile.name
  var i = 0
  while i < n.len and n[i] in {'0' .. '9'}: inc i
  if i > 0 and i < n.len and n[i] in {' ', '.', '-', '_'}:
    n = n[i .. ^1].strip(chars = {' ', '.', '-', '_'})
  if n.len == 0: path.splitFile.name else: n

proc scanFolders(dirs: seq[string]; known: Table[string, (int64, float)]): seq[Song] {.gcsafe.} =
  ## (every music file under `dirs`: one known as it was -- its size and time the same -- with its
  ## title "\0" to keep it; a new or changed one with its tags read)
  var seen: Table[string, bool]
  for d in dirs:
    if not dirExists(d): continue
    try:
      for p in walkDirRec(d, yieldFilter = {pcFile, pcLinkToFile}, skipSpecial = true):
        if not (isAudioFile(p) or p.splitFile.ext.toLowerAscii in VideoExts) or p in seen: continue
        if "/." in p or "/Android/data/" in p: continue        # (hidden folders, apps' own)
        seen[p] = true
        var size = 0'i64
        var mtime = 0.0
        try:
          let info = getFileInfo(p)
          size = info.size
          mtime = info.lastWriteTime.toUnixFloat
        except OSError: continue
        if size < 1024: continue
        let k = known.getOrDefault(p, (-1'i64, -1.0))
        if k[0] == size and k[1] == mtime:
          result.add Song(path: p, title: "\0", size: size, mtime: mtime)
          continue
        let t = readAudioTags(p, picture = false)
        var s = Song(path: p, size: size, mtime: mtime, title: t.title, artist: t.artist, album: t.album,
                     albumArtist: t.albumArtist, genre: t.genre, year: t.year, composer: t.composer,
                     track: t.track, disc: t.disc, durationMs: t.durationMs, gainDb: t.gainDb,
                     albumGainDb: t.albumGainDb, hasGain: t.hasGain)
        if s.title.len == 0: s.title = nameOf(p)
        if s.artist.len == 0: s.artist = UnknownArtist
        if s.album.len == 0: s.album = (if t.format.len > 0: p.parentDir.extractFilename else: UnknownAlbum)
        if s.year.len > 4: s.year = s.year[0 ..< 4]
        result.add s
    except OSError: discard

proc scanLibrary*() =
  ## Looks through the music folders again (on a worker thread): new songs in, gone ones out,
  ## changed ones read again.
  if scanning != nil: return
  var known: Table[string, (int64, float)]
  for s in songs: known[s.path] = (s.size, s.mtime)
  let dirs = folders
  scanNote = "Looking through " & $dirs.len & (if dirs.len == 1: " folder..." else: " folders...")
  scanning = job(proc (): seq[Song] {.gcsafe.} = scanFolders(dirs, known))

proc pollScan() =
  if scanning == nil or not scanning.ended: return
  if scanning.done:
    let now = epochTime()
    var fresh: seq[Song]
    for s in scanning.value:
      let i = byPath.getOrDefault(s.path, -1)
      if s.title == "\0":
        if i >= 0: fresh.add songs[i]
      else:
        var x = s
        if i >= 0:
          # (read again: its plays, its stars, when it came, kept)
          x.added = songs[i].added
          x.plays = songs[i].plays
          x.lastPlayed = songs[i].lastPlayed
          x.rating = songs[i].rating
        else: x.added = now
        fresh.add x
    songs = fresh
    reindex()
    changed()
    scanNote = $songs.len & (if songs.len == 1: " song" else: " songs")
  else: scanNote = "The music folders could not be read: " & scanning.error
  scanning = nil
  ui.redraw = true

proc scanningNow*(): bool = scanning != nil

# ---- what the library holds ----------------------------------------------------------------------

proc songAt*(path: string): Song =
  let i = byPath.getOrDefault(path, -1)
  if i >= 0: songs[i]
  elif path in remoteSongs: remoteSongs[path]
  else: Song(path: path, title: nameOf(path), artist: UnknownArtist)

proc trackOf*(s: Song): Track =
  ## (a song of ours as the app's tracks are: its path for its id)
  Track(source: srcLocal, id: s.path, uri: s.path, title: s.title, artist: s.artist, album: s.album,
        durationMs: s.durationMs, cover: s.coverUrl)

proc albumArtistOf(s: Song): string =
  if s.albumArtist.len > 0: s.albumArtist else: s.artist

proc albumKey*(s: Song): string = albumArtistOf(s) & "\t" & s.album

proc albums*(): seq[(string, seq[int])] =
  ## (the albums: their key, their songs in order -- disc, then track)
  var t: OrderedTable[string, seq[int]]
  for i, s in songs: t.mgetOrPut(albumKey(s), @[]).add i
  for k, v in t:
    var l = v
    l.sort(proc (a, b: int): int =
      result = cmp(songs[a].disc, songs[b].disc)
      if result == 0: result = cmp(songs[a].track, songs[b].track)
      if result == 0: result = cmp(songs[a].title, songs[b].title))
    result.add (k, l)
  result.sort(proc (a, b: (string, seq[int])): int = cmp(a[0].split('\t')[^1].toLowerAscii,
                                                         b[0].split('\t')[^1].toLowerAscii))

proc groupsBy(f: proc (s: Song): string): seq[(string, seq[int])] =
  var t: Table[string, seq[int]]
  for i, s in songs: t.mgetOrPut(f(s), @[]).add i
  for k, v in t: result.add (k, v)
  result.sort(proc (a, b: (string, seq[int])): int = cmp(a[0].toLowerAscii, b[0].toLowerAscii))

proc artists*(): seq[(string, seq[int])] = groupsBy(proc (s: Song): string = albumArtistOf(s))
proc genres*(): seq[(string, seq[int])] =
  groupsBy(proc (s: Song): string = (if s.genre.len > 0: s.genre else: "Other"))

proc smartSongs*(k: SmartKind): seq[int] =
  ## The songs of a list made by itself.
  var idx: seq[int]
  for i in 0 ..< songs.len: idx.add i
  case k
  of skFavorites:
    for i in idx:
      if songs[i].rating >= 4: result.add i
  of skMost:
    for i in idx:
      if songs[i].plays > 0: result.add i
    result.sort(proc (a, b: int): int = cmp(songs[b].plays, songs[a].plays))
    if result.len > 25: result.setLen(25)
  of skAdded:
    let since = epochTime() - 30 * 86400.0
    for i in idx:
      if songs[i].added >= since: result.add i
    result.sort(proc (a, b: int): int = cmp(songs[b].added, songs[a].added))
    if result.len > 50: result.setLen(50)
  of skPlayed:
    for i in idx:
      if songs[i].lastPlayed > 0: result.add i
    result.sort(proc (a, b: int): int = cmp(songs[b].lastPlayed, songs[a].lastPlayed))
    if result.len > 50: result.setLen(50)

proc pathsOf(idx: openArray[int]): seq[string] =
  for i in idx: result.add songs[i].path

proc setRating*(path: string; stars: int) =
  let i = byPath.getOrDefault(path, -1)
  if i >= 0 and songs[i].rating != stars:
    songs[i].rating = clamp(stars, 0, 5)
    changed()

# ---- covers --------------------------------------------------------------------------------------

proc readCover(path: string): Bitmap {.gcsafe.} =
  ## (a song's cover: its own picture, else a cover.jpg or folder.jpg beside it -- no larger
  ## than 320 pixels)
  var data = readAudioTags(path, picture = true).picture
  if data.len == 0:
    for name in ["cover.jpg", "folder.jpg", "front.jpg", "Cover.jpg", "Folder.jpg", "cover.png", "AlbumArt.jpg"]:
      let f = path.parentDir / name
      if fileExists(f):
        try: data = readFile(f) except IOError: discard
        if data.len > 0: break
  if data.len == 0: return nil
  var b: Bitmap = nil
  {.cast(gcsafe).}:
    try:
      if data.startsWith("\x89PNG"): b = decodePng(data)
      elif data.startsWith("\xFF\xD8"): b = decodeJpeg(data, scale = (if data.len > 400_000: 2 else: 1))
    except CatchableError: b = nil
    if b == nil: return nil
    result = thumbnail(b, 320, 320)

var remoteCover*: proc (url: string): Bitmap {.closure.}
  ## (set by the app: a cover from the network, fetched once -- nil until it came)

proc coverOf*(s: Song): Bitmap =
  ## A song's album's cover (nil while it is read, or when it has none): read on a worker thread,
  ## once for each album, a few at a time; a song from the network's from its address.
  if s.path.len == 0: return nil
  if s.coverUrl.len > 0 or s.path in remoteSongs:
    return (if remoteCover != nil and s.coverUrl.len > 0: remoteCover(s.coverUrl) else: nil)
  let k = albumKey(s)
  if k in covers: return covers[k]
  if k in coverJobs:
    let j = coverJobs[k]
    if j.ended:
      covers[k] = if j.done: j.value else: nil
      coverJobs.del k
      return covers[k]
    return nil
  if coverJobs.len < 3:
    let p = s.path
    coverJobs[k] = job(proc (): Bitmap {.gcsafe.} = readCover(p))
  nil

proc coverOf*(path: string): Bitmap = coverOf(songAt(path))

proc artPath(s: Song): string =
  ## (the playing song's cover in a file of the app's: what the system's controls show)
  if artFor == s.path: return artFile
  artFor = s.path
  artFile = ""
  if s.path in remoteSongs or not fileExists(s.path): return ""
  let t = readAudioTags(s.path, picture = true)
  if t.picture.len > 0:
    let f = appDir() / ("art" & (if t.pictureMime == "image/png": ".png" else: ".jpg"))
    try:
      createDir(appDir())
      writeFile(f, t.picture)
      artFile = f
    except CatchableError: discard
  artFile

# ---- the player -----------------------------------------------------------------------------------

proc hasPicture(path: string): bool =
  ## (a file with a video in it, not sound alone: an MP4's track whose handler is "vide", a
  ## Matroska's or WebM's codec "V_..." -- the file's start read, and an MP4's end, where its index
  ## may be)
  var f: File
  if not open(f, path): return false
  defer: f.close()
  let size = getFileSize(f)
  proc chunk(at, n: int64): string =
    result = newString(int(min(n, max(0'i64, size - at))))
    if result.len == 0: return
    f.setFilePos(at)
    result.setLen(f.readBuffer(result[0].addr, result.len))
  let ext = path.splitFile.ext.toLowerAscii
  if ext in [".mkv", ".webm"]:
    let head = chunk(0, 1 shl 20)
    for codec in ["V_VP8", "V_VP9", "V_AV1", "V_MPEG4", "V_MPEGH", "V_THEORA"]:
      if codec in head: return true
    return false
  for part in [chunk(0, 2 shl 20), chunk(max(0'i64, size - (8 shl 20)), 8 shl 20)]:
    var i = part.find("hdlr")
    while i >= 0:
      if i + 16 <= part.len and part[i + 12 ..< i + 16] == "vide": return true
      i = part.find("hdlr", i + 4)
  false

proc isVideo*(path: string): bool =
  ## A song that is a video (a music video on the device): Now Playing shows its picture.
  if path.splitFile.ext.toLowerAscii notin VideoExts or not fileExists(path): return false
  if path notin videoKinds: videoKinds[path] = hasPicture(path)
  videoKinds[path]

proc playerKey(): string = (if videoOn: VideoKey else: PlayerKey)

proc currentPath*(): string = (if qAt >= 0 and qAt < queue.len: queue[qAt] else: "")
proc currentSong*(): Song = songAt(currentPath())
proc localTrack*(): Track = (if currentPath().len > 0: trackOf(currentSong()) else: Track())

var stopOthers*: proc () {.closure.}
  ## (set by the app: what plays from another source pauses when ours starts)

proc start(at: int) =
  if at < 0 or at >= queue.len: return
  qAt = at
  localActive = true
  wantPlay = true
  localPos = 0
  localError = ""
  countedFor = ""
  if stopOthers != nil: stopOthers()
  closeVideo(PlayerKey)
  closeVideo(VideoKey)
  videoOn = false
  changed()
  ui.redraw = true

proc playSongs*(paths: openArray[string]; at: int) =
  ## Plays `paths` from its `at`-th song (Shuffle on: that one first, the others in any order).
  if at < 0 or at >= paths.len: return
  plainOrder = @paths
  queue = @paths
  var k = at
  if shuffleOn:
    let first = queue[at]
    queue.delete(at)
    queue.shuffle()
    queue.insert(first, 0)
    k = 0
  start(k)

proc playRemote*(list: openArray[Song]; at: int) =
  ## Plays songs from the network -- stations, Audius' tracks, the Archive's, a server's -- from
  ## the `at`-th: they go in the queue as the device's songs do.
  var paths: seq[string]
  for s in list:
    remoteSongs[s.path] = s
    paths.add s.path
  playSongs(paths, at)

proc playNext*(path: string) =
  ## The song after the one playing.
  if queue.len == 0:
    playSongs([path], 0)
    return
  queue.insert(path, qAt + 1)
  plainOrder.add path
  changed()

proc addToQueue*(path: string) =
  ## The song at the end of the queue.
  if queue.len == 0:
    playSongs([path], 0)
    return
  queue.add path
  plainOrder.add path
  changed()

proc setShuffle*(on: bool) =
  shuffleOn = on
  if queue.len > 1:
    let cur = currentPath()
    if on:
      var rest = queue
      rest.delete(qAt)
      rest.shuffle()
      queue = @[cur] & rest
      qAt = 0
    elif plainOrder.len > 0:
      queue = plainOrder
      qAt = max(0, queue.find(cur))
  changed()

proc pauseLocal*() =
  if localActive and localPlaying: playVideo(playerKey(), false)
  wantPlay = false
  localPlaying = false

proc resumeLocal*() =
  if queue.len == 0: return
  localActive = true
  wantPlay = true
  if stopOthers != nil: stopOthers()
  playVideo(playerKey(), true)

proc toggleLocal*() =
  if localPlaying: pauseLocal() else: resumeLocal()

proc nextSong*(byUser = true) =
  if queue.len == 0: return
  if qAt + 1 < queue.len: start(qAt + 1)
  elif repeatMode == rpAll or byUser: start(0)

proc previousSong*() =
  if localPos > 3000 or qAt == 0:
    seekVideo(playerKey(), 0)
    localPos = 0
  else: start(qAt - 1)

proc seekLocal*(ms: int) =
  seekVideo(playerKey(), ms)
  localPos = ms

proc eqGains*(): seq[float] =
  ## (the bands as they play: the preset's, or your own)
  if not eqOn: return @[]
  let g = if eqPreset >= 0: EqPresets[eqPreset][1] else: eqOwn
  for x in g: result.add float(x)

proc sleepLeft*(): string =
  ## ("12 min", "end of song", "" off)
  if sleepEndOfSong: "End of song"
  elif sleepAt > 0: $max(1, int(ceil((sleepAt - epochTime()) / 60))) & " min"
  else: ""

proc followPlayer(ev: VideoEvent) =
  ## (what the player says of the song playing -- where it is, its end (the next one, as Repeat
  ## says), its play counted --, and what is asked of it: its loudness, the equalizer)
  let path = currentPath()
  let s = currentSong()
  localPlaying = ev.playing
  localPos = ev.positionMs
  localDur = if ev.durationMs > 0: ev.durationMs else: s.durationMs
  localError = ev.error
  # (its loudness: ReplayGain's, 6 dB up -- louder than recorded only where the player can)
  let gain = if levelOn and s.hasGain: min(1.0, pow(10.0, (s.gainDb + 6) / 20)) else: 1.0
  setPlayerVolume(playerKey(), gain * float(clamp(userVolume, 0, 100)) / 100)
  setPlayerEqualizer(playerKey(), eqGains())
  # (played: half of it, or 30 seconds -- once)
  if countedFor != path and localDur > 0 and localPos >= min(30_000, localDur div 2):
    countedFor = path
    let i = byPath.getOrDefault(path, -1)
    if i >= 0:
      inc songs[i].plays
      songs[i].lastPlayed = epochTime()
      changed()
  if ev.ended:
    if sleepEndOfSong:
      sleepEndOfSong = false
      wantPlay = false
    elif repeatMode == rpOne: start(qAt)
    elif qAt + 1 < queue.len or repeatMode == rpAll: nextSong(byUser = false)
    else: wantPlay = false

proc showVideo(r: Rect) =
  ## (the song's video in `r`, as big as fits: it plays from where its sound was)
  let s = currentSong()
  if not videoOn:
    let at = localPos
    closeVideo(PlayerKey)
    closeVideo(VideoKey)
    videoOn = true
    if at > 0: seekVideo(VideoKey, at)
  videoShownAt = ui.frameNo
  pushFrame(rect(r.x, r.y, r.w, 0))
  let ev = videoView(s.path, height = r.h, key = VideoKey, autoplay = wantPlay, controls = false,
                     title = s.title)
  discard popFrame()
  followPlayer(ev)

proc localTick*() =
  ## Every frame: the scan's answer; the song playing -- where it is, its end (the next one, as
  ## Repeat says), its play counted, its loudness, the equalizer, the sleep timer --; the system's
  ## controls; the library kept now and then.
  pollScan()
  if not scanAsked:
    scanAsked = true
    if musicAccess(): scanLibrary()
  if dirty and epochTime() - savedAt > 5: saveLibrary()
  let path = currentPath()
  if path.len == 0 or not localActive: return
  let s = currentSong()
  # (a video's picture no longer shown -- Now Playing left, the app in the background --: its
  # sound plays on from there, in the player that plays on in the background)
  if videoOn and (ui.paused or videoShownAt < ui.frameNo - 1):
    let at = localPos
    closeVideo(VideoKey)
    videoOn = false
    if at > 0: seekVideo(PlayerKey, at)
  if not videoOn: followPlayer(audioPlayer(path, PlayerKey, autoplay = wantPlay))
  if sleepAt > 0 and epochTime() >= sleepAt:
    sleepAt = 0
    pauseLocal()
  elif sleepAt > 0: wakeIn(1000)
  # the system's controls: the lock screen, the notification, a headset's keys
  setNowPlaying(NowPlaying(title: s.title, artist: s.artist, album: s.album, artPath: artPath(s),
                           playing: localPlaying, positionMs: localPos, durationMs: localDur,
                           canNext: queue.len > 1, canPrevious: true, canSeek: true))
  for k in mediaKeys():
    case k.key
    of mkPlay: resumeLocal()
    of mkPause, mkStop: pauseLocal()
    of mkPlayPause: toggleLocal()
    of mkNext: nextSong()
    of mkPrevious: previousSong()
    of mkSeekTo: seekLocal(k.ms)
    of mkSeekBy: seekLocal(max(0, localPos + k.ms))
    of mkRaise: discard
  if localPlaying: wakeIn(500)

# ---- your playlists -------------------------------------------------------------------------------

proc addToList*(name, path: string) =
  for l in userLists.mitems:
    if l.name == name:
      if path notin l.paths: l.paths.add path
      changed()
      return
  userLists.add UserList(name: name, paths: @[path])
  changed()

# ---- the pages ------------------------------------------------------------------------------------

proc fmtCount(n: int; one, many: string): string = $n & " " & (if n == 1: one else: many)

proc songRows*(idx: openArray[int]; key: string; numbers = false) =
  ## (songs in rows: the cover, the title, the artist, the length; a tap plays them from there,
  ## the info button its menu)
  let paths = pathsOf(idx)
  tableGroup(""):
    for n, i in idx:
      let s = songs[i]
      let playingIt = localActive and s.path == currentPath()
      let h = tableRow((if numbers and s.track > 0: $s.track & ". " else: "") & s.title,
                       if playingIt: (if localPlaying: "playing" else: "paused")
                       elif s.durationMs > 0: clock(s.durationMs) else: "",
                       taInfo, subtitle = s.artist, picture = (if numbers: nil else: coverOf(s)),
                       key = key & $n & s.path)
      if h.info:
        menuPath = s.path
        songMenuOpen = true
      elif h.clicked: playSongs(paths, n)

proc localAlbum(key: string) =
  for (k, idx) in albums():
    if k != key: continue
    let s = songs[idx[0]]
    let b = coverOf(s)
    let side = min(cellRoom(), dp(220))
    let r = place(side, side)
    if b != nil:
      masked(r, float(dp(6))):
        drawBitmap(r, b)
    else:
      roundRect(r, float(dp(6)), mixColor(ui.theme.window, ui.theme.text, 0.1))
      let st = style(size = 3.0)
      text(r.x + (r.w - textWidth(nfMusic, st)) div 2, r.y + (r.h - lineHeight(st)) div 2, nfMusic, ui.theme.gray, st)
    heading(s.album, 2)
    var ms = 0
    for i in idx: ms += songs[i].durationMs
    label(albumArtistOf(s) & (if s.year.len > 0: " -- " & s.year else: "") & " -- " &
          fmtCount(idx.len, "song", "songs") & ", " & $(ms div 60000) & " min", color = ui.theme.gray)
    row:
      if button("Play", nfPlay, isDefault = true): playSongs(pathsOf(idx), 0)
      if button("Shuffle", nfRandom):
        setShuffle(true)
        playSongs(pathsOf(idx), rand(idx.high))
    songRows(idx, "album", numbers = true)
    return
  emptyState(nfMusic, "Not in the library any more")

proc localTitle*(page: string): string =
  ## (the navigation bar's title of one of our pages)
  let p = page.split(':', 2)
  case p[1]
  of "songs": "Songs"
  of "albums": "Albums"
  of "artists": "Artists"
  of "genres": "Genres"
  of "lists": "Playlists"
  of "queue": "Up Next"
  of "album": (if p.len > 2: p[2].split('\t')[^1] else: "Album")
  of "artist", "genre": (if p.len > 2: p[2] else: "")
  of "list": (if p.len > 2: p[2] else: "Playlist")
  of "smart": (if p.len > 2: p[2] else: "")
  else: "Library"

proc localParent*(page: string): string =
  ## (where Back goes from one of our pages: "" Library)
  let p = page.split(':', 2)
  case p[1]
  of "album": "local:albums"
  of "artist": "local:artists"
  of "genre": "local:genres"
  of "list", "smart": "local:lists"
  else: ""

proc filtered(idx: seq[int]): seq[int] =
  let f = libFilter.strip.toLowerAscii
  if f.len == 0: return idx
  for i in idx:
    let s = songs[i]
    if f in s.title.toLowerAscii or f in s.artist.toLowerAscii or f in s.album.toLowerAscii: result.add i

proc accessGroup(): bool =
  ## (an Android app not let read the music yet: why, and the button that asks)
  if musicAccess(): return false
  tableGroup("On This Device", "Android asks once: let Retro Music read the music on the phone, " &
                               "and your songs, albums and artists are here."):
    if tableButton("Allow Access to Music"):
      askMusicAccess()
      accessAsked = true
  if accessAsked: wakeIn(1000)
  true

proc firstFolderName(): string =
  ## (the first music folder's name -- "Music" when there is none, or its path ends in a slash)
  if folders.len > 0: result = folders[0].strip(leading = false, chars = {'/', '\\'}).extractFilename
  if result.len == 0: result = "Music"

proc localLibraryGroup*(goTo: proc (page: string)) =
  ## Library's own group: the songs on this device, by songs, albums, artists, genres; the
  ## playlists; Up Next.
  if accessGroup(): return
  if accessAsked and musicAccess() and songs.len == 0 and scanning == nil:
    accessAsked = false
    scanLibrary()
  let note = if scanning != nil: scanNote
             elif songs.len == 0: "No music found yet: put songs in " &
                                  firstFolderName() &
                                  ", or add a folder (Settings > Music Folders)."
             else: ""
  tableGroup("On This Device", note):
    let tint = color(250, 45, 85)
    if tableRow("Songs", if songs.len > 0: $songs.len else: "", taChevron, glyph = nfMusic, tint = tint).clicked:
      goTo("local:songs")
    if tableRow("Albums", "", taChevron, glyph = nfList, tint = color(236, 140, 20)).clicked: goTo("local:albums")
    if tableRow("Artists", "", taChevron, glyph = nfUser, tint = color(36, 110, 220)).clicked: goTo("local:artists")
    if tableRow("Genres", "", taChevron, glyph = nfTags, tint = color(150, 90, 210)).clicked: goTo("local:genres")
    if tableRow("Playlists", if userLists.len > 0: $userLists.len else: "", taChevron, glyph = nfListUl,
                tint = color(30, 160, 90)).clicked: goTo("local:lists")
    if queue.len > 0:
      if tableRow("Up Next", $max(0, queue.len - qAt - 1), taChevron, glyph = nfForward,
                  tint = color(128, 128, 136)).clicked: goTo("local:queue")

proc queuePage() =
  ## Up Next: the song playing, then the ones after it -- put in order with their grips, taken
  ## out with their minus.
  if queue.len == 0:
    emptyState(nfForward, "Nothing in the queue", detail = "Play a song, or Add to Queue from its menu.")
    return
  let s = currentSong()
  tableGroup("Playing"):
    if tableRow(s.title, if localPlaying: "playing" else: "paused", taNone, subtitle = s.artist,
                picture = coverOf(s), key = "q-now").clicked: toggleLocal()
  if qAt + 1 < queue.len:
    var edit: RowEdit
    tableGroup("Up Next", "Drag a song by its grip to put it elsewhere; its minus takes it out."):
      for k in qAt + 1 ..< queue.len:
        let x = songAt(queue[k])
        let e = editRow(x.title, k - qAt - 1, detail = (if x.durationMs > 0: clock(x.durationMs) else: ""),
                        subtitle = x.artist, key = "q" & $k & queue[k])
        if e.kind != reNone: edit = e
    case edit.kind
    of reDelete:
      queue.delete(qAt + 1 + edit.index)
      changed()
    of reMove:
      let p = queue[qAt + 1 + edit.index]
      queue.delete(qAt + 1 + edit.index)
      queue.insert(p, qAt + 1 + edit.to)
      changed()
    of reNone: discard
  if qAt > 0:
    tableGroup("Played"):
      for k in countdown(qAt - 1, max(0, qAt - 20)):
        let x = songAt(queue[k])
        if tableRow(x.title, "", taNone, subtitle = x.artist, key = "p" & $k & queue[k]).clicked: start(k)
  tableGroup(""):
    if tableButton("Clear Up Next", destructive = true, enabled = qAt + 1 < queue.len):
      queue.setLen(qAt + 1)
      changed()

proc listPage(name: string) =
  var at = -1
  for i, l in userLists:
    if l.name == name: at = i
  if at < 0:
    emptyState(nfListUl, "No such playlist")
    return
  var idx: seq[int]
  for p in userLists[at].paths:
    let i = byPath.getOrDefault(p, -1)
    if i >= 0: idx.add i
  if idx.len == 0:
    emptyState(nfListUl, name, detail = "Add songs to it from their menu: the info button on a song's row.")
  else:
    row:
      if button("Play", nfPlay, isDefault = true): playSongs(pathsOf(idx), 0)
      if button("Shuffle", nfRandom):
        setShuffle(true)
        playSongs(pathsOf(idx), rand(idx.high))
    var edit: RowEdit
    tableGroup(fmtCount(idx.len, "song", "songs"), "Drag by the grips to put them in order; a minus takes one out."):
      for n, i in idx:
        let e = editRow(songs[i].title, n, detail = clock(songs[i].durationMs), subtitle = songs[i].artist,
                        key = "l" & $n & songs[i].path)
        if e.kind != reNone: edit = e
    case edit.kind
    of reDelete:
      userLists[at].paths.delete(edit.index)
      changed()
    of reMove:
      let p = userLists[at].paths[edit.index]
      userLists[at].paths.delete(edit.index)
      userLists[at].paths.insert(p, edit.to)
      changed()
    of reNone: discard
  tableGroup(""):
    if tableButton("Delete Playlist", destructive = true):
      userLists.delete(at)
      changed()

proc listsPage(goTo: proc (page: string)) =
  tableGroup("Made by Themselves"):
    for k in SmartKind:
      let n = smartSongs(k).len
      if tableRow($k, if n > 0: $n else: "", taChevron, glyph = [nfStar, nfFire, nfPlus, nfHistory][ord(k)],
                  tint = [color(240, 180, 20), color(230, 80, 40), color(30, 160, 90), color(36, 110, 220)][ord(k)]).clicked:
        goTo("local:smart:" & $k)
  tableGroup("Yours"):
    for l in userLists:
      if tableRow(l.name, $l.paths.len, taChevron, key = "ul" & l.name).clicked: goTo("local:list:" & l.name)
    if tableButton("New Playlist..."):
      newListName = ""
      addPath = ""
      newListOpen = true

proc localPage*(page: string; goTo: proc (page: string)) =
  ## One of our pages: "local:songs", "local:albums", "local:album:KEY", "local:artists",
  ## "local:artist:NAME", "local:genres", "local:genre:NAME", "local:lists", "local:list:NAME",
  ## "local:smart:KIND", "local:queue".
  let p = page.split(':', 2)
  let arg = if p.len > 2: p[2] else: ""
  if p[1] notin ["queue", "album"] and accessGroup(): return
  case p[1]
  of "songs":
    discard searchBar(libFilter, "Songs, artists, albums")
    var idx: seq[int]
    for i in 0 ..< songs.len: idx.add i
    let f = filtered(idx)
    if f.len == 0:
      emptyState(nfMusic, if songs.len == 0: "No songs yet" else: "None found",
                 detail = if scanning != nil: scanNote else: "")
    else:
      if libFilter.len == 0:
        row:
          if button("Shuffle All", nfRandom, isDefault = true):
            setShuffle(true)
            playSongs(pathsOf(f), rand(f.high))
      songRows(f, "songs")
  of "albums":
    let all = albums()
    if all.len == 0:
      emptyState(nfList, "No albums yet")
      return
    if ui.w > ui.h and isCompact() or not isCompact():
      # (on its side, or a big screen: Cover Flow over the list)
      var cs: seq[Bitmap]
      var ts, ss: seq[string]
      for (k, idx) in all:
        cs.add coverOf(songs[idx[0]])
        ts.add songs[idx[0]].album
        ss.add albumArtistOf(songs[idx[0]])
      let o = coverFlow(cs, flowAt, ts, ss, h = min(dp(300), max(dp(200), remainingH() div 2)), key = "albums")
      if o >= 0: goTo("local:album:" & all[o][0])
    tableGroup(""):
      for n, (k, idx) in all:
        let s = songs[idx[0]]
        if tableRow(s.album, $idx.len, taChevron, subtitle = albumArtistOf(s), picture = coverOf(s),
                    key = "al" & k).clicked: goTo("local:album:" & k)
  of "album": localAlbum(arg)
  of "artists":
    tableGroup(""):
      for (name, idx) in artists():
        if tableRow(name, $idx.len, taChevron, picture = coverOf(songs[idx[0]]), key = "ar" & name).clicked:
          goTo("local:artist:" & name)
  of "artist", "genre":
    var idx: seq[int]
    for (name, l) in (if p[1] == "artist": artists() else: genres()):
      if name == arg: idx = l
    row:
      if button("Play", nfPlay, isDefault = true, enabled = idx.len > 0): playSongs(pathsOf(idx), 0)
      if button("Shuffle", nfRandom, enabled = idx.len > 0):
        setShuffle(true)
        playSongs(pathsOf(idx), rand(max(0, idx.high)))
    songRows(idx, p[1])
  of "genres":
    tableGroup(""):
      for (name, idx) in genres():
        if tableRow(name, $idx.len, taChevron, key = "ge" & name).clicked: goTo("local:genre:" & name)
  of "lists": listsPage(goTo)
  of "list": listPage(arg)
  of "smart":
    var k = skFavorites
    for x in SmartKind:
      if $x == arg: k = x
    let idx = smartSongs(k)
    if idx.len == 0:
      emptyState(nfStar, arg, detail = case k
        of skFavorites: "Songs you give four stars or five come here."
        of skMost: "The songs you play most come here."
        of skAdded: "Songs that came into the library in the last 30 days."
        of skPlayed: "The songs you played last.")
    else:
      row:
        if button("Play", nfPlay, isDefault = true): playSongs(pathsOf(idx), 0)
      songRows(idx, "smart")
  of "queue": queuePage()
  else: discard

proc localNowPlaying*(goTo: proc (page: string)) =
  ## Now Playing for one of our songs: its cover, its name, its stars, where it is, the controls,
  ## shuffle and repeat, Up Next, the sleep timer.
  let s = currentSong()
  let side = min(cellRoom(), dp(300))
  let b = coverOf(s)
  let r = place(side, side)
  if b != nil:
    masked(r, float(dp(8))):
      drawBitmap(r, b)
  else:
    roundRect(r, float(dp(8)), mixColor(ui.theme.window, ui.theme.text, 0.1))
    let st = style(size = 3.0)
    text(r.x + (r.w - textWidth(nfMusic, st)) div 2, r.y + (r.h - lineHeight(st)) div 2, nfMusic, ui.theme.gray, st)
  heading(s.title, 2)
  label(s.artist & (if s.album.len > 0: " -- " & s.album else: ""), color = ui.theme.gray)
  var stars = s.rating
  if ratingStars(stars): setRating(s.path, stars)
  if localError.len > 0: label(localError, color = badColor())
  if localDur > 0:
    var at = localPos div 1000
    if slider(at, 0, max(1, localDur div 1000), ticks = 0): seekLocal(at * 1000)
    row:
      label(clock(localPos), color = ui.theme.gray)
      spring()
      label("-" & clock(max(0, localDur - localPos)), color = ui.theme.gray)
  row:
    spring()
    let bw = if fingers(): dp(72) else: dp(52)
    let bh = if fingers(): dp(48) else: 0
    if button("Previous", nfStepBackward, blIconOnly, w = bw, h = bh): previousSong()
    if localPlaying:
      if button("Pause", nfPause, blIconOnly, w = bw, h = bh, isDefault = true): pauseLocal()
    elif button("Play", nfPlay, blIconOnly, w = bw, h = bh, isDefault = true): resumeLocal()
    if button("Next", nfStepForward, blIconOnly, w = bw, h = bh,
              enabled = queue.len > 1 or repeatMode == rpAll): nextSong()
    spring()
  row:
    var sh = shuffleOn
    if checkbox("Shuffle", sh): setShuffle(sh)
    spring()
    var rp = ord(repeatMode)
    if segmented(["Repeat Off", "All", "One"], rp):
      repeatMode = RepeatMode(rp)
      changed()
  tableGroup(""):
    if tableRow("Up Next", $max(0, queue.len - qAt - 1), taChevron, glyph = nfForward).clicked: goTo("local:queue")
    if tableRow("Sleep Timer", sleepLeft(), taChevron, glyph = nfMoon, tint = color(60, 70, 150)).clicked:
      sleepOpen = true
    if tableRow("Add to Playlist", "", taChevron, glyph = nfListUl, tint = color(30, 160, 90)).clicked:
      addPath = s.path
      addOpen = true

# ---- Now Playing, as the music players of 2012 drew it ----------------------------------------------

const
  black = color(0, 0, 0)
  white = color(255, 255, 255)
  npInk = color(255, 255, 255)
  npGray = color(150, 152, 158)
  npBlue = color(54, 140, 240)

proc glyphButton(id: Id; r: Rect; glyph: string; size: float; ink: Color; enabled = true): bool =
  ## (a glyph alone, pressed: dimmer -- the player's buttons on its dark bars)
  let hit = interact(id, r, enabled = enabled)
  let st = style(size = size)
  let c = if not enabled: mixColor(ink, black, 0.6) elif hit.down: mixColor(ink, black, 0.35) else: ink
  let gw = textWidth(glyph, st)
  let gy = r.y + (r.h - lineHeight(st)) div 2
  if glossLook(): text(r.x + (r.w - gw) div 2, gy - 1, glyph, withAlpha(black, 160), st)
  text(r.x + (r.w - gw) div 2, gy, glyph, c, st)
  if hit.focused: focusDots(inset(r, 2))
  hit.clicked

proc fadeDown(r: Rect; aTop, aFoot: int) =
  ## (black over `r`, from `aTop` opaque at its top to `aFoot` at its foot, a line at a time: what
  ## is under it shows through, darker down to its foot)
  for k in 0 ..< r.h:
    let a = aTop + (aFoot - aTop) * k div max(1, r.h - 1)
    if a > 0: hline(r.x, r.y + k, r.w, withAlpha(black, a))

proc hsvColor(h, s, v: float): Color =
  ## (a color by its hue -- degrees --, its saturation and its brightness, 0..1)
  let hh = (h mod 360.0 + 360.0) mod 360.0 / 60.0
  let i = int(hh) mod 6
  let f = hh - floor(hh)
  let p = v * (1 - s)
  let q = v * (1 - s * f)
  let t = v * (1 - s * (1 - f))
  let (r, g, b) = case i
    of 0: (v, t, p)
    of 1: (q, v, p)
    of 2: (p, v, t)
    of 3: (p, q, v)
    of 4: (t, p, v)
    else: (v, p, q)
  color(uint8(clamp(r * 255, 0, 255)), uint8(clamp(g * 255, 0, 255)), uint8(clamp(b * 255, 0, 255)))

proc drawArtwork*(r: Rect; s: Song; top = 0; words = true) =
  ## Artwork made from a song with no cover, the same for all of its album's songs: two colors of
  ## the album's own, and waves of sound, a record's grooves or a meter's bars, as its name falls;
  ## its title and its artist written on it (`words`), under `top` (what is drawn over its top).
  var h = 2166136261'u32
  for c in s.album & "\0" & s.artist & "\0" & (if s.album.len == 0 or s.album == UnknownAlbum: s.title else: ""):
    h = (h xor uint32(ord(c))) * 16777619'u32
  if h == 0: h = 1
  proc next(): float =
    h = h xor (h shl 13)
    h = h xor (h shr 17)
    h = h xor (h shl 5)
    float(h and 0xFFFF) / 65535.0
  let hue = next() * 360
  let light = hsvColor(hue, 0.5 + 0.3 * next(), 0.86)
  let deep = hsvColor(hue + 30 + 60 * next(), 0.8, 0.30)
  roundRectShaded(r, 0, light, deep)
  pushClip(r)
  let side = float(min(r.w, r.h))
  let line = max(1.5, side / 180)
  case int(next() * 3) mod 3
  of 0:
    # waves of sound across it
    for k in 0 ..< 6:
      let amp = side * (0.03 + 0.07 * next())
      let freq = 1.0 + 3 * next()
      let phase = next() * 2 * PI
      let y0 = float(r.y) + float(r.h) * (0.2 + 0.6 * float(k) / 5)
      var px = float(r.x)
      var py = y0 + amp * sin(phase)
      for j in 1 .. 64:
        let x = float(r.x) + float(r.w) * float(j) / 64
        let y = y0 + amp * sin(phase + freq * 2 * PI * float(j) / 64)
        thickLine(px, py, x, y, line, withAlpha(white, 36 + 10 * k))
        px = x
        py = y
  of 1:
    # a record's grooves round a point of it
    let cx = float(r.x) + float(r.w) * (0.25 + 0.5 * next())
    let cy = float(r.y) + float(r.h) * (0.3 + 0.4 * next())
    for k in 1 .. 12:
      ring(cx, cy, side * 0.06 * float(k), line, withAlpha(white, max(12, 80 - k * 6)))
    disc(cx, cy, side * 0.045, withAlpha(white, 110))
    disc(cx, cy, side * 0.012, deep)
  else:
    # a level meter's bars along its foot
    let n = 16
    let bw = float(r.w) / float(n)
    for k in 0 ..< n:
      let bh = float(r.h) * (0.12 + 0.5 * next())
      fill(rect(r.x + int(bw * float(k)) + dp(2), r.y + r.h - int(bh), max(1, int(bw) - dp(4)), int(bh)),
           withAlpha(white, 46))
  if words and r.w > dp(80):
    # its title, big, and its artist under it
    let bigSize = clamp(side / float(FontH) / 9, 1.2, 3.2)
    let big = style(bold = true, size = bigSize)
    let small = style(size = clamp(side / float(FontH) / 16, 1.0, 1.8))
    let room = r.w - dp(48)
    var lines = wrapLines(s.title, int(float(room) / bigSize), bold = true)
    if lines.len > 3: lines.setLen(3)
    let artist = if s.artist == UnknownArtist: "" else: ellipsize(s.artist, room, small)
    let textH = lines.len * lineHeight(big) + (if artist.len > 0: lineHeight(small) + dp(6) else: 0)
    var y = r.y + top + max(dp(16), (r.h * 45 div 100 - top - textH) div 2)
    for ln in lines:
      text(r.x + (r.w - textWidth(ln, big)) div 2, y + 1, ln, withAlpha(black, 70), big)
      text(r.x + (r.w - textWidth(ln, big)) div 2, y, ln, white, big)
      y += lineHeight(big)
    if artist.len > 0:
      text(r.x + (r.w - textWidth(artist, small)) div 2, y + dp(6), artist, withAlpha(white, 215), small)
  popClip()

proc darkBar(r: Rect; lighter = false) =
  ## (the player's bars: black glass in Gloss -- its top half lit --, flat dark in the others)
  if glossLook():
    let (a, b) = if lighter: (color(70, 72, 78), color(38, 39, 43)) else: (color(52, 53, 57), color(14, 14, 16))
    roundRectShaded(r, 0, a, b)
    fill(rect(r.x, r.y, r.w, r.h div 2), withAlpha(white, 14))
    hline(r.x, r.y, r.w, withAlpha(white, 40))
    hline(r.x, r.y + r.h - 1, r.w, black)
  else:
    fill(r, if lighter: color(40, 41, 45) else: color(24, 24, 27))

proc playerScreen*(area: Rect; lyrics: openArray[LyricLine]; lyricText: string; onBack: proc ();
                   goTo: proc (page: string); back = true) =
  ## Now Playing for the app's own player, drawn whole in `area`, as the music players of 2012
  ## had it: a dark bar with Back, the artist, the title and the album, and a button to the
  ## queue; under it the song's place in the queue, where it is, Repeat and Shuffle; the cover
  ## as wide as the screen -- the lyrics over its foot, the line sung lit -- or the queue's songs;
  ## at the foot the previous, play or pause, the next, and the volume.
  let s = currentSong()
  let id = idOf("nowplaying")
  fill(area, black)
  # the top bar: Back, the three lines, the queue button
  let topH = if fingers(): dp(50) else: dp(44)
  let top = rect(area.x, area.y, area.w, topH)
  darkBar(top)
  let bw = dp(46)
  if back:
    let br = rect(top.x + dp(6), top.y + (topH - dp(32)) div 2, bw, dp(32))
    if glossLook(): glossBarButton(br, false)
    if glyphButton(id + 1, br, nfArrowLeft, 1.2, npInk): onBack()
  let lr = rect(top.x + top.w - bw - dp(6), top.y + (topH - dp(32)) div 2, bw, dp(32))
  let thumb = coverOf(s)
  if showList and thumb != nil:
    if interact(id + 2, lr).clicked: showList = false
    drawBitmap(inset(lr, dp(2)), thumb)
    box(inset(lr, dp(2)), withAlpha(white, 120))
  else:
    if glossLook(): glossBarButton(lr, false)
    if glyphButton(id + 2, lr, nfListUl, 1.1, npInk): showList = not showList
  let small = style(size = 0.82)
  let mid = style(bold = true, size = 0.9)
  let tw = top.w - 2 * (bw + dp(14))
  let lh = lineHeight(small)
  let y0 = top.y + (topH - 2 * lh - lineHeight(mid)) div 2
  let third = if s.album.len > 0: s.album elif s.origin.len > 0: s.origin else: ""
  for (t, st, c, dy) in [(s.artist, small, npGray, 0), (s.title, mid, npInk, lh),
                         (third, small, npInk, lh + lineHeight(mid))]:
    if t.len == 0: continue
    let e = ellipsize(t, tw, st)
    text(top.x + (top.w - textWidth(e, st)) div 2, y0 + dy, e, c, st)
  # the foot: the controls, the volume
  let ctlH = if fingers(): dp(64) else: dp(52)
  let volH = if fingers(): dp(44) else: dp(34)
  let foot = rect(area.x, area.y + area.h - ctlH - volH, area.w, ctlH + volH)
  # the middle: the cover (or the queue), the panel over its top
  let midR = rect(area.x, top.y + topH, area.w, foot.y - top.y - topH)
  let panelH = if fingers(): dp(70) else: dp(60)
  if showList:
    # (the queue's songs, numbered, the one playing marked)
    pushFrame(rect(midR.x, midR.y + panelH, midR.w, midR.h - panelH))
    fill(rect(midR.x, midR.y + panelH, midR.w, midR.h - panelH), color(36, 37, 40))
    beginPanel(-1, "np:list", plain = true)
    var stars = s.rating
    if s.path notin remoteSongs:
      row:
        spring()
        if ratingStars(stars): setRating(s.path, stars)
        spring()
    let rh = if fingers(): dp(44) else: FontH + dp(14)
    for k in 0 ..< queue.len:
      let x = songAt(queue[k])
      let rr = place(0, rh, fill = true)
      let h = interact(Id(mixId(uint32(id), fnv("q" & $k & queue[k]))), rr)
      if h.down: fill(rr, color(54, 56, 60))
      hline(rr.x, rr.y + rr.h - 1, rr.w, color(22, 22, 24))
      vline(rr.x + dp(44), rr.y, rr.h, color(22, 22, 24))
      let num = if k == qAt: "" else: $(k + 1)
      if k == qAt:
        let cx = float(rr.x + dp(22))
        let cy = float(rr.y + rr.h div 2)
        polygon([(cx - 5, cy - 7), (cx + 7, cy), (cx - 5, cy + 7)], npBlue)
      else: text(rr.x + (dp(44) - textWidth(num)) div 2, rr.y + (rr.h - FontH) div 2, num, npGray)
      let t = ellipsize(x.title, rr.w - dp(60) - dp(50), style(bold = true))
      text(rr.x + dp(56), rr.y + (rr.h - FontH) div 2, t, npInk, true)
      if x.durationMs > 0:
        let d = clock(x.durationMs)
        text(rr.x + rr.w - textWidth(d) - dp(12), rr.y + (rr.h - FontH) div 2, d, npGray)
      if h.clicked and k != qAt: start(k)
    tableGroup(""):
      if tableRow("Sleep Timer", sleepLeft(), taChevron, glyph = nfMoon, tint = color(60, 70, 150)).clicked:
        sleepOpen = true
      if s.path notin remoteSongs:
        if tableRow("Add to Playlist", "", taChevron, glyph = nfListUl, tint = color(30, 160, 90)).clicked:
          addPath = s.path
          addOpen = true
      if tableRow("Up Next", "", taChevron, glyph = nfForward).clicked: goTo("local:queue")
    endPanel()
    discard popFrame()
  else:
    # (the cover fills the place from the panel to the controls -- a tall phone's too, its sides
    # cut off --, as the players of then filled the screen with it)
    let side = max(midR.w, midR.h)
    let cr = rect(midR.x + (midR.w - side) div 2, midR.y + (midR.h - side) div 2, side, side)
    let video = isVideo(s.path) and videoPlaysInWindow()
    let b = if video: nil else: coverOf(s)
    pushClip(midR)
    if video:
      # (a video: its picture between the panel and the controls -- a tap plays or pauses it)
      fill(midR, black)
      showVideo(rect(midR.x, midR.y + panelH, midR.w, midR.h - panelH))
    elif b != nil: drawBitmap(cr, b)
    else: drawArtwork(midR, s, top = panelH)
    popClip()
    # (a tap on the cover: the queue)
    if not video and interact(id + 3, midR, focusable = false).clicked: showList = true
    # the lyrics, over the cover's foot: the line sung lit, the others gray; without them, the
    # cover's foot darker into the controls (not over a video's picture)
    let lyrTop = midR.y + midR.h * 55 div 100
    let lyrR = rect(midR.x, lyrTop, midR.w, midR.y + midR.h - lyrTop)
    if video: discard
    elif lyrics.len == 0 and lyricText.len == 0:
      fadeDown(rect(midR.x, midR.y + midR.h - dp(60), midR.w, dp(60)), 0, 150)
    if not video and (lyrics.len > 0 or lyricText.len > 0):
      fadeDown(rect(lyrR.x, lyrR.y, lyrR.w, lyrR.h div 3), 0, 200)
      fill(rect(lyrR.x, lyrR.y + lyrR.h div 3, lyrR.w, lyrR.h - lyrR.h div 3), withAlpha(black, 200))
      let big = style(bold = true, size = 1.15)
      let lh2 = lineHeight(big) + dp(4)
      pushClip(lyrR)
      if lyrics.len > 0:
        let at = max(0, lineAt(lyrics, localPos))
        # (the line sung in the middle of the place, two lines before it)
        var y = lyrR.y + lyrR.h div 2 - lh2 div 2 - 2 * lh2
        for k in max(0, at - 2) ..< lyrics.len:
          if y > lyrR.y + lyrR.h: break
          let l = ellipsize(lyrics[k].text, lyrR.w - dp(20), big)
          let c = if k == at: npInk elif k < at: color(120, 122, 128) else: color(170, 172, 178)
          text(lyrR.x + (lyrR.w - textWidth(l, big)) div 2, y, l, c, big)
          y += lh2
        if localPlaying: wakeIn(250)
      else:
        var y = lyrR.y + dp(8)
        for ln in wrapLines(lyricText, lyrR.w - dp(24)):
          if y > lyrR.y + lyrR.h: break
          text(lyrR.x + (lyrR.w - textWidth(ln)) div 2, y, ln, color(200, 202, 208))
          y += FontH + dp(3)
      popClip()
  # the panel over the cover's top: its place in the queue, where it is, Repeat and Shuffle
  let pr = rect(midR.x, midR.y, midR.w, panelH)
  if glossLook():
    roundRectShaded(pr, 0, withAlpha(color(40, 41, 45), 215), withAlpha(color(20, 20, 22), 215))
    hline(pr.x, pr.y + pr.h - 1, pr.w, withAlpha(white, 30))
  else: fill(pr, withAlpha(color(20, 20, 22), 210))
  let countSt = style(bold = true, size = 0.8)
  if queue.len > 1:
    let c = $(qAt + 1) & " of " & $queue.len
    text(pr.x + (pr.w - textWidth(c, countSt)) div 2, pr.y + dp(3), c, npInk, countSt)
  let rowY = pr.y + lineHeight(countSt) + dp(3)
  let timeW = textWidth("-00:00") + dp(10)
  if s.live or localDur <= 0:
    let t = if s.live: "Live" elif localPlaying: clock(localPos) else: ""
    text(pr.x + (pr.w - textWidth(t, true)) div 2, rowY + dp(6), t, npInk, true)
  else:
    text(pr.x + dp(10), rowY + dp(6), clock(localPos), npInk, true)
    let rest = "-" & clock(max(0, localDur - localPos))
    text(pr.x + pr.w - textWidth(rest, true) - dp(10), rowY + dp(6), rest, npInk, true)
    pushFrame(rect(pr.x + timeW, rowY - dp(2), pr.w - 2 * timeW, 0))
    var at = localPos div 1000
    if slider(at, 0, max(1, localDur div 1000), ticks = 0): seekLocal(at * 1000)
    discard popFrame()
  let ib = rect(pr.x + dp(4), pr.y + pr.h - dp(26), dp(40), dp(24))
  if glyphButton(id + 4, ib, nfRetweet, 1.0, if repeatMode == rpOff: npGray else: npBlue):
    repeatMode = RepeatMode((ord(repeatMode) + 1) mod 3)
    changed()
  if repeatMode == rpOne:
    let one = "1"
    text(ib.x + ib.w - dp(8), ib.y, one, npBlue, style(bold = true, size = 0.7))
  let sb = rect(pr.x + pr.w - dp(44), pr.y + pr.h - dp(26), dp(40), dp(24))
  if glyphButton(id + 5, sb, nfRandom, 1.0, if shuffleOn: npBlue else: npGray): setShuffle(not shuffleOn)
  # the foot: the controls on the black bar, the volume under them
  let cb = rect(foot.x, foot.y, foot.w, ctlH)
  darkBar(cb, lighter = true)
  let fifth = cb.w div 5
  let gs = if fingers(): 1.9 else: 1.6
  if glyphButton(id + 6, rect(cb.x + fifth, cb.y, fifth, cb.h), nfStepBackward, gs, npInk): previousSong()
  if glyphButton(id + 7, rect(cb.x + 2 * fifth, cb.y, fifth, cb.h), if localPlaying: nfPause else: nfPlay,
                 gs + 0.2, npInk): toggleLocal()
  if glyphButton(id + 8, rect(cb.x + 3 * fifth, cb.y, fifth, cb.h), nfStepForward, gs, npInk,
                 enabled = queue.len > 1 or repeatMode == rpAll): nextSong()
  let vb = rect(foot.x, foot.y + ctlH, foot.w, volH)
  darkBar(vb)
  let vg = style(size = 0.95)
  text(vb.x + dp(12), vb.y + (vb.h - lineHeight(vg)) div 2, nfVolumeOff, npGray, vg)
  text(vb.x + vb.w - dp(12) - textWidth(nfVolumeUp, vg), vb.y + (vb.h - lineHeight(vg)) div 2, nfVolumeUp,
       npGray, vg)
  pushFrame(rect(vb.x + dp(36), vb.y + (vb.h - dp(26)) div 2, vb.w - dp(72), 0))
  var v = userVolume
  if slider(v, 0, 100, ticks = 0):
    userVolume = v
  discard popFrame()
  if localError.len > 0:
    let e = ellipsize(localError, area.w - dp(20))
    fill(rect(area.x, foot.y - FontH - dp(8), area.w, FontH + dp(8)), withAlpha(color(150, 20, 20), 220))
    text(area.x + (area.w - textWidth(e)) div 2, foot.y - FontH - dp(4), e, npInk)
  if accessOn:
    accessNode(arGroup, "Now Playing", value = s.title & ", " & s.artist, r = area)

proc localControls*() =
  ## (what plays, compact: the previous, play or pause, the next -- a tablet's list's)
  let room = cellRoom()
  let bw = (room - 2 * Gap) div 3
  let bh = if fingers(): dp(40) else: 0
  row:
    if button("Previous", nfStepBackward, blIconOnly, w = bw, h = bh): previousSong()
    if button(if localPlaying: "Pause" else: "Play", if localPlaying: nfPause else: nfPlay, blIconOnly,
              w = bw, h = bh, isDefault = true): toggleLocal()
    if button("Next", nfStepForward, blIconOnly, w = bw, h = bh): nextSong()

proc eqPage*() =
  ## The equalizer: on or off, a preset, or your own 10 bands.
  tableGroup("", if playerEqualizer(): "Changes the sound of the songs on this device as they play."
                 else: "This system's player has no equalizer: the songs play as recorded."):
    if tableSwitch("Equalizer", eqOn, glyph = nfSliders, tint = color(250, 45, 85)): changed()
  if not eqOn: return
  label("Your Own", bold = true)
  var own = eqPreset < 0
  row:
    for i in 0 ..< 10:
      var g = if eqPreset >= 0: EqPresets[eqPreset][1][i] else: eqOwn[i]
      if vslider(g, -12, 12, h = dp(150), label = BandNames[i]):
        if not own:
          eqOwn = EqPresets[max(0, eqPreset)][1]
          own = true
        eqOwn[i] = g
        eqPreset = -1
        changed()
  tableGroup("Presets"):
    if tableRow("Your Own", "", if eqPreset < 0: taCheck else: taNone).clicked:
      eqPreset = -1
      changed()
    for i, (name, _) in EqPresets:
      if tableRow(name, "", if eqPreset == i: taCheck else: taNone, key = "eq" & name).clicked:
        eqPreset = i
        changed()

proc soundGroup*(goTo: proc (page: string)) =
  ## Settings' Sound: the equalizer, songs at one loudness, the sleep timer, the music folders.
  tableGroup("Sound", "Level Songs plays every song at the same loudness, as its ReplayGain says."):
    if tableRow("Equalizer", if not eqOn: "Off" elif eqPreset < 0: "Your Own" else: EqPresets[eqPreset][0],
                taChevron, glyph = nfSliders, tint = color(250, 45, 85)).clicked: goTo("eq")
    if tableSwitch("Level Songs", levelOn, glyph = nfVolumeUp, tint = color(36, 110, 220)): changed()
    if tableRow("Sleep Timer", if sleepLeft().len > 0: sleepLeft() else: "Off", taChevron, glyph = nfMoon,
                tint = color(60, 70, 150)).clicked: sleepOpen = true
    if tableRow("Music Folders", $folders.len, taChevron, glyph = nfFolder, tint = color(236, 140, 20)).clicked:
      goTo("folders")

proc foldersPage*() =
  ## Where the music is looked for: the folders, one taken out by its minus; one more added.
  var edit: RowEdit
  tableGroup("Music Folders", if scanning != nil: scanNote else: fmtCount(songs.len, "song", "songs") & " in them"):
    for i, f in folders:
      let e = editRow(f.extractFilename, i, subtitle = f, movable = false, key = "f" & f)
      if e.kind != reNone: edit = e
  if edit.kind == reDelete:
    folders.delete(edit.index)
    changed()
    scanLibrary()
  tableGroup(""):
    when not defined(android):
      if tableButton("Add a Folder..."):
        pickedFolder = getHomeDir()
        folderOpen = true
    if tableButton("Look Through Them Again", enabled = scanning == nil): scanLibrary()
    if tableButton("Use the Usual Folders", enabled = folders != musicFolders()):
      folders = musicFolders()
      changed()
      scanLibrary()

proc localDialogs*() =
  ## Ours: Add to Playlist, the sleep timer, a new playlist's name, a song's menu, a folder.
  var names: seq[string]
  for l in userLists: names.add l.name
  names.add "New Playlist..."
  let pick = actionSheet(addOpen, "Add to Playlist", names)
  if pick >= 0 and pick < userLists.len: addToList(userLists[pick].name, addPath)
  elif pick == userLists.len:
    newListName = ""
    newListOpen = true
  if newListOpen and inputBox(newListOpen, "New Playlist", "Its name:", newListName) == 1:
    let n = newListName.strip
    if n.len > 0:
      if addPath.len > 0: addToList(n, addPath)
      else:
        userLists.add UserList(name: n)
        changed()
  let sl = actionSheet(sleepOpen, "Sleep Timer", ["15 minutes", "30 minutes", "45 minutes", "1 hour",
                                                  "End of the song", "Off"], destructive = 5)
  case sl
  of 0, 1, 2, 3:
    sleepAt = epochTime() + [15, 30, 45, 60][sl].float * 60
    sleepEndOfSong = false
  of 4:
    sleepEndOfSong = true
    sleepAt = 0
  of 5:
    sleepAt = 0
    sleepEndOfSong = false
  else: discard
  let mp = actionSheet(songMenuOpen, songAt(menuPath).title, ["Play Next", "Add to Queue", "Add to Playlist...",
                                                              "Rate 5 Stars"])
  case mp
  of 0: playNext(menuPath)
  of 1: addToQueue(menuPath)
  of 2:
    addPath = menuPath
    addOpen = true
  of 3: setRating(menuPath, 5)
  else: discard
  if folderOpen and fileDialog(folderOpen, pickedFolder, fmFolder, title = "Add a Music Folder"):
    if dirExists(pickedFolder) and pickedFolder notin folders:
      folders.add pickedFolder
      changed()
      scanLibrary()

proc localFrame*() =
  ## (called every frame by the app: the player and the scan)
  localTick()

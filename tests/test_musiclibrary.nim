## Tests of Retro Music's own music (examples/music/local): the folders looked through -- songs,
## albums, artists, genres, the lists made by themselves --; the player through the system's
## (a fake Android one): a song's sound asked for, the next one at its end, Repeat One, a play
## counted, its loudness, the equalizer's bands, the sleep timer; the queue -- Play Next, Add to
## Queue, Shuffle and back --; playlists kept and read back; every page drawn in every look.

import std/[os, strutils, times, tables]
import retroui
import retroui/uirelays/services
import ../examples/music/[api, screens, local]
import harness

let home = getTempDir() / "retro-musiclib"
removeDir(home)
createDir(home)
putEnv("HOME", home)
putEnv("XDG_DATA_HOME", home / ".local" / "share")
putEnv("XDG_CONFIG_HOME", home / ".config")

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

# ---- a music folder: songs of two albums, their tags written here ----------------------------------

proc frame(id, text: string): string =
  let body = "\0" & text
  let n = body.len
  id & char((n shr 24) and 255) & char((n shr 16) and 255) & char((n shr 8) and 255) & char(n and 255) &
    "\0\0" & body

proc id3(title, artist, album, track, genre: string; gain = ""): string =
  var frames = frame("TIT2", title) & frame("TPE1", artist) & frame("TALB", album) & frame("TRCK", track) &
               frame("TCON", genre)
  if gain.len > 0: frames.add frame("TXXX", "REPLAYGAIN_TRACK_GAIN\0" & gain)
  let n = frames.len
  "ID3\3\0\0" & char((n shr 21) and 127) & char((n shr 14) and 127) & char((n shr 7) and 127) &
    char(n and 127) & frames

let sample = readFile(currentSourcePath.parentDir / "data" / "music" / "t24.mp3")
let tagLen = 10 + ((ord(sample[6]) and 127) shl 21 or (ord(sample[7]) and 127) shl 14 or
                   (ord(sample[8]) and 127) shl 7 or (ord(sample[9]) and 127))
let sound = sample[tagLen .. ^1]
let music = home / "Music"
createDir(music / "Harbour")
createDir(music / "Roads")
writeFile(music / "Harbour" / "01 Morning.mp3", id3("Morning", "Sohar Strings", "Old Harbour", "1", "Jazz", "-9.00 dB") & sound)
writeFile(music / "Harbour" / "02 Tide.mp3", id3("Tide", "Sohar Strings", "Old Harbour", "2", "Jazz") & sound)
writeFile(music / "Roads" / "01 Dunes.mp3", id3("Dunes", "The Wadi Band", "Desert Roads", "1", "Rock") & sound)
writeFile(music / "Roads" / "02 Night Drive.mp3", id3("", "The Wadi Band", "Desert Roads", "2", "Rock") & sound)
writeFile(music / "notes.txt", "not music")

# ---- the window, and a fake Android player ---------------------------------------------------------

var calls: seq[string]
var state = "0\t0\t60000\t0"
systemRelays.call = proc (name, arg: string): string {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    calls.add name & "|" & arg
    case name
    of "media.videoState": state
    of "media.videoShow":
      state = "1\t0\t60000\t0"         # (a song shown: it starts from its start)
      "1"
    of "media.musicAccess": "1"
    else: "1"

proc callsOf(prefix: string): seq[string] =
  for c in calls:
    if c.startsWith(prefix): result.add c

fakeDriver()
startApp("musiclib", W, H)
mediaThroughSystem = true
loadSettings()
folders = @[music]
view = proc () = musicView()
run(2)
scanLibrary()
for _ in 0 ..< 400:
  if not scanningNow(): break
  sleep(10)
  run(1)
check not scanningNow() and songs.len == 4, "the folder looked through: 4 songs, not the text file (" & $songs.len & ")"
check songAt(music / "Roads" / "02 Night Drive.mp3").title == "Night Drive", "no title: the file's name, its number off"
check songAt(music / "Harbour" / "01 Morning.mp3").hasGain, "its ReplayGain read"
let al = albums()
check al.len == 2 and al[0][0].endsWith("Desert Roads") and al[1][1].len == 2, "two albums, by name"
check songs[al[1][1][0]].title == "Morning", "an album's songs in their order"
check artists().len == 2 and genres().len == 2, "two artists, two genres"
check smartSongs(skAdded).len == 4 and smartSongs(skMost).len == 0, "all came lately, none played yet"

# ---- playing: the system's player asked, the next at the end, a play counted -----------------------

var paths: seq[string]
for i in al[1][1]: paths.add songs[i].path
for i in al[0][1]: paths.add songs[i].path
levelOn = true
playSongs(paths, 0)
run(3)
let shows = callsOf("media.videoShow|" & PlayerKey)
check shows.len == 1 and paths[0] in shows[0] and shows[0].endsWith("\ta"), "the first song asked of the system's player, as a sound"
check nowTrack().source == srcLocal and nowTrack().title == "Morning", "it is what plays now"
check callsOf("media.videoVolume|" & PlayerKey).len == 1, "its ReplayGain: its volume set"
eqOn = true
eqPreset = 2                                    # Bass Booster
run(3)
let eqs = callsOf("media.videoEq|" & PlayerKey)
check eqs.len == 1 and eqs[0].split('\t')[1].split(',').len == 10 and eqs[0].split('\t')[1].startsWith("6.00"),
      "the equalizer's 10 bands sent"
state = "1\t31000\t60000\t0"
ticks += 300
run(3)
check songAt(paths[0]).plays == 1 and smartSongs(skPlayed).len == 1, "past 30 seconds: its play counted once"
ticks += 300
run(3)
check songAt(paths[0]).plays == 1, "... once"
state = "0\t60000\t60000\t1"
ticks += 300
run(3)
check qAt == 1 and currentPath() == paths[1], "at its end: the next song"
state = "1\t1000\t60000\t0"
repeatMode = rpOne
ticks += 300
run(2)
state = "0\t60000\t60000\t1"
ticks += 300
run(3)
check qAt == 1, "Repeat One: the same again"
repeatMode = rpOff

# ---- the queue: Play Next, Add to Queue, Shuffle and back -----------------------------------------

playNext(paths[3])
check local.queue[qAt + 1] == paths[3], "Play Next: right after this one"
addToQueue(paths[0])
check local.queue[^1] == paths[0], "Add to Queue: at its end"
let before = local.queue
setShuffle(true)
check local.queue[0] == paths[1] and qAt == 0 and local.queue.len == before.len, "Shuffle: this one first, all still there"
setShuffle(false)
check currentPath() == paths[1], "Shuffle off: the order back, this one still playing"

# ---- the sleep timer --------------------------------------------------------------------------------

state = "1\t2000\t60000\t0"
ticks += 300
run(2)
calls.setLen(0)
sleepAt = epochTime() - 1
run(3)
check callsOf("media.videoPause|" & PlayerKey).len == 1 and sleepAt == 0, "the sleep timer: paused"

# ---- playlists and stars, kept and read back ---------------------------------------------------------

addToList("Drive", paths[2])
addToList("Drive", paths[3])
addToList("Drive", paths[2])
setRating(paths[0], 5)
check userLists.len == 1 and userLists[0].paths.len == 2, "a playlist, a song in it once"
check smartSongs(skFavorites).len == 1, "five stars: a favorite"
saveLibrary()
songs.setLen(0)
userLists.setLen(0)
loadLibrary()
check songs.len == 4 and userLists.len == 1 and songAt(paths[0]).rating == 5 and songAt(paths[0]).plays == 1,
      "kept: the library, its plays and stars, the playlist"

# ---- every page, every look --------------------------------------------------------------------------

for look in [lookClassic, lookGlass, lookMatte, lookGloss]:
  uiLook = look
  ui.theme = lookSchemes(look).light
  for page in ["", "local:songs", "local:albums", "local:album:" & al[0][0], "local:artists",
               "local:artist:The Wadi Band", "local:genres", "local:genre:Jazz", "local:lists",
               "local:list:Drive", "local:smart:Most Played", "local:queue"]:
    tab = 2
    libraryPage = page
    run(2)
  tab = 3
  for page in ["", "eq", "folders"]:
    settingsPage = page
    run(2)
  settingsPage = ""
  tab = 0
  run(2)
  nowOpen = true
  run(3)
  nowOpen = false
uiLook = lookClassic
ui.theme = Classic
check true, "every page of it drawn in every look"

removeDir(home)
echo "musiclibrary: ", passed, " ok"

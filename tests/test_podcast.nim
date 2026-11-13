## Retro Podcast (examples/podcast.nim) without a window: a feed file
## followed (read by a job), an episode played from where it was left,
## the queue, Mark Played and Unfollow undone, OPML both ways, and the
## library saved and read back.

import std/[os, strutils, tables]
import harness

let home = getTempDir() / "retro-podcast-test-" & $getCurrentProcessId()
removeDir(home)
createDir(home)
# (the library in a folder of the test's own on every system: never the user's)
putEnv("XDG_DATA_HOME", home)
putEnv("APPDATA", home)
putEnv("HOME", home)

const podcastUnderTest = true
include "../examples/podcast.nim"

gstAudioSink = "fakesink"
# a feed file with three episodes (a short sound each)
let sound = home / "tone.wav"
block:
  var wav = "RIFF" & "\0\0\0\0" & "WAVEfmt " & "\x10\0\0\0\x01\0\x01\0\x40\x1f\0\0\x80\x3e\0\0\x02\0\x10\0" &
            "data" & "\0\0\0\0"
  writeFile(sound, wav & repeat('\0', 8000))
let feedPath = home / "feed.xml"
writeFile(feedPath, """<?xml version="1.0"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd"><channel>
<title>Test Show</title><itunes:author>Tester</itunes:author>
<item><title>Third</title><enclosure url="""" & sound & """" type="audio/wav" length="1"/><itunes:duration>10:00</itunes:duration></item>
<item><title>Second</title><enclosure url="""" & sound & """2" type="audio/wav" length="1"/></item>
<item><title>First</title><enclosure url="""" & sound & """3" type="audio/wav" length="1"/></item>
<item><title>No sound</title></item>
</channel></rss>""")

fakeDriver()
startApp("Retro Podcast", W, H)
view = proc () =
  jobsDone()
  libraryView()
  playerBar()
  undoKeys(history)

doAssert lib.shows.len == 0
follow(feedPath)
for _ in 0 ..< 300:
  run()
  if lib.shows[0].episodes.len > 0: break
  sleep(5)
run()

block followed:
  let s = lib.shows[0]
  doAssert s.title == "Test Show" and s.author == "Tester", s.title
  doAssert s.episodes.len == 3        # (the item with no sound left out)
  doAssert s.episodes[0].seconds == 600
  doAssert unplayed(s) == 3

block playing:
  lib.heard[sound] = Heard(posMs: 3000)
  play(sound)
  run(3)
  doAssert lib.nowPlaying == sound
  doAssert lib.source(sound) == sound

block queue:
  enqueue(sound & "2")
  enqueue(sound & "2")                 # (once)
  doAssert lib.queue == @[sound & "2"]
  doAssert playNext() and lib.nowPlaying == sound & "2" and lib.queue.len == 0

block undoes:
  markPlayed(sound & "3")
  doAssert lib.heard[sound & "3"].played and unplayed(lib.shows[0]) == 2
  doAssert history.undo()
  doAssert not lib.heard.getOrDefault(sound & "3").played
  unfollow(0)
  doAssert lib.shows.len == 0
  doAssert history.undoLabel == "Unfollow"
  doAssert history.undo() and lib.shows.len == 1 and lib.shows[0].title == "Test Show"

block opml:
  var links: seq[FeedLink]
  for s in lib.shows: links.add (s.title, s.url)
  let back = parseOpml(toOpml(links))
  doAssert back == links

block saved:
  lib.save()
  let again = load()
  doAssert again.shows.len == 1 and again.shows[0].episodes.len == 3
  doAssert again.nowPlaying == sound & "2"
  doAssert again.heard[sound].posMs == 3000

removeDir(home)
echo "podcast OK"

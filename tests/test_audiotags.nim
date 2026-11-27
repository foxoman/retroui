## Tests of retroui/audiotags: what music files say about themselves -- MP3 (ID3v2.3 in UTF-16,
## ID3v2.4 in UTF-8), FLAC, M4A, Ogg Vorbis, Opus, WAV: their title, artist, album, track and
## disc, year, genre, composer, cover, length, sound and ReplayGain --; the same from memory as
## from the file; cut short anywhere, or damaged, nothing goes wrong; which names are music.

import std/os
import retroui/audiotags

const dir = currentSourcePath.parentDir / "data" / "music"

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

let cover = readFile(dir / "cover.png")

for (file, format, gain, pic) in [("t23.mp3", "MP3", true, true), ("t24.mp3", "MP3", false, false),
                                  ("t.flac", "FLAC", true, true), ("t.m4a", "M4A", false, true),
                                  ("t.ogg", "Ogg Vorbis", false, false), ("t.opus", "Opus", false, false),
                                  ("t.wav", "WAV", false, false)]:
  let t = readAudioTags(dir / file)
  check t.format == format, file & ": " & format
  check t.title == "Café_Ümlaut", file & ": its title, its accents kept (" & t.title & ")"
  check t.artist == "The_Test_Band" and t.album == "Sample_Album", file & ": artist and album"
  check t.track == 3 and t.year == "2026" and t.genre == "Jazz", file & ": track, year, genre"
  if format != "WAV":
    check t.trackTotal == 12 and t.disc == 1 and t.discTotal == 2, file & ": 3 of 12, disc 1 of 2"
    check t.albumArtist == "Various" and t.composer == "Someone", file & ": album artist, composer"
  check abs(t.durationMs - (if format == "MP3": 2160 else: 2000)) <= 20, file & ": its length, " & $t.durationMs & " ms"
  check t.sampleRate == (if format == "Opus": 48000 else: 8000) and t.channels == 1, file & ": its rate and channels"
  check t.bitrateKbps > 0, file & ": its bit rate, " & $t.bitrateKbps & " kbps"
  check t.hasGain == gain and (not gain or abs(t.gainDb + 6.5) < 0.01), file & ": ReplayGain"
  if pic:
    check t.picture == cover and t.pictureMime == "image/png", file & ": its cover, as it was"
    check readAudioTags(dir / file, picture = false).picture.len == 0, file & ": not read when not asked for"
  # (the same from memory)
  let m = readAudioTagsFrom(readFile(dir / file))
  check m.title == t.title and m.durationMs == t.durationMs and m.picture == t.picture, file & ": from memory the same"

# (cut short anywhere, flipped bytes: read as far as it goes, never a fault)
for file in ["t23.mp3", "t.flac", "t.m4a", "t.ogg", "t.opus", "t.wav"]:
  let data = readFile(dir / file)
  var n = 0
  for cut in countup(0, data.len, max(1, data.len div 300)):
    discard readAudioTagsFrom(data[0 ..< cut])
    inc n
  var bad = data
  for i in countup(0, bad.len - 1, 7): bad[i] = char(ord(bad[i]) xor 0xFF)
  discard readAudioTagsFrom(bad)
  check n > 100, file & ": cut short " & $n & " ways, damaged: no fault"

check readAudioTags(dir / "no such file.mp3").format == "", "no file: nothing"
check readAudioTagsFrom("not music at all, just words").format == "", "words: not music"
check readAudioTagsFrom("").format == "", "nothing: not music"
check isAudioFile("x/Song.MP3") and isAudioFile("a.flac") and isAudioFile("b.opus") and
      not isAudioFile("c.txt") and not isAudioFile("d.mp3.part"), "music by its name"

echo "audiotags: ", passed, " ok"

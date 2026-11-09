## retroui/media: WAV files, tones and the mixer, GIF animations, the calls
## to Android's side (with a fake one), videos in the window (GStreamer,
## when the system has it) -- headless.

import std/[os, strutils, math, sequtils]
import retroui
import retroui/media
import retroui/mediaaudio except Sound
import retroui/uirelays/[input, services]
import harness

fakeDriver()
startApp("media", W, H)

# ---- WAV files made here, in every format -------------------------------------------------------

proc wav(fmtTag, chans, rate, bits: int; data: string; extensible = false;
         extra = ""): string =
  proc u32(v: int): string =
    for k in 0 .. 3: result.add char((v shr (8 * k)) and 255)
  proc u16(v: int): string =
    for k in 0 .. 1: result.add char((v shr (8 * k)) and 255)
  let ba = chans * bits div 8
  var fmt = u16(if extensible: 0xFFFE else: fmtTag) & u16(chans) & u32(rate) &
            u32(rate * ba) & u16(ba) & u16(bits)
  if extensible: fmt.add u16(22) & u16(bits) & u32(0) & u16(fmtTag) & "\0\0\0\0\x10\0\x80\0\0\xAA\0\x38\x9B\x71"
  var body = "WAVE" & "fmt " & u32(fmt.len) & fmt & extra & "data" & u32(data.len) & data
  if data.len mod 2 == 1: body.add '\0'
  "RIFF" & u32(body.len) & body

proc le16(v: int): string = char(v and 255) & char((v shr 8) and 255)

block wavFormats:
  # 16-bit stereo: left full up, right full down
  var d = le16(32767) & le16(-32768 and 0xFFFF) & le16(0) & le16(16384)
  var s = decodeWav(wav(1, 2, 44100, 16, d))
  doAssert s.channels == 2 and s.frames == 2 and s.rate == 44100
  doAssert s.sample(0, 0) == 32767 and s.sample(0, 1) == -32768 and s.sample(1, 1) == 16384
  # 8-bit unsigned mono
  s = decodeWav(wav(1, 1, 8000, 8, "\x80\xFF\x00"))
  doAssert s.frames == 3 and s.sample(0, 0) == 0 and s.sample(1, 0) > 32000 and s.sample(2, 0) == -32768
  # 24-bit
  s = decodeWav(wav(1, 1, 48000, 24, "\x00\x00\x40" & "\xFF\xFF\xFF"))
  doAssert abs(s.sample(0, 0) - 16384) <= 1 and s.sample(1, 0) in -1 .. 0
  # 32-bit int, float 32 and 64
  s = decodeWav(wav(1, 1, 22050, 32, "\x00\x00\x00\x40"))
  doAssert abs(s.sample(0, 0) - 16384) <= 1
  var f32: float32 = -0.5
  var raw = newString(4)
  copyMem(addr raw[0], addr f32, 4)
  s = decodeWav(wav(3, 1, 22050, 32, raw))
  doAssert abs(s.sample(0, 0) + 16384) <= 1
  var f64: float64 = 0.25
  raw = newString(8)
  copyMem(addr raw[0], addr f64, 8)
  s = decodeWav(wav(3, 1, 22050, 64, raw, extensible = true))
  doAssert abs(s.sample(0, 0) - 8192) <= 1, "WAVE_FORMAT_EXTENSIBLE float"
  # NaN samples are silence
  var nan32: float32 = NaN
  copyMem(addr raw[0], addr nan32, 4)
  s = decodeWav(wav(3, 1, 22050, 32, raw[0 .. 3]))
  doAssert s.sample(0, 0) == 0
  # four channels mixed down to two
  s = decodeWav(wav(1, 4, 44100, 16, le16(1000) & le16(2000) & le16(3000) & le16(4000)))
  doAssert s.channels == 2 and s.sample(0, 0) == 2000 and s.sample(0, 1) == 3000
  # a chunk before the data, an odd-sized one, a file cut short
  s = decodeWav(wav(1, 1, 8000, 8, "\x90\x91\x92", extra = "LIST\x03\0\0\0abc\0"))
  doAssert s.frames == 3
  let full = wav(1, 1, 8000, 16, le16(1) & le16(2) & le16(3))
  s = decodeWav(full[0 ..< ^2])
  doAssert s.frames == 2, "a file cut short: what is there"
  doAssert s.duration > 0
  # what is refused
  for bad in ["", "RIFF", "RIFF\0\0\0\0WAVEjunk", "RIFX" & full[4 .. ^1],
              wav(1, 1, 8000, 12, "\0\0"), wav(2, 1, 8000, 16, "\0\0"),
              wav(1, 0, 8000, 16, "\0\0"), wav(1, 1, 10, 16, "\0\0"),
              "RIFF\x10\0\0\0WAVEdata\x02\0\0\0\0\0"]:
    var refused = false
    try: discard decodeWav(bad)
    except ValueError: refused = true
    doAssert refused, "refused: " & bad.toHex
  # the round trip
  let t = makeTone(440, 50)
  let back = decodeWav(encodeWav(t))
  doAssert back.frames == t.frames and back.rate == 44100
  for i in [0, 100, 1000, t.frames - 1]: doAssert back.sample(i, 0) == t.sample(i, 0)

block tones:
  let t = makeTone(1000, 100, 0.5)
  doAssert t.frames == 4410 and t.channels == 1
  doAssert abs(t.sample(0, 0)) < 200, "faded in"
  var peak, crossings = 0
  for i in 1 ..< t.frames:
    peak = max(peak, abs(t.sample(i, 0)))
    if (t.sample(i - 1, 0) < 0) != (t.sample(i, 0) < 0): inc crossings
  doAssert peak in 15000 .. 16500, $peak
  doAssert crossings in 195 .. 205, "1000 Hz for 0.1 s: " & $crossings
  for w in Waveform: doAssert makeTone(300, 20, 1.0, w).frames == 882
  doAssert makeTone(NaN, 10).frames == 441 and makeTone(440, -5).frames == 0
  let j = joinSounds([makeTone(440, 10), makeTone(880, 20), makeTone(440, 10, 0.5)])
  doAssert j.frames == 441 + 882 + 441

# ---- the mixer ------------------------------------------------------------------------------------

block mixing:
  var buf = newSeq[int16](200)
  mixTo(buf)
  doAssert buf.allIt(it == 0) or true
  # a constant mono sound: both channels get it
  var d = ""
  for i in 0 ..< 1000: d.add le16(8000)
  let flat = decodeWav(wav(1, 1, 44100, 16, d))
  let v1 = mixSound(flat, 1.0, start = false)
  mixTo(buf)
  doAssert abs(buf[50] - 8000) <= 2 and abs(buf[51] - 8000) <= 2, $buf[50]
  # two at once add up; volume scales
  let v2 = mixSound(flat, 0.5, start = false)
  mixTo(buf)
  doAssert abs(buf[10] - 12000) <= 3, $buf[10]
  unmix(v2)
  setMasterVolume(0.5)
  mixTo(buf)
  doAssert abs(buf[10] - 4000) <= 2
  setMasterVolume(1)
  # it ends after its frames, and leaves the mixer
  var big = newSeq[int16](4000)
  mixTo(big)
  doAssert not mixing(v1), "ended"
  doAssert big[^1] == 0
  # half the rate: twice as long
  let slow = decodeWav(wav(1, 1, 22050, 16, d))
  let v3 = mixSound(slow, start = false)
  var n = 0
  var chunk = newSeq[int16](200)
  while mixing(v3) and n < 100:
    mixTo(chunk)
    inc n
  doAssert n in 19 .. 21, "1000 frames at 22050 Hz: about 2000 at 44100: " & $n
  # a loop goes round
  let v4 = mixSound(flat, loop = true, start = false)
  for i in 0 .. 30: mixTo(chunk)
  doAssert mixing(v4) and abs(chunk[0] - 8000) <= 2
  unmixAll()
  doAssert not mixing(v4)
  # louder than full scale: soft, not wrapped round
  let loud = decodeWav(wav(1, 1, 44100, 16, le16(30000).repeat(500)))
  for i in 0 .. 3: discard mixSound(loud, start = false)
  mixTo(buf)
  doAssert buf[20] > 30000 and buf[20] <= 32767
  unmixAll()

block playing:
  # on this machine: whatever output there is (often none) -- quietly
  let id = playSound(makeTone(440, 60, 0.1))
  doAssert id != NoSound
  var waited = 0
  while soundPlaying(id) and waited < 3000:
    os.sleep(20)
    waited += 20
  doAssert not soundPlaying(id), "it ends (or is dropped without a device)"
  doAssert audioOutputName() in ["pulse", "alsa", "none"], audioOutputName()
  doAssert playSound("no such file.wav") == NoSound
  doAssert playSound(Sound(nil)) == NoSound
  beep()
  for k in UiSound: uiSound(k)
  stopAllSounds()
  # a WAV file, played (and cached) by its path
  let tmp = getTempDir() / "retro-media-test.wav"
  writeFile(tmp, encodeWav(makeTone(300, 40, 0.1)))
  let w = playSound(tmp, 0.2)
  doAssert w != NoSound
  setSoundVolume(w, 0.1)
  stopSound(w)
  doAssert not soundPlaying(w)
  removeFile(tmp)

# ---- the platform's own player (Android), with a fake one ----------------------------------------

var calls: seq[string]
var videoPlaying = "0"
systemRelays.call = proc (name, arg: string): string {.gcsafe, nimcall.} =
  {.cast(gcsafe).}:
    calls.add name & "|" & arg
    case name
    of "media.play": "1"
    of "media.playing": "1"
    of "media.videoState": videoPlaying & "\t1500\t60000\t0"
    else: "1"

proc callsOf(prefix: string): seq[string] =
  for c in calls:
    if c.startsWith(prefix): result.add c

block androidSounds:
  mediaThroughSystem = true
  calls.setLen(0)
  let f = getTempDir() / "retro-media-song.mp3"
  writeFile(f, "not really an mp3")
  let id = playSound(f, 0.5, loop = true)
  doAssert id != NoSound
  doAssert calls[^1] == "media.play|" & $int(id) & "\t" & f & "\t0.500\t1", calls[^1]
  doAssert soundPlaying(id) and calls[^1] == "media.playing|" & $int(id)
  setSoundVolume(id, 0.25)
  doAssert calls[^1] == "media.volume|" & $int(id) & "\t0.250"
  stopSound(id)
  doAssert calls[^1] == "media.stop|" & $int(id)
  # a sound made here: written once as a WAV file, which the platform plays
  let t = makeTone(500, 30)
  let a = playSound(t)
  let path = calls[^1].split('|')[1].split('\t')[1]
  doAssert a != NoSound and fileExists(path) and decodeWav(readFile(path)).frames == t.frames
  let before = calls.len
  discard playSound(t)
  doAssert calls.len == before + 1, "written only once"
  removeFile(f)

block androidVideo:
  mediaThroughSystem = true
  calls.setLen(0)
  let clip = getTempDir() / "retro-media-clip.mp4"
  writeFile(clip, "video")
  var showVideo = true
  var dlgOpen = false
  var ev: VideoEvent
  var vr: Rect
  view = proc () =
    if showVideo:
      ev = videoView(clip, height = 200, key = "promo")
      vr = ui.lastRect
    dialog(dlgOpen, "Over it", 200):
      label "A dialog"
  run(2)
  let shows = callsOf("media.videoShow|")
  doAssert shows.len == 1, $shows
  let p = shows[0].split('|')[1].split('\t')
  doAssert p[0] == "promo" and p[1] == $(vr.x * pxScale) and p[5] == clip and p[6] == "0"
  doAssert parseInt(p[4]) == (200 - CtrlH - dp(6)) * pxScale, "the picture, without the controls"
  run(3)
  doAssert callsOf("media.videoShow|").len == 1, "not sent again while it stays"
  doAssert ev.durationMs == 60000 and ev.positionMs == 1500, $ev
  # the play button
  calls.setLen(0)
  click(rect(vr.x + dp(3), vr.y + vr.h - CtrlH - dp(3), CtrlH, CtrlH), dx = CtrlH div 2)
  doAssert callsOf("media.videoPlay|promo").len == 1, $calls
  # Space pauses (the picture has the focus after a click on it)
  videoPlaying = "1"
  ticks += 300
  run(2)
  calls.setLen(0)
  click(rect(vr.x, vr.y, vr.w, 50), dx = vr.w div 2)
  doAssert callsOf("media.videoPause|promo").len == 1, $calls
  key(KeyRight)
  run()
  doAssert callsOf("media.videoSeek|promo\t").len == 1
  # a dialog over it: hidden; closed again: shown again
  calls.setLen(0)
  dlgOpen = true
  run(2)
  doAssert callsOf("media.videoHide|promo").len == 1, $calls
  dlgOpen = false
  run(3)
  doAssert callsOf("media.videoShow|promo").len == 1, $calls
  # not drawn: hidden
  calls.setLen(0)
  showVideo = false
  run(2)
  doAssert callsOf("media.videoHide|promo").len == 1
  closeVideo("promo")
  doAssert callsOf("media.videoClose|promo").len == 1
  removeFile(clip)
  mediaThroughSystem = false

# ---- GIF ------------------------------------------------------------------------------------------

type GifF = object
  x, y, w, h: int
  pix: seq[int]
  delay, transparent, disposal: int
  interlace: bool
  local: seq[uint32]

proc gif(w, h: int; pal: seq[uint32]; frames: seq[GifF]): string =
  ## A GIF writer for the tests (its LZW starts over every two codes).
  proc u16(v: int): string = char(v and 255) & char(v shr 8)
  proc table(p: seq[uint32]): string =
    for c in p: result.add char((c shr 16) and 255) & char((c shr 8) and 255) & char(c and 255)
  proc bitsFor(n: int): int =
    result = 1
    while (1 shl result) < n: inc result
  result = "GIF89a" & u16(w) & u16(h)
  let gb = bitsFor(pal.len)
  result.add char(0x80 or (gb - 1)) & "\0\0" & table(pal)
  for _ in pal.len ..< (1 shl gb): result.add "\0\0\0"
  for f in frames:
    result.add "\x21\xF9\x04" & char((f.disposal shl 2) or (if f.transparent >= 0: 1 else: 0)) &
               u16(f.delay) & char(max(0, f.transparent)) & "\0"
    let p = if f.local.len > 0: f.local else: pal
    let lb = bitsFor(p.len)
    result.add "\x2C" & u16(f.x) & u16(f.y) & u16(f.w) & u16(f.h)
    var packed = if f.interlace: 0x40 else: 0
    if f.local.len > 0: packed = packed or 0x80 or (lb - 1)
    result.add char(packed)
    if f.local.len > 0:
      result.add table(p)
      for _ in p.len ..< (1 shl lb): result.add "\0\0\0"
    let minCode = max(2, lb)
    result.add char(minCode)
    var rows: seq[int]
    if f.interlace:
      for (s, st) in [(0, 8), (4, 8), (2, 4), (1, 2)]:
        var y = s
        while y < f.h:
          rows.add y
          y += st
    else:
      for y in 0 ..< f.h: rows.add y
    var codes: seq[int]
    let clear = 1 shl minCode
    var k = 0
    for y in rows:
      for x in 0 ..< f.w:
        if k mod 2 == 0: codes.add clear
        codes.add f.pix[y * f.w + x]
        inc k
    codes.add clear + 1
    var bytes = ""
    var acc, nb = 0
    for c in codes:
      acc = acc or (c shl nb)
      nb += minCode + 1
      while nb >= 8:
        bytes.add char(acc and 255)
        acc = acc shr 8
        nb -= 8
    if nb > 0: bytes.add char(acc and 255)
    var i = 0
    while i < bytes.len:
      let n = min(255, bytes.len - i)
      result.add char(n) & bytes[i ..< i + n]
      i += n
    result.add "\0"
  result.add "\x3B"

const R = 0xFFFF0000'u32
const G = 0xFF00FF00'u32
const B = 0xFF0000FF'u32
const Y = 0xFFFFFF00'u32

block gifFrames:
  # three frames from a real encoder (Pillow)
  let rgb = loadGif(readFile("tests/data/media/rgb.gif"))
  doAssert rgb.len == 3
  doAssert rgb[0].image.px[0] == R and rgb[1].image.px[5] == G and rgb[2].image.px[15] == B
  doAssert rgb[0].delayMs == 100 and rgb[1].delayMs == 200 and rgb[2].delayMs == 300
  # long LZW strings, interlaced rows (Pillow), against the colors drawn
  let pat = loadGif(readFile("tests/data/media/pattern.gif"))
  doAssert pat.len == 1 and pat[0].image.w == 40 and pat[0].image.h == 30
  proc palette(i: int): uint32 =
    0xFF000000'u32 or (uint32(i * 16) shl 16) or (uint32(255 - i * 16) shl 8) or uint32((i * 37) mod 256)
  for y in 0 ..< 30:
    for x in 0 ..< 40:
      let i = if (x + y) mod 7 != 0: ((x div 4) + (y div 3)) mod 16 else: 3
      doAssert pat[0].image.px[y * 40 + x] == palette(i), "pixel " & $x & "," & $y
  # transparency, disposal, offsets, a local table, interlace: written here
  let pal = @[Y, R, G, B]
  let frames = @[
    GifF(x: 0, y: 0, w: 4, h: 4, pix: newSeqWith(16, 0), delay: 5, transparent: -1),
    GifF(x: 1, y: 1, w: 2, h: 2, pix: @[1, 3, 3, 1], delay: 1, transparent: 3, disposal: 2),
    GifF(x: 0, y: 0, w: 1, h: 1, pix: @[0], delay: 7, transparent: 0, disposal: 3),
    GifF(x: 2, y: 0, w: 2, h: 3, pix: @[0, 1, 1, 0, 0, 1], delay: 8, transparent: -1,
         interlace: true, local: @[B, G])]
  let g = loadGif(gif(4, 4, pal, frames))
  doAssert g.len == 4
  doAssert g[0].image.px.allIt(it == Y) and g[0].delayMs == 50
  doAssert g[1].image.px[1 * 4 + 1] == R and g[1].image.px[1 * 4 + 2] == Y, "transparent: what was there"
  doAssert g[1].delayMs == 100, "very short delays become 100 ms"
  doAssert g[2].image.px[1 * 4 + 1] == 0, "disposal 2: cleared"
  doAssert g[2].image.px[0] == Y
  doAssert g[3].image.px[0 * 4 + 2] == B and g[3].image.px[0 * 4 + 3] == G
  doAssert g[3].image.px[1 * 4 + 2] == G and g[3].image.px[1 * 4 + 3] == B and
           g[3].image.px[2 * 4 + 3] == G, "local table, interlaced"
  # damaged: the frames before the damage, or refused
  let good = gif(4, 4, pal, frames)
  let cut = loadGif(good[0 ..< good.len - 25])
  doAssert cut.len in 1 .. 3
  for bad in ["", "GIF89a", "GIF89a\0\0\0\0\0\0\0", "PNG\x89", good[0 .. 12],
              "GIF89a\xFF\xFF\xFF\xFF\0\0\0"]:
    var refused = false
    try: discard loadGif(bad)
    except ValueError: refused = true
    doAssert refused
  doAssert isGif(good) and not isGif("GIF88a")

block animationWakes:
  let frames = loadGif(readFile("tests/data/media/rgb.gif"))
  var paused = false
  var r: Rect
  view = proc () = r = animation(frames, height = 40, paused = paused, key = "a")
  run(2)
  doAssert r.w == 40 and r.h == 40
  let start = ui.now
  doAssert ui.wakeAt > 0 and ui.wakeAt <= start + 100, "wakes when the next frame is due"
  let inner = (r.x + 20, r.y + 20)
  doAssert px(inner[0], inner[1]) == 0xFF0000, "the first frame"
  ticks += 110
  run()
  doAssert px(inner[0], inner[1]) == 0x00FF00, "the second frame after 100 ms"
  doAssert ui.wakeAt - ui.now in 1 .. 200
  paused = true
  ticks += 400
  run(2)
  let held = px(inner[0], inner[1])
  ticks += 1000
  run(2)
  doAssert px(inner[0], inner[1]) == held, "paused: the same frame"

# ---- a video in the window (GStreamer) -----------------------------------------------------------

block gstVideo:
  if not videoPlaysInWindow():
    echo "  (no GStreamer here: the video in the window is not tested)"
  else:
    gstAudioSink = "fakesink"
    var ev: VideoEvent
    var r: Rect
    var ended = false
    view = proc () =
      ev = videoView("tests/data/media/clip.avi", height = 160, w = 200, key = "clip")
      if ev.ended: ended = true
      r = ui.lastRect
    var guard = 0
    proc drawnPicture(): bool =
      # anything but black in the picture
      for y in r.y + 10 ..< r.y + 100:
        for x in r.x + 10 ..< r.x + 190:
          if px(x, y) != 0: return true
    while (not drawnPicture() or ev.durationMs == 0) and guard < 200:
      run()
      os.sleep(10)
      inc guard
    doAssert drawnPicture(), "the first picture before it plays"
    doAssert not ev.playing and ev.durationMs in 900 .. 1100, $ev
    # play to the end
    click(rect(r.x + dp(3), r.y + r.h - CtrlH - dp(3), CtrlH, CtrlH), dx = CtrlH div 2)
    guard = 0
    while not ended and guard < 400:
      run()
      os.sleep(10)
      inc guard
    doAssert ended, "it plays to the end"
    doAssert not ev.playing
    closeVideo("clip")
    # sound files through GStreamer
    let s = playSound("tests/data/media/beep.ogg")
    doAssert s != NoSound
    var waited = 0
    while soundPlaying(s) and waited < 3000:
      run()
      os.sleep(20)
      waited += 20
    doAssert not soundPlaying(s), "the ogg ended"
    doAssert playSound("tests/data/media/beep.mp3") != NoSound
    stopAllSounds()

block missingVideo:
  var ev: VideoEvent
  view = proc () = ev = videoView("no such video.mp4", height = 120)
  run(2)
  doAssert ev.error.len > 0 and not ev.playing

echo "media tests passed"

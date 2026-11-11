## Sound, video and animations, with nothing to install: the kit decodes
## WAV files and makes tones itself and plays them through the system's
## own audio output (loaded only when the first sound plays); other kinds
## of files go to the system's player where there is one.
##
## - `playSound(path)`, `playSound(sound)`, `stopSound`, `soundPlaying`,
##   `setSoundVolume`, `stopAllSounds`, `setMasterVolume`
## - `decodeWav`, `encodeWav`, `makeTone`, `joinSounds`: sounds in memory
## - `tone`, `beep`, `uiSound`: short sounds made on the spot (no files)
## - `videoView(path)`: a video in the window, with play / pause, a
##   position bar and the time
## - `videoInfo`, `videoFrameAt`, `videoFrames`, `videoFrame`: reading
##   videos -- size, frame rate, length, the picture at any time
## - `beginVideo`, `addFrame`, `finish`: writing MP4 videos (H.264)
## - `loadGif`, `animation`: animated GIF pictures
##
## What plays where:
##
## ============  ===========================  ==========================  ============================
## Platform      WAV, tones                   MP3, OGG, AAC, FLAC...      Video (`videoView`)
## ============  ===========================  ==========================  ============================
## Linux, BSD    PulseAudio or ALSA           GStreamer, when installed   in the window (GStreamer)
## Termux (X11)  PulseAudio                   GStreamer, when installed   in the window (GStreamer)
## Windows       waveOut                      the system (MCI)            in the window (Media Foundation)
## macOS, iOS    AudioQueue                   AVAudioPlayer               in the window (AVFoundation)
## Android       MediaPlayer                  MediaPlayer                 in the window (VideoView)
## ============  ===========================  ==========================  ============================
##
## Without a sound device, or a format the system cannot play, sounds are
## quietly not heard (`playSound` gives `NoSound`); nothing waits or
## crashes.
##
## Reading and writing videos: Android through the system (MediaMetadataRetriever;
## MediaCodec and MediaMuxer); Linux with GStreamer; any desktop with the
## `ffmpeg` program installed (reading without GStreamer, and writing:
## libx264, else libopenh264, else MPEG-4 part 2); Windows without ffmpeg
## writes through Media Foundation.
##
## .. code-block:: nim
##   let v = beginVideo("spin.mp4", 640, 360, fps = 30)
##   for k in 0 ..< 90: v.addFrame(drawFrame(k))     # Bitmaps
##   if not v.finish(): echo v.error
##   let pic = videoFrameAt("spin.mp4", ms = 1500, maxSide = 320)
##
## .. code-block:: nim
##   let ding = decodeWav(readFile("ding.wav"))
##   app "Media", 400, 300:
##     if button("&Ding"): discard playSound(ding)
##     if button("&Beep"): beep()
##     let v = videoView("intro.mp4", height = 200)

import std/[os, strutils, tables, hashes, times, osproc, streams, locks]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
from std/math import round
import gfx, core, widgets, platform, pixelicons, imaging
import uirelays/services
import mediaaudio, mediagif, mediagst, mediaplayer
from thumbcache import cacheFolder
export mediaaudio.Sound, mediaaudio.Waveform, mediaaudio.decodeWav,
       mediaaudio.encodeWav, mediaaudio.makeTone, mediaaudio.joinSounds,
       mediaaudio.rate, mediaaudio.channels, mediaaudio.frames, mediaaudio.duration,
       mediaaudio.sample, mediaaudio.mixTo, mediaaudio.setMasterVolume,
       mediaaudio.audioOutputName, mediaaudio.OutRate, mediaaudio.MaxWavBytes
export mediagif

template th: untyped = ui.theme

type
  SoundId* = distinct int
    ## A sound playing (to stop it, ask whether it still plays...).
  UiSound* = enum
    ## The short sounds `uiSound` makes.
    usClick, usNotify, usSuccess, usWarning, usError
  Backend = enum
    beMixer, beSystem, beGst, beMci, beAv
  Playing = object
    backend: Backend
    voice: int                 # beMixer
    gst: GstPlayer             # beGst
    av: pointer                # beAv: the AVAudioPlayer
    loop: bool

const NoSound* = SoundId(0)
  ## What `playSound` gives when the sound cannot be played.

proc `==`*(a, b: SoundId): bool {.borrow.}
  ## The same sound.
proc `$`*(a: SoundId): string {.borrow.}
  ## The sound's number as text.

var
  mediaThroughSystem* = androidApp
    ## Sounds and videos go to the platform's own side
    ## (`systemCall("media.*")`): Android (set there by itself). Tests set it to check the
    ## calls.
  gstAudioSink* = ""
    ## The GStreamer element for the sound of files and videos ("" the
    ## system's; "fakesink" none -- for tests).
  playing: Table[int, Playing]
  nextSound = 1
  wavCache: Table[string, Sound]
  uiSounds: array[UiSound, Sound]
  hooked = false

proc cacheDir(): string =
  ## (sounds made into files, video frames on their way: the system's
  ## folder for caches, as the thumbnails -- not the app's own data)
  result = cacheFolder("retro-media")
  try: createDir(result) except OSError: discard

# ---- the platforms' own players ------------------------------------------------------------------

when defined(windows):
  proc mciSendStringW(cmd: WideCString; ret: WideCString; retLen: uint32;
                      cb: pointer): uint32 {.stdcall, dynlib: "winmm", importc.}
  proc mci(cmd: string): string =
    var buf = newWideCString(newString(128))
    if mciSendStringW(newWideCString(cmd), buf, 128, nil) != 0: return "\0"
    $buf

when defined(macosx) or defined(ios):
  import std/dynlib
  var
    objcLoaded = 0
    getClass: proc (name: cstring): pointer {.cdecl, gcsafe.}
    selector: proc (name: cstring): pointer {.cdecl, gcsafe.}
    msgSend: pointer
  proc objcReady(): bool =
    if objcLoaded == 0:
      objcLoaded = -1
      let objc = loadLib("/usr/lib/libobjc.A.dylib")
      let av = loadLib("/System/Library/Frameworks/AVFoundation.framework/AVFoundation")
      if objc != nil and av != nil:
        getClass = cast[typeof(getClass)](objc.symAddr("objc_getClass"))
        selector = cast[typeof(selector)](objc.symAddr("sel_registerName"))
        msgSend = objc.symAddr("objc_msgSend")
        if getClass != nil and selector != nil and msgSend != nil: objcLoaded = 1
    objcLoaded == 1
  type
    Msg0 = proc (self0, cmd0: pointer): pointer {.cdecl.}
    MsgP = proc (self0, cmd0, arg0: pointer): pointer {.cdecl.}
    MsgPP = proc (self0, cmd0, arg0, arg1: pointer): pointer {.cdecl.}
    MsgI = proc (self0, cmd0: pointer; arg0: int) {.cdecl.}
    MsgF = proc (self0, cmd0: pointer; arg0: float32) {.cdecl.}
    MsgB = proc (self0, cmd0: pointer): int8 {.cdecl.}
  template send0(o: pointer; sel: string): pointer = cast[Msg0](msgSend)(o, selector(sel))
  template sendP(o: pointer; sel: string; a: pointer): pointer =
    cast[MsgP](msgSend)(o, selector(sel), a)
  template sendPP(o: pointer; sel: string; a, b: pointer): pointer =
    cast[MsgPP](msgSend)(o, selector(sel), a, b)
  template sendI(o: pointer; sel: string; a: int) = cast[MsgI](msgSend)(o, selector(sel), a)
  template sendF(o: pointer; sel: string; a: float32) = cast[MsgF](msgSend)(o, selector(sel), a)
  template sendB(o: pointer; sel: string): bool = cast[MsgB](msgSend)(o, selector(sel)) != 0

  proc avPlay(path: string; volume: float; loop: bool): pointer =
    if not objcReady(): return nil
    let str = sendP(getClass("NSString"), "stringWithUTF8String:", cstring(path))
    let url = sendP(getClass("NSURL"), "fileURLWithPath:", str)
    if url == nil: return nil
    let p = sendPP(send0(getClass("AVAudioPlayer"), "alloc"), "initWithContentsOfURL:error:",
                   url, nil)
    if p == nil: return nil
    sendF(p, "setVolume:", float32(volume))
    sendI(p, "setNumberOfLoops:", if loop: -1 else: 0)
    if not sendB(p, "play"):
      discard send0(p, "release")
      return nil
    p

proc pollSounds() =
  ## Each frame: sounds played by GStreamer that ended go round again or
  ## leave.
  var gone: seq[int]
  for id, p in playing.mpairs:
    if p.backend == beGst:
      discard p.gst.poll()
      if p.gst.ended or p.gst.failed:
        if p.loop and not p.gst.failed:
          p.gst.seekMs(0)
          p.gst.play()
        else:
          p.gst.close()
          gone.add id
  for id in gone: playing.del id

proc track(p: Playing): SoundId =
  result = SoundId(nextSound)
  playing[nextSound] = p
  inc nextSound
  if p.backend == beGst and not hooked:
    hooked = true
    beginFrameHooks.add pollSounds

# ---- playing --------------------------------------------------------------------------------------

proc systemPlay(path: string; volume: float; loop: bool): SoundId =
  let id = nextSound
  let r = systemCall("media.play", $id & "\t" & path & "\t" & formatFloat(volume, ffDecimal, 3) &
                     "\t" & (if loop: "1" else: "0"))
  if r != "1": return NoSound
  track(Playing(backend: beSystem, loop: loop))

proc playSound*(s: Sound; volume = 1.0; loop = false): SoundId =
  ## Plays `s` (made by `decodeWav`, `makeTone`...) over whatever else
  ## plays, at `volume` (1 as recorded), again and again with `loop`
  ## (until `stopSound`). `NoSound` when it cannot be played.
  if s == nil or s.frames == 0: return NoSound
  if mediaThroughSystem:
    # the platform plays files: the sound is written once to the app's folder
    if s.cacheFile.len == 0 or not fileExists(s.cacheFile):
      let f = cacheDir() / "sound-" & toHex(int(pcmHash(s)) and 0x7FFFFFFF, 8) & ".wav"
      try:
        if not fileExists(f): writeFile(f, encodeWav(s))
        s.cacheFile = f
      except IOError, OSError:
        return NoSound
    return systemPlay(s.cacheFile, volume, loop)
  let v = mixSound(s, volume, loop)
  if v == 0: NoSound else: track(Playing(backend: beMixer, voice: v, loop: loop))

proc playSound*(path: string; volume = 1.0; loop = false): SoundId =
  ## Plays the sound file `path`: WAV everywhere; MP3, OGG, AAC, FLAC and
  ## others where the system plays them (see the table above). `NoSound`
  ## when the file is missing or cannot be played here.
  if not fileExists(path): return NoSound
  if mediaThroughSystem: return systemPlay(path, volume, loop)
  if path.toLowerAscii.endsWith(".wav"):
    let key = path & "\0" & $getLastModificationTime(path).toUnix
    var s = wavCache.getOrDefault(key)
    if s == nil:
      try:
        s = decodeWav(readFile(path))
      except CatchableError:
        s = nil
      if s != nil:
        if wavCache.len > 32: wavCache.clear()
        wavCache[key] = s
    if s != nil: return playSound(s, volume, loop)
  when defined(windows):
    let id = nextSound
    let alias = "retro" & $id
    if mci("open \"" & path & "\" type mpegvideo alias " & alias) == "\0": return NoSound
    discard mci("setaudio " & alias & " volume to " & $int(clamp(volume, 0.0, 1.0) * 1000))
    if mci("play " & alias & (if loop: " repeat" else: "")) == "\0":
      discard mci("close " & alias)
      return NoSound
    return track(Playing(backend: beMci, loop: loop))
  elif defined(macosx) or defined(ios):
    let p = avPlay(path, volume, loop)
    if p == nil: return NoSound
    return track(Playing(backend: beAv, av: p, loop: loop))
  else:
    let g = gstOpen(path, video = false, audioSink = gstAudioSink)
    if g == nil: return NoSound
    g.setVolume(volume)
    g.play()
    return track(Playing(backend: beGst, gst: g, loop: loop))

proc soundPlaying*(id: SoundId): bool =
  ## The sound `id` is still playing.
  let k = int(id)
  if not playing.hasKey(k): return false
  let p = playing[k]
  case p.backend
  of beMixer: result = mixing(p.voice)
  of beSystem: result = systemCall("media.playing", $k) == "1"
  of beGst:
    discard p.gst.poll()
    result = not (p.gst.ended or p.gst.failed) or p.loop
  of beMci:
    when defined(windows): result = mci("status retro" & $k & " mode") == "playing"
  of beAv:
    when defined(macosx) or defined(ios): result = sendB(p.av, "isPlaying")
  if not result:
    if p.backend == beGst: p.gst.close()
    playing.del k

proc stopSound*(id: SoundId) =
  ## Stops the sound `id` (nothing happens when it ended already).
  let k = int(id)
  if not playing.hasKey(k): return
  let p = playing[k]
  case p.backend
  of beMixer: unmix(p.voice)
  of beSystem: discard systemCall("media.stop", $k)
  of beGst: p.gst.close()
  of beMci:
    when defined(windows): discard mci("close retro" & $k)
  of beAv:
    when defined(macosx) or defined(ios):
      discard send0(p.av, "stop")
      discard send0(p.av, "release")
  playing.del k

proc stopAllSounds*() =
  ## Stops every sound.
  var ids: seq[int]
  for k in playing.keys: ids.add k
  for k in ids: stopSound(SoundId(k))
  unmixAll()

proc setSoundVolume*(id: SoundId; volume: float) =
  ## Changes the volume of a sound while it plays (1 as recorded).
  let k = int(id)
  if not playing.hasKey(k): return
  let p = playing[k]
  case p.backend
  of beMixer: setMixVolume(p.voice, volume)
  of beSystem: discard systemCall("media.volume", $k & "\t" & formatFloat(volume, ffDecimal, 3))
  of beGst: p.gst.setVolume(volume)
  of beMci:
    when defined(windows):
      discard mci("setaudio retro" & $k & " volume to " & $int(clamp(volume, 0.0, 1.0) * 1000))
  of beAv:
    when defined(macosx) or defined(ios): sendF(p.av, "setVolume:", float32(volume))

proc tone*(hz: float; ms: int; volume = 0.5; wave = wSine): SoundId {.discardable.} =
  ## Plays a tone of `hz` hertz for `ms` milliseconds.
  playSound(makeTone(hz, ms, volume, wave))

proc beep*() =
  ## The short beep of an app that says "no" (or "look here").
  discard tone(800, 140, 0.35, wSquare)

proc uiSound*(kind: UiSound; volume = 1.0) =
  ## A short sound for the moments apps have them: a click, a new
  ## message, something done, a warning, an error. Made here, no files.
  if uiSounds[kind] == nil:
    uiSounds[kind] = case kind
      of usClick: makeTone(1800, 18, 0.25, wSine, 3)
      of usNotify: joinSounds([makeTone(660, 110, 0.35), makeTone(880, 160, 0.35)])
      of usSuccess: joinSounds([makeTone(523, 90, 0.3), makeTone(659, 90, 0.3),
                                makeTone(784, 160, 0.3)])
      of usWarning: joinSounds([makeTone(440, 140, 0.35, wTriangle),
                                makeTone(330, 200, 0.35, wTriangle)])
      of usError: makeTone(196, 260, 0.3, wSquare)
  discard playSound(uiSounds[kind], volume)

# ---- animations ---------------------------------------------------------------------------------

proc animation*(frames: openArray[GifFrame]; height = 0; w = 0; paused = false;
                key = ""): Rect {.discardable.} =
  ## Plays the frames of `loadGif` round and round, each for its delay; the
  ## first frame's size (or `height` with its proportions kept, or `w`).
  ## It wakes the app only when the next frame is due. `paused` holds the
  ## frame shown. Returns where it is.
  if frames.len == 0 or frames[0].image == nil: return
  let fw = frames[0].image.w
  let fh = frames[0].image.h
  let hh = if height > 0: height elif w > 0: w * fh div max(1, fw) else: fh
  let ww = if w > 0: w else: hh * fw div max(1, fh)
  let r = place(ww, hh)
  let id = idOf("animation:" & key)
  var st = state(id)
  var total = 0
  for f in frames: total += max(10, f.delayMs)
  if st.aux == 0:                         # first seen: it starts now
    st.aux = 1
    st.anchor = ui.now
  if paused:
    if st.aux2 == 0: st.aux2 = max(1, ui.now - st.anchor + 1)
  elif st.aux2 != 0:
    st.anchor = ui.now - (st.aux2 - 1)    # going on from where it stopped
    st.aux2 = 0
  let t = (if st.aux2 != 0: st.aux2 - 1 else: ui.now - st.anchor) mod max(1, total)
  var at = 0
  var k = 0
  while k < frames.high and at + max(10, frames[k].delayMs) <= t:
    at += max(10, frames[k].delayMs)
    inc k
  if not paused and frames.len > 1:
    wakeInShown(r, at + max(10, frames[k].delayMs) - t)    # (out of view: no frames)
  state(id) = st
  drawBitmap(r, frames[k].image)
  ui.lastId = id
  ui.lastRect = r
  r

# ---- video ------------------------------------------------------------------------------------------

type
  VideoEvent* = object
    ## What a `videoView` is doing.
    playing*: bool           ## it is playing (not paused or stopped)
    ended*: bool             ## it played to the end (this frame)
    positionMs*, durationMs*: int  ## where it is and how long it is (ms; 0: not known yet)
    error*: string           ## why it cannot play ("" when it can)
  VideoState = ref object
    path: string
    audio: bool              # a sound: its name in a panel, no picture
    sound: SoundId           # (played by `playSound` where nothing else can)
    gst: MediaPlayer         # the system's player, drawn by the kit (`mediaplayer`)
    tried: bool
    shown: bool              # the system's view is over the window
    shownRect: Rect
    drawnFrame: int
    drawnDialog: Id
    playing, ended: bool
    pos, dur: int
    polledAt: int
    error: string

var videos: Table[string, VideoState]
var videoHook = false

proc videoPlaysInWindow*(): bool =
  ## `videoView` shows videos inside the window here: Android (the system's
  ## view), Windows (Media Foundation), macOS and iOS (AVFoundation), Linux
  ## and other Unix systems with GStreamer; elsewhere it offers the
  ## system's player.
  mediaThroughSystem or playerAvailable()

proc deviceRect(r: Rect): Rect =
  rect(r.x * pxScale, r.y * pxScale, r.w * pxScale, r.h * pxScale)

proc hideCovered() =
  ## After every frame: a system video view not drawn this frame, or with
  ## a menu or a dialog over it, is hidden (it sits above the kit's
  ## drawing); a GStreamer video not drawn pauses.
  for key, v in videos:
    let drawn = v.drawnFrame == ui.frameNo
    let dlg = if ui.dialogTopNow != 0: ui.dialogTopNow else: ui.dialogTop
    let covered = ui.popup != 0 or (dlg != 0 and v.drawnDialog != dlg)
    if v.shown and (not drawn or covered):
      v.shown = false
      discard systemCall("media.videoHide", key)
    if v.gst != nil and not drawn and v.playing:
      v.gst.pause()
      v.playing = false

proc timeText(ms: int): string =
  let s = max(0, ms) div 1000
  $(s div 60) & ":" & align($(s mod 60), 2, '0')

proc videoView*(path: string; height = -1; w = 0; autoplay = false; controls = true;
                key = ""; audio = false): VideoEvent {.discardable.} =
  ## A video in the window, with play / pause, a position bar and the time
  ## under it (`controls`); Space plays and pauses, Left / Right go back
  ## and on 5 seconds, Home to the start, when it has the focus; a click on
  ## the picture plays and pauses. `path` is a file or a web address
  ## (http, https; HLS where the system plays it). The system's own player
  ## plays it and the kit draws its pictures in the window (under its
  ## menus and dialogs): Media Foundation on Windows, AVFoundation on macOS
  ## and iOS, GStreamer on Linux; in an Android app the system's VideoView
  ## shows it (hidden while a menu or a dialog is over it). Where there is
  ## none it shows a button that opens the file in the system's player.
  ## `key` tells several apart. `audio`: a sound file (`audioView`).
  let k = if key.len > 0: key else: path
  var v = videos.getOrDefault(k)
  if v == nil or v.path != path or v.audio != audio:
    if v != nil and v.gst != nil: v.gst.close()
    if v != nil and v.sound != NoSound: stopSound(v.sound)
    v = VideoState(path: path, audio: audio, sound: NoSound)
    videos[k] = v
  if not videoHook:
    videoHook = true
    endFrameHooks.add hideCovered
  let barH = if controls: CtrlH + dp(6) else: 0
  let hh = if height < 0: remainingH() else: height
  let r = place(if w > 0: w else: 0, hh, fill = w <= 0)
  let area = rect(r.x, r.y, r.w, max(dp(20), r.h - barH))
  let id = idOf("video:" & k)
  let hit = interact(id, area)
  v.drawnFrame = ui.frameNo
  v.drawnDialog = ui.curDialog
  let exists = isStream(path) or fileExists(path)
  if not exists: v.error = "There is no file " & path.extractFilename & "."
  # the player
  var toggle, toStart = false
  var seekTo = -1
  if hit.clicked: toggle = true
  if hit.focused and canInput():
    if keyHit(KeySpace): toggle = true
    elif keyHit(KeyLeft): seekTo = max(0, v.pos - 5000)
    elif keyHit(KeyRight): seekTo = min(max(0, v.dur - 100), v.pos + 5000)
    elif keyHit(KeyHome): toStart = true
  let mode = if not exists: 0
             elif mediaThroughSystem: 1
             elif playerAvailable(): 2
             elif audio: 3
             else: 0
  case mode
  of 1:
    # the platform's own view, over the area (a sound's: a dot in its corner)
    let dr = if audio: deviceRect(rect(area.x, area.y, 1, 1)) else: deviceRect(area)
    let covered = ui.popup != 0 or
                  ((ui.dialogTopNow != 0 or ui.dialogTop != 0) and ui.curDialog == 0)
    if not covered and (not v.shown or dr != v.shownRect):
      if systemCall("media.videoShow", k & "\t" & $dr.x & "\t" & $dr.y & "\t" & $dr.w & "\t" &
                    $dr.h & "\t" & path & "\t" & (if autoplay and not v.tried: "1" else: "0")) == "\0":
        v.error = "The system cannot show this video."
      else:
        v.shown = true
        v.shownRect = dr
        if autoplay and not v.tried: v.playing = true
      v.tried = true
    if toggle:
      discard systemCall(if v.playing: "media.videoPause" else: "media.videoPlay", k)
      v.playing = not v.playing
    if toStart: seekTo = 0
    if seekTo >= 0:
      discard systemCall("media.videoSeek", k & "\t" & $seekTo)
      v.pos = seekTo
    if ui.now - v.polledAt >= 250 or ui.now < v.polledAt:
      v.polledAt = ui.now
      let s = systemCall("media.videoState", k).split('\t')
      if s.len >= 4:
        v.playing = s[0] == "1"
        v.pos = (try: parseInt(s[1]) except ValueError: v.pos)
        v.dur = (try: parseInt(s[2]) except ValueError: v.dur)
        if s[3] == "1" and not v.ended: result.ended = true
        v.ended = s[3] == "1"
    if v.playing: wakeIn(250)
    fill(area, color(0, 0, 0))
  of 2:
    if v.gst == nil and not v.tried:
      v.tried = true
      v.gst = openPlayer(path, video = not audio, audioSink = gstAudioSink)
      if v.gst == nil:
        v.error = if audio: "This sound cannot be played here." else: "This video cannot be played here."
      elif autoplay:
        v.gst.play()
        v.playing = true
      else: v.gst.showFirstPicture()
    let g = v.gst
    if g != nil:
      if toggle:
        if v.playing: g.pause()
        else:
          if v.ended: g.seekMs(0)
          g.play()
        v.playing = not v.playing
        v.ended = false
      if toStart: seekTo = 0
      if seekTo >= 0:
        g.seekMs(seekTo)
        v.pos = seekTo
      discard g.poll()
      if g.failed:
        v.error = if audio: "This sound cannot be played here." else: "This video cannot be played here."
        v.playing = false
      if g.ended and not v.ended:
        v.ended = true
        v.playing = false
        result.ended = true
      v.pos = g.positionMs
      if v.dur == 0: v.dur = g.durationMs
      if v.playing or (g.frame == nil and not audio):
        if audio: wakeIn(250)            # (sound plays on when scrolled away)
        else: wakeInShown(area, 15)
    fill(area, color(0, 0, 0))
    if g != nil and g.frame != nil and not audio:
      # the picture, as large as fits, in proportion
      let f = g.frame
      let s = min(area.w / f.w, area.h / f.h)
      let pw = int(f.w.float * s)
      let ph = int(f.h.float * s)
      drawBitmap(rect(area.x + (area.w - pw) div 2, area.y + (area.h - ph) div 2, pw, ph), f)
  of 3:
    # a sound where only `playSound` plays it (no position: from the start)
    if toggle or toStart:
      if v.sound != NoSound and soundPlaying(v.sound):
        stopSound(v.sound)
        v.sound = NoSound
        v.playing = false
      else:
        v.sound = playSound(path)
        v.playing = v.sound != NoSound
        if not v.playing: v.error = "This sound cannot be played here."
    if v.playing and not soundPlaying(v.sound):
      v.playing = false
      result.ended = true
    if v.playing: wakeIn(250)
  else:
    # no player in the window here: the system's player, on request
    fill(area, color(0, 0, 0))
    let d = min(area.h div 3, dp(40))
    if d > dp(8):
      beginKeepSides(area)       # (play points right in every language)
      arrow(area.x + area.w div 2 + d div 6, area.y + area.h div 2 - FontH, dRight,
            color(255, 255, 255), d)
      endKeepSides()
    let name = ellipsize(path.extractFilename, area.w - dp(16))
    text(area.x + (area.w - textWidth(name)) div 2, area.y + area.h div 2 + d div 2,
         name, color(255, 255, 255))
    if exists and v.error.len == 0:
      v.error = "Videos open in the system's player on this platform."
  if audio:
    # a sound: its name in a panel, a note, how far it has played
    fill(area, th.window)
    sunken(area)
    let big = style(size = clamp(area.h.float / FontH.float / 3.2, 1.0, 5.0))
    let g = pxMusic
    let gh = lineHeight(big)
    let name = ellipsize(path.extractFilename, area.w - dp(16))
    let total = gh + FontH + dp(6)
    var y = area.y + max(dp(4), (area.h - total) div 2)
    if area.h >= total:
      text(area.x + (area.w - textWidth(g, big)) div 2, y, g, th.select, big)
      y += gh + dp(6)
    text(area.x + (area.w - textWidth(name)) div 2, min(y, area.y + area.h - FontH - dp(2)),
         name, th.text, true)
    if v.error.len > 0 and area.h >= total + FontH * 2:
      let e = ellipsize(v.error, area.w - dp(16))
      text(area.x + (area.w - textWidth(e)) div 2, y + FontH + dp(4), e, th.gray)
  if hit.focused: focusDots(inset(area, 2))
  # the controls
  if controls:
    let bar = rect(r.x, area.y + area.h, r.w, barH)
    # (the controls are not mirrored in a right-to-left interface: play
    # points right and time runs to the right, as on every player)
    beginKeepSides(bar)
    fill(bar, th.face)
    let b = rect(bar.x + dp(3), bar.y + dp(3), CtrlH, CtrlH)
    if mode == 0:
      pushFrame(rect(bar.x + dp(3), bar.y + dp(3), bar.w - dp(6), 0))
      if button("Play in the system's &player", enabled = exists): discard openFile(path)
      discard popFrame()
    else:
      let bh = interact(id + 1, b, focusable = false)
      buttonFace(b, bh.down, rounded = false, bevel = 1, hot = hovered(b))
      let c = th.text
      if v.playing:
        let bw = max(2, CtrlH div 7)
        fill(b.x + b.w div 2 - bw - bw div 2, b.y + CtrlH div 4, bw, CtrlH div 2, c)
        fill(b.x + b.w div 2 + bw div 2, b.y + CtrlH div 4, bw, CtrlH div 2, c)
      else: arrow(b.x + b.w div 2 + 1, b.y + b.h div 2, dRight, c, CtrlH div 2)
      if bh.clicked:
        if mode == 3:
          if v.playing:
            stopSound(v.sound)
            v.sound = NoSound
            v.playing = false
          else:
            v.sound = playSound(path)
            v.playing = v.sound != NoSound
        elif mode == 1:
          discard systemCall(if v.playing: "media.videoPause" else: "media.videoPlay", k)
          v.playing = not v.playing
        elif v.gst != nil:
          if v.playing: v.gst.pause()
          else:
            if v.ended: v.gst.seekMs(0)
            v.gst.play()
          v.playing = not v.playing
          v.ended = false
      # the position bar: a click or a drag goes there
      let tt = timeText(v.pos) & " / " & timeText(v.dur)
      let tw = textWidth(tt)
      let track = rect(b.x + b.w + dp(8), bar.y + barH div 2 - dp(4),
                       max(dp(20), bar.x + bar.w - tw - dp(12) - (b.x + b.w + dp(8))), dp(8))
      let th2 = interact(id + 2, rect(track.x, bar.y, track.w, barH), focusable = false)
      if th2.down and v.dur > 0:
        let ms = clamp((ui.mx - track.x) * v.dur div max(1, track.w), 0, v.dur)
        if abs(ms - v.pos) > 50:
          if mode == 1: discard systemCall("media.videoSeek", k & "\t" & $ms)
          elif v.gst != nil: v.gst.seekMs(ms)
          v.pos = ms
      fill(track, th.field)
      sunken(track)
      if v.dur > 0:
        let fx = track.w * clamp(v.pos, 0, v.dur) div v.dur
        fill(rect(track.x + 1, track.y + 1, max(0, fx - 1), track.h - 2), th.select)
        let thumb = rect(track.x + fx - dp(4), bar.y + dp(4), dp(8), barH - dp(8))
        buttonFace(thumb, false, rounded = false, bevel = 1)
      text(bar.x + bar.w - tw - dp(6), bar.y + (barH - FontH) div 2, tt, th.text)
    endKeepSides()
  result.playing = v.playing
  result.positionMs = v.pos
  result.durationMs = v.dur
  result.error = v.error
  if accessOn:
    accessNode(arImage, path.extractFilename, id = id, r = r, help = (if audio: "sound" else: "video"))
  ui.lastId = id
  ui.lastRect = r

proc audioView*(path: string; height = -1; autoplay = false; key = ""): VideoEvent {.discardable.} =
  ## A sound file to play: a panel with a note and its name, play / pause,
  ## a position bar and the time under it (MP3, OGG, FLAC, WAV... where the
  ## system plays them: Android; GStreamer on Linux; elsewhere it plays
  ## from the start with `playSound`, without the position). `closeVideo`
  ## stops it.
  videoView(path, height, 0, autoplay, true, key, audio = true)

proc closeVideo*(key: string) =
  ## Lets the player of the `videoView` (or `audioView`) with this `key`
  ## (or path) go.
  let v = videos.getOrDefault(key)
  if v == nil: return
  if v.sound != NoSound: stopSound(v.sound)
  if v.gst != nil: v.gst.close()
  if v.shown or mediaThroughSystem: discard systemCall("media.videoClose", key)
  videos.del key

# ---- reading videos -------------------------------------------------------------------------------
#
# Android: the system's MediaMetadataRetriever (tools/android/RetroMedia.java), kept open for the
# file last asked about, its pictures handed over raw (no PNG between). Linux and the like:
# GStreamer, when it is there. Without it (and on Windows and macOS) the `ffmpeg` program, when it
# is installed: one ffmpeg kept running for the file last asked about, decoding on from where it is
# -- a picture further on is read on, a jump back (or more than a few seconds on) starts it again a
# little before the place asked for.

type
  VideoInfo* = object
    ## What `videoInfo` tells of a video file.
    width*, height*: int     ## the picture's size, as shown (turned when the file says so)
    fps*: float              ## pictures a second (0: not known)
    durationMs*: int         ## how long it is (0: not known -- it cannot be read here)
    frames*: int             ## how many pictures (the file's count, else duration x fps; 0: not known)
  VideoTool* = enum
    ## What reads videos on desktops (see `videoTool`).
    vtAuto,                  ## GStreamer where it is, else ffmpeg
    vtGStreamer, vtFfmpeg

var
  videoTool* = vtAuto
    ## What reads videos on desktops (Android: always the system's side).
  ffmpegProgram* = ""
    ## The ffmpeg program videos are read and written with on desktops ("": the one on the
    ## PATH; ffprobe is looked for beside it).
  toolLock, readLock: Lock
  toolsLooked = false
  foundFfmpeg, foundFfprobe, ffEncoderList: string
  ffMajor = -1               # ffmpeg's version (0: not known)

initLock(toolLock)
initLock(readLock)

const toolOpts: set[ProcessOption] = when defined(windows): {poDaemon} else: {}  # (no console window)

proc lookForTools() =
  if toolsLooked: return
  toolsLooked = true
  when not (androidApp or defined(ios)):
    foundFfmpeg = findExe("ffmpeg")
    foundFfprobe = findExe("ffprobe")

proc ffmpegExe*(): string {.gcsafe.} =
  ## The ffmpeg program videos are read and written with here ("": none).
  {.cast(gcsafe).}:
    withLock toolLock:
      if ffmpegProgram.len > 0: return (if fileExists(ffmpegProgram): ffmpegProgram else: "")
      lookForTools()
      result = foundFfmpeg

proc ffprobeExe(): string =
  {.cast(gcsafe).}:
    withLock toolLock:
      if ffmpegProgram.len > 0:
        let p = ffmpegProgram.parentDir / ("ffprobe" & ExeExt)
        return (if fileExists(p): p else: "")
      lookForTools()
      result = foundFfprobe

proc readFull(s: Stream; p: pointer; n: int): bool =
  ## Exactly `n` bytes from a pipe (Windows' give what is there).
  var got = 0
  while got < n:
    let k = try: s.readData(cast[pointer](cast[int](p) + got), n - got)
            except CatchableError: 0
    if k <= 0: return false
    got += k
  true

proc toolRun(exe: string; args: openArray[string]): string =
  ## What `exe` writes (its errors too) by the time it ends. (Not on
  ## Android, before 9 without posix_spawn, nor iOS: no tools there.)
  if exe.len == 0: return ""
  when androidApp or defined(ios):
    result = ""
  else:
    try:
      let p = startProcess(exe, args = args, options = toolOpts + {poStdErrToStdOut})
      try:
        result = p.outputStream.readAll()
        discard p.waitForExit()
      finally:
        p.close()
    except CatchableError:
      result = ""

proc ffVersion(): int =
  ## ffmpeg's major version (0 when it does not say: taken as new).
  {.cast(gcsafe).}:
    if ffMajor < 0:
      let v = toolRun(ffmpegExe(), ["-hide_banner", "-version"])
      ffMajor = 0
      let k = v.find("version ")
      if k >= 0:
        var i = k + 8
        while i < v.len and v[i] notin {'0'..'9'} and v[i] != ' ': inc i   # "n6.1"
        var n = 0
        var digits = false
        while i < v.len and v[i] in {'0'..'9'}:
          n = n * 10 + ord(v[i]) - ord('0')
          digits = true
          inc i
        if digits and i < v.len and v[i] == '.': ffMajor = n
    ffMajor

proc rate(s: string): float =
  ## "30000/1001", "25", "12.5" as a number (0: none).
  let s = s.strip(chars = {'"', ' ', '\r'})
  let k = s.find('/')
  try:
    if k > 0:
      let d = parseFloat(s[k + 1 .. ^1])
      if d != 0: result = parseFloat(s[0 ..< k]) / d
    elif s.len > 0: result = parseFloat(s)
  except ValueError: result = 0
  if result != result or result < 0 or result > 10000: result = 0      # NaN, nonsense

proc seconds(s: string): float =
  result = try: parseFloat(s.strip(chars = {'"', ' ', '\r'})) except ValueError: 0.0
  if result != result or result < 0: result = 0                         # NaN, "N/A"

proc ffInfo(path: string): VideoInfo =
  ## ffprobe's word on the video (or ffmpeg's, when there is no ffprobe).
  var rot = 0
  var avg, real, sdur, fdur: float
  let probe = ffprobeExe()
  if probe.len > 0:
    let o = toolRun(probe, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                            "stream=width,height,avg_frame_rate,r_frame_rate,nb_frames,duration:" &
                            "stream_side_data=rotation:stream_tags=rotate:format=duration",
                            "-of", "flat", path])
    for line in o.splitLines:
      let k = line.find('=')
      if k < 0: continue
      let key = line[0 ..< k]
      let v = line[k + 1 .. ^1].strip(chars = {'"', ' ', '\r'})
      template num(): int = (try: parseInt(v) except ValueError: 0)
      if key.endsWith(".width"): result.width = num()
      elif key.endsWith(".height"): result.height = num()
      elif key.endsWith(".avg_frame_rate"): avg = rate(v)
      elif key.endsWith(".r_frame_rate"): real = rate(v)
      elif key.endsWith(".nb_frames"): result.frames = num()
      elif key.endsWith(".rotation") or key.endsWith(".rotate"):
        rot = (try: int(parseFloat(v)) except ValueError: 0)
      elif key == "format.duration": fdur = seconds(v)
      elif key.startsWith("streams.") and key.endsWith(".duration"): sdur = seconds(v)
  else:
    # `ffmpeg -i`: "Duration: 00:00:06.00," and "Stream #0:0...: Video: h264 ..., 640x360 [SAR
    # 1:1 DAR 16:9], 734 kb/s, 30 fps, ..." and "displaymatrix: rotation of -90.00 degrees"
    let o = toolRun(ffmpegExe(), ["-hide_banner", "-nostdin", "-i", path])
    var seenVideo = false
    for line in o.splitLines:
      let l = line.strip
      if l.startsWith("Duration:"):
        let t = l[9 .. ^1].strip.split(',')[0].split(':')
        if t.len == 3:
          try: fdur = parseFloat(t[0]) * 3600 + parseFloat(t[1]) * 60 + parseFloat(t[2])
          except ValueError: discard
      elif l.startsWith("Stream #") and " Video: " in l and not seenVideo:
        seenVideo = true
        for part in l.split(','):
          let p = part.strip
          if result.width == 0:
            for word in p.split(' '):
              let x = word.find('x')
              if x > 0:
                let a = try: parseInt(word[0 ..< x]) except ValueError: 0
                let b = try: parseInt(word[x + 1 .. ^1]) except ValueError: 0
                if a > 0 and b > 0:
                  result.width = a
                  result.height = b
                  break
          if p.endsWith(" fps"): avg = rate(p[0 ..< ^4])
          elif p.endsWith(" tbr") and real == 0: real = rate(p[0 ..< ^4])
      elif seenVideo and l.startsWith("displaymatrix: rotation of "):
        rot = (try: int(parseFloat(l[27 .. ^1].split(' ')[0])) except ValueError: 0)
  if abs(rot) mod 180 == 90: swap(result.width, result.height)
  result.fps = if avg > 0: avg else: real
  let dur = if fdur > 0: fdur else: sdur
  result.durationMs = int(dur * 1000 + 0.5)
  if result.frames <= 0 and result.fps > 0: result.frames = int(dur * result.fps + 0.5)

type Prerolled = object
  bmp: Bitmap
  pos, dur: int64            # where the picture is shown from and for how long, ns (-1: not known)
  fps: float                 # the stream's frame rate (0: not known)

when not (androidApp or defined(ios) or defined(windows) or defined(macosx)):
  # Exact seeks and frame steps, and the picture they give taken here: `GstPlayer.poll` asks
  # for a sample before the preroll, and (GStreamer 1.24) that asking drops the preroll a paused
  # seek gives.
  import std/[dynlib, importutils]
  type
    MapInfo = object                   # GstMapInfo
      memory: pointer
      flags: cint
      data: ptr UncheckedArray[uint8]
      size, maxsize: csize_t
      userData, reserved: array[4, pointer]
    MiniObject = object                # GstMiniObject
      typ: csize_t
      refcount, lockstate: cint
      flags: cuint
      copy, dispose, free: pointer
      privUint: cuint
      privPointer: pointer
    BufferHead = object                # the start of GstBuffer (public)
      mini: MiniObject
      pool: pointer
      pts, dts, duration: uint64
  const clockNone = high(uint64)
  var
    gstLoaded = 0
    gstSeekFn: proc (e: pointer; fmt, flags: cint; pos: int64): cint {.cdecl, gcsafe.}
    gstPullPreroll: proc (sink: pointer; timeout: uint64): pointer {.cdecl, gcsafe.}
    gstSampleBuffer, gstSampleCaps, gstSampleSegment: proc (s: pointer): pointer {.cdecl, gcsafe.}
    gstCapsStruct: proc (c: pointer; i: cuint): pointer {.cdecl, gcsafe.}
    gstStructInt: proc (s: pointer; field: cstring; v: ptr cint): cint {.cdecl, gcsafe.}
    gstStructFraction: proc (s: pointer; field: cstring; num, den: ptr cint): cint {.cdecl, gcsafe.}
    gstStreamTime: proc (seg: pointer; fmt: cint; pos: uint64): uint64 {.cdecl, gcsafe.}
    gstBufMap: proc (b: pointer; info: ptr MapInfo; flags: cint): cint {.cdecl, gcsafe.}
    gstBufUnmap: proc (b: pointer; info: ptr MapInfo) {.cdecl, gcsafe.}
    gstUnref: proc (o: pointer) {.cdecl, gcsafe.}
    gstNewStep: proc (fmt: cint; amount: uint64; rate: cdouble; flush, intermediate: cint): pointer {.cdecl, gcsafe.}
    gstSendEvent: proc (e, event: pointer): cint {.cdecl, gcsafe.}

  proc gstFns(): bool =
    if gstLoaded == 0:
      gstLoaded = -1
      let core = loadLib("libgstreamer-1.0.so.0")
      let app = loadLib("libgstapp-1.0.so.0")
      if core == nil or app == nil: return false
      template get(lib, v, name: untyped) =
        v = cast[typeof(v)](lib.symAddr(name))
        if v == nil: return false
      get(core, gstSeekFn, "gst_element_seek_simple")
      get(app, gstPullPreroll, "gst_app_sink_try_pull_preroll")
      get(core, gstSampleBuffer, "gst_sample_get_buffer")
      get(core, gstSampleCaps, "gst_sample_get_caps")
      get(core, gstSampleSegment, "gst_sample_get_segment")
      get(core, gstCapsStruct, "gst_caps_get_structure")
      get(core, gstStructInt, "gst_structure_get_int")
      get(core, gstStructFraction, "gst_structure_get_fraction")
      get(core, gstStreamTime, "gst_segment_to_stream_time")
      get(core, gstBufMap, "gst_buffer_map")
      get(core, gstBufUnmap, "gst_buffer_unmap")
      get(core, gstUnref, "gst_mini_object_unref")
      get(core, gstNewStep, "gst_event_new_step")
      get(core, gstSendEvent, "gst_element_send_event")
      gstLoaded = 1
    gstLoaded == 1

  proc exactSeek(g: GstPlayer; ms: int): bool =
    ## GStreamer (paused) to the picture shown at `ms`: an accurate seek,
    ## from the key frame before it decoded on to it.
    privateAccess(GstPlayer)
    if g == nil or g.pipe == nil or not gstFns(): return false
    g.ended = false
    gstSeekFn(g.pipe, 3, 1 or 2, int64(max(0, ms)) * 1_000_000) != 0   # time; flush, accurate

  proc stepOn(g: GstPlayer; n: int): bool =
    ## GStreamer (paused) `n` pictures on, decoding on from where it is.
    privateAccess(GstPlayer)
    if g == nil or g.pipe == nil or n <= 0 or not gstFns(): return false
    let e = gstNewStep(4, uint64(n), 1.0, 1, 0)      # GST_FORMAT_BUFFERS; flush, not intermediate
    e != nil and gstSendEvent(g.pipe, e) != 0

  proc prerolled(g: GstPlayer; timeoutMs: int): Prerolled =
    ## The picture the paused player stopped on (after `exactSeek` or
    ## `stepOn`), where it is in the stream, the frame rate.
    privateAccess(GstPlayer)
    result = Prerolled(pos: -1, dur: -1)
    if g == nil or g.sink == nil or not gstFns(): return
    let sample = gstPullPreroll(g.sink, uint64(timeoutMs) * 1_000_000)
    if sample == nil: return
    let buf = gstSampleBuffer(sample)
    let caps = gstSampleCaps(sample)
    var w, h, num, den: cint
    if buf != nil and caps != nil:
      let st = gstCapsStruct(caps, 0)
      if st != nil and gstStructFraction(st, "framerate", addr num, addr den) != 0 and num > 0 and den > 0:
        result.fps = num / den
      if st != nil and gstStructInt(st, "width", addr w) != 0 and
         gstStructInt(st, "height", addr h) != 0 and w > 0 and h > 0 and w <= 16384 and h <= 16384:
        var info: MapInfo
        if gstBufMap(buf, addr info, 1) != 0:
          let n = int(w) * int(h)
          if int(info.size) >= n * 4:                          # BGRx
            result.bmp = newBitmap(w, h)
            copyMem(addr result.bmp.px[0], info.data, n * 4)
            for p in result.bmp.px.mitems: p = p or 0xFF000000'u32
            result.bmp.opaque = true
          gstBufUnmap(buf, addr info)
      let head = cast[ptr BufferHead](buf)
      let seg = gstSampleSegment(sample)
      if head.pts != clockNone and seg != nil:
        let st = gstStreamTime(seg, 3, head.pts)
        if st != clockNone: result.pos = int64(st)
      if head.duration != clockNone and head.duration > 0: result.dur = int64(head.duration)
      elif result.fps > 0: result.dur = int64(1e9 / result.fps)
    gstUnref(sample)
else:
  proc exactSeek(g: GstPlayer; ms: int): bool = false
  proc stepOn(g: GstPlayer; n: int): bool = false
  proc prerolled(g: GstPlayer; timeoutMs: int): Prerolled = Prerolled(pos: -1, dur: -1)

proc useGst(): bool =
  case videoTool
  of vtGStreamer: gstAvailable()
  of vtFfmpeg: false
  of vtAuto: gstAvailable()

proc systemInfo(path: string): VideoInfo =
  # "width \t height \t duration ms \t fps \t frames" (turned as shown)
  let s = systemCall("media.info", path).split('\t')
  if s.len >= 5:
    try:
      result = VideoInfo(width: parseInt(s[0]), height: parseInt(s[1]), durationMs: parseInt(s[2]),
                         fps: rate(s[3]), frames: parseInt(s[4]))
    except ValueError: result = VideoInfo()
  if result.frames <= 0 and result.fps > 0:
    result.frames = int(result.durationMs.float * result.fps / 1000 + 0.5)

proc gstInfo(path: string): VideoInfo =
  ## The size, length and frame rate GStreamer gives.
  let g = gstOpen(path, video = true, audioSink = "fakesink")
  if g == nil: return
  defer: g.close()
  g.showFirstPicture()
  var t = 0
  while (g.frame == nil or g.durationMs <= 0) and not g.failed and t < 3000:
    discard g.poll()
    sleep(10)
    t += 10
  if g.frame != nil:
    result.width = g.frame.w
    result.height = g.frame.h
  result.durationMs = max(0, g.durationMs)
  if g.frame != nil and g.waitReady(3000) and g.exactSeek(0):
    result.fps = g.prerolled(2000).fps
    if result.fps > 0: result.frames = int(result.durationMs.float * result.fps / 1000 + 0.5)

proc videoInfo*(path: string): VideoInfo {.gcsafe.} =
  ## The video's picture size, frame rate, length and number of pictures;
  ## all 0 where it cannot be read here. Android: the system; desktops:
  ## ffprobe (or ffmpeg) when installed (the file's count of pictures),
  ## else GStreamer (the count from the length and the frame rate).
  {.cast(gcsafe).}:
    try:
      if not fileExists(path) and not mediaThroughSystem: return
      if mediaThroughSystem: return systemInfo(path)
      if videoTool != vtGStreamer and ffmpegExe().len > 0:
        result = ffInfo(path)
        if result.durationMs > 0 or result.width > 0: return
      if gstAvailable() and videoTool != vtFfmpeg: result = gstInfo(path)
    except CatchableError:
      result = VideoInfo()

# ---- one picture at a time ------------------------------------------------------------------------------

type
  FfReader = ref object
    path: string
    maxSide: int
    changed: Time
    p: Process
    outS, errS: Stream
    startS: float            # where this ffmpeg began, seconds
    tbNum, tbDen: int        # its time base (0: from pts_time)
    cur: Bitmap              # the picture read last
    curT: float              # its time, seconds (-1: none yet)
    nextT: float             # the next one's (-1: not read yet)
    nextW, nextH: int
    ended: bool
    fps: float
  GstReader = object
    path: string
    changed: Time
    g: GstPlayer
    durMs: int
    cur: Prerolled           # the picture it shows
    failed: string           # the file GStreamer could not read (ffmpeg's then)

var
  ffr: FfReader
  gsr: GstReader

proc stop(r: FfReader) =
  if r == nil or r.p == nil: return
  try:
    r.p.kill()
    discard r.p.waitForExit(3000)
  except CatchableError: discard
  try: r.p.close()
  except CatchableError: discard
  r.p = nil
  r.outS = nil
  r.errS = nil

proc start(r: FfReader; atS: float): bool =
  ## ffmpeg reading from `atS` seconds on, each picture as BGRA, its time
  ## and size told by `showinfo` on the error stream.
  r.stop()
  r.cur = nil
  r.curT = -1
  r.nextT = -1
  r.ended = false
  r.startS = max(0.0, atS)
  r.tbNum = 0
  r.tbDen = 0
  var vf = ""
  if r.maxSide > 0:
    let m = $r.maxSide
    vf = "scale=w='min(iw," & m & ")':h='min(ih," & m & ")':force_original_aspect_ratio=decrease,"
  vf.add "format=bgra,showinfo"
  var args = @["-hide_banner", "-nostdin", "-nostats", "-loglevel", "info"]
  if r.startS > 0: args.add ["-ss", formatFloat(r.startS, ffDecimal, 6)]
  args.add ["-i", r.path, "-an", "-sn", "-dn", "-vf", vf]
  let v = ffVersion()
  if v > 0 and v < 5: args.add ["-vsync", "passthrough"]
  else: args.add ["-fps_mode", "passthrough"]
  args.add ["-f", "rawvideo", "-"]
  when androidApp or defined(ios):
    false                            # (no ffmpeg there: the system reads videos)
  else:
    try:
      r.p = startProcess(ffmpegExe(), args = args, options = toolOpts)
      r.outS = r.p.outputStream
      r.errS = r.p.errorStream
      true
    except CatchableError:
      r.p = nil
      false

proc intAfter(line, key: string; at = 0): tuple[v: int; ok: bool] =
  let k = line.find(key, at)
  if k < 0: return
  var i = k + key.len
  while i < line.len and line[i] == ' ': inc i
  var neg = false
  if i < line.len and line[i] == '-':
    neg = true
    inc i
  while i < line.len and line[i] in {'0'..'9'}:
    result.v = result.v * 10 + ord(line[i]) - ord('0')
    result.ok = true
    inc i
  if neg: result.v = -result.v

proc peek(r: FfReader): bool =
  ## The time and size of the next picture, read ahead (false: no more).
  if r.nextT >= 0: return true
  if r.ended or r.errS == nil: return false
  var line: string
  while true:
    let ok = try: r.errS.readLine(line) except CatchableError: false
    if not ok:
      r.ended = true
      return false
    if "Parsed_showinfo" notin line: continue
    if r.tbDen == 0 and "config in time_base:" in line:
      let k = line.find("time_base:")
      let parts = line[k + 10 .. ^1].strip.split({',', ' '})[0].split('/')
      if parts.len == 2:
        r.tbNum = (try: parseInt(parts[0]) except ValueError: 0)
        r.tbDen = (try: parseInt(parts[1]) except ValueError: 0)
      continue
    let tk = line.find(" pts_time:")
    if tk < 0: continue
    var t = -1.0
    let pts = intAfter(line, " pts:")
    if pts.ok and r.tbNum > 0 and r.tbDen > 0:
      t = pts.v.float * r.tbNum.float / r.tbDen.float
    else:
      var e = tk + 10
      while e < line.len and line[e] != ' ': inc e
      t = try: parseFloat(line[tk + 10 ..< e]) except ValueError: -1.0
      if t < 0: t = (if r.curT >= 0: r.curT - r.startS + 1 / max(1.0, r.fps) else: 0)
    let sk = line.find(" s:")
    if sk < 0: continue
    let w = intAfter(line, " s:")
    let h = intAfter(line, "x", sk + 3)
    if not (w.ok and h.ok) or w.v <= 0 or h.v <= 0 or w.v > 16384 or h.v > 16384:
      r.ended = true
      return false
    r.nextT = r.startS + max(0.0, t)
    r.nextW = w.v
    r.nextH = h.v
    return true

proc advance(r: FfReader): bool =
  ## Reads the next picture.
  if not r.peek(): return false
  let b = newBitmap(r.nextW, r.nextH)
  if not readFull(r.outS, addr b.px[0], b.px.len * 4):
    r.ended = true
    return false
  when cpuEndian == bigEndian:
    for p in b.px.mitems:          # B G R A in memory
      p = (p shr 24) or ((p shr 8) and 0xFF00'u32) or ((p shl 8) and 0xFF0000'u32) or (p shl 24)
  for p in b.px.mitems: p = p or 0xFF000000'u32
  b.opaque = true
  r.cur = b
  r.curT = r.nextT
  r.nextT = -1
  true

proc copyOf(b: Bitmap): Bitmap =
  result = newBitmap(b.w, b.h)
  result.px = b.px
  result.opaque = b.opaque

proc ffFrameAt(path: string; ms, maxSide: int): Bitmap =
  if ffmpegExe().len == 0: return nil
  let changed = try: getLastModificationTime(path) except OSError: Time()
  var r = ffr
  if r == nil or r.path != path or r.maxSide != maxSide or r.changed != changed:
    r.stop()
    r = FfReader(path: path, maxSide: maxSide, changed: changed, curT: -1, nextT: -1,
                 fps: ffInfo(path).fps)
    ffr = r
  let t = max(0, ms) / 1000
  const eps = 1e-6
  let at = if r.curT >= 0: r.curT else: r.startS
  if r.p == nil or t < at - eps or t > at + 3.0 or (r.ended and r.cur == nil):
    # (a little before: the picture shown at t may begin before it)
    if not r.start(t - (if r.fps > 0: 1.5 / r.fps else: 0.1)): return nil
  while true:
    if r.curT < 0:
      if not r.advance(): break
      continue
    if r.curT > t + eps: break           # before the first picture: the first
    if not r.peek(): break               # the last picture
    if r.nextT > t + eps: break
    if not r.advance(): break
  if r.cur != nil: copyOf(r.cur) else: nil

proc waitFrame(g: GstPlayer; ms: int) =
  var t = 0
  while g.frame == nil and not g.failed and t < ms:
    discard g.poll()
    if g.frame == nil:
      sleep(2)
      t += 2

proc gstFrameAt(path: string; ms, maxSide: int): Bitmap =
  ## The picture at `ms` by GStreamer: the one it shows already, or a few
  ## pictures on by stepping (no decoding again from the key frame), or an
  ## exact seek.
  let changed = try: getLastModificationTime(path) except OSError: Time()
  if gsr.failed == path & "\0" & $changed.toUnix: return nil
  if gsr.g == nil or gsr.path != path or gsr.changed != changed:
    if gsr.g != nil: gsr.g.close()
    gsr = GstReader(path: path, changed: changed, cur: Prerolled(pos: -1, dur: -1))
    let g = gstOpen(path, video = true, audioSink = "fakesink")
    if g != nil:
      g.showFirstPicture()
      g.waitFrame(3000)
      if g.frame == nil or not g.waitReady(3000):
        g.close()
        gsr.failed = path & "\0" & $changed.toUnix
        return nil
    else:
      gsr.failed = path & "\0" & $changed.toUnix
      return nil
    gsr.g = g
    gsr.durMs = g.durationMs
  let g = gsr.g
  if gsr.durMs <= 0: gsr.durMs = g.durationMs
  let at = if gsr.durMs > 0: min(max(0, ms), gsr.durMs - 1) else: max(0, ms)
  let t = int64(at) * 1_000_000
  let c = gsr.cur
  var f = Prerolled(pos: -1, dur: -1)
  if c.bmp != nil and c.pos >= 0 and c.dur > 0 and t >= c.pos:
    if t < c.pos + c.dur: f = c                                   # the same picture
    elif t - c.pos <= 3_000_000_000:
      if g.stepOn(int((t - c.pos) div c.dur)):
        f = g.prerolled(3000)
        if f.bmp != nil and not (f.pos >= 0 and f.dur > 0 and f.pos <= t and t < f.pos + f.dur):
          f.bmp = nil                                             # (not there: seek)
  if f.bmp == nil and g.exactSeek(at): f = g.prerolled(3000)
  if f.bmp == nil:
    g.close()
    gsr.g = nil
    gsr.cur = Prerolled(pos: -1, dur: -1)
    gsr.failed = path & "\0" & $changed.toUnix
    return nil
  gsr.cur = f
  result = copyOf(f.bmp)
  if maxSide > 0 and (result.w > maxSide or result.h > maxSide):
    result = thumbnail(result, maxSide, maxSide)

proc systemFrameAt(path: string; ms, maxSide: int): Bitmap =
  ## Android: the picture written raw (BGRA, w x h) by the system's side.
  if not path.startsWith("/"): return nil
  let tmp = cacheDir() / "vraw-" & $getThreadId() & ".bgra"
  try:
    let r = systemCall("media.frameRaw", path & "\t" & tmp & "\t" & $max(0, ms) & "\t" & $maxSide).split('\t')
    if r.len >= 3 and r[0] == "1":
      let w = parseInt(r[1])
      let h = parseInt(r[2])
      let data = readFile(tmp)
      if w > 0 and h > 0 and data.len == w * h * 4:
        result = newBitmap(w, h)
        copyMem(addr result.px[0], unsafeAddr data[0], data.len)
        for p in result.px.mitems: p = p or 0xFF000000'u32
        result.opaque = true
  except CatchableError, OSError:
    result = nil
  try: removeFile(tmp) except OSError: discard

proc videoFrameAt*(path: string; ms: int; maxSide = 0): Bitmap {.gcsafe.} =
  ## The picture of the video `path` shown at `ms` milliseconds (the last
  ## one beginning at or before it; past the end the last), no larger than
  ## `maxSide` pixels (0: as it is); nil where videos cannot be read here.
  ## The decoder is kept for the next call: pictures a little further on
  ## come quickly (scrubbing, playing through); `closeVideoReader` lets it
  ## go. Android: the system's; Linux: GStreamer (an exact seek each
  ## time), else ffmpeg; Windows, macOS: ffmpeg when installed.
  result = nil         # (a value at once: see tools/writecheck.py)
  {.cast(gcsafe).}:
    try:
      if mediaThroughSystem: result = systemFrameAt(path, ms, maxSide); return
      if not fileExists(path): result = nil; return
      withLock readLock:
        if useGst():
          result = gstFrameAt(path, ms, maxSide)
          if result != nil or videoTool == vtGStreamer: return
        result = ffFrameAt(path, ms, maxSide)
    except CatchableError:
      result = nil

proc closeVideoReader*() {.gcsafe.} =
  ## Lets the decoder `videoFrameAt` keeps go (it holds the file open).
  {.cast(gcsafe).}:
    if mediaThroughSystem:
      discard systemCall("media.frameClose", "")
      return
    withLock readLock:
      if ffr != nil:
        ffr.stop()
        ffr = nil
      if gsr.g != nil:
        gsr.g.close()
        gsr = GstReader()

# ---- pictures of videos ---------------------------------------------------------------------------

const videoExts* = [".mp4", ".mkv", ".avi", ".mov", ".webm", ".wmv", ".3gp", ".m4v", ".flv",
                    ".mpg", ".mpeg", ".ts"]
  ## The kinds of video `addVideoPreviews` shows pictures of.

proc ffOneFrame(path: string; ms, maxW, maxH: int): Bitmap =
  ## One picture by a short-lived ffmpeg (the file lists' pictures: not the
  ## kept reader, which a scrubbing view may be using).
  result = nil         # (a value at once: see tools/writecheck.py)
  let r = FfReader(path: path, maxSide: max(maxW, maxH), curT: -1, nextT: -1)
  try:
    if r.start(ms / 1000) and r.advance(): result = r.cur
  finally:
    r.stop()
  if result != nil and (result.w > maxW or result.h > maxH): result = thumbnail(result, maxW, maxH)

proc dark(f: Bitmap): bool =
  ## Black, or nearly (as many videos begin: a fade in).
  var sum = 0
  let step = max(1, f.px.len div 4096)
  var n = 0
  for i in countup(0, f.px.high, step):
    let c = f.px[i]
    sum += int((c shr 16) and 255) + int((c shr 8) and 255) + int(c and 255)
    inc n
  sum div max(1, n * 3) < 20

proc laterMs(dur: int): int = min(min(dur div 3, max(1500, dur div 10)), 5000)

proc ffThumb(path: string; maxW, maxH: int): Bitmap =
  if ffmpegExe().len == 0 or not fileExists(path): return nil
  result = ffOneFrame(path, 0, maxW, maxH)
  if result != nil and dark(result):
    let dur = ffInfo(path).durationMs
    if dur > 500:
      let later = ffOneFrame(path, laterMs(dur), maxW, maxH)
      if later != nil: result = later

proc gstThumb(path: string; maxW, maxH: int): Bitmap =
  let g = gstOpen(path, video = true, audioSink = "fakesink")
  if g == nil: return nil
  defer: g.close()
  g.showFirstPicture()
  g.waitFrame(3000)
  if g.frame == nil: return nil
  if dark(g.frame):
    let dur = g.durationMs
    if dur > 500:
      let first = g.frame
      g.frame = nil
      g.seekMs(laterMs(dur))
      g.play()
      g.waitFrame(2000)
      if g.frame == nil: g.frame = first
  let b = g.frame
  result = if b.w > maxW or b.h > maxH: thumbnail(b, maxW, maxH) else: b

proc videoFrame*(path: string; maxW, maxH: int): Bitmap {.gcsafe.} =
  ## A picture of the video `path` -- its first one, or a little way in
  ## when that is black (a fade in) -- fitted into `maxW` x `maxH`; nil
  ## where it cannot be had (Android, Linux with GStreamer, desktops with
  ## ffmpeg can). Takes a moment: ask for it on a worker (`pictureAsync`,
  ## after `addVideoPreviews`).
  result = nil         # (a value at once: see tools/writecheck.py)
  {.cast(gcsafe).}:
    try:
      if mediaThroughSystem:
        if not path.startsWith("/"): return
        let tmp = cacheDir() / "frame-" & toHex(int(hash(path & $getThreadId())) and 0x7FFFFFFF, 8) & ".jpg"
        if systemCall("media.frame", path & "\t" & tmp & "\t" & $max(maxW, maxH)) == "1":
          result = loadPicture(tmp, maxW, maxH)
        try: removeFile(tmp) except OSError: discard
        return
      if useGst():
        result = gstThumb(path, maxW, maxH)
        if result != nil or videoTool == vtGStreamer: return
      result = ffThumb(path, maxW, maxH)
    except CatchableError:
      result = nil

proc videoDuration*(path: string): int {.gcsafe.} =
  ## How long the video `path` is, milliseconds (0: not known -- it cannot
  ## be read here).
  {.cast(gcsafe).}:
    try:
      if mediaThroughSystem:
        return (try: parseInt(systemCall("media.duration", path)) except ValueError: 0)
      if useGst():
        let g = gstOpen(path, video = true, audioSink = "fakesink")
        if g != nil:
          defer: g.close()
          g.showFirstPicture()
          var t = 0
          while g.durationMs <= 0 and not g.failed and t < 3000:
            discard g.poll()
            sleep(10)
            t += 10
          result = max(0, g.durationMs)
        if result > 0 or videoTool == vtGStreamer: return
      if ffmpegExe().len > 0 and fileExists(path): result = ffInfo(path).durationMs
    except CatchableError:
      result = 0

proc videoFrames*(path: string; everyMs: int; maxFrames = 300; maxSide = 0;
                  fromMs = 0; toMs = -1): seq[tuple[bmp: Bitmap; ms: int]] {.gcsafe.} =
  ## The video's pictures every `everyMs` milliseconds (from `fromMs` to
  ## `toMs`, -1 its end; at most `maxFrames`; no larger than `maxSide`
  ## pixels, 0 as they are): Import > Video Frames to Layers. Empty where
  ## videos cannot be read (Android, Linux with GStreamer, desktops with
  ## ffmpeg can).
  {.cast(gcsafe).}:
    let dur = videoDuration(path)
    if dur <= 0: return
    let last = if toMs < 0: dur else: min(dur, toMs)
    var t = max(0, fromMs)
    if mediaThroughSystem:
      if not path.startsWith("/"): return
      while t <= last and result.len < maxFrames:
        let b = systemFrameAt(path, t, maxSide)
        if b != nil: result.add (b, t)
        t += max(1, everyMs)
      discard systemCall("media.frameClose", "")
      return
    # (desktops: the kept reader -- GStreamer's exact seeks, or one ffmpeg reading on through it)
    while t <= last and result.len < maxFrames:
      let b = videoFrameAt(path, min(t, max(0, dur - 1)), maxSide)
      if b != nil: result.add (b, t)
      t += max(1, everyMs)
    closeVideoReader()

proc addVideoPreviews*() =
  ## Teaches the file widgets (lists, previews, Open dialogs) to show a
  ## picture of each video (where `videoFrame` can make one: Windows and
  ## macOS when ffmpeg is installed). (GStreamer is started by the first
  ## picture asked for, on a worker: not here.)
  when defined(windows) or defined(macosx) or defined(ios):
    if not mediaThroughSystem and ffmpegExe().len == 0: return
  addPictureReader(videoExts, proc (path: string; maxW, maxH: int): Bitmap {.nimcall, gcsafe.} =
    videoFrame(path, maxW, maxH))

# ---- writing videos (MP4, H.264) ----------------------------------------------------------------------
#
# Android: MediaCodec (video/avc) and MediaMuxer on the system's side, each picture handed over as a
# YUV 4:2:0 file made here. Desktops: the `ffmpeg` program (libx264; else libopenh264; else MPEG-4
# part 2 in the MP4), each picture piped to it raw. Windows without ffmpeg: Media Foundation's sink
# writer (its H.264 encoder).

type
  WriterKind = enum
    wkNone, wkFfmpeg, wkSystem, wkMf
  VideoWriter* = ref object
    ## A video being written (`beginVideo`, `addFrame`, `finish`).
    path*: string            ## the file written
    width*, height*: int     ## the size written: the size asked for, made even (the last column
                             ## or row repeated)
    fps*: float              ## pictures a second
    frames*: int             ## pictures added
    codec*: string           ## what encodes it ("libx264", "MediaCodec c2.android.avc.encoder"...)
    error*: string           ## why it failed ("" while all is well)
    srcW, srcH: int
    kind: WriterKind
    p: Process
    sysId, tmp: string
    bt709: bool
    buf: seq[uint32]
    mf: pointer
    mfStream: uint32
    done: bool

var
  videoEncoders* = @["libx264", "libopenh264", "mpeg4"]
    ## The ffmpeg encoders `beginVideo` tries, in order (the first ffmpeg has).
  writerCount = 0

proc ffHasEncoder(name: string): bool =
  ## ffmpeg has the encoder `name` (asked once).
  {.cast(gcsafe).}:
    if ffEncoderList.len == 0:
      let list = toolRun(ffmpegExe(), ["-hide_banner", "-encoders"])
      withLock toolLock:
        ffEncoderList = if list.len > 0: list else: " "
    for line in ffEncoderList.splitLines:
      let w = line.splitWhitespace
      if w.len >= 2 and w[0].len == 6 and w[0][0] == 'V' and w[1] == name: return true
    false

proc rateText(fps: float): string =
  ## The frame rate as ffmpeg wants it: NTSC's exactly (30000/1001...).
  for base in [24, 30, 48, 60, 120]:
    if abs(fps - base.float * 1000 / 1001) < 0.0005: return $(base * 1000) & "/1001"
  if abs(fps - round(fps)) < 1e-9: $int(round(fps)) else: formatFloat(fps, ffDecimal, 6)

proc defaultBitrate(w, h: int; fps: float): int =
  ## Bits a second for a good picture: about 0.12 bit a pixel.
  max(300_000, int(w.float * h.float * max(1.0, fps) * 0.12))

when defined(windows):
  # Media Foundation's sink writer (Windows 7 and later; not in the "N" editions without the Media
  # Feature Pack): loaded at run time, its COM objects called through their tables.
  import std/dynlib
  type
    Guid = object
      d1: uint32
      d2, d3: uint16
      d4: array[8, uint8]
    Hr = int32
  proc mediaGuid(fourcc: uint32): Guid =
    Guid(d1: fourcc, d2: 0, d3: 0x10, d4: [0x80'u8, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71])
  const
    mtMajorType = Guid(d1: 0x48eba18e'u32, d2: 0xf8c9, d3: 0x4687,
                       d4: [0xbf'u8, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f])
    mtSubtype = Guid(d1: 0xf7e34c9a'u32, d2: 0x42e8, d3: 0x4714,
                     d4: [0xb7'u8, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5])
    mtFrameSize = Guid(d1: 0x1652c33d'u32, d2: 0xd6b2, d3: 0x4012,
                       d4: [0xb8'u8, 0x34, 0x72, 0x03, 0x08, 0x49, 0xa3, 0x7d])
    mtFrameRate = Guid(d1: 0xc459a2e8'u32, d2: 0x3d2c, d3: 0x4e44,
                       d4: [0xb1'u8, 0x32, 0xfe, 0xe5, 0x15, 0x6c, 0x7b, 0xb0])
    mtPixelAspect = Guid(d1: 0xc6376a1e'u32, d2: 0x8d0a, d3: 0x4027,
                         d4: [0xbe'u8, 0x45, 0x6d, 0x9a, 0x0a, 0xd3, 0x9b, 0xb6])
    mtInterlace = Guid(d1: 0xe2724bb8'u32, d2: 0xe676, d3: 0x4806,
                       d4: [0xb4'u8, 0xb2, 0xa8, 0xd6, 0xef, 0xb4, 0x4c, 0xcd])
    mtAvgBitrate = Guid(d1: 0x20332624'u32, d2: 0xfb0d, d3: 0x4d9e,
                        d4: [0xbd'u8, 0x0d, 0xcb, 0xf6, 0x78, 0x6c, 0x10, 0x2e])
    mtDefaultStride = Guid(d1: 0x644b4e48'u32, d2: 0x1e02, d3: 0x4516,
                           d4: [0xb0'u8, 0xeb, 0xc0, 0x1c, 0xa9, 0xd4, 0x9a, 0xc6])
    mediaTypeVideo = Guid(d1: 0x73646976'u32, d2: 0x0000, d3: 0x0010,
                          d4: [0x80'u8, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71])
    transcodeContainer = Guid(d1: 0x150ff23f'u32, d2: 0x4abc, d3: 0x478b,
                              d4: [0xac'u8, 0x4f, 0xe1, 0x91, 0x6f, 0xba, 0x1c, 0xca])
    containerMpeg4 = Guid(d1: 0xdc6cd05d'u32, d2: 0xb9d0, d3: 0x40ef,
                          d4: [0xbd'u8, 0x35, 0xfa, 0x62, 0x2c, 0x1a, 0xb2, 0x8a])
    mfVersion = 0x00020070'u32           # MF_SDK_VERSION 2 << 16 | MF_API_VERSION 0x70
    interlaceProgressive = 2'u32
  var
    mfState = 0                          # 0 not tried, 1 there, -1 not there
    mfStartup: proc (version, flags: uint32): Hr {.stdcall, gcsafe.}
    mfShutdown: proc (): Hr {.stdcall, gcsafe.}
    mfCreateMediaType: proc (t: ptr pointer): Hr {.stdcall, gcsafe.}
    mfCreateAttributes: proc (a: ptr pointer; size: uint32): Hr {.stdcall, gcsafe.}
    mfCreateSample: proc (s: ptr pointer): Hr {.stdcall, gcsafe.}
    mfCreateMemoryBuffer: proc (n: uint32; b: ptr pointer): Hr {.stdcall, gcsafe.}
    mfCreateSinkWriter: proc (url: WideCString; bs, attrs: pointer; w: ptr pointer): Hr {.stdcall, gcsafe.}
    coInitializeEx: proc (r: pointer; flags: uint32): Hr {.stdcall, gcsafe.}

  proc mfAvailable(): bool =
    {.cast(gcsafe).}:
      if mfState == 0:
        mfState = -1
        let plat = loadLib("mfplat.dll")
        let rw = loadLib("mfreadwrite.dll")
        let ole = loadLib("ole32.dll")
        if plat != nil and rw != nil and ole != nil:
          mfStartup = cast[typeof(mfStartup)](plat.symAddr("MFStartup"))
          mfShutdown = cast[typeof(mfShutdown)](plat.symAddr("MFShutdown"))
          mfCreateMediaType = cast[typeof(mfCreateMediaType)](plat.symAddr("MFCreateMediaType"))
          mfCreateAttributes = cast[typeof(mfCreateAttributes)](plat.symAddr("MFCreateAttributes"))
          mfCreateSample = cast[typeof(mfCreateSample)](plat.symAddr("MFCreateSample"))
          mfCreateMemoryBuffer = cast[typeof(mfCreateMemoryBuffer)](plat.symAddr("MFCreateMemoryBuffer"))
          mfCreateSinkWriter = cast[typeof(mfCreateSinkWriter)](rw.symAddr("MFCreateSinkWriterFromURL"))
          coInitializeEx = cast[typeof(coInitializeEx)](ole.symAddr("CoInitializeEx"))
          if mfStartup != nil and mfShutdown != nil and mfCreateMediaType != nil and
             mfCreateAttributes != nil and
             mfCreateSample != nil and mfCreateMemoryBuffer != nil and mfCreateSinkWriter != nil and
             coInitializeEx != nil:
            mfState = 1
      mfState == 1

  # the methods used, by their places in the COM tables (checked against mingw-w64's headers)
  template slot(o: pointer; i: int): pointer = cast[ptr UncheckedArray[pointer]](cast[ptr pointer](o)[])[i]
  proc comRelease(o: pointer) =
    if o != nil: discard cast[proc (o: pointer): uint32 {.stdcall.}](slot(o, 2))(o)
  proc setU32(o: pointer; key: Guid; v: uint32): Hr =                 # IMFAttributes::SetUINT32
    cast[proc (o: pointer; k: ptr Guid; v: uint32): Hr {.stdcall.}](slot(o, 21))(o, unsafeAddr key, v)
  proc setU64(o: pointer; key: Guid; v: uint64): Hr =                 # SetUINT64
    cast[proc (o: pointer; k: ptr Guid; v: uint64): Hr {.stdcall.}](slot(o, 22))(o, unsafeAddr key, v)
  proc setGuid(o: pointer; key, v: Guid): Hr =                        # SetGUID
    cast[proc (o: pointer; k, v: ptr Guid): Hr {.stdcall.}](slot(o, 24))(o, unsafeAddr key, unsafeAddr v)

  proc mfFail(v: VideoWriter; what: string; hr: Hr): bool =
    v.error = "Media Foundation could not " & what & " (0x" & toHex(uint32(hr)) & ")."
    if v.mf != nil:
      comRelease(v.mf)
      v.mf = nil
      discard mfShutdown()
    v.kind = wkNone
    false

  proc mfBegin(v: VideoWriter; bitrate: int): bool =
    ## The sink writer: H.264 in an MP4 (from the name's extension), fed
    ## RGB32 (B G R X, top-down) pictures it converts itself.
    if not mfAvailable(): return false
    discard coInitializeEx(nil, 0)       # COINIT_MULTITHREADED (or as the thread has it already)
    var hr = mfStartup(mfVersion, 0)
    if hr < 0:
      v.error = "Media Foundation is not there (0x" & toHex(uint32(hr)) & ")."
      return false
    var w, attrs: pointer
    # an MP4 whatever the name's extension
    if mfCreateAttributes(addr attrs, 1) >= 0 and setGuid(attrs, transcodeContainer, containerMpeg4) < 0:
      comRelease(attrs)
      attrs = nil
    hr = mfCreateSinkWriter(newWideCString(v.path), nil, attrs, addr w)
    comRelease(attrs)
    if hr < 0:
      discard mfShutdown()
      v.error = "Media Foundation cannot write " & v.path.extractFilename & " (0x" & toHex(uint32(hr)) & ")."
      return false
    v.mf = w
    v.kind = wkMf
    v.codec = "Media Foundation H.264"
    var num = uint64(round(v.fps * 1000))
    var den = 1000'u64
    for base in [24, 30, 48, 60, 120]:
      if abs(v.fps - base.float * 1000 / 1001) < 0.0005: (num, den) = (uint64(base * 1000), 1001'u64)
    if abs(v.fps - round(v.fps)) < 1e-9: (num, den) = (uint64(round(v.fps)), 1'u64)
    let size = (uint64(v.width) shl 32) or uint64(v.height)
    let br = if bitrate > 0: bitrate else: defaultBitrate(v.width, v.height, v.fps)
    # what is written
    var outType: pointer
    hr = mfCreateMediaType(addr outType)
    if hr < 0: return v.mfFail("make a media type", hr)
    var ok = setGuid(outType, mtMajorType, mediaTypeVideo) >= 0 and
             setGuid(outType, mtSubtype, mediaGuid(0x34363248'u32)) >= 0 and      # 'H264'
             setU32(outType, mtAvgBitrate, uint32(min(br, int(high(int32))))) >= 0 and
             setU32(outType, mtInterlace, interlaceProgressive) >= 0 and
             setU64(outType, mtFrameSize, size) >= 0 and
             setU64(outType, mtFrameRate, (num shl 32) or den) >= 0 and
             setU64(outType, mtPixelAspect, (1'u64 shl 32) or 1) >= 0
    var stream: uint32
    if ok:
      hr = cast[proc (o, t: pointer; idx: ptr uint32): Hr {.stdcall.}](slot(w, 3))(w, outType, addr stream)
      ok = hr >= 0                                                         # AddStream
    comRelease(outType)
    if not ok: return v.mfFail("set up the H.264 encoder", hr)
    v.mfStream = stream
    # what is given: RGB32, top-down (a positive stride)
    var inType: pointer
    hr = mfCreateMediaType(addr inType)
    if hr < 0: return v.mfFail("make a media type", hr)
    ok = setGuid(inType, mtMajorType, mediaTypeVideo) >= 0 and
         setGuid(inType, mtSubtype, mediaGuid(22)) >= 0 and                      # D3DFMT_X8R8G8B8
         setU32(inType, mtInterlace, interlaceProgressive) >= 0 and
         setU32(inType, mtDefaultStride, uint32(v.width * 4)) >= 0 and
         setU64(inType, mtFrameSize, size) >= 0 and
         setU64(inType, mtFrameRate, (num shl 32) or den) >= 0 and
         setU64(inType, mtPixelAspect, (1'u64 shl 32) or 1) >= 0
    if ok:
      hr = cast[proc (o: pointer; idx: uint32; t, enc: pointer): Hr {.stdcall.}](slot(w, 4))(
        w, stream, inType, nil)                                                # SetInputMediaType
      ok = hr >= 0
    comRelease(inType)
    if not ok: return v.mfFail("take pictures of this size", hr)
    hr = cast[proc (o: pointer): Hr {.stdcall.}](slot(w, 5))(w)                # BeginWriting
    if hr < 0: return v.mfFail("begin writing", hr)
    v.error = ""
    true

  proc mfAdd(v: VideoWriter): bool =
    let n = v.width * v.height * 4
    var buf, sample: pointer
    var hr = mfCreateMemoryBuffer(uint32(n), addr buf)
    if hr < 0: return v.mfFail("make a buffer", hr)
    var data: pointer
    hr = cast[proc (o: pointer; p: ptr pointer; maxLen, curLen: pointer): Hr {.stdcall.}](slot(buf, 3))(
      buf, addr data, nil, nil)                                                # Lock
    if hr >= 0:
      copyMem(data, addr v.buf[0], n)                                          # 0xAARRGGBB: B G R A
      discard cast[proc (o: pointer): Hr {.stdcall.}](slot(buf, 4))(buf)       # Unlock
      hr = cast[proc (o: pointer; n: uint32): Hr {.stdcall.}](slot(buf, 6))(buf, uint32(n))
    if hr >= 0: hr = mfCreateSample(addr sample)
    if hr >= 0:
      hr = cast[proc (o, b: pointer): Hr {.stdcall.}](slot(sample, 42))(sample, buf)   # AddBuffer
    let t0 = int64(float(v.frames) * 10_000_000.0 / v.fps + 0.5)
    let t1 = int64(float(v.frames + 1) * 10_000_000.0 / v.fps + 0.5)
    if hr >= 0: hr = cast[proc (o: pointer; t: int64): Hr {.stdcall.}](slot(sample, 36))(sample, t0)
    if hr >= 0: hr = cast[proc (o: pointer; t: int64): Hr {.stdcall.}](slot(sample, 38))(sample, t1 - t0)
    if hr >= 0:
      hr = cast[proc (o: pointer; idx: uint32; s: pointer): Hr {.stdcall.}](slot(v.mf, 6))(
        v.mf, v.mfStream, sample)                                              # WriteSample
    comRelease(sample)
    comRelease(buf)
    if hr < 0: return v.mfFail("write a picture", hr)
    true

  proc mfFinish(v: VideoWriter) =
    if v.mf == nil: return
    let hr = cast[proc (o: pointer): Hr {.stdcall.}](slot(v.mf, 11))(v.mf)     # Finalize
    comRelease(v.mf)
    v.mf = nil
    discard mfShutdown()
    if hr < 0 and v.error.len == 0:
      v.error = "Media Foundation could not finish the video (0x" & toHex(uint32(hr)) & ")."

proc videoEncodeAvailable*(): bool {.gcsafe.} =
  ## Videos can be written here: Android (API 24+, an H.264 encoder);
  ## desktops with ffmpeg; Windows with Media Foundation.
  {.cast(gcsafe).}:
    if mediaThroughSystem: return systemCall("media.encAvailable", "") == "1"
    if ffmpegExe().len > 0:
      for e in videoEncoders:
        if ffHasEncoder(e): return true
    when defined(windows):
      if mfAvailable(): return true
    false

when not (androidApp or defined(ios)):
  proc ffmpegBegin(v: VideoWriter; path: string; fps: float; bitrate: int)

proc beginVideo*(path: string; w, h: int; fps: float; bitrate = 0): VideoWriter =
  ## Starts writing the MP4 video `path` (H.264), `w` x `h` pixels (an odd
  ## size is made even by repeating the last column or row), `fps`
  ## pictures a second, `bitrate` bits a second (0: chosen for a good
  ## picture). Always gives a writer; `error` says when it cannot be
  ## written here (then `addFrame` does nothing and `finish` is false).
  result = VideoWriter(path: path, srcW: w, srcH: h, fps: fps,
                       width: w + (w and 1), height: h + (h and 1))
  let v = result
  # the BT.709 colours for HD, BT.601 below (what players take when the file does not say)
  v.bt709 = v.height >= 720 or v.width >= 1280
  if w <= 0 or h <= 0 or w > 16384 or h > 16384 or fps <= 0 or fps > 1000:
    v.error = "The video's size or frame rate is not possible."
    return
  try: createDir(path.parentDir) except OSError: discard
  if mediaThroughSystem:
    inc writerCount
    v.sysId = $writerCount & "-" & $getCurrentProcessId()
    v.tmp = cacheDir() / "venc-" & v.sysId & ".yuv"
    let r = systemCall("media.encBegin", v.sysId & "\t" & path & "\t" & $v.width & "\t" & $v.height &
                       "\t" & formatFloat(fps, ffDecimal, 6) & "\t" & $bitrate & "\t" &
                       (if v.bt709: "709" else: "601")).split('\t')
    if r.len >= 4 and r[0] == "1":
      v.kind = wkSystem
      v.width = (try: parseInt(r[1]) except ValueError: v.width)
      v.height = (try: parseInt(r[2]) except ValueError: v.height)
      v.codec = "MediaCodec " & r[3]
    else:
      v.error = if r.len >= 2 and r[0] == "0": r[1] else: "Videos cannot be written on this device."
    return
  when not (androidApp or defined(ios)):
    # (ffmpeg: desktops only -- Android before 9 has no posix_spawn, and
    # writes through the system above)
    ffmpegBegin(v, path, fps, bitrate)
    if v.kind == wkFfmpeg: return
  when defined(windows):
    if mfBegin(v, bitrate): return
  if v.error.len == 0:
    v.error = "Videos cannot be written here: ffmpeg is not installed."

when not (androidApp or defined(ios)):
  proc ffmpegBegin(v: VideoWriter; path: string; fps: float; bitrate: int) =
    let ff = ffmpegExe()
    if ff.len > 0:
      var enc = ""
      for e in videoEncoders:
        if ffHasEncoder(e):
          enc = e
          break
      if enc.len > 0:
        let br = if bitrate > 0: bitrate else: defaultBitrate(v.width, v.height, fps)
        let matrix = if v.bt709: "bt709" else: "smpte170m"
        var args = @["-hide_banner", "-nostdin", "-nostats", "-loglevel", "error", "-y",
                     "-f", "rawvideo", "-pix_fmt", "bgra", "-s", $v.width & "x" & $v.height,
                     "-framerate", rateText(fps), "-i", "-",
                     "-vf", "scale=out_color_matrix=" & (if v.bt709: "bt709" else: "bt601") &
                            ":out_range=tv,format=yuv420p",
                     "-c:v", enc]
        case enc
        of "libx264":
          if bitrate > 0: args.add ["-b:v", $br, "-maxrate", $(br * 3 div 2), "-bufsize", $(br * 2)]
          else: args.add ["-crf", "20"]
          args.add ["-preset", "medium", "-profile:v", "high"]
        of "mpeg4": args.add ["-b:v", $br, "-qmin", "2", "-qmax", "12"]
        else: args.add ["-b:v", $br]
        args.add ["-pix_fmt", "yuv420p", "-colorspace", matrix, "-color_primaries",
                  (if v.bt709: "bt709" else: "smpte170m"), "-color_trc", (if v.bt709: "bt709" else: "smpte170m"),
                  "-color_range", "tv", "-movflags", "+faststart", "-f", "mp4", path]
        try:
          v.p = startProcess(ff, args = args, options = toolOpts + {poStdErrToStdOut})
          v.kind = wkFfmpeg
          v.codec = enc
          return
        except CatchableError, OSError:
          v.error = "ffmpeg could not be started."

proc frameOf(v: VideoWriter; b: Bitmap) =
  ## `b` as the writer's picture in `v.buf`: put over black (its
  ## transparent parts), centred (made smaller to fit when it is larger),
  ## the columns and rows the even size adds repeating the last.
  let ww = v.width
  let hh = v.height
  if v.buf.len != ww * hh: v.buf = newSeq[uint32](ww * hh)
  var src = b
  var ox, oy = 0
  if b.w != v.srcW or b.h != v.srcH:
    if b.w > v.srcW or b.h > v.srcH: src = thumbnail(b, v.srcW, v.srcH)
    for p in v.buf.mitems: p = 0xFF000000'u32
    ox = (v.srcW - src.w) div 2
    oy = (v.srcH - src.h) div 2
  let opaque = src.opaque
  for y in 0 ..< src.h:
    let row = (y + oy) * ww + ox
    let srow = y * src.w
    if opaque:
      copyMem(addr v.buf[row], unsafeAddr src.px[srow], src.w * 4)
    else:
      for x in 0 ..< src.w:
        let p = src.px[srow + x]
        let a = p shr 24
        if a == 255: v.buf[row + x] = p
        else:
          let r = ((p shr 16) and 255) * a div 255
          let g = ((p shr 8) and 255) * a div 255
          let bl = (p and 255) * a div 255
          v.buf[row + x] = 0xFF000000'u32 or (r shl 16) or (g shl 8) or bl
  # the size made even (or aligned as Android's encoder wants it): the last column and row repeated
  for y in 0 ..< v.srcH:
    for x in v.srcW ..< ww: v.buf[y * ww + x] = v.buf[y * ww + v.srcW - 1]
  for y in v.srcH ..< hh:
    copyMem(addr v.buf[y * ww], addr v.buf[(v.srcH - 1) * ww], ww * 4)

proc i420Of(px: openArray[uint32]; w, h: int; bt709: bool): string =
  ## The picture as YUV 4:2:0, planar (Y, then U, then V), limited range.
  # BT.709 / BT.601 in 16.16 fixed point: Y = 16 + (kr R + kg G + kb B) * 219/255 ...
  let (yr, yg, yb, ur, ug, ub, vr, vg, vb) =
    if bt709: (46.559, 156.629, 15.812, -25.664, -86.336, 112.0, 112.0, -101.730, -10.270)
    else: (65.481, 128.553, 24.966, -37.797, -74.203, 112.0, 112.0, -93.786, -18.214)
  template fx(c: float): int = int(round(c * 65536.0 / 255.0))
  let cyr = fx(yr)
  let cyg = fx(yg)
  let cyb = fx(yb)
  let cur = fx(ur)
  let cug = fx(ug)
  let cub = fx(ub)
  let cvr = fx(vr)
  let cvg = fx(vg)
  let cvb = fx(vb)
  result = newString(w * h * 3 div 2)
  let uOff = w * h
  let vOff = uOff + (w div 2) * (h div 2)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let p = px[y * w + x]
      let r = int((p shr 16) and 255)
      let g = int((p shr 8) and 255)
      let b = int(p and 255)
      result[y * w + x] = char(clamp((cyr * r + cyg * g + cyb * b + 32768) shr 16 + 16, 16, 235))
  for y in 0 ..< h div 2:
    for x in 0 ..< w div 2:
      var r, g, b = 0
      for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)]:
        let p = px[(2 * y + dy) * w + 2 * x + dx]
        r += int((p shr 16) and 255)
        g += int((p shr 8) and 255)
        b += int(p and 255)
      let i = y * (w div 2) + x
      result[uOff + i] = char(clamp((cur * r + cug * g + cub * b + 131072) shr 18 + 128, 16, 240))
      result[vOff + i] = char(clamp((cvr * r + cvg * g + cvb * b + 131072) shr 18 + 128, 16, 240))

proc addFrame*(v: VideoWriter; b: Bitmap): bool {.discardable.} =
  ## Adds the next picture (shown 1 / fps seconds). A picture of another
  ## size is centred on black (made smaller when it is larger); transparent
  ## parts are black. False (and `error` set) when it could not be written.
  if v == nil or v.done or v.error.len > 0 or v.kind == wkNone or b == nil or b.w <= 0 or b.h <= 0:
    return false
  v.frameOf(b)
  case v.kind
  of wkFfmpeg:
    try:
      when cpuEndian == bigEndian:
        var be = v.buf
        for p in be.mitems:
          p = (p shr 24) or ((p shr 8) and 0xFF00'u32) or ((p shl 8) and 0xFF0000'u32) or (p shl 24)
        v.p.inputStream.writeData(addr be[0], be.len * 4)
      else:
        v.p.inputStream.writeData(addr v.buf[0], v.buf.len * 4)
    except CatchableError, OSError:
      var said = ""
      try:
        v.p.inputStream.close()
        said = v.p.outputStream.readAll().strip
      except CatchableError, OSError: discard
      v.error = "ffmpeg stopped: " & (if said.len > 0: said.splitLines[^1] else: "it could not write the video.")
      return false
  of wkSystem:
    try:
      writeFile(v.tmp, i420Of(v.buf, v.width, v.height, v.bt709))
    except IOError, OSError:
      v.error = "The picture could not be written for the encoder."
      return false
    let us = int64(float(v.frames) * 1_000_000.0 / v.fps + 0.5)
    let r = systemCall("media.encFrame", v.sysId & "\t" & v.tmp & "\t" & $us).split('\t')
    if r[0] != "1":
      v.error = if r.len >= 2: r[1] else: "The encoder stopped."
      return false
  of wkMf:
    when defined(windows):
      if not mfAdd(v): return false
  of wkNone: return false
  inc v.frames
  true

proc finish*(v: VideoWriter): bool =
  ## Ends the video: the file is complete when true; on false `error` says
  ## why (the file may be missing or broken).
  if v == nil: return false
  if v.done: return v.error.len == 0
  v.done = true
  case v.kind
  of wkFfmpeg:
    var said = ""
    var code = -1
    try:
      v.p.inputStream.close()
      said = v.p.outputStream.readAll().strip
      code = v.p.waitForExit()
    except CatchableError, OSError: discard
    try: v.p.close()
    except CatchableError, OSError: discard
    if v.error.len == 0 and code != 0:
      v.error = "ffmpeg could not write the video" & (if said.len > 0: ": " & said.splitLines[^1] else: ".")
  of wkSystem:
    let r = systemCall("media.encEnd", v.sysId & "\t" & (if v.error.len > 0: "1" else: "0")).split('\t')
    if v.error.len == 0 and r[0] != "1":
      v.error = if r.len >= 2: r[1] else: "The encoder could not finish the video."
    try: removeFile(v.tmp) except OSError: discard
  of wkMf:
    when defined(windows): mfFinish(v)
  of wkNone: discard
  if v.error.len == 0 and v.frames == 0: v.error = "The video has no pictures."
  if v.error.len == 0 and (not fileExists(v.path) or getFileSize(v.path) == 0):
    v.error = "The video file was not written."
  v.error.len == 0

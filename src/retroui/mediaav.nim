## (included by mediaplayer) macOS and iOS: AVFoundation's AVPlayer, the
## system's own player: it plays the sound itself, and an
## AVPlayerItemVideoOutput hands the kit each picture (BGRA), which the kit
## draws in the window -- under its menus and dialogs, as any drawing.
## Files and web addresses (MP4, MOV, HLS, MP3, AAC...), reached through
## the Objective-C runtime; AVFoundation and CoreVideo are loaded when the
## first video plays.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[dynlib, os]
import native

type
  CMTime {.bycopy.} = object
    value: int64
    timescale: int32
    flags: uint32
    epoch: int64
  MediaPlayer* = ref object
    ## A file or an address playing through AVFoundation.
    player, item, output: ObjcId
    frame*: Bitmap           ## the latest picture (nil: none yet)
    ended*: bool             ## it played to the end
    failed*: bool            ## it cannot be played
    video: bool
    volume: float
    started: bool            ## asked to play at least once
    lastPos: int
    rate: float32            ## (the speed: 1 as recorded)

var
  avState = 0                ## 0 not tried, 1 there, -1 not
  cvLock: proc (b: pointer; flags: uint64): int32 {.cdecl, gcsafe.}
  cvUnlock: proc (b: pointer; flags: uint64): int32 {.cdecl, gcsafe.}
  cvBase: proc (b: pointer): pointer {.cdecl, gcsafe.}
  cvRow: proc (b: pointer): csize_t {.cdecl, gcsafe.}
  cvWidth, cvHeight: proc (b: pointer): csize_t {.cdecl, gcsafe.}
  cvRelease: proc (b: pointer) {.cdecl, gcsafe.}
  cvFormatKey: ptr ObjcId        ## kCVPixelBufferPixelFormatTypeKey

const
  Frameworks = when defined(ios): "/System/Library/Frameworks/"
               else: "/System/Library/Frameworks/"
  Bgra = 0x42475241'u32          # kCVPixelFormatType_32BGRA ('BGRA')

proc playerAvailable*(): bool =
  ## AVFoundation is there (loaded the first time).
  if avState == 0:
    avState = -1
    let av = loadLib(Frameworks & "AVFoundation.framework/AVFoundation")
    let cv = loadLib(Frameworks & "CoreVideo.framework/CoreVideo")
    if av != nil and cv != nil and objcClass("AVPlayer") != nil:
      cvLock = cast[typeof(cvLock)](cv.symAddr("CVPixelBufferLockBaseAddress"))
      cvUnlock = cast[typeof(cvUnlock)](cv.symAddr("CVPixelBufferUnlockBaseAddress"))
      cvBase = cast[typeof(cvBase)](cv.symAddr("CVPixelBufferGetBaseAddress"))
      cvRow = cast[typeof(cvRow)](cv.symAddr("CVPixelBufferGetBytesPerRow"))
      cvWidth = cast[typeof(cvWidth)](cv.symAddr("CVPixelBufferGetWidth"))
      cvHeight = cast[typeof(cvHeight)](cv.symAddr("CVPixelBufferGetHeight"))
      cvRelease = cast[typeof(cvRelease)](cv.symAddr("CVBufferRelease"))
      cvFormatKey = cast[ptr ObjcId](cv.symAddr("kCVPixelBufferPixelFormatTypeKey"))
      if cvLock != nil and cvUnlock != nil and cvBase != nil and cvRow != nil and
         cvWidth != nil and cvHeight != nil and cvRelease != nil and cvFormatKey != nil:
        avState = 1
  avState == 1

proc ms(t: CMTime): int =
  ## A CMTime in milliseconds (0 when it is not a time: indefinite, invalid).
  if (t.flags and 1) == 0 or (t.flags and (4 or 8 or 16)) != 0 or t.timescale <= 0: 0
  else: int(t.value * 1000 div int64(t.timescale))

proc close*(p: MediaPlayer) =
  ## Stops it and lets it go.
  if p == nil or p.player == nil: return
  autoreleasePool:
    objcSend(void, p.player, "pause")
    if p.item != nil and p.output != nil: objcSend(void, p.item, "removeOutput:", p.output)
    if p.output != nil: objcSend(void, p.output, "release")
    objcSend(void, p.player, "release")
  p.player = nil
  p.item = nil
  p.output = nil

proc openPlayer*(path: string; video: bool; audioSink = ""): MediaPlayer =
  ## `path` (a file or a web address) ready to play, paused at its start;
  ## nil when AVFoundation is not there. `audioSink` "fakesink": no sound.
  if not playerAvailable(): return nil
  let l = path.toLowerAscii
  let web = l.startsWith("http://") or l.startsWith("https://")
  if not web and not fileExists(path): return nil
  autoreleasePool:
    let url = if web: objcSend(ObjcId, objcClass("NSURL"), "URLWithString:", nsString(path))
              else: objcSend(ObjcId, objcClass("NSURL"), "fileURLWithPath:", nsString(path.absolutePath))
    if url == nil: return nil
    let player = objcSend(ObjcId, objcClass("AVPlayer"), "playerWithURL:", url)
    if player == nil: return nil
    objcSend(void, player, "retain")
    result = MediaPlayer(player: player, video: video, volume: 1.0, rate: 1.0)
    result.item = objcSend(ObjcId, player, "currentItem")
    when defined(ios):
      if not video:
        # (a sound plays with the ring switch on silent, and on in the
        # background with UIBackgroundModes audio)
        let session = objcSend(ObjcId, objcClass("AVAudioSession"), "sharedInstance")
        if session != nil:
          discard objcSend(bool, session, "setCategory:error:",
                           nsString("AVAudioSessionCategoryPlayback"), ObjcId(nil))
          discard objcSend(bool, session, "setActive:error:", true, ObjcId(nil))
    if audioSink == "fakesink": objcSend(void, player, "setMuted:", true)
    if video and result.item != nil:
      # the pictures as BGRA, for the kit to draw
      let fmt = objcSend(ObjcId, objcClass("NSNumber"), "numberWithUnsignedInt:", Bgra)
      let key = cvFormatKey[]
      let attrs = objcSend(ObjcId, objcClass("NSDictionary"), "dictionaryWithObject:forKey:", fmt, key)
      let output = objcSend(ObjcId, objcSend(ObjcId, objcClass("AVPlayerItemVideoOutput"), "alloc"),
                            "initWithPixelBufferAttributes:", attrs)
      if output != nil:
        objcSend(void, result.item, "addOutput:", output)
        result.output = output

proc play*(p: MediaPlayer) =
  ## Plays (on from where it is).
  if p == nil or p.player == nil: return
  p.ended = false
  p.started = true
  objcSend(void, p.player, "setMuted:", false)
  objcSend(void, p.player, "play")
  if p.rate != 1.0: objcSend(void, p.player, "setRate:", p.rate)

proc pause*(p: MediaPlayer) =
  ## Pauses where it is.
  if p != nil and p.player != nil: objcSend(void, p.player, "pause")

proc playing*(p: MediaPlayer): bool =
  ## It is playing.
  p != nil and p.player != nil and objcSend(float32, p.player, "rate") != 0

proc positionMs*(p: MediaPlayer): int =
  ## Where it is, in milliseconds.
  if p == nil or p.player == nil: 0 else: ms(objcSend(CMTime, p.player, "currentTime"))

proc durationMs*(p: MediaPlayer): int =
  ## How long it is, in milliseconds (0 when not known; a live stream).
  if p == nil or p.item == nil: 0 else: ms(objcSend(CMTime, p.item, "duration"))

proc setRate*(p: MediaPlayer; rate: float) =
  ## The speed it plays at (0.5 .. 3; 1 as recorded); a voice keeps its pitch.
  if p == nil or p.player == nil: return
  p.rate = float32(clamp(rate, 0.25, 4.0))
  if objcSend(float32, p.player, "rate") != 0: objcSend(void, p.player, "setRate:", p.rate)

proc seekMs*(p: MediaPlayer; ms: int) =
  ## Goes to `ms` milliseconds.
  if p == nil or p.player == nil: return
  p.ended = false
  let t = CMTime(value: int64(max(0, ms)), timescale: 1000, flags: 1, epoch: 0)
  objcSend(void, p.player, "seekToTime:", t)

proc setVolume*(p: MediaPlayer; v: float) =
  ## The volume (0..1 here; more is as 1).
  if p == nil or p.player == nil: return
  p.volume = clamp(v, 0.0, 4.0)
  objcSend(void, p.player, "setVolume:", float32(min(1.0, p.volume)))

proc showFirstPicture*(p: MediaPlayer) =
  ## Its first picture without playing (taken when the output has it).
  discard

proc takeFrame(p: MediaPlayer; t: CMTime): bool =
  let buf = objcSend(pointer, p.output, "copyPixelBufferForItemTime:itemTimeForDisplay:", t,
                     pointer(nil))
  if buf == nil: return false
  if cvLock(buf, 1) == 0:
    let w = int(cvWidth(buf))
    let h = int(cvHeight(buf))
    let row = int(cvRow(buf))
    let base = cast[ptr UncheckedArray[uint8]](cvBase(buf))
    if base != nil and w > 0 and h > 0 and w <= 8192 and h <= 8192 and row >= w * 4:
      if p.frame == nil or p.frame.w != w or p.frame.h != h: p.frame = newBitmap(w, h)
      for y in 0 ..< h:
        let src = cast[ptr UncheckedArray[uint32]](addr base[y * row])
        for x in 0 ..< w: p.frame.px[y * w + x] = src[x] or 0xFF000000'u32
      p.frame.changed()
      result = true
    discard cvUnlock(buf, 1)
  cvRelease(buf)

proc poll*(p: MediaPlayer): bool =
  ## Takes what happened: the end, an error, a new picture (then true).
  if p == nil or p.player == nil: return false
  autoreleasePool:
    if p.item != nil and objcSend(int, p.item, "status") == 2: p.failed = true   # failed
    let pos = p.positionMs
    let dur = p.durationMs
    if p.started and dur > 0 and pos >= dur - 40 and not p.playing and not p.ended:
      p.ended = true
    p.lastPos = pos
    if p.output != nil and p.item != nil:
      let t = objcSend(CMTime, p.item, "currentTime")
      if objcSend(bool, p.output, "hasNewPixelBufferForItemTime:", t) or p.frame == nil:
        result = p.takeFrame(t)

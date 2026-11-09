## (included by mediasession) macOS and iOS: MPNowPlayingInfoCenter (the
## menu bar's Now Playing, the lock screen, Control Center) and
## MPRemoteCommandCenter (their buttons, the media keys, AirPods), through
## the Objective-C runtime; MediaPlayer.framework is loaded when the app
## first says what it plays.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/dynlib
import native

proc objc_allocateClassPair(super: pointer; name: cstring; extra: int): pointer {.importc, cdecl.}
proc objc_registerClassPair(cls: pointer) {.importc, cdecl.}
proc class_addMethod(cls, name, imp: pointer; types: cstring): bool {.importc, cdecl.}

var
  mpState = 0                    ## 0 not tried, 1 ready, -1 none
  mpLib: LibHandle
  mpTarget: ObjcId

proc key(name: string): ObjcId =
  ## One of MediaPlayer's NSString constants (MPMediaItemPropertyTitle...).
  let p = cast[ptr ObjcId](mpLib.symAddr(name))
  if p == nil: nsString(name) else: p[]

proc playAct(self, cmd, event: ObjcId): int {.cdecl.} =
  press(mkPlay)
  0
proc pauseAct(self, cmd, event: ObjcId): int {.cdecl.} =
  press(mkPause)
  0
proc toggleAct(self, cmd, event: ObjcId): int {.cdecl.} =
  press(mkPlayPause)
  0
proc stopAct(self, cmd, event: ObjcId): int {.cdecl.} =
  press(mkStop)
  0
proc nextAct(self, cmd, event: ObjcId): int {.cdecl.} =
  press(mkNext)
  0
proc previousAct(self, cmd, event: ObjcId): int {.cdecl.} =
  press(mkPrevious)
  0
proc seekAct(self, cmd, event: ObjcId): int {.cdecl.} =
  press(mkSeekTo, int(objcSend(float64, event, "positionTime") * 1000))
  0

const Commands = [("playCommand", "retroPlay:"), ("pauseCommand", "retroPause:"),
                  ("togglePlayPauseCommand", "retroToggle:"), ("stopCommand", "retroStop:"),
                  ("nextTrackCommand", "retroNext:"), ("previousTrackCommand", "retroPrevious:"),
                  ("changePlaybackPositionCommand", "retroSeek:")]

proc ready(): bool =
  if mpState != 0: return mpState == 1
  mpState = -1
  mpLib = loadLib("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer")
  if mpLib == nil or objcClass("MPRemoteCommandCenter") == nil: return false
  var cls = objcClass("RetroMediaTarget")
  if cls == nil:
    cls = objc_allocateClassPair(objcClass("NSObject"), "RetroMediaTarget", 0)
    if cls == nil: return false
    let imps = [cast[pointer](playAct), cast[pointer](pauseAct), cast[pointer](toggleAct),
                cast[pointer](stopAct), cast[pointer](nextAct), cast[pointer](previousAct),
                cast[pointer](seekAct)]
    for i, (_, s) in Commands:
      discard class_addMethod(cls, sel(s), imps[i], "q@:@")
    objc_registerClassPair(cls)
  mpTarget = objcSend(ObjcId, objcSend(ObjcId, cls, "alloc"), "init")
  let center = objcSend(ObjcId, objcClass("MPRemoteCommandCenter"), "sharedCommandCenter")
  if center == nil: return false
  for (getter, s) in Commands:
    # (a selector known only now: objc_msgSend called as it is)
    let c = cast[proc (o, s: pointer): ObjcId {.cdecl.}](msgSendFor[ObjcId]())(center, sel(getter))
    if c != nil:
      discard objcSend(ObjcId, c, "addTarget:action:", mpTarget, sel(s))
      objcSend(void, c, "setEnabled:", true)
  mpState = 1
  true

proc number(v: float64): ObjcId = objcSend(ObjcId, objcClass("NSNumber"), "numberWithDouble:", v)

proc tell(old: NowPlaying; first: bool) =
  if not ready(): return
  autoreleasePool:
    let center = objcSend(ObjcId, objcClass("MPRemoteCommandCenter"), "sharedCommandCenter")
    objcSend(void, objcSend(ObjcId, center, "nextTrackCommand"), "setEnabled:", current.canNext)
    objcSend(void, objcSend(ObjcId, center, "previousTrackCommand"), "setEnabled:", current.canPrevious)
    objcSend(void, objcSend(ObjcId, center, "changePlaybackPositionCommand"), "setEnabled:",
             current.canSeek)
    let d = objcSend(ObjcId, objcClass("NSMutableDictionary"), "dictionary")
    template put(v: ObjcId; k: string) =
      objcSend(void, d, "setObject:forKey:", v, key(k))
    if current.title.len > 0: put(nsString(current.title), "MPMediaItemPropertyTitle")
    if current.artist.len > 0: put(nsString(current.artist), "MPMediaItemPropertyArtist")
    if current.album.len > 0: put(nsString(current.album), "MPMediaItemPropertyAlbumTitle")
    if current.durationMs > 0:
      put(number(float64(current.durationMs) / 1000), "MPMediaItemPropertyPlaybackDuration")
    put(number(float64(current.positionMs) / 1000), "MPNowPlayingInfoPropertyElapsedPlaybackTime")
    put(number(if current.playing: 1.0 else: 0.0), "MPNowPlayingInfoPropertyPlaybackRate")
    put(objcSend(ObjcId, objcClass("NSNumber"), "numberWithInteger:", (if current.video: 2 else: 1)),
        "MPNowPlayingInfoPropertyMediaType")
    let info = objcSend(ObjcId, objcClass("MPNowPlayingInfoCenter"), "defaultCenter")
    objcSend(void, info, "setNowPlayingInfo:", d)
    if respondsTo(info, "setPlaybackState:"):
      objcSend(void, info, "setPlaybackState:", (if current.playing: 1 else: 2))

proc untell() =
  if mpState != 1: return
  autoreleasePool:
    let info = objcSend(ObjcId, objcClass("MPNowPlayingInfoCenter"), "defaultCenter")
    objcSend(void, info, "setNowPlayingInfo:", ObjcId(nil))
    if respondsTo(info, "setPlaybackState:"): objcSend(void, info, "setPlaybackState:", 3)

proc pump() = discard
  ## (the commands come on the main thread, as the app's frames: `press`)

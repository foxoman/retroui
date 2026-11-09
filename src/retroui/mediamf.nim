## (included by mediaplayer) Windows: Media Foundation's media engine, the
## player inside Windows 8 and later (and its Edge), in frame-server mode:
## it plays the sound itself and hands the kit each picture, which the kit
## draws in the window -- under its menus and dialogs, as any drawing. Files
## and web addresses (MP4, H.264/H.265, MP3, AAC, WMV...); loaded at run
## time (mfplat.dll: Windows N editions have it with the Media Feature
## Pack). The pictures come through a WIC bitmap: no Direct3D needed.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[dynlib, os]
import wincom

const
  ClsidEngineFactory = guid"b44392da-499b-446b-a4cb-005fead0e6d5"
  IidEngineFactory = guid"4d645ace-26aa-4688-9be1-df3516990b93"
  IidEngineNotify = guid"fee7c112-e776-42b5-9bbf-0048524e2bd5"
  AttrCallback = guid"c60381b8-83a4-41f8-a3d0-de05076849a9"
  AttrOutputFormat = guid"5066893c-8cf9-42bc-8b8a-472212e52726"
  ClsidWicFactory = guid"cacaf262-9370-4615-a13b-9f5539da4c0a"
  IidWicFactory = guid"ec5ec8a9-c395-4314-9c77-54d7a935ff70"
  WicBgra = guid"6fddc324-4e03-4bfe-b185-3d77768dc90f"
  WicPbgra = guid"6fddc324-4e03-4bfe-b185-3d77768dc910"
  MfVersion = 0x00020070'u32
  DxgiB8G8R8A8 = 87'u32
  # what the engine tells (MF_MEDIA_ENGINE_EVENT)
  EvError = 5
  EvLoadedMetadata = 10
  EvEnded = 19
  EvFirstFrame = 1009

type
  MfRect {.bycopy.} = object
    left, top, right, bottom: int32
  Events = object
    ## (written by the engine's threads, read by the app's)
    ended, failed, ready, frameReady: int
  MediaPlayer* = ref object
    ## A file or an address playing through Media Foundation.
    engine: Com
    notify: ptr Callback
    events: ptr Events
    wic: Com                 ## the bitmap pictures come into
    wicW, wicH: int
    wicFormat: Guid
    frame*: Bitmap           ## the latest picture (nil: none yet)
    ended*: bool             ## it played to the end
    failed*: bool            ## it cannot be played
    video: bool
    volume: float
    poster: bool             ## showing its first picture, not playing

var
  mfState = 0                ## 0 not tried, 1 there, -1 not
  mfStartup: proc (version, flags: uint32): HRESULT {.stdcall, gcsafe.}
  mfCreateAttributes: proc (a: ptr Com; n: uint32): HRESULT {.stdcall, gcsafe.}
  wicFactory: Com

proc playerAvailable*(): bool =
  ## Media Foundation's engine is there (loaded the first time).
  if mfState == 0:
    mfState = -1
    let plat = loadLib("mfplat.dll")
    if plat != nil:
      mfStartup = cast[typeof(mfStartup)](plat.symAddr("MFStartup"))
      mfCreateAttributes = cast[typeof(mfCreateAttributes)](plat.symAddr("MFCreateAttributes"))
      if mfStartup != nil and mfCreateAttributes != nil:
        coInit()
        if succeeded(mfStartup(MfVersion, 0)):
          var f: Com
          if coCreate(ClsidEngineFactory, IidEngineFactory, f):
            f.release()
            mfState = 1
  mfState == 1

proc onEvent(c: ptr Callback; a, b: pointer): HRESULT {.nimcall, gcsafe.} =
  ## IMFMediaEngineNotify::EventNotify, from the engine's threads.
  let ev = cast[ptr Events](c.user)
  case int(cast[uint](a) and 0xFFFF_FFFF'u)
  of EvEnded: atomicStoreN(addr ev.ended, 1, ATOMIC_RELEASE)
  of EvError: atomicStoreN(addr ev.failed, 1, ATOMIC_RELEASE)
  of EvLoadedMetadata: atomicStoreN(addr ev.ready, 1, ATOMIC_RELEASE)
  of EvFirstFrame: atomicStoreN(addr ev.frameReady, 1, ATOMIC_RELEASE)
  else: discard
  0

proc urlOf(path: string): string =
  let l = path.toLowerAscii
  if l.startsWith("http://") or l.startsWith("https://") or l.startsWith("file:") or
     l.startsWith("rtsp://") or l.startsWith("ms-appx"):
    path
  else:
    var p = path.absolutePath.replace('\\', '/')
    "file:///" & p.strip(leading = true, trailing = false, chars = {'/'})

proc close*(p: MediaPlayer) =
  ## Stops it and lets it go.
  if p == nil or p.engine == nil: return
  discard p.engine.call(42, proc (this: Com): HRESULT {.stdcall, gcsafe.})(p.engine)  # Shutdown
  p.engine.release()
  p.engine = nil
  if p.wic != nil:
    p.wic.release()
    p.wic = nil
  if p.notify != nil:
    release(cast[Com](p.notify))
    p.notify = nil
  # (the events stay: the engine's threads may still be on their way out)

proc openPlayer*(path: string; video: bool; audioSink = ""): MediaPlayer =
  ## `path` (a file or a web address) ready to play, paused at its start;
  ## nil when Media Foundation is not there or cannot open it. `audioSink`
  ## "fakesink": no sound.
  if not playerAvailable(): return nil
  let l = path.toLowerAscii
  if not (l.startsWith("http") or l.startsWith("rtsp") or fileExists(path)): return nil
  let events = cast[ptr Events](allocShared0(sizeof(Events)))
  let notify = newCallback(0, events, onEvent, [IidEngineNotify])
  var attrs: Com
  if not succeeded(mfCreateAttributes(addr attrs, 2)) or attrs == nil:
    release(cast[Com](notify))
    return nil
  var g1 = AttrCallback
  discard attrs.call(27, proc (this: Com; key: ptr Guid; v: pointer): HRESULT {.stdcall, gcsafe.})(
    attrs, addr g1, notify)                                    # SetUnknown
  var g2 = AttrOutputFormat
  discard attrs.call(21, proc (this: Com; key: ptr Guid; v: uint32): HRESULT {.stdcall, gcsafe.})(
    attrs, addr g2, DxgiB8G8R8A8)                              # SetUINT32
  var factory, engine: Com
  if coCreate(ClsidEngineFactory, IidEngineFactory, factory):
    discard factory.call(3, proc (this: Com; flags: uint32; a: Com; e: ptr Com): HRESULT {.stdcall, gcsafe.})(
      factory, 0, attrs, addr engine)                          # CreateInstance
    factory.release()
  attrs.release()
  if engine == nil:
    release(cast[Com](notify))
    return nil
  result = MediaPlayer(engine: engine, notify: notify, events: events, video: video, volume: 1.0)
  if audioSink == "fakesink":
    discard engine.call(35, proc (this: Com; on: int32): HRESULT {.stdcall, gcsafe.})(engine, 1)  # SetMuted
  let src = bstr(urlOf(path))
  discard engine.call(10, proc (this: Com; pre: int32): HRESULT {.stdcall, gcsafe.})(engine, 3)   # SetPreload: auto
  let hr = engine.call(6, proc (this: Com; url: pointer): HRESULT {.stdcall, gcsafe.})(engine, src)  # SetSource
  freeBstr(src)
  if not succeeded(hr):
    result.close()
    result = nil; return
  discard engine.call(12, proc (this: Com): HRESULT {.stdcall, gcsafe.})(engine)    # Load

proc play*(p: MediaPlayer) =
  ## Plays (on from where it is).
  if p == nil or p.engine == nil: return
  p.ended = false
  p.poster = false
  discard p.engine.call(35, proc (this: Com; on: int32): HRESULT {.stdcall, gcsafe.})(p.engine, 0)
  discard p.engine.call(32, proc (this: Com): HRESULT {.stdcall, gcsafe.})(p.engine)

proc pause*(p: MediaPlayer) =
  ## Pauses where it is.
  if p != nil and p.engine != nil:
    discard p.engine.call(33, proc (this: Com): HRESULT {.stdcall, gcsafe.})(p.engine)

proc playing*(p: MediaPlayer): bool =
  ## It is playing.
  p != nil and p.engine != nil and not p.poster and
    p.engine.call(20, proc (this: Com): int32 {.stdcall, gcsafe.})(p.engine) == 0   # IsPaused

proc positionMs*(p: MediaPlayer): int =
  ## Where it is, in milliseconds.
  if p == nil or p.engine == nil: return 0
  let s = p.engine.call(16, proc (this: Com): float64 {.stdcall, gcsafe.})(p.engine)  # GetCurrentTime
  if s > 0 and s < 1e9: int(s * 1000) else: 0

proc durationMs*(p: MediaPlayer): int =
  ## How long it is, in milliseconds (0 when not known; a live stream).
  if p == nil or p.engine == nil: return 0
  let s = p.engine.call(19, proc (this: Com): float64 {.stdcall, gcsafe.})(p.engine)  # GetDuration
  if s > 0 and s < 1e9: int(s * 1000) else: 0

proc seekMs*(p: MediaPlayer; ms: int) =
  ## Goes to `ms` milliseconds.
  if p == nil or p.engine == nil: return
  p.ended = false
  discard p.engine.call(17, proc (this: Com; s: float64): HRESULT {.stdcall, gcsafe.})(
    p.engine, float64(max(0, ms)) / 1000)

proc setVolume*(p: MediaPlayer; v: float) =
  ## The volume (0..1 here; more is as 1).
  if p == nil or p.engine == nil: return
  p.volume = clamp(v, 0.0, 4.0)
  discard p.engine.call(37, proc (this: Com; v: float64): HRESULT {.stdcall, gcsafe.})(
    p.engine, min(1.0, p.volume))

proc showFirstPicture*(p: MediaPlayer) =
  ## Its first picture without playing (taken when the engine has it).
  if p != nil: p.poster = true

proc takeFrame(p: MediaPlayer): bool =
  ## The picture now into `frame` (the engine draws it into a WIC bitmap).
  var cx, cy: uint32
  discard p.engine.call(40, proc (this: Com; x, y: ptr uint32): HRESULT {.stdcall, gcsafe.})(
    p.engine, addr cx, addr cy)                                 # GetNativeVideoSize
  let w = int(cx)
  let h = int(cy)
  if w <= 0 or h <= 0 or w > 8192 or h > 8192: return false
  if wicFactory == nil and not coCreate(ClsidWicFactory, IidWicFactory, wicFactory): return false
  if p.wic == nil or p.wicW != w or p.wicH != h:
    if p.wic != nil: p.wic.release()
    p.wic = nil
    for fmt in [WicBgra, WicPbgra]:
      var g = fmt
      if succeeded(wicFactory.call(17, proc (this: Com; w, h: uint32; f: ptr Guid; cache: int32;
                                            b: ptr Com): HRESULT {.stdcall, gcsafe.})(
           wicFactory, uint32(w), uint32(h), addr g, 2, addr p.wic)) and p.wic != nil:
        p.wicFormat = fmt
        break
    if p.wic == nil: return false
    p.wicW = w
    p.wicH = h
  var dst = MfRect(left: 0, top: 0, right: int32(w), bottom: int32(h))
  let hr = p.engine.call(43, proc (this: Com; surf: Com; src, dst, border: pointer): HRESULT {.stdcall, gcsafe.})(
    p.engine, p.wic, nil, addr dst, nil)                        # TransferVideoFrame
  if not succeeded(hr): return false
  if p.frame == nil or p.frame.w != w or p.frame.h != h: p.frame = newBitmap(w, h)
  var rows = newSeq[uint32](w * h)
  if not succeeded(p.wic.call(7, proc (this: Com; r: pointer; stride, size: uint32; buf: pointer): HRESULT {.stdcall, gcsafe.})(
       p.wic, nil, uint32(w * 4), uint32(w * h * 4), addr rows[0])): return false   # CopyPixels
  for i in 0 ..< w * h: p.frame.px[i] = rows[i] or 0xFF000000'u32
  p.frame.changed()
  true

proc poll*(p: MediaPlayer): bool =
  ## Takes what happened: the end, an error, a new picture (then true).
  if p == nil or p.engine == nil: return false
  if atomicLoadN(addr p.events.ended, ATOMIC_ACQUIRE) != 0:
    atomicStoreN(addr p.events.ended, 0, ATOMIC_RELEASE)
    p.ended = true
  if atomicLoadN(addr p.events.failed, ATOMIC_ACQUIRE) != 0: p.failed = true
  if not p.video: return false
  var pts: int64
  let fresh = p.engine.call(44, proc (this: Com; pts: ptr int64): HRESULT {.stdcall, gcsafe.})(
    p.engine, addr pts) == 0                                    # OnVideoStreamTick: S_OK
  if fresh or (p.frame == nil and atomicLoadN(addr p.events.frameReady, ATOMIC_ACQUIRE) != 0):
    result = p.takeFrame()

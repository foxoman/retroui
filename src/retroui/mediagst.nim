## GStreamer, when the system has it (most Linux desktops do), loaded at
## run time: `retroui/media` plays sound files of any kind (MP3, OGG, AAC,
## FLAC...) and shows video in the window with it, from files and web
## addresses. Without GStreamer,
## `gstAvailable` is false and nothing else here is used. Apps use it
## through `retroui/media`'s `videoView` and `playSound`.
##
## ```nim
## if gstAvailable():
##   let p = gstOpen("song.ogg", video = false)
##   if p != nil:
##     p.play()
##     echo p.durationMs()
## ```

import std/[dynlib, os, strutils]
import uirelays/target   # (androidApp: an APK, not a program in Termux)
import gfx

type
  GstMapInfo = object
    memory: pointer
    flags: cint
    data: ptr UncheckedArray[uint8]
    size, maxsize: csize_t
    userData: array[4, pointer]
    reserved: array[4, pointer]
  GstPlayer* = ref object
    ## A file playing through GStreamer: its picture (video), where it is.
    pipe, sink, bus: pointer
    frame*: Bitmap           ## the latest picture of a video (nil: none yet)
    ended*: bool             ## it played to the end
    failed*: bool            ## GStreamer could not play it
    video: bool
    posterPending: bool
    volume: float

var
  loaded = 0                 # 0 not tried, 1 there, -1 not there
  gstInit: proc (argc, argv: pointer) {.cdecl, gcsafe.}
  makeElement: proc (factory, name: cstring): pointer {.cdecl, gcsafe.}
  setState: proc (e: pointer; state: cint): cint {.cdecl, gcsafe.}
  getState: proc (e: pointer; state, pending: ptr cint; timeout: uint64): cint {.cdecl, gcsafe.}
  queryPos, queryDur: proc (e: pointer; fmt: cint; v: ptr int64): cint {.cdecl, gcsafe.}
  seekSimple: proc (e: pointer; fmt, flags: cint; pos: int64): cint {.cdecl, gcsafe.}
  getBus: proc (e: pointer): pointer {.cdecl, gcsafe.}
  popFiltered: proc (bus: pointer; types: cint): pointer {.cdecl, gcsafe.}
  miniUnref, objUnref, gFree: proc (o: pointer) {.cdecl, gcsafe.}
  toUri: proc (path: cstring; err: ptr pointer): cstring {.cdecl, gcsafe.}
  capsFrom: proc (s: cstring): pointer {.cdecl, gcsafe.}
  sampleBuffer, sampleCaps: proc (s: pointer): pointer {.cdecl, gcsafe.}
  bufMap: proc (b: pointer; info: ptr GstMapInfo; flags: cint): cint {.cdecl, gcsafe.}
  bufUnmap: proc (b: pointer; info: ptr GstMapInfo) {.cdecl, gcsafe.}
  capsStruct: proc (c: pointer; i: cuint): pointer {.cdecl, gcsafe.}
  structInt: proc (s: pointer; field: cstring; v: ptr cint): cint {.cdecl, gcsafe.}
  pullSample, pullPreroll: proc (sink: pointer; timeout: uint64): pointer {.cdecl, gcsafe.}
  objSet: proc (o: pointer; name: cstring) {.cdecl, varargs, gcsafe.}

const
  FormatTime = 3
  StateNull = 1
  StatePaused = 3
  StatePlaying = 4
  MsgEos = 1
  MsgError = 2

when not (androidApp or defined(ios) or defined(windows) or defined(macosx)):
  import std/locks
  var gstLock: Lock
  initLock(gstLock)

proc loadGst(): bool =
  ## (GStreamer's functions found, GStreamer started: the first time
  ## takes a moment -- its plugins looked through)
  when androidApp or defined(ios) or defined(windows) or defined(macosx):
    return false
  else:
    let core = loadLib("libgstreamer-1.0.so.0")
    let app = loadLib("libgstapp-1.0.so.0")
    let gobj = loadLib("libgobject-2.0.so.0")
    let glib = loadLib("libglib-2.0.so.0")
    if core == nil or app == nil or gobj == nil or glib == nil: return false
    template get(lib, v, name: untyped) =
      v = cast[typeof(v)](lib.symAddr(name))
      if v == nil: return false
    get(core, gstInit, "gst_init")
    get(core, makeElement, "gst_element_factory_make")
    get(core, setState, "gst_element_set_state")
    get(core, getState, "gst_element_get_state")
    get(core, queryPos, "gst_element_query_position")
    get(core, queryDur, "gst_element_query_duration")
    get(core, seekSimple, "gst_element_seek_simple")
    get(core, getBus, "gst_element_get_bus")
    get(core, popFiltered, "gst_bus_pop_filtered")
    get(core, miniUnref, "gst_mini_object_unref")
    get(core, objUnref, "gst_object_unref")
    get(core, toUri, "gst_filename_to_uri")
    get(core, capsFrom, "gst_caps_from_string")
    get(core, sampleBuffer, "gst_sample_get_buffer")
    get(core, sampleCaps, "gst_sample_get_caps")
    get(core, bufMap, "gst_buffer_map")
    get(core, bufUnmap, "gst_buffer_unmap")
    get(core, capsStruct, "gst_caps_get_structure")
    get(core, structInt, "gst_structure_get_int")
    get(app, pullSample, "gst_app_sink_try_pull_sample")
    get(app, pullPreroll, "gst_app_sink_try_pull_preroll")
    get(gobj, objSet, "g_object_set")
    get(glib, gFree, "g_free")
    gstInit(nil, nil)
    true

proc gstAvailable*(): bool {.gcsafe.} =
  ## GStreamer (with its app library) is on this system. The first call
  ## starts it (any thread may make it: the others wait).
  when androidApp or defined(ios) or defined(windows) or defined(macosx):
    return false
  else:
    {.cast(gcsafe).}:
      if loaded != 0: return loaded == 1
      withLock gstLock:
        if loaded == 0: loaded = (if loadGst(): 1 else: -1)
      loaded == 1

proc close*(p: GstPlayer) =
  ## Stops it and lets it go.
  if p == nil or p.pipe == nil: return
  discard setState(p.pipe, StateNull)
  if p.bus != nil: objUnref(p.bus)
  objUnref(p.pipe)
  p.pipe = nil
  p.bus = nil
  p.sink = nil

proc systemAudioSink(): string =
  ## The sound output to ask for: PulseAudio (or PipeWire's) when its
  ## server is there, else ALSA when there are sound cards, else none (a
  ## machine without sound plays its videos silent -- GStreamer's own
  ## choice may try a sink that ends the program there).
  let rt = getEnv("XDG_RUNTIME_DIR")
  if getEnv("PULSE_SERVER").len > 0 or (rt.len > 0 and fileExists(rt / "pulse" / "native")):
    "pulsesink"
  elif rt.len > 0 and fileExists(rt / "pipewire-0"): "pipewiresink"
  elif dirExists("/dev/snd"): "alsasink"
  else: "fakesink"

proc gstOpen*(path: string; video: bool; audioSink = ""): GstPlayer =
  ## `path` ready to play (paused on its first picture); nil when
  ## GStreamer is not there or cannot make the player. `audioSink`: an
  ## element for the sound ("fakesink": none; "" the system's).
  let l = path.toLowerAscii
  let stream = l.startsWith("http://") or l.startsWith("https://") or l.startsWith("rtsp://")
  if not gstAvailable() or not (stream or fileExists(path)): return nil
  let pipe = makeElement("playbin", nil)
  if pipe == nil: return nil
  result = GstPlayer(pipe: pipe, video: video, volume: 1.0)
  if stream:
    # (a web address: playbin fetches it, HLS and DASH too where the
    #  plugins are there)
    objSet(pipe, "uri", path.cstring, nil)
  else:
    var err: pointer
    let uri = toUri(path.absolutePath.cstring, addr err)
    if uri == nil:
      objUnref(pipe)
      result = nil; return
    objSet(pipe, "uri", uri, nil)
    gFree(uri)
  if video:
    let sink = makeElement("appsink", nil)
    if sink != nil:
      let caps = capsFrom("video/x-raw,format=BGRx")
      objSet(sink, "caps", caps, nil)
      miniUnref(caps)
      objSet(sink, "max-buffers", cint(2), nil)
      objSet(sink, "drop", cint(1), nil)
      objSet(pipe, "video-sink", sink, nil)    # (playbin keeps it)
      result.sink = sink
  else:
    let fake = makeElement("fakesink", nil)
    if fake != nil: objSet(pipe, "video-sink", fake, nil)
  let wanted = if audioSink.len > 0: audioSink else: systemAudioSink()
  var a = makeElement(wanted.cstring, nil)
  if a == nil and audioSink.len == 0 and wanted != "alsasink" and dirExists("/dev/snd"):
    a = makeElement("alsasink", nil)
  if a != nil: objSet(pipe, "audio-sink", a, nil)
  result.bus = getBus(pipe)
  if setState(pipe, StatePaused) == 0:       # GST_STATE_CHANGE_FAILURE
    result.close()
    result = nil; return

proc play*(p: GstPlayer) =
  ## Plays (on from where it is).
  if p != nil and p.pipe != nil:
    p.ended = false
    if p.posterPending:
      p.posterPending = false
      objSet(p.pipe, "volume", cdouble(p.volume), nil)
    discard setState(p.pipe, StatePlaying)

proc pause*(p: GstPlayer) =
  ## Pauses where it is.
  if p != nil and p.pipe != nil: discard setState(p.pipe, StatePaused)

proc waitReady*(p: GstPlayer; ms: int): bool =
  ## Waits up to `ms` until it is paused or playing (its first picture is
  ## there); false when it failed.
  if p == nil or p.pipe == nil: return false
  var st, pend: cint
  getState(p.pipe, addr st, addr pend, uint64(ms) * 1_000_000) != 0 and
    st in [StatePaused.cint, StatePlaying.cint]

proc playing*(p: GstPlayer): bool =
  ## It is playing (or about to).
  if p == nil or p.pipe == nil: return false
  var st, pend: cint
  discard getState(p.pipe, addr st, addr pend, 0)
  st == StatePlaying or pend == StatePlaying

proc positionMs*(p: GstPlayer): int =
  ## Where it is, in milliseconds (0 when not known).
  if p == nil or p.pipe == nil: return 0
  var v: int64
  if queryPos(p.pipe, FormatTime, addr v) != 0 and v >= 0: int(v div 1_000_000) else: 0

proc durationMs*(p: GstPlayer): int =
  ## How long it is, in milliseconds (0 when not known).
  if p == nil or p.pipe == nil: return 0
  var v: int64
  if queryDur(p.pipe, FormatTime, addr v) != 0 and v >= 0: int(v div 1_000_000) else: 0

proc seekMs*(p: GstPlayer; ms: int) =
  ## Goes to `ms` milliseconds (the nearest key frame).
  if p != nil and p.pipe != nil:
    p.ended = false
    discard seekSimple(p.pipe, FormatTime, 1 or 4, int64(max(0, ms)) * 1_000_000)  # flush, key unit

proc setVolume*(p: GstPlayer; v: float) =
  ## The volume (0..4; 1 is as recorded).
  if p != nil and p.pipe != nil:
    p.volume = clamp(v, 0.0, 4.0)
    if not p.posterPending: objSet(p.pipe, "volume", cdouble(p.volume), nil)

proc showFirstPicture*(p: GstPlayer) =
  ## Gets the first picture of a video without playing it (it plays,
  ## silent, until the picture comes; `poll` then pauses it at the start).
  if p == nil or p.pipe == nil or p.sink == nil or p.frame != nil: return
  p.posterPending = true
  objSet(p.pipe, "volume", cdouble(0), nil)
  discard setState(p.pipe, StatePlaying)

proc takeSample(p: GstPlayer; sample: pointer) =
  if sample == nil: return
  let buf = sampleBuffer(sample)
  let caps = sampleCaps(sample)
  var w, h: cint
  if buf != nil and caps != nil:
    let st = capsStruct(caps, 0)
    if st != nil and structInt(st, "width", addr w) != 0 and structInt(st, "height", addr h) != 0 and
       w > 0 and h > 0 and w <= 8192 and h <= 8192:
      var info: GstMapInfo
      if bufMap(buf, addr info, 1) != 0:
        let n = int(w) * int(h)
        if int(info.size) >= n * 4:
          if p.frame == nil or p.frame.w != w or p.frame.h != h: p.frame = newBitmap(w, h)
          let d = info.data
          for i in 0 ..< n:
            p.frame.px[i] = 0xFF000000'u32 or uint32(d[i * 4]) or (uint32(d[i * 4 + 1]) shl 8) or
                            (uint32(d[i * 4 + 2]) shl 16)
          p.frame.changed()
        bufUnmap(buf, addr info)
  miniUnref(sample)

proc poll*(p: GstPlayer): bool =
  ## Takes what happened: the end, an error, a new picture (then true).
  if p == nil or p.pipe == nil: return false
  if p.bus != nil:
    let m = popFiltered(p.bus, MsgEos)
    if m != nil:
      p.ended = true
      miniUnref(m)
    let e = popFiltered(p.bus, MsgError)
    if e != nil:
      p.failed = true
      miniUnref(e)
  if p.sink != nil:
    var s = pullSample(p.sink, 0)
    var got = false
    while s != nil:                          # (only the newest one is shown)
      p.takeSample(s)
      got = true
      s = pullSample(p.sink, 0)
    if not got and p.frame == nil:
      let pre = pullPreroll(p.sink, 0)
      if pre != nil:
        p.takeSample(pre)
        got = true
    result = got
    if got and p.posterPending:
      p.posterPending = false
      discard setState(p.pipe, StatePaused)
      discard seekSimple(p.pipe, FormatTime, 1 or 4, 0)
      objSet(p.pipe, "volume", cdouble(p.volume), nil)

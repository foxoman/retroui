## (included by capture) Windows: the camera through Media Foundation's
## source reader (its pictures turned into RGB32 by Windows, read on a
## thread of the camera's own) and the microphone through waveIn. Loaded
## at run time (mf.dll, mfplat.dll, mfreadwrite.dll, winmm.dll).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/dynlib
import wincom

const
  AttrSourceType = guid"c60ac5fe-252a-478f-a0ef-bc8fa5f7cad3"
  SourceTypeVidcap = guid"8ac3587a-4ae7-42d8-99e0-0a6013eef90f"
  AttrFriendlyName = guid"60d0e559-52f8-4fa2-bbce-acdb34a8ec01"
  AttrSymbolicLink = guid"58f0aad8-22bf-4f8a-bb3d-d2c4978c6e2f"
  IidMediaSource = guid"279a808d-aec7-40c8-9c6b-a6b492c78a66"
  AttrVideoProcessing = guid"fb394f3d-ccf1-42ee-bbb3-f9b845d5681d"
  MtMajorType = guid"48eba18e-f8c9-4687-bf11-0a74c9f96a8f"
  MtSubtype = guid"f7e34c9a-42e8-4714-b74b-cb29d72c35e5"
  MtFrameSize = guid"1652c33d-d6b2-4012-b834-72030849a37d"
  MtDefaultStride = guid"644b4e48-1e02-4516-b0eb-c01ca9d49ac6"
  MediaTypeVideo = guid"73646976-0000-0010-8000-00aa00389b71"
  FormatRgb32 = guid"00000016-0000-0010-8000-00aa00389b71"
  FirstVideoStream = 0xFFFFFFFC'u32

var
  mfCapState = 0
  mfStartupC: proc (version, flags: uint32): HRESULT {.stdcall, gcsafe.}
  mfAttributes: proc (a: ptr Com; n: uint32): HRESULT {.stdcall, gcsafe.}
  mfMediaType: proc (t: ptr Com): HRESULT {.stdcall, gcsafe.}
  mfEnumDevices: proc (a: Com; list: ptr ptr UncheckedArray[Com]; n: ptr uint32): HRESULT {.stdcall, gcsafe.}
  mfReaderFromSource: proc (src, attrs: Com; r: ptr Com): HRESULT {.stdcall, gcsafe.}
  coInitThread: proc (r: pointer; flags: uint32): HRESULT {.stdcall, gcsafe.}

proc mfCapture(): bool =
  if mfCapState == 0:
    mfCapState = -1
    let plat = loadLib("mfplat.dll")
    let mf = loadLib("mf.dll")
    let rw = loadLib("mfreadwrite.dll")
    let ole = loadLib("ole32.dll")
    if plat != nil and mf != nil and rw != nil and ole != nil:
      mfStartupC = cast[typeof(mfStartupC)](plat.symAddr("MFStartup"))
      mfAttributes = cast[typeof(mfAttributes)](plat.symAddr("MFCreateAttributes"))
      mfMediaType = cast[typeof(mfMediaType)](plat.symAddr("MFCreateMediaType"))
      mfEnumDevices = cast[typeof(mfEnumDevices)](mf.symAddr("MFEnumDeviceSources"))
      mfReaderFromSource = cast[typeof(mfReaderFromSource)](rw.symAddr("MFCreateSourceReaderFromMediaSource"))
      coInitThread = cast[typeof(coInitThread)](ole.symAddr("CoInitializeEx"))
      if mfStartupC != nil and mfAttributes != nil and mfMediaType != nil and mfEnumDevices != nil and
         mfReaderFromSource != nil and coInitThread != nil:
        coInit()
        if succeeded(mfStartupC(0x00020070'u32, 0)): mfCapState = 1
  mfCapState == 1

proc setGuid(a: Com; key, v: Guid) =
  var k = key
  var g = v
  discard a.call(24, proc (this: Com; k, v: ptr Guid): HRESULT {.stdcall, gcsafe.})(a, addr k, addr g)

proc attrText(a: Com; key: Guid): string =
  var k = key
  var p: pointer
  var n: uint32
  if succeeded(a.call(13, proc (this: Com; k: ptr Guid; s: ptr pointer; n: ptr uint32): HRESULT {.stdcall, gcsafe.})(
       a, addr k, addr p, addr n)):
    result = wideOf(p)
    taskFree(p)

proc devices(): seq[Com] =
  ## The video capture devices (IMFActivate; released by the caller).
  if not mfCapture(): return
  var attrs: Com
  if not succeeded(mfAttributes(addr attrs, 1)) or attrs == nil: return
  attrs.setGuid(AttrSourceType, SourceTypeVidcap)
  var list: ptr UncheckedArray[Com]
  var n: uint32
  if succeeded(mfEnumDevices(attrs, addr list, addr n)) and list != nil:
    for i in 0 ..< int(n): result.add list[i]
    taskFree(list)
  attrs.release()

proc sysCameras(): seq[CameraInfo] =
  for d in devices():
    result.add CameraInfo(id: d.attrText(AttrSymbolicLink), name: d.attrText(AttrFriendlyName),
                          facing: cfExternal)
    d.release()

type
  MfShared = object
    ## (the camera's thread and the app's)
    lock: Lock
    px: seq[uint32]
    w, h: int
    fresh, stop, failed, started: bool
    link: string
  MfCam = ref object of RootObj
    sh: ptr MfShared
    thread: Thread[ptr MfShared]

proc cameraLoop(sh: ptr MfShared) {.thread.} =
  {.cast(gcsafe).}:
    discard coInitThread(nil, 0)                 # (this thread: multithreaded)
    var source, reader: Com
    for d in devices():
      if source == nil and (sh.link.len == 0 or d.attrText(AttrSymbolicLink) == sh.link):
        var iid = IidMediaSource
        discard d.call(33, proc (this: Com; iid: ptr Guid; o: ptr Com): HRESULT {.stdcall, gcsafe.})(
          d, addr iid, addr source)                                     # ActivateObject
      d.release()
    var attrs: Com
    if source != nil and succeeded(mfAttributes(addr attrs, 1)):
      var k = AttrVideoProcessing
      discard attrs.call(21, proc (this: Com; k: ptr Guid; v: uint32): HRESULT {.stdcall, gcsafe.})(
        attrs, addr k, 1)
      discard mfReaderFromSource(source, attrs, addr reader)
      attrs.release()
    var stride = 0
    if reader != nil:
      var mt: Com
      if succeeded(mfMediaType(addr mt)):
        mt.setGuid(MtMajorType, MediaTypeVideo)
        mt.setGuid(MtSubtype, FormatRgb32)
        discard reader.call(7, proc (this: Com; s: uint32; r: pointer; t: Com): HRESULT {.stdcall, gcsafe.})(
          reader, FirstVideoStream, nil, mt)                            # SetCurrentMediaType
        mt.release()
      var cur: Com
      if succeeded(reader.call(6, proc (this: Com; s: uint32; t: ptr Com): HRESULT {.stdcall, gcsafe.})(
           reader, FirstVideoStream, addr cur)) and cur != nil:
        var k = MtFrameSize
        var size: uint64
        discard cur.call(8, proc (this: Com; k: ptr Guid; v: ptr uint64): HRESULT {.stdcall, gcsafe.})(
          cur, addr k, addr size)
        var ks = MtDefaultStride
        var st: uint32
        if succeeded(cur.call(7, proc (this: Com; k: ptr Guid; v: ptr uint32): HRESULT {.stdcall, gcsafe.})(
             cur, addr ks, addr st)): stride = int(cast[int32](st))
        withLock sh.lock:
          sh.w = int(size shr 32)
          sh.h = int(size and 0xFFFF_FFFF'u64)
        cur.release()
    if reader == nil or sh.w <= 0 or sh.h <= 0:
      withLock sh.lock: sh.failed = true
      if source != nil: source.release()
      return
    withLock sh.lock: sh.started = true
    if stride == 0: stride = sh.w * 4
    while true:
      var stop: bool
      withLock sh.lock: stop = sh.stop
      if stop: break
      var actual, flags: uint32
      var ts: int64
      var sample: Com
      let hr = reader.call(9, proc (this: Com; s, f: uint32; a, fl: ptr uint32; ts: ptr int64;
                                    smp: ptr Com): HRESULT {.stdcall, gcsafe.})(
        reader, FirstVideoStream, 0, addr actual, addr flags, addr ts, addr sample)   # ReadSample
      if not succeeded(hr) or (flags and 2) != 0:        # (MF_SOURCE_READERF_ENDOFSTREAM)
        withLock sh.lock: sh.failed = true
        break
      if sample == nil: continue
      var buf: Com
      discard sample.call(41, proc (this: Com; b: ptr Com): HRESULT {.stdcall, gcsafe.})(sample, addr buf)
      if buf != nil:
        var data: ptr UncheckedArray[uint8]
        var maxLen, curLen: uint32
        if succeeded(buf.call(3, proc (this: Com; d: ptr ptr UncheckedArray[uint8]; m, c: ptr uint32): HRESULT {.stdcall, gcsafe.})(
             buf, addr data, addr maxLen, addr curLen)):
          let w = sh.w
          let h = sh.h
          let rowBytes = abs(stride)
          if int(curLen) >= rowBytes * h:
            withLock sh.lock:
              sh.px.setLen(w * h)
              for y in 0 ..< h:
                # (a negative stride: the rows bottom up)
                let srcY = if stride < 0: h - 1 - y else: y
                let row = cast[ptr UncheckedArray[uint32]](addr data[srcY * rowBytes])
                for x in 0 ..< w: sh.px[y * w + x] = row[x] or 0xFF000000'u32
              sh.fresh = true
          discard buf.call(4, proc (this: Com): HRESULT {.stdcall, gcsafe.})(buf)
        buf.release()
      sample.release()
    reader.release()
    discard source.call(12, proc (this: Com): HRESULT {.stdcall, gcsafe.})(source)   # Shutdown
    source.release()

proc sysOpen(c: CamState) =
  if not mfCapture():
    c.error = "This Windows has no Media Foundation (the Media Feature Pack)."
    return
  if devices().len == 0:
    c.error = "There is no camera."
    return
  let m = MfCam(sh: cast[ptr MfShared](allocShared0(sizeof(MfShared))))
  initLock m.sh.lock
  m.sh.link = c.camera
  c.sys = m
  createThread(m.thread, cameraLoop, m.sh)

proc sysTake(c: CamState): bool =
  if c.sys == nil: return false
  let m = MfCam(c.sys)
  withLock m.sh.lock:
    if m.sh.failed and not m.sh.started: c.error = "The camera does not start."
    if m.sh.fresh:
      m.sh.fresh = false
      if c.frame == nil or c.frame.w != m.sh.w or c.frame.h != m.sh.h:
        c.frame = newBitmap(m.sh.w, m.sh.h)
      if m.sh.px.len == c.frame.px.len:
        copyMem(addr c.frame.px[0], addr m.sh.px[0], m.sh.px.len * 4)
        c.frame.changed()
        result = true

proc sysClose(c: CamState) =
  if c.sys == nil: return
  let m = MfCam(c.sys)
  withLock m.sh.lock: m.sh.stop = true
  joinThread(m.thread)
  `=destroy`(m.sh[])
  deallocShared(m.sh)
  c.sys = nil

proc sysPlace(c: CamState; r: Rect; covered: bool) = discard
proc sysPhoto(c: CamState; path: string): bool = false

# ---- the microphone: waveIn --------------------------------------------------------------------------

type
  WaveFormat {.packed.} = object
    tag, channels: uint16
    rate, bytesPerSec: uint32
    blockAlign, bits, cbSize: uint16
  WaveHdr = object
    data: pointer
    length, recorded: uint32
    user: uint
    flags, loops: uint32
    next: pointer
    reserved: uint

var
  wiOpen: proc (h: ptr pointer; dev: uint32; fmt: ptr WaveFormat; cb, inst: uint; flags: uint32): uint32 {.stdcall, gcsafe.}
  wiPrepare, wiUnprepare, wiAdd: proc (h: pointer; hdr: ptr WaveHdr; size: uint32): uint32 {.stdcall, gcsafe.}
  wiStart, wiStop, wiReset, wiClose: proc (h: pointer): uint32 {.stdcall, gcsafe.}
  wiState = 0

proc waveIn(): bool =
  if wiState == 0:
    wiState = -1
    let mm = loadLib("winmm.dll")
    if mm != nil:
      wiOpen = cast[typeof(wiOpen)](mm.symAddr("waveInOpen"))
      wiPrepare = cast[typeof(wiPrepare)](mm.symAddr("waveInPrepareHeader"))
      wiUnprepare = cast[typeof(wiUnprepare)](mm.symAddr("waveInUnprepareHeader"))
      wiAdd = cast[typeof(wiAdd)](mm.symAddr("waveInAddBuffer"))
      wiStart = cast[typeof(wiStart)](mm.symAddr("waveInStart"))
      wiStop = cast[typeof(wiStop)](mm.symAddr("waveInStop"))
      wiReset = cast[typeof(wiReset)](mm.symAddr("waveInReset"))
      wiClose = cast[typeof(wiClose)](mm.symAddr("waveInClose"))
      if wiOpen != nil and wiPrepare != nil and wiAdd != nil and wiStart != nil and wiClose != nil:
        wiState = 1
  wiState == 1

const WiBuffers = 4
const WiFrames = 4410            # a tenth of a second each

type WinRec = object
  h: pointer
  hdrs: array[WiBuffers, WaveHdr]
  bufs: array[WiBuffers, array[WiFrames, int16]]

var winRec: ptr WinRec

proc recordLoop(r: ptr Recorder) {.thread.} =
  ## (takes the buffers waveIn filled, gives them back)
  {.cast(gcsafe).}:
    let w = winRec
    while true:
      var stop: bool
      withLock r.lock: stop = r.stopAsked
      for i in 0 ..< WiBuffers:
        if (w.hdrs[i].flags and 1) != 0:                     # WHDR_DONE
          let n = int(w.hdrs[i].recorded) div 2
          let lv = levelOf(cast[ptr UncheckedArray[int16]](addr w.bufs[i][0]), n)
          withLock r.lock:
            let at = r.pcm.len
            r.pcm.setLen(at + n * 2)
            if n > 0: copyMem(addr r.pcm[at], addr w.bufs[i][0], n * 2)
            r.level = lv
          w.hdrs[i].flags = w.hdrs[i].flags and not 1'u32
          if not stop: discard wiAdd(w.h, addr w.hdrs[i], uint32(sizeof(WaveHdr)))
      if stop: break
      sleep(20)
    withLock r.lock: r.running = false

proc sysRecordStart(path: string): bool =
  if not waveIn(): return false
  winRec = cast[ptr WinRec](allocShared0(sizeof(WinRec)))
  var fmt = WaveFormat(tag: 1, channels: 1, rate: 44100, bytesPerSec: 88200, blockAlign: 2, bits: 16)
  if wiOpen(addr winRec.h, 0xFFFFFFFF'u32, addr fmt, 0, 0, 0) != 0:
    deallocShared(winRec)
    winRec = nil
    return false
  for i in 0 ..< WiBuffers:
    winRec.hdrs[i].data = addr winRec.bufs[i][0]
    winRec.hdrs[i].length = uint32(WiFrames * 2)
    discard wiPrepare(winRec.h, addr winRec.hdrs[i], uint32(sizeof(WaveHdr)))
    discard wiAdd(winRec.h, addr winRec.hdrs[i], uint32(sizeof(WaveHdr)))
  rec = cast[ptr Recorder](allocShared0(sizeof(Recorder)))
  initLock rec.lock
  rec.path = path
  rec.rate = 44100
  rec.channels = 1
  rec.running = true
  rec.started = epochTime()
  discard wiStart(winRec.h)
  createThread(recThread, recordLoop, rec)
  true

proc sysRecordStop(): int =
  if rec == nil: return 0
  withLock rec.lock: rec.stopAsked = true
  joinThread(recThread)
  discard wiStop(winRec.h)
  discard wiReset(winRec.h)
  for i in 0 ..< WiBuffers:
    discard wiUnprepare(winRec.h, addr winRec.hdrs[i], uint32(sizeof(WaveHdr)))
  discard wiClose(winRec.h)
  deallocShared(winRec)
  winRec = nil
  let bytes = rec.pcm.len
  result = bytes * 1000 div (2 * rec.channels * rec.rate)
  try: writeFile(rec.path, wavHeader(rec.rate, rec.channels, bytes) & rec.pcm)
  except IOError, OSError: result = -1
  deinitLock rec.lock
  `=destroy`(rec[])
  deallocShared(rec)
  rec = nil

proc sysRecording(): bool =
  if rec == nil: return false
  withLock rec.lock: result = rec.running

proc sysLevel(): float =
  if rec == nil: return 0
  withLock rec.lock: result = rec.level

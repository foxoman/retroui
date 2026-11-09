## The camera and the microphone, through each system's own API: a live
## camera picture in the window (drawn by the kit, under its menus and
## dialogs), photos, videos of the camera, and sound recorded to a file.
##
## ============  ===========================================  =========================================
## Platform      Camera                                       Microphone
## ============  ===========================================  =========================================
## Linux, BSD    Video4Linux (/dev/videoN: YUYV, MJPEG)       PulseAudio (or PipeWire's), else ALSA
## Windows       Media Foundation (the source reader)         waveIn
## macOS, iOS    AVFoundation (AVCaptureSession)              AVAudioRecorder
## Android app   Camera2, its preview over the widget         MediaRecorder
## Termux        Termux:API (photos)                          Termux:API (termux-microphone-record)
## Web page      getUserMedia (a <video>, its pictures read)  getUserMedia (16-bit WAV)
## ============  ===========================================  =========================================
##
## Nothing is linked: each is loaded or opened the first time it is used.
## A web page asks the browser, which asks the user (the page over https
## or from localhost).
## Phones ask the user for the camera or the microphone the first time
## (an Android app needs `retroapk --permission:CAMERA` and
## `--permission:RECORD_AUDIO`; iOS and macOS apps the usage texts
## `retroios` and `tools/macapp.sh` put in Info.plist).
##
## .. code-block:: nim
##   app "Camera", 640, 520:
##     let cam = cameraView(height = 420)
##     if cam.error.len > 0: label cam.error
##     row:
##       if button("&Photo"): cameraPhoto("", "photo.jpg")
##       if button(if cam.recording: "&Stop" else: "&Record"):
##         if cam.recording: cameraStop() else: cameraRecord("", "clip.mp4")
##       if button("&Voice"):
##         if recordingSound(): discard stopRecordingSound()
##         else: discard recordSound("note.wav")
##     progress(soundLevel())
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, tables, times, locks, algorithm]
import uirelays/target
import uirelays/services
import gfx, core, widgets, imaging, jpeg
import media

type
  CameraFacing* = enum
    ## Which way a camera looks.
    cfAny      ## whichever there is (the back one first on phones)
    cfBack     ## away from the user
    cfFront    ## at the user
    cfExternal ## plugged in (a webcam)
  CameraInfo* = object
    ## A camera the system has.
    id*: string                ## what `cameraView` takes as `camera`
    name*: string              ## as the system names it
    facing*: CameraFacing
  CameraEvent* = object
    ## What a `cameraView` shows and did this frame.
    ready*: bool               ## its pictures are coming
    width*, height*: int       ## their size
    error*: string             ## why there is none ("" when there is)
    photo*: string             ## a photo `cameraPhoto` asked for was saved (its path), this frame
    recording*: bool           ## `cameraRecord` records
    recordedMs*: int           ## for this long
    saved*: string             ## a video `cameraStop` ended was saved (its path), this frame

# ---- what every system's camera gives --------------------------------------------------------------

type
  CamState = ref object
    camera: string
    facing: CameraFacing
    frame: Bitmap              ## the latest picture
    ready: bool
    error: string
    photoAsked, photoDone: string
    recPath, saved: string
    rec: VideoWriter
    recStart: float
    recFrames: int
    drawn: int
    sys: RootRef               ## the system's part (each system's own type)

var
  cams: Table[string, CamState]
  camHooked = false

# ---- Linux, BSD: Video4Linux ------------------------------------------------------------------------

proc yuyvToBitmap*(data: openArray[uint8]; w, h: int; into: var Bitmap) =
  ## A YUYV (YUV 4:2:2) picture as 0xFFRRGGBB pixels (BT.601, limited
  ## range): what most webcams send.
  if into == nil or into.w != w or into.h != h: into = newBitmap(w, h)
  template clip(v: int): uint32 = uint32(max(0, min(255, v)))
  for y in 0 ..< h:
    for x2 in 0 ..< w div 2:
      let i = (y * w + x2 * 2) * 2
      if i + 3 >= data.len: return
      let y0 = (int(data[i]) - 16) * 298
      let u = int(data[i + 1]) - 128
      let y1 = (int(data[i + 2]) - 16) * 298
      let v = int(data[i + 3]) - 128
      let r = 409 * v + 128
      let g = -100 * u - 208 * v + 128
      let b = 516 * u + 128
      into.px[y * w + x2 * 2] = 0xFF000000'u32 or clip((y0 + r) shr 8) shl 16 or
                                clip((y0 + g) shr 8) shl 8 or clip((y0 + b) shr 8)
      into.px[y * w + x2 * 2 + 1] = 0xFF000000'u32 or clip((y1 + r) shr 8) shl 16 or
                                    clip((y1 + g) shr 8) shl 8 or clip((y1 + b) shr 8)
  into.changed()

# ---- the microphone ----------------------------------------------------------------------------------

type
  Recorder = object
    path: string
    dev, dev2: pointer          ## (the sound system's handles, Linux)
    rate, channels: int
    pcm: string                 ## (what came so far, 16-bit)
    level: float32
    running, stopAsked: bool
    started: float
    lock: Lock

var rec: ptr Recorder
when not defined(wasm):
  var recThread: Thread[ptr Recorder]

proc wavHeader*(rate, channels, bytes: int): string =
  ## The 44 bytes before `bytes` of 16-bit PCM samples in a WAV file.
  proc put(r: var string; v, n: int) =
    for k in 0 ..< n: r.add char((v shr (8 * k)) and 255)
  result = "RIFF"
  result.put(36 + bytes, 4)
  result.add "WAVEfmt "
  result.put(16, 4)
  result.put(1, 2)
  result.put(channels, 2)
  result.put(rate, 4)
  result.put(rate * channels * 2, 4)
  result.put(channels * 2, 2)
  result.put(16, 2)
  result.add "data"
  result.put(bytes, 4)

proc levelOf(p: ptr UncheckedArray[int16]; n: int): float32 =
  var peak = 0
  for i in 0 ..< n: peak = max(peak, abs(int(p[i])))
  float32(peak) / 32768

when not (androidApp or defined(windows) or defined(macosx) or defined(ios) or
          defined(js) or defined(wasm)):
  import std/posix

  const
    VidiocQuerycap = 0x80685600'u
    VidiocSFmt = 0xc0d05605'u
    VidiocReqbufs = 0xc0145608'u
    VidiocQuerybuf = 0xc0585609'u
    VidiocQbuf = 0xc058560f'u
    VidiocDqbuf = 0xc0585611'u
    VidiocStreamon = 0x40045612'u
    VidiocStreamoff = 0x40045613'u
    BufTypeCapture = 1'u32
    MemoryMmap = 1'u32
    CapVideoCapture = 0x1'u32
    CapDeviceCaps = 0x80000000'u32
    FmtYuyv = 0x56595559'u32
    FmtMjpeg = 0x47504a4d'u32

  type
    V4lCap {.bycopy.} = object
      driver: array[16, char]
      card: array[32, char]
      busInfo: array[32, char]
      version, capabilities, deviceCaps: uint32
      reserved: array[3, uint32]
    V4lPix {.bycopy.} = object
      width, height, pixelformat, field, bytesperline, sizeimage, colorspace, priv,
        flags, ycbcrEnc, quantization, xferFunc: uint32
    V4lFormat {.bycopy.} = object
      typ: uint32
      pad: uint32
      pix: V4lPix
      rest: array[200 - sizeof(V4lPix), uint8]
    V4lReqbufs {.bycopy.} = object
      count, typ, memory, capabilities: uint32
      flags: uint8
      reserved: array[3, uint8]
    V4lBuffer {.bycopy.} = object
      index, typ, bytesused, flags, field, pad0: uint32
      timestamp: array[2, int64]
      timecode: array[16, uint8]
      sequence, memory: uint32
      offset: uint64            ## (the union m: an offset for MMAP)
      length, reserved2: uint32
      requestFd: int32
      pad1: uint32
    V4lDevice = object
      fd: cint
      w, h: int
      format: uint32
      bufs: seq[tuple[p: pointer; n: int]]
      streaming: bool

  proc ioctl(fd: cint; req: uint; arg: pointer): cint {.importc, header: "<sys/ioctl.h>", varargs.}

  when sizeof(int) == 8:
    # (the kernel's structures, as videodev2.h lays them out on 64 bits)
    static:
      doAssert sizeof(V4lCap) == 104
      doAssert sizeof(V4lFormat) == 208
      doAssert sizeof(V4lReqbufs) == 20
      doAssert sizeof(V4lBuffer) == 88

  proc text(a: openArray[char]): string =
    for c in a:
      if c == '\0': break
      result.add c

  proc v4lCameras(): seq[CameraInfo] =
    var paths: seq[string]
    for p in walkPattern("/dev/video*"): paths.add p
    paths.sort()
    for p in paths:
      let fd = posix.open(p.cstring, O_RDWR or O_NONBLOCK)
      if fd < 0: continue
      var cap: V4lCap
      if ioctl(fd, VidiocQuerycap, addr cap) == 0:
        let caps = if (cap.capabilities and CapDeviceCaps) != 0: cap.deviceCaps else: cap.capabilities
        if (caps and CapVideoCapture) != 0:
          result.add CameraInfo(id: p, name: text(cap.card), facing: cfExternal)
      discard posix.close(fd)

  proc close(d: var V4lDevice) =
    if d.fd <= 0: return
    if d.streaming:
      var t = BufTypeCapture
      discard ioctl(d.fd, VidiocStreamoff, addr t)
    for b in d.bufs: discard munmap(b.p, b.n)
    d.bufs.setLen(0)
    discard posix.close(d.fd)
    d.fd = 0
    d.streaming = false

  proc open(d: var V4lDevice; path: string): string =
    ## The camera at `path` streaming (640 x 480 or near, YUYV or MJPEG);
    ## "" or why not.
    let fd = posix.open(path.cstring, O_RDWR or O_NONBLOCK)
    if fd < 0: return "The camera cannot be opened (" & path & ")."
    d.fd = fd
    var ok = false
    for fmt in [FmtYuyv, FmtMjpeg]:
      var f = V4lFormat(typ: BufTypeCapture)
      f.pix = V4lPix(width: 640, height: 480, pixelformat: fmt, field: 1)   # V4L2_FIELD_NONE
      if ioctl(fd, VidiocSFmt, addr f) == 0 and f.pix.pixelformat == fmt:
        d.w = int(f.pix.width)
        d.h = int(f.pix.height)
        d.format = fmt
        ok = true
        break
    if not ok:
      d.close()
      return "The camera gives no picture the kit reads (YUYV or MJPEG)."
    var rb = V4lReqbufs(count: 4, typ: BufTypeCapture, memory: MemoryMmap)
    if ioctl(fd, VidiocReqbufs, addr rb) != 0 or rb.count == 0:
      d.close()
      return "The camera's buffers cannot be had."
    for i in 0 ..< int(rb.count):
      var b = V4lBuffer(index: uint32(i), typ: BufTypeCapture, memory: MemoryMmap)
      if ioctl(fd, VidiocQuerybuf, addr b) != 0:
        d.close()
        return "The camera's buffers cannot be had."
      let p = mmap(nil, int(b.length), PROT_READ or PROT_WRITE, MAP_SHARED, fd, Off(b.offset))
      if p == MAP_FAILED:
        d.close()
        return "The camera's buffers cannot be had."
      d.bufs.add (p, int(b.length))
      discard ioctl(fd, VidiocQbuf, addr b)
    var t = BufTypeCapture
    if ioctl(fd, VidiocStreamon, addr t) != 0:
      d.close()
      return "The camera does not start."
    d.streaming = true
    ""

  proc take(d: var V4lDevice; into: var Bitmap): bool =
    ## The newest picture the camera has (without waiting); false: none new.
    if not d.streaming: return false
    var last = -1
    var used = 0
    while true:
      var b = V4lBuffer(typ: BufTypeCapture, memory: MemoryMmap)
      if ioctl(d.fd, VidiocDqbuf, addr b) != 0: break
      if last >= 0:
        var old = V4lBuffer(index: uint32(last), typ: BufTypeCapture, memory: MemoryMmap)
        discard ioctl(d.fd, VidiocQbuf, addr old)
      last = int(b.index)
      used = int(b.bytesused)
    if last < 0: return false
    let buf = d.bufs[last]
    let data = cast[ptr UncheckedArray[uint8]](buf.p)
    if d.format == FmtYuyv:
      yuyvToBitmap(toOpenArray(data, 0, min(used, buf.n) - 1), d.w, d.h, into)
      result = true
    else:
      var s = newString(min(used, buf.n))
      if s.len > 0: copyMem(addr s[0], data, s.len)
      let pic = try: decodeJpeg(s) except CatchableError: nil
      if pic != nil:
        into = pic
        result = true
    var back = V4lBuffer(index: uint32(last), typ: BufTypeCapture, memory: MemoryMmap)
    discard ioctl(d.fd, VidiocQbuf, addr back)

  type V4lCam = ref object of RootObj
    dev: V4lDevice

  proc sysCameras(): seq[CameraInfo] = v4lCameras()

  proc sysOpen(c: CamState) =
    var id = c.camera
    if id.len == 0:
      let all = v4lCameras()
      if all.len == 0:
        c.error = (when defined(android): "Photos only, with Termux:API (cameraPhoto)."
                   else: "There is no camera.")
        return
      id = all[0].id
    let v = V4lCam()
    c.sys = v
    c.error = v.dev.open(id)

  proc sysTake(c: CamState): bool =
    c.sys != nil and V4lCam(c.sys).dev.take(c.frame)

  proc sysClose(c: CamState) =
    if c.sys != nil: V4lCam(c.sys).dev.close()
  proc sysPlace(c: CamState; r: Rect; covered: bool) = discard

  proc sysPhoto(c: CamState; path: string): bool =
    ## (Termux: the phone's camera through Termux:API, when there is no
    ##  /dev/video)
    when defined(android):
      if c.frame == nil:
        return execShellCmd("termux-camera-photo -c " &
                            (if c.facing == cfFront: "1" else: "0") & " " &
                            quoteShell(path) & " >/dev/null 2>&1") == 0
    false

  import std/dynlib

  type
    PaSampleSpec {.bycopy.} = object
      format: cint
      rate: uint32
      channels: uint8

  var
    paNew: proc (server, name: cstring; dir: cint; dev, stream: cstring; ss: ptr PaSampleSpec;
                 map, attr: pointer; err: ptr cint): pointer {.cdecl, gcsafe.}
    paRead: proc (s: pointer; data: pointer; n: csize_t; err: ptr cint): cint {.cdecl, gcsafe.}
    paFree: proc (s: pointer) {.cdecl, gcsafe.}
    alsaOpen: proc (pcm: ptr pointer; name: cstring; stream, mode: cint): cint {.cdecl, gcsafe.}
    alsaSet: proc (pcm: pointer; format, access: cint; channels, rate: cuint; resample: cint;
                   latency: cuint): cint {.cdecl, gcsafe.}
    alsaRead: proc (pcm: pointer; buf: pointer; frames: culong): clong {.cdecl, gcsafe.}
    alsaClose: proc (pcm: pointer): cint {.cdecl, gcsafe.}
    alsaQuiet: proc (h: pointer): cint {.cdecl, gcsafe.}
    audioLibs = 0

  proc alsaNoMessage(file: cstring; line: cint; fn: cstring; err: cint; fmt: cstring) {.cdecl, varargs.} =
    discard

  proc loadAudio() =
    if audioLibs != 0: return
    audioLibs = -1
    let pa = loadLib("libpulse-simple.so.0")
    if pa != nil:
      paNew = cast[typeof(paNew)](pa.symAddr("pa_simple_new"))
      paRead = cast[typeof(paRead)](pa.symAddr("pa_simple_read"))
      paFree = cast[typeof(paFree)](pa.symAddr("pa_simple_free"))
    let al = loadLib("libasound.so.2")
    if al != nil:
      alsaOpen = cast[typeof(alsaOpen)](al.symAddr("snd_pcm_open"))
      alsaSet = cast[typeof(alsaSet)](al.symAddr("snd_pcm_set_params"))
      alsaRead = cast[typeof(alsaRead)](al.symAddr("snd_pcm_readi"))
      alsaClose = cast[typeof(alsaClose)](al.symAddr("snd_pcm_close"))
      alsaQuiet = cast[typeof(alsaQuiet)](al.symAddr("snd_lib_error_set_handler"))
      # (ALSA's own messages on stderr, when it has no card: not printed)
      if alsaQuiet != nil: discard alsaQuiet(cast[pointer](alsaNoMessage))
    audioLibs = 1

  proc recordLoop(r: ptr Recorder) {.thread.} =
    ## (the recording's own thread: blocks in the sound system's read)
    {.cast(gcsafe).}:
      var buf: array[2048, int16]
      let pa = r.dev
      let pcm = r.dev2
      var err: cint
      while true:
        var stop: bool
        withLock r.lock: stop = r.stopAsked
        if stop: break
        var got = 0
        if pa != nil:
          if paRead(pa, addr buf[0], csize_t(sizeof(buf)), addr err) < 0: break
          got = buf.len
        else:
          let n = alsaRead(pcm, addr buf[0], culong(buf.len div r.channels))
          if n < 0: continue
          got = int(n) * r.channels
        let lv = levelOf(cast[ptr UncheckedArray[int16]](addr buf[0]), got)
        withLock r.lock:
          let at = r.pcm.len
          r.pcm.setLen(at + got * 2)
          copyMem(addr r.pcm[at], addr buf[0], got * 2)
          r.level = lv
      if pa != nil: paFree(pa)
      if pcm != nil: discard alsaClose(pcm)
      withLock r.lock: r.running = false

  proc sysRecordStart(path: string): bool =
    when defined(android):
      # (Termux: the phone's microphone through Termux:API)
      return execShellCmd("termux-microphone-record -f " & quoteShell(path) &
                          " -l 0 >/dev/null 2>&1") == 0
    loadAudio()
    # (the microphone opened here: a recording that cannot start says so)
    var pa, pcm: pointer
    var err: cint
    if paNew != nil and paRead != nil:
      var ss = PaSampleSpec(format: 3, rate: 44100, channels: 1)                          # S16LE
      pa = paNew(nil, "retro", 2, nil, "recording", addr ss, nil, nil, addr err)          # record
    if pa == nil and alsaOpen != nil and alsaSet != nil and alsaRead != nil:
      if alsaOpen(addr pcm, "default", 1, 0) == 0:                                        # capture
        if alsaSet(pcm, 2, 3, 1, 44100, 1, 300_000) != 0:                                 # S16_LE, rw
          discard alsaClose(pcm)
          pcm = nil
      else: pcm = nil
    if pa == nil and pcm == nil: return false
    rec = cast[ptr Recorder](allocShared0(sizeof(Recorder)))
    initLock rec.lock
    rec.path = path
    rec.dev = pa
    rec.dev2 = pcm
    rec.rate = 44100
    rec.channels = 1
    rec.running = true
    rec.started = epochTime()
    createThread(recThread, recordLoop, rec)
    true

  proc sysRecordStop(): int =
    when defined(android):
      discard execShellCmd("termux-microphone-record -q >/dev/null 2>&1")
      return 0
    if rec == nil: return 0
    withLock rec.lock: rec.stopAsked = true
    joinThread(recThread)
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

elif defined(windows):
  include capture_win
elif defined(macosx) or defined(ios):
  include capture_apple
elif androidApp:
  include capture_android
elif defined(wasm):
  include capture_web
else:
  proc sysRecordStart(path: string): bool = false
  proc sysRecordStop(): int = 0
  proc sysRecording(): bool = false
  proc sysLevel(): float = 0
  proc sysCameras(): seq[CameraInfo] = @[]
  proc sysOpen(c: CamState) = c.error = "There is no camera here."
  proc sysTake(c: CamState): bool = false
  proc sysClose(c: CamState) = discard
  proc sysPlace(c: CamState; r: Rect; covered: bool) = discard
  proc sysPhoto(c: CamState; path: string): bool = false

# ---- the camera, the same everywhere ----------------------------------------------------------------

proc cameras*(): seq[CameraInfo] =
  ## The cameras the system has.
  sysCameras()

proc savePicture(b: Bitmap; path: string): bool =
  let ext = path.splitFile.ext.toLowerAscii
  try:
    writeFile(path, if ext == ".png": b.encodePng() else: b.encodeJpeg(quality = 90))
    true
  except IOError, OSError: false

proc camFrame() {.nimcall.} =
  ## After each frame: a camera not drawn in it lets the camera go (its
  ## light goes out); a recording goes on only while it is drawn.
  var gone: seq[string]
  for k, c in cams:
    if c.drawn < ui.frameNo - 1 and c.rec == nil: gone.add k
  for k in gone:
    sysClose(cams[k])
    cams.del k

proc cameraView*(key = ""; camera = ""; facing = cfAny; height = -1; w = 0;
                 mirror = false): CameraEvent {.discardable.} =
  ## The camera's live picture, as large as fits, `height` pixels high (-1:
  ## the room left). `camera`: one of `cameras()` (""): the first, or one
  ## that looks `facing`). `mirror`: shown as in a mirror (a front camera).
  ## The camera is on while the view is drawn, and off once it is not.
  let r = place(if w > 0: w else: 0, if height < 0: remainingH() else: height, fill = w <= 0)
  var c = cams.getOrDefault(key)
  if c == nil or c.camera != camera or c.facing != facing:
    if c != nil: sysClose(c)
    c = CamState(camera: camera, facing: facing)
    cams[key] = c
    sysOpen(c)
  if not camHooked:
    camHooked = true
    endFrameHooks.add camFrame
  c.drawn = ui.frameNo
  if c.error.len == 0 and sysTake(c): c.ready = true
  fill(r, color(0, 0, 0))
  let covered = ui.popup != 0 or (ui.dialogTop != 0 and ui.curDialog != ui.dialogTop)
  sysPlace(c, r, covered)
  if c.frame != nil:
    let f = c.frame
    let s = min(r.w / f.w, r.h / f.h)
    let pw = int(f.w.float * s)
    let ph = int(f.h.float * s)
    let dst = rect(r.x + (r.w - pw) div 2, r.y + (r.h - ph) div 2, pw, ph)
    if mirror:
      var m = newBitmap(f.w, f.h)
      for y in 0 ..< f.h:
        for x in 0 ..< f.w: m.px[y * f.w + x] = f.px[y * f.w + f.w - 1 - x]
      drawBitmap(dst, m)
    else: drawBitmap(dst, f)
    result.width = f.w
    result.height = f.h
  elif c.error.len > 0:
    let line = ellipsize(c.error, r.w - dp(16))
    text(r.x + (r.w - textWidth(line)) div 2, r.y + (r.h - FontH) div 2, line,
         color(255, 255, 255))
  # a photo asked for: the next picture, saved
  if c.photoAsked.len > 0 and c.frame != nil and c.ready:
    if savePicture(c.frame, c.photoAsked): result.photo = c.photoAsked
    c.photoAsked = ""
  elif c.photoAsked.len > 0 and c.error.len > 0:
    if sysPhoto(c, c.photoAsked): result.photo = c.photoAsked
    c.photoAsked = ""
  # a video: each new picture into the writer
  if c.rec != nil and c.frame != nil and c.ready:
    let want = int((epochTime() - c.recStart) * 30)
    while c.recFrames <= want:
      discard c.rec.addFrame(c.frame)
      inc c.recFrames
  result.ready = c.ready
  result.error = c.error
  result.recording = c.rec != nil
  if c.rec != nil: result.recordedMs = int((epochTime() - c.recStart) * 1000)
  if c.saved.len > 0:
    result.saved = c.saved
    c.saved = ""
  if c.error.len == 0: wakeInShown(r, 33)
  ui.lastRect = r

proc cameraPhoto*(key = ""; path: string) =
  ## Saves the camera's next picture to `path` (JPEG; PNG by its
  ## extension); `CameraEvent.photo` says when it is there.
  let c = cams.getOrDefault(key)
  if c != nil: c.photoAsked = path

proc cameraFrame*(key = ""): Bitmap =
  ## The camera's latest picture (nil: none yet), to read it: a barcode,
  ## a face. Not to be changed.
  let c = cams.getOrDefault(key)
  if c != nil: c.frame else: nil

proc cameraRecord*(key = ""; path: string): bool {.discardable.} =
  ## Records the camera into the video `path` (MP4, H.264, 30 pictures a
  ## second, by `retroui/media`'s writer) until `cameraStop`; false when
  ## the camera shows nothing yet or no writer is there.
  let c = cams.getOrDefault(key)
  if c == nil or c.frame == nil or c.rec != nil: return false
  let w = c.frame.w and not 1
  let h = c.frame.h and not 1
  c.rec = beginVideo(path, w, h, fps = 30)
  if c.rec == nil or c.rec.error.len > 0:
    c.rec = nil
    return false
  c.recPath = path
  c.recStart = epochTime()
  c.recFrames = 0
  true

proc cameraStop*(key = "") =
  ## Ends the recording `cameraRecord` started; `CameraEvent.saved` says
  ## when the video is written.
  let c = cams.getOrDefault(key)
  if c == nil or c.rec == nil: return
  if c.rec.finish(): c.saved = c.recPath
  c.rec = nil

proc cameraClose*(key = "") =
  ## Lets the camera go now (it goes by itself once its view is not drawn).
  let c = cams.getOrDefault(key)
  if c == nil: return
  if c.rec != nil: cameraStop(key)
  sysClose(c)
  cams.del key

var soundStarted = false

proc recordSound*(path: string): bool =
  ## Records the microphone into `path` until `stopRecordingSound`: a WAV
  ## file (16-bit, 44.1 kHz, mono) on Linux and Windows; on Android, iOS
  ## and macOS the system's recorder writes it (AAC in an .m4a by its
  ## extension, else WAV). False when there is no microphone (or the user
  ## said no).
  if soundStarted: return false
  soundStarted = sysRecordStart(path)
  soundStarted

proc stopRecordingSound*(): int {.discardable.} =
  ## Ends the recording `recordSound` started and writes it; how long it
  ## is in milliseconds (0: not known, -1: it could not be written).
  if not soundStarted: return 0
  soundStarted = false
  sysRecordStop()

proc recordingSound*(): bool =
  ## The microphone records.
  soundStarted and sysRecording()

proc soundLevel*(): float =
  ## How loud the microphone is now, 0..1 (a meter; 0 when not recording).
  if soundStarted: sysLevel() else: 0.0

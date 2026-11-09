## (included by capture) macOS and iOS: the camera through AVFoundation's
## AVCaptureSession (its pictures as BGRA, handed over by a delegate of the
## kit's own on a queue of the session's), the microphone through
## AVAudioRecorder. Reached through the Objective-C runtime; AVFoundation,
## CoreMedia and CoreVideo are loaded the first time. The app's Info.plist
## needs NSCameraUsageDescription and NSMicrophoneUsageDescription
## (`retroios`, `tools/macapp.sh` write them): the system asks the user
## once.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[dynlib, math]
import native

proc objc_allocateClassPair(super: pointer; name: cstring; extra: int): pointer {.importc, cdecl.}
proc objc_registerClassPair(cls: pointer) {.importc, cdecl.}
proc class_addMethod(cls, name, imp: pointer; types: cstring): bool {.importc, cdecl.}
proc dispatch_queue_create(label: cstring; attr: pointer): pointer {.importc, cdecl.}

type
  AvShared = object
    ## (the session's queue and the app's thread)
    lock: Lock
    px: ptr UncheckedArray[uint32]
    cap: int                     ## pixels px holds
    w, h: int
    fresh: bool
  AvCam = ref object of RootObj
    session, delegate: ObjcId

var
  avCapState = 0
  cmImage: proc (sb: pointer): pointer {.cdecl, gcsafe.}
  cvLockC: proc (b: pointer; flags: uint64): int32 {.cdecl, gcsafe.}
  cvUnlockC: proc (b: pointer; flags: uint64): int32 {.cdecl, gcsafe.}
  cvBaseC: proc (b: pointer): pointer {.cdecl, gcsafe.}
  cvRowC, cvWidthC, cvHeightC: proc (b: pointer): csize_t {.cdecl, gcsafe.}
  cvFormatKeyC: ptr ObjcId
  avShared: ptr AvShared         ## (one camera at a time)

proc avCapture(): bool =
  if avCapState == 0:
    avCapState = -1
    let av = loadLib("/System/Library/Frameworks/AVFoundation.framework/AVFoundation")
    let cm = loadLib("/System/Library/Frameworks/CoreMedia.framework/CoreMedia")
    let cv = loadLib("/System/Library/Frameworks/CoreVideo.framework/CoreVideo")
    if av != nil and cm != nil and cv != nil:
      cmImage = cast[typeof(cmImage)](cm.symAddr("CMSampleBufferGetImageBuffer"))
      cvLockC = cast[typeof(cvLockC)](cv.symAddr("CVPixelBufferLockBaseAddress"))
      cvUnlockC = cast[typeof(cvUnlockC)](cv.symAddr("CVPixelBufferUnlockBaseAddress"))
      cvBaseC = cast[typeof(cvBaseC)](cv.symAddr("CVPixelBufferGetBaseAddress"))
      cvRowC = cast[typeof(cvRowC)](cv.symAddr("CVPixelBufferGetBytesPerRow"))
      cvWidthC = cast[typeof(cvWidthC)](cv.symAddr("CVPixelBufferGetWidth"))
      cvHeightC = cast[typeof(cvHeightC)](cv.symAddr("CVPixelBufferGetHeight"))
      cvFormatKeyC = cast[ptr ObjcId](cv.symAddr("kCVPixelBufferPixelFormatTypeKey"))
      if cmImage != nil and cvLockC != nil and cvBaseC != nil and cvRowC != nil and
         cvWidthC != nil and cvHeightC != nil and cvFormatKeyC != nil and
         objcClass("AVCaptureSession") != nil:
        avCapState = 1
  avCapState == 1

proc onSample(self, cmd, output, sample, connection: pointer) {.cdecl.} =
  ## captureOutput:didOutputSampleBuffer:fromConnection:, on the session's
  ## queue: the picture copied for the app (nothing of Nim's made here).
  let sh = avShared
  if sh == nil or sample == nil: return
  let buf = cmImage(sample)
  if buf == nil or cvLockC(buf, 1) != 0: return
  let w = int(cvWidthC(buf))
  let h = int(cvHeightC(buf))
  let row = int(cvRowC(buf))
  let base = cast[ptr UncheckedArray[uint8]](cvBaseC(buf))
  if base != nil and w > 0 and h > 0 and w <= 8192 and h <= 8192 and row >= w * 4:
    acquire(sh.lock)
    if sh.cap < w * h:
      if sh.px != nil: deallocShared(sh.px)
      sh.px = cast[ptr UncheckedArray[uint32]](allocShared(w * h * 4))
      sh.cap = w * h
    for y in 0 ..< h:
      let src = cast[ptr UncheckedArray[uint32]](addr base[y * row])
      for x in 0 ..< w: sh.px[y * w + x] = src[x] or 0xFF000000'u32
    sh.w = w
    sh.h = h
    sh.fresh = true
    release(sh.lock)
  discard cvUnlockC(buf, 1)

proc videoDevices(): seq[ObjcId] =
  let all = objcSend(ObjcId, objcClass("AVCaptureDevice"), "devicesWithMediaType:", nsString("vide"))
  if all == nil: return
  for i in 0 ..< objcSend(int, all, "count"):
    result.add objcSend(ObjcId, all, "objectAtIndex:", i)

proc facingOf(d: ObjcId): CameraFacing =
  case objcSend(int, d, "position")
  of 1: cfBack
  of 2: cfFront
  else: cfExternal

proc sysCameras(): seq[CameraInfo] =
  if not avCapture(): return
  autoreleasePool:
    for d in videoDevices():
      result.add CameraInfo(id: toNim(objcSend(ObjcId, d, "uniqueID")),
                            name: toNim(objcSend(ObjcId, d, "localizedName")), facing: facingOf(d))

proc sysOpen(c: CamState) =
  if not avCapture():
    c.error = "AVFoundation is not there."
    return
  autoreleasePool:
    var dev: ObjcId
    for d in videoDevices():
      let id = toNim(objcSend(ObjcId, d, "uniqueID"))
      if (c.camera.len > 0 and id == c.camera) or
         (c.camera.len == 0 and (c.facing == cfAny or facingOf(d) == c.facing) and dev == nil):
        dev = d
    if dev == nil:
      c.error = "There is no camera."
      return
    let input = objcSend(ObjcId, objcClass("AVCaptureDeviceInput"), "deviceInputWithDevice:error:",
                         dev, pointer(nil))
    if input == nil:
      c.error = "The camera cannot be used (the user said no, or another app has it)."
      return
    let session = objcSend(ObjcId, objcSend(ObjcId, objcClass("AVCaptureSession"), "alloc"), "init")
    objcSend(void, session, "setSessionPreset:", nsString("AVCaptureSessionPreset640x480"))
    if objcSend(bool, session, "canAddInput:", input): objcSend(void, session, "addInput:", input)
    var cls = objcClass("RetroCameraDelegate")
    if cls == nil:
      cls = objc_allocateClassPair(objcClass("NSObject"), "RetroCameraDelegate", 0)
      discard class_addMethod(cls, sel("captureOutput:didOutputSampleBuffer:fromConnection:"),
                              cast[pointer](onSample), "v@:@^v@")
      objc_registerClassPair(cls)
    let delegate = objcSend(ObjcId, objcSend(ObjcId, cls, "alloc"), "init")
    let output = objcSend(ObjcId, objcSend(ObjcId, objcClass("AVCaptureVideoDataOutput"), "alloc"), "init")
    let fmt = objcSend(ObjcId, objcClass("NSNumber"), "numberWithUnsignedInt:", 0x42475241'u32)  # BGRA
    objcSend(void, output, "setVideoSettings:",
             objcSend(ObjcId, objcClass("NSDictionary"), "dictionaryWithObject:forKey:", fmt, cvFormatKeyC[]))
    objcSend(void, output, "setAlwaysDiscardsLateVideoFrames:", true)
    if avShared == nil:
      avShared = cast[ptr AvShared](allocShared0(sizeof(AvShared)))
      initLock avShared.lock
    objcSend(void, output, "setSampleBufferDelegate:queue:", delegate,
             dispatch_queue_create("org.retro.camera", nil))
    if objcSend(bool, session, "canAddOutput:", output): objcSend(void, session, "addOutput:", output)
    objcSend(void, output, "release")
    objcSend(void, session, "startRunning")
    c.sys = AvCam(session: session, delegate: delegate)

proc sysTake(c: CamState): bool =
  if c.sys == nil or avShared == nil: return false
  withLock avShared.lock:
    if avShared.fresh:
      avShared.fresh = false
      let w = avShared.w
      let h = avShared.h
      if c.frame == nil or c.frame.w != w or c.frame.h != h: c.frame = newBitmap(w, h)
      copyMem(addr c.frame.px[0], avShared.px, w * h * 4)
      c.frame.changed()
      result = true

proc sysClose(c: CamState) =
  if c.sys == nil: return
  let a = AvCam(c.sys)
  autoreleasePool:
    objcSend(void, a.session, "stopRunning")
    objcSend(void, a.session, "release")
  c.sys = nil

proc sysPlace(c: CamState; r: Rect; covered: bool) = discard
proc sysPhoto(c: CamState; path: string): bool = false

# ---- the microphone: AVAudioRecorder -----------------------------------------------------------------

var recorder: ObjcId
var recPathA: string

proc sysRecordStart(path: string): bool =
  if objcClass("AVAudioRecorder") == nil and not avCapture(): return false
  autoreleasePool:
    when defined(ios):
      let s = objcSend(ObjcId, objcClass("AVAudioSession"), "sharedInstance")
      discard objcSend(bool, s, "setCategory:error:", nsString("AVAudioSessionCategoryPlayAndRecord"),
                       pointer(nil))
      discard objcSend(bool, s, "setActive:error:", true, pointer(nil))
    let aac = path.toLowerAscii.endsWith(".m4a") or path.toLowerAscii.endsWith(".aac")
    let d = objcSend(ObjcId, objcClass("NSMutableDictionary"), "dictionary")
    template put(k: string; v: ObjcId) = objcSend(void, d, "setObject:forKey:", v, nsString(k))
    template num(v: int): ObjcId = objcSend(ObjcId, objcClass("NSNumber"), "numberWithInt:", int32(v))
    put("AVFormatIDKey", num(if aac: 0x61616320 else: 0x6c70636d))     # 'aac ', 'lpcm'
    put("AVSampleRateKey", objcSend(ObjcId, objcClass("NSNumber"), "numberWithDouble:", 44100.0))
    put("AVNumberOfChannelsKey", num(1))
    if not aac:
      put("AVLinearPCMBitDepthKey", num(16))
      put("AVLinearPCMIsFloatKey", num(0))
      put("AVLinearPCMIsBigEndianKey", num(0))
    let url = objcSend(ObjcId, objcClass("NSURL"), "fileURLWithPath:", nsString(path.absolutePath))
    let r = objcSend(ObjcId, objcSend(ObjcId, objcClass("AVAudioRecorder"), "alloc"),
                     "initWithURL:settings:error:", url, d, pointer(nil))
    if r == nil: return false
    objcSend(void, r, "setMeteringEnabled:", true)
    if not objcSend(bool, r, "record"):
      objcSend(void, r, "release")
      return false
    recorder = r
    recPathA = path
  recorder != nil

proc sysRecordStop(): int =
  if recorder == nil: return 0
  autoreleasePool:
    result = int(objcSend(float64, recorder, "currentTime") * 1000)
    objcSend(void, recorder, "stop")
    objcSend(void, recorder, "release")
  recorder = nil

proc sysRecording(): bool =
  recorder != nil and objcSend(bool, recorder, "isRecording")

proc sysLevel(): float =
  if recorder == nil: return 0
  objcSend(void, recorder, "updateMeters")
  let db = objcSend(float32, recorder, "averagePowerForChannel:", 0'u)
  clamp(pow(10.0, float(db) / 20), 0.0, 1.0)

## (included by capture) An Android app: the camera through Camera2 and the
## microphone through AudioRecord or MediaRecorder
## (`tools/android/RetroCamera.java`), reached with `systemCall`. The
## camera's pictures come as bytes (8 of size, then RGBA) and the kit draws
## them. The first use asks the user (the APK needs
## `--permission:CAMERA`, `--permission:RECORD_AUDIO`).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

type DroidCam = ref object of RootObj
  asked: float

proc sysCameras(): seq[CameraInfo] =
  for line in systemCall("camera.list", "").splitLines:
    let p = line.split('\t')
    if p.len >= 3:
      result.add CameraInfo(id: p[0], name: p[1],
                            facing: case p[2]
                                    of "front": cfFront
                                    of "back": cfBack
                                    else: cfExternal)

proc sysOpen(c: CamState) =
  let f = case c.facing
          of cfFront: "front"
          of cfBack: "back"
          of cfExternal: "external"
          else: "any"
  let r = systemCall("camera.open", c.camera & "\t" & f)
  c.sys = DroidCam(asked: epochTime())
  if r == "perm": c.error = "The app may use the camera once you allow it."
  elif r != "1": c.error = systemCall("camera.state", "")

proc sysTake(c: CamState): bool =
  if c.sys == nil: return false
  if c.error.len > 0:
    # (allowed meanwhile: opened again, once a second)
    let d = DroidCam(c.sys)
    if epochTime() - d.asked > 1.0:
      c.error = ""
      sysOpen(c)
    return false
  let s = systemCall("camera.frame", "")
  if s.len < 8 or s == "\0":
    let e = systemCall("camera.state", "")
    if e.len > 0 and e != "\0": c.error = e
    return false
  let w = int(uint8(s[0])) or int(uint8(s[1])) shl 8 or int(uint8(s[2])) shl 16
  let h = int(uint8(s[4])) or int(uint8(s[5])) shl 8 or int(uint8(s[6])) shl 16
  if w <= 0 or h <= 0 or s.len < 8 + w * h * 4: return false
  if c.frame == nil or c.frame.w != w or c.frame.h != h: c.frame = newBitmap(w, h)
  copyMem(addr c.frame.px[0], unsafeAddr s[8], w * h * 4)
  c.frame.changed()
  true

proc sysClose(c: CamState) =
  if c.sys != nil: discard systemCall("camera.close", "")
  c.sys = nil

proc sysPlace(c: CamState; r: Rect; covered: bool) = discard
proc sysPhoto(c: CamState; path: string): bool = false

proc sysRecordStart(path: string): bool =
  systemCall("camera.recStart", path) == "1"

proc sysRecordStop(): int =
  try: parseInt(systemCall("camera.recStop", "")) except ValueError: 0

proc sysRecording(): bool = systemCall("camera.recording", "") == "1"

proc sysLevel(): float =
  try: parseFloat(systemCall("camera.recLevel", "")) except ValueError: 0.0

# (the camera and the microphone of a web page: `capture.nim` includes this.
# The browser asks the user the first time; the page must be served over
# https or from localhost)

import uirelays/services

proc rwCameraFrame(id: cint; px: pointer; w, h: cint): cint {.importc: "rw_camera_frame", cdecl.}

type WebCam = ref object of RootObj
  id: cint

proc webJson(s: string): string =
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\0' .. '\x1f': discard
    else: result.add c
  result.add '"'

proc sysCameras(): seq[CameraInfo] =
  for line in systemCall("camera.list", "").splitLines:
    let f = line.split('\t')
    if f.len < 3: continue
    let facing = if f[2] == "back": cfBack elif f[2] == "front": cfFront else: cfAny
    result.add CameraInfo(id: f[0], name: f[1], facing: facing)

proc sysOpen(c: CamState) =
  let facing = case c.facing
    of cfBack: "back"
    of cfFront: "front"
    else: ""
  let id = try: parseInt(systemCall("camera.open", "{\"id\":" & webJson(c.camera) &
                                    ",\"facing\":" & webJson(facing) & "}")) except ValueError: 0
  if id <= 0:
    c.error = "This browser has no camera for the page."
    return
  c.sys = WebCam(id: cint(id))

proc sysTake(c: CamState): bool =
  if c.sys == nil: return false
  let id = WebCam(c.sys).id
  let state = systemCall("camera.state", $id)
  if state == "denied":
    c.error = "The camera was not allowed (the browser asked)."
    return false
  if state.startsWith("error"):
    c.error = "The camera: " & state[min(6, state.len) .. ^1]
    return false
  if state != "ok": return false
  let w = rwCameraFrame(id, nil, 0, 0)
  let h = rwCameraFrame(id, nil, -1, 0)
  if w <= 0 or h <= 0: return false
  if c.frame == nil or c.frame.w != w or c.frame.h != h: c.frame = newBitmap(w, h)
  rwCameraFrame(id, addr c.frame.px[0], w, h) > 0

proc sysClose(c: CamState) =
  if c.sys != nil: discard systemCall("camera.close", $WebCam(c.sys).id)
  c.sys = nil

proc sysPlace(c: CamState; r: Rect; covered: bool) = discard
proc sysPhoto(c: CamState; path: string): bool = false

# ---- the microphone: 16-bit WAV, written to the file when it stops ----

proc sysRecordStart(path: string): bool =
  systemCall("mic.start", absolutePath(path)) == "1"

proc sysRecordStop(): int =
  try: parseInt(systemCall("mic.stop", "")) except ValueError: -1

proc sysRecording(): bool =
  systemCall("mic.state", "") in ["ok", "waiting"]

proc sysLevel(): float =
  try: parseFloat(systemCall("mic.level", "")) except ValueError: 0.0

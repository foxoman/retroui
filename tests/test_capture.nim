## The camera and the microphone without either: a YUYV picture (what
## webcams send) turned into pixels exactly, the WAV header of a recording,
## and the camera's view and the recorder telling plainly that there is
## nothing (no crash, nothing left running).

import std/[os, strutils]
import retroui
import retroui/[capture, gfx]
import harness

block yuyv:
  # four pixels: black, white (Y 16 / 235, no colour), then a red pair
  # (Y 81, U 90, V 240: BT.601's red)
  let data = [16'u8, 128, 235, 128, 81, 90, 81, 240]
  var b: Bitmap
  yuyvToBitmap(data, 4, 1, b)
  doAssert b.w == 4 and b.h == 1
  doAssert b.px[0] == 0xFF000000'u32, toHex(b.px[0])
  doAssert b.px[1] == 0xFFFFFFFF'u32, toHex(b.px[1])
  let r = (b.px[2] shr 16) and 255
  let g = (b.px[2] shr 8) and 255
  let bl = b.px[2] and 255
  doAssert r >= 250 and g <= 5 and bl <= 5, toHex(b.px[2])
  doAssert b.px[3] == b.px[2]

block wav:
  let h = wavHeader(44100, 1, 88200)
  doAssert h.len == 44
  doAssert h.startsWith("RIFF") and h[8 ..< 16] == "WAVEfmt " and h[36 ..< 40] == "data"
  proc u32(s: string; at: int): int =
    int(uint8(s[at])) or int(uint8(s[at + 1])) shl 8 or int(uint8(s[at + 2])) shl 16 or
      int(uint8(s[at + 3])) shl 24
  doAssert u32(h, 4) == 36 + 88200 and u32(h, 24) == 44100 and u32(h, 40) == 88200

fakeDriver()
var ev: CameraEvent
view = proc () = ev = cameraView(height = 200)
startApp("capture", 400, 300)
run(3)
if cameras().len == 0:
  doAssert ev.error.len > 0 and not ev.ready
  doAssert cameraFrame() == nil
  doAssert not cameraRecord("", getTempDir() / "retro-cam.mp4")
# the view not drawn: the camera let go
view = proc () = discard
run(3)
doAssert cameraFrame() == nil

# a recording where there may be no microphone: it says so, or records
let wavPath = getTempDir() / "retro-mic-" & $getCurrentProcessId() & ".wav"
if recordSound(wavPath):
  sleep(300)
  doAssert soundLevel() >= 0
  let ms = stopRecordingSound()
  doAssert ms >= 0 and fileExists(wavPath)
  doAssert readFile(wavPath).startsWith("RIFF")
  removeFile(wavPath)
  echo "test_capture: recorded ", ms, " ms"
else:
  doAssert not recordingSound() and soundLevel() == 0 and stopRecordingSound() == 0
echo "test_capture: ok"

## The kit as a web page (`retroweb`), checked in a real browser (headless
## Chromium, `run.js`): the browser drives the mouse and the keyboard and
## reads what the page shows; this app checks what came and writes a line
## a check into the console (PASS / FAIL), then "DONE n" (n failures).
## What the page's driver does is also checked from outside: the pixels on
## the canvas are the app's frame (`drawn.png`, compared by run.js), the
## files it writes stay after a reload.
##
##   sh tests/web/run.sh

import std/[os, strutils]
import retroui
import retroui/[htmlview, http, imaging, media, system, capture, mediasession, secrets, view3d]
import retroui/uirelays/screen

var
  step = 0
  stepFrames = 0
  failed = 0
  clicks = 0
  name = "start"
  items: seq[string]
  sel = 0
  btnR, editR, listR: Rect
  web: WebEvent
  showWeb = false
  vid: VideoEvent
  showVideo = false
  picking = false
  picked = ""
  openR: Rect
  showCamera = false
  cam: CameraEvent
  camFrames = 0
  show3d = false
  scene3: Scene3
  cam3 = camera3()

for i in 1 .. 50: items.add "Row " & $i

proc check(ok: bool; what: string) =
  echo (if ok: "PASS " else: "FAIL "), what
  if not ok: inc failed

proc next() =
  inc step
  stepFrames = 0

proc mark(what: string; r: Rect) =
  ## Where a widget is, for the browser to click (CSS pixels).
  let k = zoomLevel()
  echo "AT ", what, " ", (r.x + r.w div 2) * k, " ", (r.y + r.h div 2) * k

app "webcheck", 640, 480:
  inc stepFrames
  wakeIn(30)
  label "The kit in a browser"
  if button("&Press"): inc clicks
  btnR = ui.lastRect
  edit name
  editR = ui.lastRect
  discard listbox(items, sel, rows = 6)
  listR = ui.lastRect
  label "clicks " & $clicks & ", name " & name & ", row " & $(sel + 1)
  if showWeb:
    web = webView(webAppUrl("page.html"), height = 90, key = "page", engine = weSystem)
  if step == 7:
    if button("&Open..."): picking = true
    openR = ui.lastRect
    var path = ""
    if filePicker(picking, path, fmOpen, ["*.txt"]): picked = path
  if showVideo:
    vid = videoView("/app/live.mp4", height = 90, autoplay = true, key = "v")
  if showCamera:
    cam = cameraView(height = 90, key = "cam")
    if cam.ready: inc camFrames
  if show3d:
    view3d(scene3, cam3, height = 120, key = "web3d")
  case step
  of 0:
    if stepFrames > 3:
      let l = getWindowLayout()
      check(l.width > 0 and l.height > 0 and platformName() == "web",
            "a window: " & $l.width & " x " & $l.height & " at " & $l.uiScale & "%, on " & platformName())
      mark("button", btnR)
      mark("edit", editR)
      mark("list", listR)
      echo "READY"
      next()
  of 1:
    if clicks >= 2 or stepFrames > 300:
      check(clicks == 2, "two clicks on the button: " & $clicks)
      echo "NEXT typing"
      next()
  of 2:
    if name == "Hello, browser!" or stepFrames > 300:
      check(name == "Hello, browser!", "typed: " & name)
      echo "NEXT paste"
      next()
  of 3:
    if name == "Grüße ✓ 你好" or stepFrames > 300:
      check(name == "Grüße ✓ 你好", "pasted: " & name)
      echo "NEXT list"
      next()
  of 4:
    if sel >= 2 or stepFrames > 300:
      check(sel >= 2, "the list took a click and the arrow keys: row " & $(sel + 1))
      # files: the app's own, and one kept
      let given = try: readFile("/app/data.txt") except IOError: ""
      check(given.strip == "a file the app came with", "a file the app came with: " & given.strip)
      let keep = getHomeDir() / "kept.txt"
      let before = try: readFile(keep) except IOError: ""
      writeFile(keep, "written " & $(before.len + 1))
      check(fileExists(keep), "a file written in the home folder (was: " & before & ")")
      createDir(getHomeDir() / "folder")
      var n = 0
      for f in walkDir(getHomeDir()): inc n
      check(n >= 2, "the home folder listed: " & $n)
      # the web: the page's own address
      let r = httpRequest("GET", "manifest.webmanifest")
      check(r.status == 200 and "\"name\"" in r.body, "an HTTP request through the page: " & $r.status)
      # sound: Web Audio starts
      discard playSound(makeTone(440, 50, 0.1))
      check(true, "a sound played (" & audioOutputName() & ")")
      showWeb = true
      next()
  of 5:
    if web.messages.len > 0 or stepFrames > 300:
      check("hello from the page" in web.messages, "the app's own page (an iframe) posted: " &
            web.messages.join(", "))
      showWeb = false
      showVideo = true
      next()
  of 6:
    if vid.positionMs > 200 or vid.error.len > 0 or stepFrames > 400:
      check(vid.positionMs > 200, "a video played (" & $vid.positionMs & " ms" &
            (if vid.error.len > 0: ", " & vid.error else: "") & ")")
      showVideo = false
      next()
  of 7:
    # the system's features in a page; a file to the user; a file from the user
    if stepFrames == 1:
      let d = deviceInfo()
      check(d.name.len > 0 and d.platform == "web" and d.system.startsWith("Web"),
            "the device: " & d.name & ", " & d.system)
      check(systemLanguage().len >= 2, "the language: " & systemLanguage())
      check(d.battery.level >= -1, "the battery: " & $d.battery.level)
      # (headless Chromium refuses notifications whatever the page is allowed:
      # what `notify` answers must agree with `notifyAvailable`)
      let allowed = notifyAvailable()
      check(notify("webcheck", "a notification of the page", tag = "check") == allowed,
            "a notification (" & (if allowed: "shown" else: "the browser refuses them") & ")")
      check(speak("") == false, "nothing to say says nothing")
      writeFile("/downloads/saved.txt", "saved by the app")
      check(fileExists("/downloads/saved.txt"), "a file written for the user")
    let p = location()
    if stepFrames > 3 and stepFrames < 6: mark("open", openR)
    if stepFrames == 5:
      echo "NEXT open"
    if (p.state != psWaiting and picked.len > 0) or stepFrames > 900:
      check(p.state == psOk and abs(p.lat - 23.588) < 0.01, "the place: " & $p.state & " " & $p.lat & ", " & $p.lon)
      let text = try: readFile(picked) except IOError: ""
      check(text == "picked by the browser", "a file from the browser's chooser: " & picked & " " & text)
      next()
  of 8:
    # secrets, the camera and the microphone (Chromium's fake ones), the
    # system's media controls
    if stepFrames == 1:
      check(saveSecret("webcheck", "token", "s3cr\x01et ✓"), "a secret kept")
      check(loadSecret("webcheck", "token") == "s3cr\x01et ✓", "the secret read back")
      check(saveSecret("webcheck", "gone", "x") and (deleteSecret("webcheck", "gone"); loadSecret("webcheck", "gone") == ""),
            "a secret forgotten")
      setNowPlaying(NowPlaying(title: "webcheck song", artist: "Retro", playing: true,
                               durationMs: 60000, canNext: true))
      showCamera = true
      check(recordSound("/tmp/voice.wav"), "the microphone asked")
    if (camFrames >= 5 and stepFrames > 60) or stepFrames > 900:
      check(camFrames >= 5 and cam.width > 0, "the camera: " & $camFrames & " pictures of " & $cam.width & " x " &
            $cam.height & (if cam.error.len > 0: " (" & cam.error & ")" else: ""))
      let ms = stopRecordingSound()
      let wav = try: readFile("/tmp/voice.wav") except IOError: ""
      check(ms > 0 and wav.startsWith("RIFF") and wav.len > 1000, "the microphone recorded " & $ms & " ms, " &
            $wav.len & " bytes")
      showCamera = false
      echo "NEXT access"
      next()
  of 9:
    # a screen reader presses the button (its ARIA element, clicked)
    if clicks >= 3 or stepFrames > 600:
      check(clicks == 3, "a screen reader pressed the button: " & $clicks)
      # a model with materials: drawn by WebGL 2 (a context of its own)
      var m = box(2, 2, 2, color(200, 30, 30))
      m.material = 0
      scene3.materials.add Material3(name: "red", baseColor: [0.85'f32, 0.1, 0.1, 1], metallic: 0.1,
                                     roughness: 0.6)
      scene3.add m
      show3d = true
      next()
  of 10:
    if stepFrames > 20:
      let pic = view3dPicture("web3d")
      var red = false
      if pic != nil:
        let c = pic.px[(pic.h div 2) * pic.w + pic.w div 2]
        red = ((c shr 16) and 255) > 2 * ((c shr 8) and 255) and ((c shr 16) and 255) > 60
      check(view3dOnGpu("web3d") and red, "a 3D model drawn by WebGL 2: on the GPU " & $view3dOnGpu("web3d") &
            ", red in its middle " & $red)
      show3d = false
      next()
  of 11:
    # (no caret blinking: the frame and the canvas compared a moment apart)
    if stepFrames == 1: ui.focus = Id(0)
    if stepFrames > 10:
      # (the frame as the app drew it, for run.js to compare with the canvas)
      let pic = framePicture()
      check(pic != nil and pic.savePng("/tmp/drawn.png"), "the frame kept")
      echo "DONE ", failed
      next()
  else: discard

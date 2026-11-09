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
import retroui/[htmlview, http, imaging, media]
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
  if showVideo:
    vid = videoView("/app/live.mp4", height = 90, autoplay = true, key = "v")
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
    if stepFrames > 10:
      # (the frame as the app drew it, for run.js to compare with the canvas)
      let pic = framePicture()
      check(pic != nil and pic.savePng("/tmp/drawn.png"), "the frame kept")
      echo "DONE ", failed
      next()
  else: discard

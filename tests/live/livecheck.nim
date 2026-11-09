## The kit on a real system, with its own driver -- what the headless tests
## cannot see: a window opens, frames reach it, the pages of the guide are
## drawn as on every other system, menus and dialogs open, and the system's
## browser engine shows a page and talks to the app.
##
## It goes through its pages by itself, saves each frame it drew
## (`framePicture`) as `NAME.png` and writes `results.txt` -- a line per
## check, PASS, FAIL or SKIP -- into $RETRO_LIVE_OUT (else the app's data
## folder: on Android and iOS, where CI fetches it), then ends: 0 when
## nothing failed. `tools/live/compare.nim` compares the pictures with
## `tests/live/ref` (made on Linux: the kit draws the same pixels
## everywhere).
##
##   nim c -r -d:release tests/live/livecheck.nim       (a desktop)
##   retroapk tests/live/livecheck.nim --debuggable --install --run
##
## $RETRO_LIVE_WEB=need makes a missing browser engine a failure (CI
## installs one everywhere), $RETRO_LIVE_VIDEO_NEED=1 a missing video
## player; $RETRO_LIVE_ONLY=web,grid only those pages; $RETRO_LIVE_VIDEO the
## video it plays (tests/data/media/live.mp4).

import std/[os, strutils, times]
import retroui
import retroui/[htmlview, imaging, charts, media]

const WebPage = """<!doctype html><html><head><meta charset="utf-8">
<title>Live check</title></head><body style="font-family:sans-serif">
<h2 id="h">Live check</h2><p id="said">nothing yet</p>
<script>
window.addEventListener("retro", function (e) {
  document.getElementById("said").textContent = e.detail;
  retro.post("pong:" + e.detail);
});
retro.post("ready");
</script></body></html>"""

type Page = enum pgControls, pgGrid, pgChart, pgHtml, pgMenu, pgDialog, pgWeb, pgVideo, pgDone

var
  outDir = getEnv("RETRO_LIVE_OUT")
  results: seq[string]
  failed = 0
  page = pgControls
  pageFrames = 0
  pageStart = 0.0
  only: seq[string]
  # the controls page's state
  name = "Retro Nim UI"
  agree = true
  size = 1
  level = 60
  pick = 2
  # the grid's
  cols = @[Column(title: "Name", width: 140), Column(title: "City", width: 110),
           Column(title: "Salary", width: 90)]
  sel = 1
  menuShown: MenuShown
  menuOn = false
  dlgOpen = false
  # the web page's
  webAsk = -1
  webReady, webRunOk, webRound, webNative = false
  webSent = false
  webNote = ""
  # the video's
  videoFile = getEnv("RETRO_LIVE_VIDEO", "tests/data/media/live.mp4")
  videoMaxPos = 0

proc cellOf(row, col: int): string =
  const people = [["Salim", "Nizwa", "1,200.000"], ["Maryam", "Sohar", "1,350.500"],
                  ["Aisha", "Sur", "980.250"], ["Ahmed", "Muscat", "2,100.000"]]
  people[row][col]

proc note(kind, what: string; why = "") =
  let line = kind & " " & what & (if why.len > 0: ": " & why else: "")
  results.add line
  echo "livecheck: ", line
  if kind == "FAIL": inc failed

proc save(what: string) =
  let pic = framePicture()
  if pic == nil:
    note("SKIP", what & ".png", "the GPU draws (RETRO_GPU=cpu for pictures)")
    return
  if pic.savePng(outDir / what & ".png"):
    note("PASS", what & ".png", $pic.w & "x" & $pic.h)
  else:
    note("FAIL", what & ".png", "not written")

proc wanted(p: Page): bool =
  only.len == 0 or ($p)[2 .. ^1].toLowerAscii in only

proc next() =
  inc page
  while page < pgDone and not wanted(page): inc page
  pageFrames = 0
  pageStart = epochTime()

proc finish() =
  try: writeFile(outDir / "results.txt", results.join("\n") & "\n")
  except IOError: echo "livecheck: results.txt not written"
  echo "livecheck: ", (if failed == 0: "all passed" else: $failed & " failed")
  quitApp()

if outDir.len == 0: outDir = dataDir("livecheck")
createDir(outDir)
for o in getEnv("RETRO_LIVE_ONLY").split(','):
  if o.strip.len > 0: only.add o.strip.toLowerAscii
writeFile(outDir / "page.html", WebPage)
webAppFolder(outDir)
if not wanted(page): next()
pageStart = epochTime()

app "Live check", 800, 600:
  inc pageFrames
  # (gray text on every system, as the reference pictures: not the
  #  system's sharp text where it is the default)
  if ui.frameNo <= 1:
    setSubpixelText(false)
    # (the CPU draws, so the frames can be saved -- on phones too, where
    #  no environment says so)
    setGpuMode(gmCpu)
  let shown = epochTime() - pageStart
  # (a page is pictured after it settled: 12 frames and a third of a second)
  let settled = pageFrames >= 12 and shown >= 0.35
  # (a menu opened as if clicked: before the menu bar that draws it)
  if page == pgMenu and not menuOn:
    menuShown = showMenu(["&File"])
    menuOn = true
  menubar:
    menu "&File":
      discard menuItem("&New", "Ctrl+N")
      discard menuItem("&Open...", "Ctrl+O")
      menuSeparator()
      discard menuItem("E&xit")
    menu "&Help":
      discard menuItem("&About")
  case page
  of pgControls, pgMenu, pgDialog:
    group "Buttons":
      row:
        discard button("OK", isDefault = true)
        discard button("Cancel")
        discard button("Disabled", enabled = false)
    group "Text and choices":
      row([90, -1]):
        label "&Name:"
        discard edit(name)
      checkbox("&Agree to the terms", agree)
      row:
        radio("&Small", size, 0)
        radio("&Medium", size, 1)
        radio("&Large", size, 2)
      row([90, -1]):
        label "Level:"
        discard slider(level, 0, 100)
      progress(level / 100)
      discard listbox(["Muscat", "Sohar", "Nizwa", "Sur", "Salalah"], pick, rows = 4)
    if page == pgDialog: dlgOpen = true
    dialog(dlgOpen, "A dialog", 320):
      label "Dialogs are drawn by the kit, over the window."
      row:
        spring()
        discard button("Close", isDefault = true)
    if settled:
      save(($page)[2 .. ^1].toLowerAscii)
      if page == pgMenu:
        hideMenu(menuShown)
        menuOn = false
      if page == pgDialog: dlgOpen = false
      next()
  of pgGrid:
    discard grid(cols, 4, cellOf, sel, height = 8)
    if settled:
      save("grid")
      next()
  of pgChart:
    barChart([12.0, 19.0, 7.0, 15.0, 22.0], ["Jan", "Feb", "Mar", "Apr", "May"],
             h = 300)
    if settled:
      save("chart")
      next()
  of pgHtml:
    discard htmlView("<h2>Sales <u>report</u></h2><p>Up <b>12%</b>, costs " &
                     "<span style=\"color:#c00\">down</span>.</p>" &
                     "<table><tr><th>Month</th><th align=right>Sales</th></tr>" &
                     "<tr><td>August</td><td align=right>1,020</td></tr></table>" &
                     "<ul><li>North<li>South</ul>", height = 300)
    if settled:
      save("html")
      next()
  of pgWeb:
    # (the page at the app's own address: its folder served by the engine)
    let ev = webView(webAppUrl("page.html"), key = "live", engine = weSystem, height = 300)
    webNative = ev.native
    for m in ev.messages:
      if m == "ready": webReady = true
      elif m == "pong:hello": webRound = true
    if webReady and webAsk < 0: webAsk = webRun("live", "1+2")
    if webReady and not webSent:
      webPost("live", "hello")
      webSent = true
    for r in ev.results:
      if r.id == webAsk:
        webRunOk = r.value == "3"
        if not webRunOk: webNote = "webRun gave " & r.value & r.error
    label "Engine: " & (if ev.native: "the system's" else: "the kit's") &
          "  Title: " & ev.title
    let done = webReady and webRunOk and webRound
    if not webNative and pageFrames >= 5:
      let kind = if getEnv("RETRO_LIVE_WEB") == "need": "FAIL" else: "SKIP"
      note(kind, "web", "no browser engine of the system's")
      next()
    elif done or shown > 25.0:
      note(if webReady: "PASS" else: "FAIL", "web page loaded", ev.url)
      note(if webRunOk: "PASS" else: "FAIL", "webRun", webNote)
      note(if webRound: "PASS" else: "FAIL", "webPost and retro.post")
      save("web")
      webClose("live")
      next()
  of pgVideo:
    if not fileExists(videoFile):
      note("SKIP", "video", "no " & videoFile & " here")
      next()
    elif not videoPlaysInWindow():
      note(if getEnv("RETRO_LIVE_VIDEO_NEED") == "1": "FAIL" else: "SKIP", "video",
           "no player of the system's here")
      next()
    else:
      let v = videoView(videoFile, height = 300, autoplay = true, key = "live")
      videoMaxPos = max(videoMaxPos, v.positionMs)
      label "Video: " & $v.positionMs & " of " & $v.durationMs & " ms " & v.error
      if v.error.len > 0 or videoMaxPos >= 800 or shown > 12.0:
        note(if videoMaxPos >= 800 and v.error.len == 0: "PASS" else: "FAIL", "video plays",
             $videoMaxPos & " ms of " & $v.durationMs & (if v.error.len > 0: ": " & v.error else: ""))
        note(if v.durationMs in 1500 .. 2500: "PASS" else: "FAIL", "video length",
             $v.durationMs & " ms (2000)")
        save("video")
        closeVideo("live")
        next()
  of pgDone:
    finish()
  wakeIn(30)

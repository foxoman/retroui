## Tests of vector art from words (retroui/aivector): what the service is told, the SVG found in
## an answer's words and kept to shapes -- no scripts, pictures, links, events or styles from
## elsewhere --, placed as shape layers; asked of the test's own service (tests/aimock.py).

import std/[os, osproc, strutils, streams, exitprocs]
import retroui, retroui/[aichat, aivector, photo, svgimport, jobs, inspect]
import retroui/uirelays/access
import harness

fakeDriver()
startApp("Vector", W, H)

# ---- what the service is told ----
let sys = vectorSystem(vkIcon, [0xFF1E3A2A'u32, 0xFF9AB43A'u32])
doAssert "<svg" in sys and "viewBox=\"0 0 512 512\"" in sys and "icon" in sys
doAssert "#1e3a2a" in sys and "#9ab43a" in sys, "its colors as #rrggbb"
doAssert "seamless" in vectorSystem(vkPattern) and "background" in vectorSystem(vkScene)

# ---- the SVG in an answer, kept to shapes ----
let answer = """Here is your palm:
```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" onload="alert(1)">
  <script>alert(2)</script>
  <style>@import url(http://evil.example/x.css);</style>
  <image href="http://evil.example/track.png" x="0" y="0" width="10" height="10"/>
  <a href="javascript:alert(3)"><rect x="1" y="1" width="5" height="5"/></a>
  <defs><linearGradient id="g"><stop offset="0" stop-color="#9ab43a"/><stop offset="1" stop-color="#4a6a1a"/></linearGradient></defs>
  <rect x="0" y="0" width="512" height="512" fill="#1e3a2a"/>
  <path d="M256 480 L240 260 L272 260 Z" fill="url(#g)" onclick="alert(4)"/>
  <circle cx="256" cy="200" r="90" fill="url(http://evil.example/p.svg#x)" stroke="#203020"/>
  <text x="10" y="20">words</text>
</svg>
```
Enjoy!"""
let svg = svgOfAnswer(answer)
doAssert svg.len > 0
for bad in ["script", "alert", "style", "evil", "image", "onload", "onclick", "javascript", "<a", "<text"]:
  doAssert bad notin svg, bad & " kept: " & svg
doAssert "<path" in svg and "<circle" in svg and "url(#g)" in svg and "linearGradient" in svg
doAssert "stroke=\"#203020\"" in svg and "fill=\"url(http" notin svg, "a paint from elsewhere left out"
doAssert svgOfAnswer("Sorry, I can't draw that.") == ""
doAssert svgOfAnswer("<svg xmlns=\"http://www.w3.org/2000/svg\"><text>only words</text></svg>") == "",
  "no shapes: nothing"
doAssert safeSvg("<html><svg/></html>") == "" and safeSvg("not xml at all <") == ""

# ---- placed as shapes ----
let d = newDoc(800, 800, 0xFFFFFFFF'u32)
let before = d.layers.len
let made = d.placeSvg(svg, rect(100, 100, 600, 600))
doAssert made.len >= 3 and d.layers.len > before
var shapes = 0
for L in made:
  if L.isShape: inc shapes
doAssert shapes >= 3, "its rectangle, path and circle are shapes: " & $shapes

# ---- asked of a service (the test's own: it says back what it is sent) ----
let python = if findExe("python3").len > 0: "python3" else: "python"
let mock = startProcess(python, args = [currentSourcePath().parentDir / "aimock.py"], options = {poUsePath})
proc stopAtExit(p: Process) =
  addExitProc(proc () = p.terminate())
stopAtExit(mock)
let port = mock.outputStream.readLine.strip
let s = AiSettings(kind: akOpenAi, url: "http://127.0.0.1:" & port & "/v1/chat/completions", model: "mock",
                   key: "sk-test")
proc waitFor[T](j: Job[T]) =
  for i in 0 ..< 600:
    if j.ended: return
    sleep(20)
let j = askVector(s, "<svg viewBox=\"0 0 10 10\"><rect width=\"10\" height=\"10\" fill=\"#ff0000\" " &
                     "onmouseover=\"x()\"/></svg>", vkSubject)
waitFor(j)
let (got, err) = vectorAnswer(s, j)
doAssert err == "" and "<rect" in got and "onmouseover" notin got, err & " " & got
let j2 = askVector(s, "a palm, please", vkScene)
waitFor(j2)
let (none, why) = vectorAnswer(s, j2)
doAssert none == "" and "no drawing" in why, why
# ---- the dialog: the words asked, the answer handed back between frames ----
block theDialog:
  let ask = newVectorAsk(vkIcon)
  ask.words = "<svg viewBox=\"0 0 8 8\"><circle cx=\"4\" cy=\"4\" r=\"3\" fill=\"#00aa00\"/></svg>"
  ask.open = true
  var got, why, said: string
  var answered = false
  view = proc () =
    vectorDialog(ask, s, proc (svg, error, words: string) =
      got = svg
      why = error
      said = words
      answered = true, colors = [0xFF000000'u32, 0xFFFFFFFF'u32])
  accessKeep = true                     # (the frame's controls kept, to find by name)
  run(3)
  let gen = findNode(accessTree, "Generate", {arButton})
  doAssert gen >= 0, "its Generate button"
  click(nodeRect(accessTree[gen]))
  for i in 0 ..< 300:
    run(1)
    if answered: break
    sleep(20)
  doAssert answered and not ask.open and not ask.busy
  doAssert "<circle" in got and why == "" and said == ask.words.strip, got & why

echo "aivector ok"

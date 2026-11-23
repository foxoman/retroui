## Tests of the downloader (retroui/fetch, on a local file) and of reading
## Google Fonts' CSS (retroui/googlefonts) -- the network itself is not used.

import std/[os, strutils, times]
import retroui/[fetch, googlefonts, textengine, busy]

let css = """
@font-face {
  font-family: 'Cairo';
  font-style: normal;
  font-weight: 400;
  src: url(https://fonts.gstatic.com/s/cairo/v28/SLXgc1nY6HkvangtZmpQdkhzfH5lkSs2SgRjCAGMQ1z0hOA-W1Q.ttf) format('truetype');
}
@font-face {
  font-family: 'Cairo';
  font-style: normal;
  font-weight: 700;
  src: url(https://fonts.gstatic.com/s/cairo/v28/bold.ttf) format('truetype');
}
"""
let faces = fontFaces(css)
doAssert faces.len == 2 and faces[1].weight == "700" and faces[0].url.endsWith(".ttf")
doAssert googleFontList.len > 100
var arabic = 0
for f in googleFontList:
  if f.arabic: inc arabic
doAssert arabic >= 25
# every family of Google Fonts: the Arabic ones first (those picked, then the rest), each once
let all = googleFontCatalog()
doAssert all.len > 1800
var names: seq[string]
for f in all:
  doAssert f.family notin names, f.family & " twice"
  names.add f.family
doAssert all[0].family == "Cairo" and all[0].arabic
var firstOther = -1
for i, f in all:
  if not f.arabic:
    firstOther = i
    break
doAssert firstOther >= 50
for f in all[firstOther .. ^1]: doAssert not f.arabic or f.family in ["Rubik"], f.family
for fam in ["Kufam", "Vazirmatn", "Reem Kufi Fun", "Qahiri"]:
  let i = names.find(fam)
  doAssert i >= 0 and i < firstOther and all[i].arabic, fam
doAssert all[names.find("Roboto")].category == "Sans Serif" and all[names.find("ABeeZee")].category == "Sans Serif"
doAssert all[names.find("Lobster")].category == "Display"

let dir = getTempDir() / "retro-fetch-test"
removeDir(dir)
createDir(dir)
writeFile(dir / "src.bin", "hello fonts")
if findExe("curl").len > 0:
  let err = downloadFile("file://" & dir / "src.bin", dir / "sub" / "got.bin")
  doAssert err == "", err
  doAssert readFile(dir / "sub" / "got.bin") == "hello fonts"
  doAssert downloadFile("file://" & dir / "missing.bin", dir / "x.bin").len > 0, "a failure says so"
  doAssert not fileExists(dir / "x.bin") and not fileExists(dir / "x.bin.part")
when defined(posix):
  block aDownloadKeepsTheWindowAlive:
    # on the thread that draws, a download that takes long keeps the busy box ticking (the
    # window drawn, its events read -- Retro Atelier's Browse Assets did not answer for its
    # whole download), and the box's Cancel ends it: a "curl" here that takes 30 s
    let bin = dir / "slowbin"
    createDir(bin)
    writeFile(bin / "curl", "#!/bin/sh\nsleep 30\n")
    setFilePermissions(bin / "curl", {fpUserRead, fpUserWrite, fpUserExec})
    let path = getEnv("PATH")
    putEnv("PATH", bin & ":" & path)
    markUiThread()
    var ticks {.global.} = 0
    busyHook = proc () {.nimcall.} =
      inc ticks
      if ticks == 10: busyCancelAsked = true    # (Cancel pressed)
    let t0 = epochTime()
    beginBusy("Getting it", cancel = true)
    let err = downloadFile("https://example.com/big.bin", dir / "slow" / "big.bin")
    endBusy(cancel = true)
    putEnv("PATH", path)
    busyHook = nil
    doAssert err == "cancelled", err
    doAssert ticks >= 10 and epochTime() - t0 < 10, $(ticks, epochTime() - t0)
    doAssert not fileExists(dir / "slow" / "big.bin") and not fileExists(dir / "slow" / "big.bin.part")
doAssert not isInstalled(dir, "Cairo")
createDir(familyDir(dir, "Noto Kufi Arabic"))
writeFile(familyDir(dir, "Noto Kufi Arabic") / "NotoKufiArabic-Regular.ttf", "x")
doAssert isInstalled(dir, "Noto Kufi Arabic")
# ---- a family from Google's repository, checked (a local copy of it) -------------------------

block fromTheRepository:
  let dejavu = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
  let dejavuBold = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
  let latinOnly = "/usr/share/fonts/truetype/google-fonts/Poppins-Regular.ttf"
  if fileExists(dejavu) and fileExists(dejavuBold) and fileExists(latinOnly) and findExe("curl").len > 0:
    let repo = dir / "repo"
    let fonts = dir / "Fonts"
    createDir(repo / "ofl")
    createDir(repo / "files")
    copyFile(dejavu, repo / "files" / "Kufiya-Regular.ttf")
    copyFile(dejavuBold, repo / "files" / "Kufiya-Bold.ttf")
    copyFile(latinOnly, repo / "files" / "Latinish-Regular.ttf")
    writeFile(repo / "files" / "Webby-Regular.ttf", "wOF2" & repeat('\0', 64))
    proc entry(name, kind, url: string): string =
      "{\"name\": \"" & name & "\", \"type\": \"" & kind & "\", \"download_url\": \"" & url &
        "\", \"url\": \"" & url & "\"}"
    let u = "file://" & repo / "files" & "/"
    # a family with static styles in "static" (taken), a variable file at the top (left)
    writeFile(repo / "ofl" / "kufiya", "[" & entry("Kufiya[wght].ttf", "file", u & "Kufiya-Regular.ttf") & ", " &
              entry("static", "dir", "file://" & repo / "ofl" / "kufiya-static") & "]")
    writeFile(repo / "ofl" / "kufiya-static", "[" & entry("Kufiya-Regular.ttf", "file", u & "Kufiya-Regular.ttf") &
              ", " & entry("Kufiya-Bold.ttf", "file", u & "Kufiya-Bold.ttf") & ", " &
              entry("Kufiya-Thin.ttf", "file", u & "Kufiya-Regular.ttf") & "]")
    # (a copy of the folder's listing at the path GitHub's API gives it as)
    let base = "file://" & repo & "/"
    # (how far it is, told as it goes; asked to stop, nothing of it kept)
    var steps: seq[string]
    let stopNow = installGoogleFont("Kufiya", fonts, needArabic = true, github = base,
                                    hooks = FontFetchHooks(stop: proc (): bool = true))
    doAssert stopNow == (0, "stopped") and not dirExists(familyDir(fonts, "Kufiya")), $stopNow
    var calls = 0
    proc told(step, of0: int; what: string) {.gcsafe.} =
      {.cast(gcsafe).}:
        steps.add what
        doAssert step <= of0
    proc asked(): bool {.gcsafe.} =
      {.cast(gcsafe).}: inc calls
      false
    let r = installGoogleFont("Kufiya", fonts, needArabic = true, github = base,
                              hooks = FontFetchHooks(progress: told, stop: asked))
    doAssert r.error == "" and r.files == 2, $r
    doAssert "Kufiya-Regular.ttf" in steps and "Kufiya-Bold.ttf" in steps and calls >= 3, $steps
    doAssert fileExists(familyDir(fonts, "Kufiya") / "Kufiya-Regular.ttf")
    doAssert fileExists(familyDir(fonts, "Kufiya") / "Kufiya-Bold.ttf")
    doAssert fontCheck(familyDir(fonts, "Kufiya") / "Kufiya-Regular.ttf", needArabic = true) == ""
    # a Latin-only file for an Arabic family: taken out, and said why
    writeFile(repo / "ofl" / "latinish", "[" & entry("Latinish-Regular.ttf", "file", u & "Latinish-Regular.ttf") & "]")
    let r2 = installGoogleFont("Latinish", fonts, needArabic = true, github = base)
    doAssert r2.files == 0 and "no Arabic letters" in r2.error, $r2
    doAssert not fileExists(familyDir(fonts, "Latinish") / "Latinish-Regular.ttf")
    # a web font named .ttf: not taken
    writeFile(repo / "ofl" / "webby", "[" & entry("Webby-Regular.ttf", "file", u & "Webby-Regular.ttf") & "]")
    let r3 = installGoogleFont("Webby", fonts, github = base)
    doAssert r3.files == 0 and "web font" in r3.error, $r3
    # the font lists offer what came, drawn in its own letters -- or say why not
    addFontDir(fonts)
    scanFonts(force = true)
    doAssert fontProblem("DejaVu Sans") == ""
    doAssert "not installed" in fontProblem("No Such Family")
    let broken = dir / "Broken"
    createDir(broken)
    var data = readFile(latinOnly)
    # (its 'head' table pointed past the end: listed by its name, not drawable)
    let n = (ord(data[4]) shl 8) or ord(data[5])
    for i in 0 ..< n:
      if data[12 + 16 * i ..< 16 + 16 * i] == "head":
        for k in 0 .. 3: data[12 + 16 * i + 8 + k] = '\xFF'
    # (named "Brokeni", a family of its own)
    data = data.replace("Poppins", "Brokeni")
    var wide = ""
    for c in "Poppins": wide.add '\0' & c
    var wide2 = ""
    for c in "Brokeni": wide2.add '\0' & c
    data = data.replace(wide, wide2)
    writeFile(broken / "Brokenish-Regular.ttf", data)
    addFontDir(broken)
    scanFonts(force = true)
    doAssert "Brokeni" in fontFamilies(), "listed by its name"
    let why = fontProblem("Brokeni")
    doAssert why.len > 0 and "Brokenish-Regular.ttf" in why, "and said that it cannot be drawn: " & why
    doAssert fontCheck(broken / "Brokenish-Regular.ttf").len > 0

echo "google fonts tests passed"

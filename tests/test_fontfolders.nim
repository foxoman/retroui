## Tests of retroui/fontfolders (a folder on disk, as on a desktop) and of the text engine's
## fonts offered one by one: a folder's fonts offered and its families named -- in folders
## inside folders too, .otf (CFF) fonts with them --, looked through a few milliseconds each
## frame with its progress told, stopped, taken away with it, a font put in while the app
## runs found, fonts chosen kept in "Your Fonts", a font read through `fontReader` the first
## time it draws.

import std/[os, tables, times]
import retroui, retroui/[headless, fontfolders, textengine, ttf]
import retroui/uirelays/input

let root = getTempDir() / "retro-fontfolders-test"
removeDir(root)
putEnv("XDG_DATA_HOME", root / "data")
createDir(root / "mine" / "sub")
const app = "Retro Fonts Test"
let kufi = currentSourcePath().parentDir / "data" / "fonts" / "ReemKufi-Subset.ttf"
let cffFont = currentSourcePath().parentDir / "data" / "fonts" / "NotoSansArabic-Subset-CFF.otf"
copyFile(kufi, root / "mine" / "sub" / "kufi.ttf")
createDir(root / "mine" / "sub" / "deeper" / "deepest")
copyFile(cffFont, root / "mine" / "sub" / "deeper" / "deepest" / "naskh.otf")

useHeadless(300, 200)
startApp("Fonts", 300, 200)
var clock = 1000
inputRelays.getTicks = proc (): int = clock

block aFolder:
  doAssert "Reem Kufi" notin fontFamilies()
  addFontFolder(app, FontFolder(name: "mine", kind: ffPath, place: root / "mine"))
  doAssert fontFolders(app).len == 1 and fontFolders(app)[0].name == "mine"
  doAssert fontScan().running, "looked through over frames"
  var frames = 0
  while fontScan().running and frames < 200:
    discard beginFrame()
    endFrame()
    inc frames
  doAssert not fontScan().running and fontScan().found == 2 and fontScan().looked >= 5,
           "every folder inside it looked in: " & $fontScan()
  doAssert "Reem Kufi" in fontFamilies(), "its fonts offered"
  let cffFam = parseFace(readFile(cffFont)).family
  doAssert cffFam in fontFamilies(), "the .otf (CFF) one too, three folders down"
  doAssert fontFace(cffFam, "Regular").face.glyphOf(0x0628) != 0, "drawn: its outlines made TrueType"
  doAssert fontFolders(app)[0].familiesIn.len == 2 and "Reem Kufi" in fontFolders(app)[0].familiesIn
  # (at the next start: offered again, from what the index kept)
  useFontFolders(app)
  waitFontScan()
  doAssert "Reem Kufi" in fontFamilies()

block manyAndStopped:
  # a folder of many fonts: a frame does a few milliseconds of it, Stop leaves what was found
  createDir(root / "many")
  for i in 0 ..< 60: copyFile(kufi, root / "many" / ("k" & $i & ".ttf"))
  addFontFolder(app, FontFolder(name: "many", kind: ffPath, place: root / "many"))
  doAssert fontScan().running
  stopFontScan()
  discard beginFrame()
  endFrame()
  doAssert not fontScan().running, "stopped"
  refreshFontFolders(app)
  waitFontScan()
  doAssert fontScan().found == 62, "all of them when it is let go on: " & $fontScan()
  removeFontFolder(app, 1)

block watched:
  # a font put in while the app runs: found when the folder changes
  let data = readFile(kufi)
  doAssert "Reem Kufi" in fontFamilies()
  removeFontFolder(app, 0)
  doAssert "Reem Kufi" notin fontFamilies() and fontFolders(app).len == 0, "taken away with it"
  createDir(root / "later")
  addFontFolder(app, FontFolder(name: "later", kind: ffPath, place: root / "later"))
  waitFontScan()
  doAssert fontFolders(app)[0].familiesIn.len == 0
  writeFile(root / "later" / "k.ttf", data)
  setLastModificationTime(root / "later", getTime() + initDuration(seconds = 5))
  clock += 6000
  discard beginFrame()
  watchFontFolders(app)
  endFrame()
  waitFontScan()
  doAssert "Reem Kufi" in fontFamilies(), "found when the folder changed"
  removeFontFolder(app, 0)

block chosenAndKept:
  doAssert storeFonts(app, [kufi, currentSourcePath()]) == 1, "the font kept, not the other file"
  waitFontScan()
  doAssert fileExists(storeFolder(app) / "ReemKufi-Subset.ttf")
  doAssert fontFolders(app)[^1].name == "Your Fonts" and "Reem Kufi" in fontFamilies()
  removeFontFolder(app, fontFolders(app).high)

block readThroughAProvider:
  # (as on a phone: a font with no path the program can open, read the first time it draws)

  let bytes = readFile(kufi)
  var store {.global.}: Table[string, string]
  store["<test:k>"] = bytes
  fontReader = proc (path: string): string {.nimcall, gcsafe.} =
    {.cast(gcsafe).}: store.getOrDefault(path)
  addFontFile("Provider Kufi", "Regular", "<test:k>")
  doAssert "Provider Kufi" in fontFamilies()
  let f = fontFace("Provider Kufi", "Regular")
  doAssert f.face.glyphOf(0x0628) != 0, "read through fontReader"
  dropFontFiles("<test:")
  scanFonts(force = true)
  doAssert "Provider Kufi" notin fontFamilies()


stopApp()
removeDir(root)
echo "test_fontfolders: ok"

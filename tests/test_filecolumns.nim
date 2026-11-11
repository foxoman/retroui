## Tests of Retro Files' newer parts in the toolkit: the column view (its
## columns, clicks, keys, type-ahead, the folder shown ahead, many rows),
## renaming many by a pattern, selecting by a pattern, PDF pages drawn on
## workers (`pdfView`, `pageAsync`) and the sound player -- headless, on
## the fake driver.

import std/[os, times, strutils, sequtils]
import retroui, retroui/pdfview
import retroui/uirelays/[input, services]
import harness

fakeDriver()
startApp("columns", W, H)
view = proc () = discard

proc waitFor(cond: proc (): bool; what: string; seconds = 15.0) =
  let until = epochTime() + seconds
  while not cond():
    doAssert epochTime() < until, "timed out: " & what
    run()
    os.sleep(2)

let base = getTempDir() / "retro-columns-test"
removeDir(base)
createDir(base / "Alpha" / "Inner")
createDir(base / "Beta")
writeFile(base / "Alpha" / "note.txt", "hello")
writeFile(base / "Alpha" / "Inner" / "deep.txt", "deep")
for i in 0 ..< 3000: writeFile(base / "Beta" / ("item_" & align($i, 4, '0') & ".txt"), "x")
writeFile(base / "zeta.md", "# z")

# ---- names by a pattern ---------------------------------------------------------------------

block batchNamesWork:
  let names = @["IMG_001.jpg", "IMG_002.jpg", "notes"]
  doAssert batchNames(names, "Holiday ###") == @["Holiday 001.jpg", "Holiday 002.jpg", "Holiday 003"]
  doAssert batchNames(names, "* - #", start = 9) == @["IMG_001 - 9.jpg", "IMG_002 - 10.jpg", "notes - 11"]
  doAssert batchNames(names, "*", "IMG_", "Photo ") == @["Photo 001.jpg", "Photo 002.jpg", "notes"]
  doAssert batchNames(["a file.TXT"], "*", letters = ccUpper) == @["A FILE.TXT"]
  doAssert batchNames(["my old-file.txt"], "*", letters = ccTitle) == @["My Old-File.Txt"]
  doAssert batchNames(["x.tar"], "") == @["x.tar"], "an empty pattern keeps the name"

block globsMatch:
  doAssert globMatch("img_2026_01.jpg", "img_20??_*.jpg")
  doAssert not globMatch("img_26_01.jpg", "img_20??_*.jpg")
  doAssert matchesAny("Photo.PNG", ["*.png"])
  doAssert matchesAny("report-final.pdf", ["*.doc", "report*"])
  doAssert not matchesAny("a.txt", ["*.png", "b*"])

block renameManyAndSelect:
  let d = base / "ren"
  createDir(d)
  for n in ["a.txt", "b.txt", "c.txt"]: writeFile(d / n, n)
  let m = newFolderModel(d)
  waitFor(proc (): bool = m.items.len == 3, "the listing")
  doAssert m.selectMatching("*.txt") == 3
  doAssert m.selectMatching("b*") == 1 and m.marked.count(true) == 1
  doAssert m.selectMatching("a* c*") == 2
  # two names swap places, through names of their own
  let (done, err) = m.renameAll([d / "a.txt", d / "b.txt"], ["b.txt", "a.txt"])
  doAssert err.len == 0, err
  doAssert done.len == 2
  doAssert readFile(d / "a.txt") == "b.txt" and readFile(d / "b.txt") == "a.txt"
  # a clash with a file not renamed is refused before anything moves
  let (done2, err2) = m.renameAll([d / "a.txt"], ["c.txt"])
  doAssert done2.len == 0 and "already exists" in err2
  doAssert readFile(d / "c.txt") == "c.txt"
  let (_, err3) = m.renameAll([d / "a.txt", d / "b.txt"], ["same.txt", "same.txt"])
  doAssert "Two files" in err3
  # a pattern over all three, as the dialog does it
  var paths: seq[string]
  var names: seq[string]
  for n in ["a.txt", "b.txt", "c.txt"]:
    paths.add d / n
    names.add n
  let (done4, err4) = m.renameAll(paths, batchNames(names, "File ##"))
  doAssert err4.len == 0 and done4.len == 3
  doAssert fileExists(d / "File 01.txt") and fileExists(d / "File 03.txt")
  doAssert not fileExists(d / "a.txt")

# ---- the column view ------------------------------------------------------------------------

block columnView:
  let m = newFolderModel(base / "Alpha")
  waitFor(proc (): bool = m.items.len == 2, "the listing")
  var activated = ""
  view = proc () =
    let ev = fileColumns(m, root = base, height = 400, key = "t")
    if ev.activated: activated = ev.item.name
  run(3)
  # the columns: base (with Alpha picked) and Alpha
  waitFor(proc (): bool = true, "")
  # click "Inner" (a folder) in the second column: it opens
  var innerAt = -1
  for i, it in m.items:
    if it.name == "Inner": innerAt = i
  doAssert innerAt >= 0
  # (the second column starts at Pad + 240 + 2; rows under the head)
  let colX = Pad + dp(240) + 2 + 40
  let rowY0 = CtrlH + dp(4) + 1 + Pad + max(ItemH, FontH + dp(10)) div 2 + Pad
  let pitch = max(ItemH, FontH + dp(10)) + Gap
  click(rect(colX, rowY0 + innerAt * pitch - 4, 10, 8))
  run(2)
  waitFor(proc (): bool = m.dir == base / "Alpha" / "Inner" and m.items.len == 1, "into Inner")
  # Left goes up a column, with Inner picked and shown ahead
  key(KeyLeft)
  run(2)
  waitFor(proc (): bool = m.dir == base / "Alpha" and m.items.len == 2, "back to Alpha")
  doAssert m.current.name == "Inner"
  # Down picks note.txt: a file -- the preview column
  key(KeyDown)
  run(2)
  doAssert m.current.name == "note.txt"
  # Enter on a file activates it
  key(KeyEnter)
  run()
  doAssert activated == "note.txt", activated
  # Right on a folder goes in; Up picks it back first
  key(KeyUp)
  run()
  key(KeyRight)
  run(2)
  waitFor(proc (): bool = m.dir == base / "Alpha" / "Inner", "Right goes in")
  # up to the root: Left stops there
  key(KeyLeft)
  run(2)
  key(KeyLeft)
  run(2)
  waitFor(proc (): bool = m.dir == base, "up to the root")
  key(KeyLeft)
  run(2)
  doAssert m.dir == base, "not past the root"
  view = proc () = discard           # (the model goes with the block)

block manyRowsAndTypeAhead:
  let m = newFolderModel(base / "Beta")
  waitFor(proc (): bool = m.items.len == 3000, "3000 files")
  view = proc () =
    discard fileColumns(m, root = base, height = 400, key = "many")
  run(3)
  # click a row to take the keys, then type a name: it is picked and scrolled to
  let colX = Pad + dp(240) + 2 + 40
  let rowY0 = CtrlH + dp(4) + 1 + Pad + max(ItemH, FontH + dp(10)) div 2 + Pad
  click(rect(colX, rowY0 - 4, 10, 8))
  run(2)
  doAssert m.current.name == "item_0000.txt", m.current.name
  typeText("item_2500")
  run(3)
  doAssert m.current.name == "item_2500.txt", m.current.name
  # (only the rows in view are made: a frame of 3000 rows is quick)
  let t0 = epochTime()
  for _ in 0 ..< 20: run()
  let per = (epochTime() - t0) / 20
  doAssert per < 0.05, "a frame of the column view took " & $per & " s"
  view = proc () = discard

block twoModelsOneKey:
  # two folder windows in columns, drawn with one key: each keeps its own
  # columns -- no listing again every frame (that piled up thousands of
  # listings once), and the work settles
  let a = newFolderModel(base / "Alpha" / "Inner")
  let b = newFolderModel(base / "Beta")
  waitFor(proc (): bool = not a.loading and not b.loading, "both listed")
  view = proc () =
    discard fileColumns(a, root = base, height = 200, key = "same")
    discard fileColumns(b, root = base, height = 200, key = "same")
  run(3)
  waitFor(proc (): bool = (run(); not busy()), "the columns' listings done")
  for _ in 0 ..< 50: run()
  doAssert not busy(), "the columns list their folders again every frame"
  view = proc () = discard

# ---- PDF pages on workers ---------------------------------------------------------------------

block pdfViewPages:
  addPdfPreviews()
  # a PDF of three pages, each a color of its own
  var doc = newPdf("three")
  let colors = [color(220, 40, 40), color(40, 160, 60), color(40, 70, 220)]
  for c in colors:
    let pg = doc.addPage((300.0, 400.0))
    pg.fillColor(c)
    pg.rect(0, 0, 300, 400)
    pg.fill()
  let path = base / "three.pdf"
  writeFile(path, doc.render())
  # the first page is the file's picture
  let pic = pdfPreview(path, 64, 64)
  doAssert pic != nil and pic.h == 64 and pic.w in 46 .. 50, $pic.w & "x" & $pic.h
  # page 2 drawn on a worker
  var got: Bitmap
  discard pageAsync(path, 1, 60, 80, onDone = proc (r: var TaskResult) =
    doAssert r.page == 1
    got = toBitmap(move r))
  waitFor(proc (): bool = got != nil, "page 2 drawn")
  let c = got.px[got.w * got.h div 2]
  doAssert ((c shr 8) and 255) > 120 and ((c shr 16) and 255) < 90, "page 2 is green: " & toHex(c)
  # the view: every page in view drawn, the page in view known, zoom
  let v = openPdfView(path)
  doAssert v.count == 3
  view = proc () =
    pdfView(v, height = 300)
  run(3)
  waitFor(proc (): bool = (run(); px(W div 2, 120) != 0xFFFFFF'u32 and
                           (px(W div 2, 120) and 0xFF0000'u32) shr 16 > 150), "page 1 shown in red")
  doAssert v.page == 0
  v.goToPage(2)
  run(3)
  doAssert v.page == 2, $v.page
  waitFor(proc (): bool = (run(); (px(W div 2, 150) and 0xFF'u32) > 150), "page 3 shown in blue")
  let z0 = v.zoomPercent
  v.zoomIn()
  run(3)
  doAssert v.zoomPercent > z0
  v.fitWidth()
  run(2)
  view = proc () = discard
  closePdfView(v)
  doAssert pdfPage(base / "zeta.md", 0, 50, 50) == nil, "not a PDF"

# ---- the sound player -------------------------------------------------------------------------

block audioPlayer:
  # (the system's player, as Android has it: the calls it gets are checked)
  var calls {.global.}: seq[string]
  mediaThroughSystem = true
  let before = systemRelays.call
  systemRelays.call = proc (name, arg: string): string {.gcsafe, nimcall.} =
    {.cast(gcsafe).}:
      calls.add name
      case name
      of "media.videoState": "1\t1500\t4000\t0"
      else: "1"
  let wav = base / "tone.wav"
  writeFile(wav, encodeWav(makeTone(440, 200)))
  var ev: VideoEvent
  view = proc () =
    ev = audioView(wav, height = 200, autoplay = true, key = "snd")
  run(3)
  doAssert "media.videoShow" in calls
  doAssert ev.playing and ev.durationMs == 4000 and ev.positionMs == 1500, $ev
  closeVideo("snd")
  doAssert "media.videoClose" in calls
  mediaThroughSystem = false
  systemRelays.call = before

block upTwiceAtOnce:
  # Up twice before the first listing came goes up two (from the folder on
  # its way), and Back comes back the same way
  view = proc () = discard
  let m = newFolderModel(base / "Alpha" / "Inner")
  waitFor(proc (): bool = m.dir == base / "Alpha" / "Inner" and not m.loading, "Inner")
  m.goUp()
  m.goUp()
  waitFor(proc (): bool = m.dir == base and not m.loading, "two up")
  doAssert m.current.name == "Alpha", m.current.name
  m.goBack()
  waitFor(proc (): bool = m.dir == base / "Alpha" and not m.loading, "back one")

removeDir(base)
echo "test_filecolumns: ok"

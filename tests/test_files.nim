## Tests of retroui/files (listings, formats, file jobs) and retroui/zip,
## on a scratch folder.

import std/[os, strutils, algorithm]
import std/times
import std/random
import retroui/[files, zip, imaging, gfx, textfile, background, appicon, codec]

let root = getTempDir() / "retro-files-test"
removeDir(root)
createDir(root)

proc mk(rel: string; content = "x") =
  createDir((root / rel).parentDir)
  writeFile(root / rel, content)

proc durationTextOk(): bool = true

proc finish(j: FileJob) =
  while j.state == jsRunning: j.run(5)

proc names(dir: string): seq[string] =
  for kind, p in walkDir(dir): result.add p.extractFilename
  result.sort()

block formats:
  doAssert sizeText(0) == "0 bytes"
  doAssert sizeText(1) == "1 byte"
  doAssert sizeText(1536) == "1.5 KB"
  doAssert sizeText(700 * 1024 * 1024) == "700 MB"
  doAssert sizeText(3'i64 * 1024 * 1024 * 1024 + 300 * 1024 * 1024) == "3.3 GB"
  doAssert validName("ok.txt") == ""
  doAssert validName("a/b").len > 0 and validName("  ").len > 0
  doAssert extOf("Photo.JPG") == "jpg"
  doAssert kindName(FileItem(name: "a.txt")) == "Text Document"
  doAssert kindName(FileItem(name: "x", isDir: true)) == "File folder"
  doAssert kindOf(FileItem(name: "song.mp3")) == fkAudio
  doAssert mimeType("a.pdf") == "application/pdf"
  doAssert diskSpace(root).total > 0

block listing:
  mk("list/b.txt", "bb")
  mk("list/A.txt", "a")
  mk("list/.hidden", "h")
  createDir(root / "list/zfolder")
  var l = listFolder(root / "list")
  doAssert l.len == 3, "hidden files are left out"
  sortFiles(l)
  doAssert l[0].name == "zfolder" and l[0].isDir, "folders first"
  doAssert l[1].name == "A.txt" and l[2].name == "b.txt"
  sortFiles(l, bySize, descending = true)
  doAssert l[1].name == "b.txt"
  doAssert listFolder(root / "list", showHidden = true).len == 4
  # quick: names and kinds only (sizes and dates come with the full listing)
  var q = listFolder(root / "list", quick = true)
  sortFiles(q)
  doAssert q.len == 3 and q[0].isDir and q[0].name == "zfolder"
  for it in q: doAssert it.stub and it.size == 0
  for it in listFolder(root / "list"): doAssert not it.stub
  doAssert uniqueName(root / "list", "b.txt") == "b (2).txt"
  doAssert uniqueName(root / "list", "new.txt") == "new.txt"

block copyTree:
  mk("src/one.txt", "1")
  mk("src/sub/two.txt", "22")
  mk("src/sub/deeper/three.txt", "333")
  createDir(root / "dst")
  let j = newJob(jkCopy, [root / "src"], root / "dst")
  j.finish()
  doAssert j.state == jsDone and j.errors.len == 0, $j.errors
  doAssert readFile(root / "dst/src/sub/deeper/three.txt") == "333"
  doAssert j.created == @[root / "dst/src"]
  doAssert j.doneBytes == 6 and j.progressOf == 1.0

block copyConflicts:
  writeFile(root / "src/one.txt", "new one")
  let j = newJob(jkCopy, [root / "src"], root / "dst")
  j.finish()
  doAssert j.state == jsAsking and j.conflict == "one.txt", "asks about a taken name"
  j.resolve(cfKeepBoth)
  j.finish()
  doAssert j.state == jsAsking, "asks again for the next one"
  j.resolve(cfReplace, forAll = true)
  j.finish()
  doAssert j.state == jsDone
  doAssert readFile(root / "dst/src/one (2).txt") == "new one"
  doAssert readFile(root / "dst/src/one.txt") == "1", "kept the old one"
  let skip = newJob(jkCopy, [root / "src/one.txt"], root / "dst/src", cfSkip)
  skip.finish()
  doAssert readFile(root / "dst/src/one.txt") == "1", "skip leaves it alone"

block copyIntoItself:
  let j = newJob(jkCopy, [root / "src"], root / "src/sub")
  j.finish()
  doAssert j.errors.len == 1 and not dirExists(root / "src/sub/src")
  let beside = newJob(jkCopy, [root / "src/one.txt"], root / "src")
  beside.finish()
  doAssert fileExists(root / "src/one (2).txt"), "a copy beside it"

block moveItems:
  mk("mv/a.txt", "a")
  mk("mv/dir/b.txt", "b")
  createDir(root / "mvto")
  let j = newJob(jkMove, [root / "mv/a.txt", root / "mv/dir"], root / "mvto")
  j.finish()
  doAssert j.state == jsDone and j.errors.len == 0, $j.errors
  doAssert names(root / "mv").len == 0
  doAssert readFile(root / "mvto/dir/b.txt") == "b"
  # into a folder that exists: merge
  mk("mv2/dir/c.txt", "c")
  let m = newJob(jkMove, [root / "mv2/dir"], root / "mvto", cfReplace)
  m.finish()
  doAssert names(root / "mvto/dir") == @["b.txt", "c.txt"]
  doAssert not dirExists(root / "mv2/dir")

block deleteSafely:
  mk("keep/precious.txt", "do not lose me")
  mk("del/x.txt")
  mk("del/sub/y.txt")
  when not defined(windows):
    createSymlink(root / "keep", root / "del/sub/link-to-keep")
  let j = newJob(jkDelete, [root / "del"])
  j.finish()
  doAssert j.errors.len == 0, $j.errors
  doAssert not dirExists(root / "del")
  doAssert readFile(root / "keep/precious.txt") == "do not lose me",
    "a link inside a deleted folder does not take its target along"

block measure:
  let j = newJob(jkMeasure, [root / "dst"])
  j.finish()
  doAssert j.files == 4 and j.folders == 4 and j.totalBytes == 6 + 7, $(j.files, j.folders, j.totalBytes)

block zipAndUnzip:
  let z = newJob(jkZip, [root / "src"], root / "src.zip")
  z.finish()
  doAssert z.state == jsDone and fileExists(root / "src.zip"), $z.errors
  var entryNames: seq[string]
  for e in zipEntries(root / "src.zip"): entryNames.add e.name
  doAssert "src/sub/deeper/three.txt" in entryNames
  createDir(root / "unz")
  let u = newJob(jkUnzip, [root / "src.zip"], root / "unz")
  u.finish()
  doAssert u.state == jsDone and u.errors.len == 0, $u.errors
  doAssert readFile(root / "unz/src/sub/deeper/three.txt") == "333"
  doAssert u.created == @[root / "unz/src"]
  let again = newJob(jkUnzip, [root / "src.zip"], root / "unz")
  again.finish()
  doAssert again.state == jsAsking
  again.resolve(cfKeepBoth, forAll = true)
  again.finish()
  doAssert readFile(root / "unz/src/one.txt") == "new one", "the old file is kept"
  doAssert readFile(root / "unz/src/one (3).txt") == "new one"
  doAssert readFile(root / "unz/src/sub/two (2).txt") == "22"

block cancelHalfway:
  mk("big/large.bin", "z".repeat(5_000_000))
  createDir(root / "bigto")
  let j = newJob(jkCopy, [root / "big/large.bin"], root / "bigto")
  j.run(0)                                 # plans
  j.run(0)                                 # one piece
  doAssert j.state == jsRunning and j.doneBytes > 0 and j.doneBytes < 5_000_000, $(j.state, j.doneBytes, j.errors)
  j.cancel()
  doAssert j.state == jsCancelled and not fileExists(root / "bigto/large.bin"),
    "a cancelled copy leaves no half file"

block bigCopyInPieces:
  let j = newJob(jkCopy, [root / "big/large.bin"], root / "bigto")
  var frames = 0
  while j.state == jsRunning:
    j.run(0)
    inc frames
  doAssert j.state == jsDone and frames > 3, "a big file takes several frames"
  doAssert readFile(root / "bigto/large.bin") == readFile(root / "big/large.bin")

block jpegs:
  let here = currentSourcePath().parentDir / "data"
  proc near(p: uint32; r, g, b: int): bool =
    abs(int((p shr 16) and 255) - r) < 24 and abs(int((p shr 8) and 255) - g) < 24 and
      abs(int(p and 255) - b) < 24
  for name in ["quad.jpg", "quad-progressive.jpg"]:
    let b = decodeJpeg(readFile(here / name))
    doAssert b.w == 64 and b.h == 48, name
    doAssert near(b.px[10 * 64 + 10], 200, 30, 30), name & " red corner"
    doAssert near(b.px[40 * 64 + 50], 240, 220, 40), name & " yellow corner"
    let s = decodeJpeg(readFile(here / name), 8)
    doAssert s.w == 8 and s.h == 6 and near(s.px[0], 200, 30, 30), name & " at 1/8"
  doAssert jpegSize(readFile(here / "quad.jpg")) == (64, 48)
  # EXIF orientation 6: turned a quarter clockwise, the red corner goes right
  let r = decodeJpeg(readFile(here / "quad-rotated.jpg"))
  doAssert r.w == 48 and r.h == 64
  doAssert near(r.px[5 * 48 + 42], 200, 30, 30), "rotated"
  let p = loadPicture(here / "quad.jpg", 32, 32)
  doAssert p != nil and p.w == 32 and p.h == 24, "loadPicture fits it"
  doAssertRaises(JpegError): discard decodeJpeg("\xFF\xD8garbage")

block naturalOrder:
  doAssert cmpNatural("file2", "file10") < 0
  doAssert cmpNatural("File10", "file2") > 0
  doAssert cmpNatural("a", "A") == -cmpNatural("A", "a") and cmpNatural("a", "A") != 0
  doAssert cmpNatural("Apple", "banana") < 0
  doAssert cmpNatural("img007", "img7") != 0
  var items = @[FileItem(name: "p10.txt"), FileItem(name: "p2.txt"),
                FileItem(name: "docs", isDir: true), FileItem(name: "p1.txt")]
  sortFiles(items)
  doAssert items[0].name == "docs", "folders first"
  doAssert items[1].name == "p1.txt" and items[2].name == "p2.txt" and
           items[3].name == "p10.txt", "numbers in order"

block bigText:
  var s = newStringOfCap(2_000_000)
  for i in 0 ..< 100_000: s.add "line " & $i & "\tend\n"
  s.add "last"
  writeFile(root / "big.log", s)
  let t = openTextFile(root / "big.log")
  doAssert t.lineCount <= 100_001
  while not t.done: t.index(5)
  doAssert t.lineCount == 100_001, $t.lineCount
  doAssert t.line(0) == "line 0    end"
  doAssert t.line(99_999) == "line 99999    end"
  doAssert t.line(100_000) == "last"
  doAssert t.line(50_000).startsWith("line 50000")
  doAssert t.line(3).startsWith("line 3")   # going back reads again
  # the file becomes shorter while it is shown (a log rotated): no crash
  writeFile(root / "rotated.log", s)
  let rt = openTextFile(root / "rotated.log")
  while not rt.done: rt.index(5)
  writeFile(root / "rotated.log", "short\n")
  for i in [0, 1, 50_000, 99_999, 100_000]: discard rt.line(i)
  rt.close()
  doAssert abs(t.progress - 1.0) < 1e-9
  t.close()
  writeFile(root / "empty.txt", "")
  let e = openTextFile(root / "empty.txt")
  doAssert e.done and e.lineCount <= 1
  e.close()
  let h = openHexFile(root / "big.log")
  doAssert h.lineCount == (s.len + 15) div 16
  doAssert h.line(0).startsWith("00000000  6C 69 6E 65 20 30"), h.line(0)
  doAssert h.line(0).endsWith("line 0.end.line "), h.line(0)
  h.close()

block workInTheBackground:
  for i in 0 ..< 30: mk("bg/f" & $i & ".txt", "z")
  var blue = newSeq[uint32](40 * 30)
  for c in blue.mitems: c = 0xFF2040C0'u32
  let bytes = png(40, 30, blue)
  var data = newString(bytes.len)
  for i, b in bytes: data[i] = char(b)
  writeFile(root / "bg" / "blue.png", data)
  doAssert pictureSize(root / "bg" / "blue.png") == (40, 30)
  let f = folderAsync(root / "bg")
  let p = pictureAsync(root / "bg" / "blue.png", 20, 20)
  let bad = pictureAsync(root / "bg" / "f1.txt", 20, 20)
  var got: seq[TaskResult]
  let until = epochTime() + 10
  while got.len < 3 and epochTime() < until:
    for r in finished(): got.add r
    sleep(2)
  doAssert got.len == 3
  for r in got:
    if r.ticket == f:
      doAssert r.kind == tkFolder and r.items.len == 31 and r.error == ""
    elif r.ticket == p:
      doAssert r.w == 20 and r.h == 15, $r.w & "x" & $r.h
      let b = toBitmap(r)
      doAssert b != nil and b.px.len == 300
    else:
      doAssert r.ticket == bad and r.error.len > 0 and toBitmap(r) == nil
  doAssert not busy()

block damagedFilesAreRefusedNotCrashing:
  # every decoder fed thousands of damaged copies of good files: an error
  # (CatchableError) is fine, a crash (Defect) is a bug
  var r = initRand(2024)
  proc mutate(s: string): string =
    result = s
    for _ in 0 ..< r.rand(1 .. 6):
      if result.len == 0: result = "\0"
      case r.rand(5)
      of 0: result[r.rand(result.high)] = char(r.rand(255))
      of 1:
        let i = r.rand(result.high)
        result[i] = char(ord(result[i]) xor (1 shl r.rand(7)))
      of 2: result.setLen(r.rand(result.len))
      of 3:
        if result.len >= 4:
          let i = r.rand(result.len - 4)
          for k in 0 .. 3: result[i + k] = (if r.rand(1) == 0: '\xFF' else: '\0')
      of 4:
        if result.len > 2:
          let a = r.rand(result.high)
          result.insert(result[a ..< min(result.len, a + 32)], r.rand(result.len))
      else:
        result[r.rand(result.high)] = '\x7F'
  var pixels = newSeq[uint32](12 * 9)
  for i, p in pixels.mpairs: p = 0xFF000000'u32 or uint32(i * 2345)
  let pngBytes = png(12, 9, pixels)
  var pngData = newString(pngBytes.len)
  for i, b in pngBytes: pngData[i] = char(b)
  var bmp = "BM" & "\0".repeat(52)
  proc put32(s: var string; at, v: int) =
    for k in 0 .. 3: s[at + k] = char((v shr (8 * k)) and 255)
  bmp.put32(10, 54); bmp.put32(14, 40); bmp.put32(18, 4); bmp.put32(22, 3)
  bmp[26] = '\1'; bmp[28] = char(24)
  bmp.add "\x10\x20\x30".repeat(12)
  doAssert decodeBmp(bmp).w == 4
  let jpgData = readFile(currentSourcePath().parentDir / "data" / "quad-progressive.jpg")
  mk("dz/a.txt", "hello hello hello")
  zipFolder(root / "dz", root / "dz.zip")
  let zipData = readFile(root / "dz.zip")
  var defects = 0
  for i in 0 ..< 1500:
    for kind in 0 .. 4:
      let input = mutate([pngData, bmp, jpgData, jpgData, zipData][kind])
      try:
        case kind
        of 0: discard decodePng(input)
        of 1: discard decodeBmp(input)
        of 2: discard decodeJpeg(input)
        of 3: discard decodeJpeg(input, 8)
        else:
          writeFile(root / "damaged.zip", input)
          for e in zipEntries(root / "damaged.zip"):
            try: discard readEntry(root / "damaged.zip", e) except CatchableError: discard
      except CatchableError: discard
      except Defect as e:
        inc defects
        echo "decoder ", kind, " crashed: ", e.msg
  doAssert defects == 0
  # what a damaged file may not do: claim a huge size, or unpack forever
  var huge = pngData
  huge[16] = '\x7F'                           # width 2 billion
  doAssertRaises(ImageError): discard decodePng(huge)
  let bomb = zlibCompress(newSeq[byte](1_000_000))
  doAssert zlibDecompress(bomb).len == 1_000_000
  doAssertRaises(InflateError): discard zlibDecompress(bomb, maxOut = 1000)

block deflateMatchesAtAnyOffset:
  # (matches compared eight bytes at a time from any byte offset -- once
  # read through a uint64 pointer, unaligned: undefined behaviour that
  # UBSan reported; now copied)
  var r = initRand(5)
  for level in [1, 4, 6, 9]:
    for n in [0, 1, 7, 9, 300, 70_000]:
      var data = newSeq[byte](n)
      for i in 0 ..< n:
        data[i] = if i mod 37 < 20: byte(i mod 7) else: byte(r.rand(255))
      doAssert zlibDecompress(zlibCompressLevel(data, level)) == data

block zipCannotWriteOutsideItsFolder:
  for evil in ["../evil.txt", "/tmp/evil.txt", "a/../../evil.txt", "C:\\evil.txt"]:
    var z = newZipWriter()
    z.addFile(evil, "x")
    writeFile(root / "evil.zip", z.finish())
    createDir(root / "evil-out")
    if ".." in evil or ':' in evil:
      doAssertRaises(ZipError): extractZip(root / "evil.zip", root / "evil-out")
    else:
      extractZip(root / "evil.zip", root / "evil-out")   # an absolute name stays inside
      doAssert fileExists(root / "evil-out" / "tmp" / "evil.txt")
    doAssert not fileExists(root / "evil.txt") and not fileExists(root.parentDir / "evil.txt")

block trashAndUndo:
  # a trash of our own (XDG_DATA_HOME), so the user's is not touched
  putEnv("XDG_DATA_HOME", root / "xdg")
  mk("tr/keep.txt", "k")
  mk("tr/gone.txt", "bye")
  mk("tr/dir/inner.txt", "in")
  doAssert moveToTrash(root / "tr" / "gone.txt") == ""
  doAssert moveToTrash(root / "tr" / "dir") == ""
  doAssert not fileExists(root / "tr" / "gone.txt") and not dirExists(root / "tr" / "dir")
  var items = trashItems()
  doAssert items.len == 2, $items.len
  var originals: seq[string]
  for it in items: originals.add it.original
  doAssert (root / "tr" / "gone.txt") in originals and (root / "tr" / "dir") in originals
  # the same name again: both are kept
  mk("tr/gone.txt", "again")
  doAssert moveToTrash(root / "tr" / "gone.txt") == ""
  doAssert trashItems().len == 3
  # back where it was
  for it in trashItems():
    if it.original == root / "tr" / "dir": doAssert restore(it) == ""
  doAssert fileExists(root / "tr" / "dir" / "inner.txt")
  # a trash job, then undo puts the files back
  let j = newJob(jkTrash, [root / "tr" / "keep.txt", root / "tr" / "dir"])
  j.finish()
  doAssert j.state == jsDone and j.trashed.len == 2
  doAssert not fileExists(root / "tr" / "keep.txt")
  remember(j)
  doAssert canUndo() and undoLabel().startsWith("Undo Delete")
  let u = undo()
  doAssert u.error == "", u.error
  doAssert fileExists(root / "tr" / "keep.txt") and fileExists(root / "tr" / "dir" / "inner.txt")
  # undo a move and a rename
  createDir(root / "tr2")
  let mv = newJob(jkMove, [root / "tr" / "keep.txt"], root / "tr2")
  mv.finish()
  doAssert mv.moved == @[(root / "tr" / "keep.txt", root / "tr2" / "keep.txt")]
  remember(mv)
  doAssert undo().error == ""
  doAssert fileExists(root / "tr" / "keep.txt") and not fileExists(root / "tr2" / "keep.txt")
  moveFile(root / "tr" / "keep.txt", root / "tr" / "kept.txt")
  remember UndoStep(kind: ukRename, pairs: @[(root / "tr" / "keep.txt", root / "tr" / "kept.txt")],
                    what: "Rename keep.txt")
  doAssert undo().error == ""
  doAssert fileExists(root / "tr" / "keep.txt")
  # undo a copy: the copy goes to the trash
  let cp = newJob(jkCopy, [root / "tr" / "keep.txt"], root / "tr2")
  cp.finish()
  remember(cp)
  doAssert fileExists(root / "tr2" / "keep.txt")
  doAssert undo().error == ""
  doAssert not fileExists(root / "tr2" / "keep.txt")
  doAssert not canUndo()
  doAssert emptyTrash() == 0 and trashItems().len == 0
  doAssert cp.bytesPerSecond >= 0 and durationTextOk()

block pasteShortcut:
  # Explorer's Paste Shortcut: a link here (on Windows a .url), followed;
  # a second one numbered; Undo takes them away
  createDir(root / "sc")
  writeFile(root / "sc" / "notes.txt", "hello")
  createDir(root / "sc" / "Pictures")
  writeFile(root / "sc" / "Pictures" / "beach.png", "png")
  createDir(root / "sc" / "here")
  let r = makeShortcuts([root / "sc" / "notes.txt", root / "sc" / "Pictures"], root / "sc" / "here")
  doAssert r.error == "", r.error
  doAssert r.made.len == 2
  doAssert r.made[0].extractFilename.startsWith("Shortcut to notes.txt"), r.made[0]
  doAssert shortcutTarget(r.made[0]) == absolutePath(root / "sc" / "notes.txt"), shortcutTarget(r.made[0])
  doAssert shortcutTarget(r.made[1]) == absolutePath(root / "sc" / "Pictures")
  doAssert shortcutTarget(root / "sc" / "notes.txt") == "", "a file is not a shortcut"
  when not defined(windows):
    doAssert readFile(r.made[0]) == "hello", "the link opens the file"
    doAssert dirExists(r.made[1]), "and the folder"
  let again = makeShortcuts([root / "sc" / "notes.txt"], root / "sc" / "here")
  doAssert again.made.len == 1 and "(2)" in again.made[0].extractFilename, again.made[0]
  doAssert canUndo() and undoLabel() == "Undo Paste Shortcut"
  doAssert undo().error == ""
  doAssert not fileExists(again.made[0]) and not symlinkExists(again.made[0])
  doAssert undo().error == ""
  doAssert not symlinkExists(r.made[0]) and not fileExists(r.made[0])
  doAssert fileExists(root / "sc" / "notes.txt"), "the file itself stays"
  # (the links in the trash, emptied: the links go, not what they lead to)
  doAssert emptyTrash() == 0
  doAssert fileExists(root / "sc" / "Pictures" / "beach.png"), "emptying the trash kept the folder's files"

removeDir(root)
echo "files tests passed"

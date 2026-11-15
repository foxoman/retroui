## Tests of the system's own file picker behind the kit's file dialogs
## (retroui/systemfiles), with a system that is made up: a document picked
## is given as a copy, a file saved goes where the picker said, and what
## the app writes later is handed back by itself.

import std/[os, strutils]
import retroui/systemfiles

let dir = getTempDir() / "retro-systemfiles-test"
removeDir(dir)
createDir(dir)

var
  asked: seq[string]           # (what the system was asked to show)
  answer = ""                  # (what the user does in its picker)
  written: seq[(string, string)]
  handed: seq[string]

proc frames(n: int) =
  ## (frames go by: the app's dialogs are called, closed)
  for _ in 0 ..< n:
    var closed = false
    var p = ""
    discard systemFileDialog(closed, p, false, "idle")
    sleep(110)

doAssert not hasSystemFiles() and not systemFilesOn(), "a desktop has none"
systemFiles(true)
doAssert not systemFilesOn(), "asked for, but there is none"
block noneThere:
  var open = true
  var path = "x"
  doAssert not systemFileDialog(open, path, false, "open") and not open, "closed again, nothing picked"

# ---- a system that asks where before the file is written (Android)
setSystemFilesBackend SystemFilesBackend(
  askOpen: (proc (): bool = (asked.add "open"; true)),
  opened: (proc (): string = (result = answer; answer = "")),
  askSave: (proc (name, mime: string): bool = (asked.add "save " & name & " " & mime; true)),
  saveTo: (proc (): string = (result = answer; answer = "")),
  write: (proc (origin, path: string): bool = (written.add (origin, readFile(path)); origin != "doc:bad")),
  cache: (proc (): string = dir))
doAssert hasSystemFiles() and systemFilesOn()

block opening:
  let copy = dir / "letter.txt"
  writeFile(copy, "dear")
  var open = true
  var path = ""
  doAssert not systemFileDialog(open, path, false, "open") and open, "the picker is up"
  doAssert asked == @["open"]
  doAssert not systemFileDialog(open, path, false, "open") and asked.len == 1, "asked once"
  answer = copy & "\tdoc:1"
  doAssert systemFileDialog(open, path, false, "open") and not open
  doAssert path == copy
  # read, not changed: nothing goes back
  frames(16)
  doAssert written.len == 0
  # the app saves it: it goes back to the document it came from, once
  writeFile(copy, "dear friend")
  frames(4)
  doAssert written.len == 0, "not while it may still be written"
  frames(14)
  doAssert written == @[("doc:1", "dear friend")]
  frames(6)
  doAssert written.len == 1
  # left without picking
  open = true
  doAssert not systemFileDialog(open, path, false, "open")
  answer = "\1"
  doAssert not systemFileDialog(open, path, false, "open") and not open
  doAssert path == copy, "the path is as it was"

block saving:
  written.setLen(0)
  asked.setLen(0)
  var open = true
  var path = "/somewhere/else/poster.png"
  doAssert not systemFileDialog(open, path, true, "save")
  doAssert asked == @["save poster.png image/png"], $asked
  answer = "doc:2"
  doAssert systemFileDialog(open, path, true, "save") and not open
  doAssert path.startsWith(dir) and path.extractFilename == "poster.png" and dirExists(path.parentDir)
  # written by the app a moment later (through a part file, as the kit's savers do)
  writeFile(path & ".part", "PNG1")
  moveFile(path & ".part", path)
  frames(18)
  doAssert written == @[("doc:2", "PNG1")]
  # saved again: to the same document, without asking
  writeFile(path, "PNG2!")
  frames(18)
  doAssert written.len == 2 and written[1] == ("doc:2", "PNG2!") and asked.len == 1
  # a second Save As of the same name: another file
  open = true
  var path2 = path
  discard systemFileDialog(open, path2, true, "save")
  answer = "doc:bad"
  doAssert systemFileDialog(open, path2, true, "save") and path2 != path
  writeFile(path2, "x")
  frames(18)
  doAssert "poster.png" in systemFilesNote(), "what could not be written is told"
  doAssert systemFilesNote() == ""

# ---- a system that asks where once the file is there (iOS)
setSystemFilesBackend SystemFilesBackend(
  askOpen: (proc (): bool = true),
  opened: (proc (): string = (result = answer; answer = "")),
  hand: (proc (path: string): bool = (handed.add readFile(path); true)),
  cache: (proc (): string = dir))
block savingAfter:
  var open = true
  var path = "notes.txt"
  doAssert systemFileDialog(open, path, true, "save") and not open, "answered at once"
  doAssert path.extractFilename == "notes.txt"
  frames(14)
  doAssert handed.len == 0, "nothing written yet: nothing handed over"
  writeFile(path, "one")
  frames(18)
  doAssert handed == @["one"]

removeDir(dir)
echo "test_systemfiles: ok"

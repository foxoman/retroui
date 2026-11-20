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

block adopted:
  # a file another app gave ("Open with" a file manager that let it be written): its copy's
  # changes go back to its document as a picked one's do
  written.setLen(0)
  let copy = dir / "given.idml"
  writeFile(copy, "IDML1")
  adoptSystemFile(copy, "content://files/given")
  frames(16)
  doAssert written.len == 0, "not changed: nothing goes back"
  writeFile(copy, "IDML2")
  frames(18)
  doAssert written == @[("content://files/given", "IDML2")], $written
  adoptSystemFile(dir / "other.png", "")       # (no document: nothing to write back to)

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

# ---- a folder picked in the system's folder picker (Android's): what the app writes into the
# folder it is given goes into the one picked, its folders as folders
block folders:
  var tree: seq[(string, string, string, string)]    # (folder, name, mime, what it holds)
  var folderAnswer = ""
  var made = 0
  setSystemFilesBackend SystemFilesBackend(
    askOpen: (proc (): bool = true), opened: (proc (): string = ""),
    cache: (proc (): string = dir),
    askFolder: (proc (): bool = (asked.add "folder"; true)),
    folderPicked: (proc (): string = (result = folderAnswer; folderAnswer = "")),
    putInto: (proc (t, folder, name, mime, path: string): string =
      doAssert t == "tree:1"
      for i, e in tree:
        if e[0] == folder and e[1] == name:
          tree[i][3] = (if path.len > 0: readFile(path) else: "")
          return folder & "/" & name
      inc made
      tree.add (folder, name, mime, (if path.len > 0: readFile(path) else: ""))
      folder & "/" & name))
  doAssert hasSystemFolders() and systemFoldersOn()
  var open = true
  var path = ""
  asked.setLen(0)
  doAssert not systemFolderDialog(open, path, "pkg") and open and asked == @["folder"]
  folderAnswer = "tree:1\troot"
  doAssert systemFolderDialog(open, path, "pkg") and not open and dirExists(path)
  createDir(path / "Links")
  writeFile(path / "Book.rpb", "book")
  writeFile(path / "Links" / "photo.jpg", "jpeg")
  proc pump(n: int) =
    for _ in 0 ..< n:
      var closed = false
      var p = ""
      discard systemFolderDialog(closed, p, "idle")
      sleep(110)
  pump(20)
  var names: seq[string]
  for e in tree: names.add e[0] & "|" & e[1]
  doAssert "root|Book.rpb" in names and "root|Links" in names and "root/Links|photo.jpg" in names, $names
  # (written again: over the one there, not a second)
  let before = made
  writeFile(path / "Book.rpb", "book 2")
  pump(20)
  doAssert made == before
  for e in tree:
    if e[1] == "Book.rpb": doAssert e[3] == "book 2"
  # (left: nothing)
  open = true
  doAssert not systemFolderDialog(open, path, "pkg2")
  folderAnswer = "\1"
  doAssert not systemFolderDialog(open, path, "pkg2") and not open

removeDir(dir)
echo "test_systemfiles: ok"

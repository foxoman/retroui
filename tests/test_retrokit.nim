## retrokit run's own options (what goes to the app's environment, what to
## the compiler), the package `--android` follows, and what `--watch` watches: the sources of the app's folder
## and two levels below it, not hidden folders, caches or links to folders.

import std/[os, times]
import ../src/retrokit {.all.}

# ---- run's options ----------------------------------------------------------------------------

for v in ["RETRO_WINDOW", "RETRO_SCALE", "RETRO_SIZE", "RETRO_THEME"]: delEnv(v)
let rest = runOptions(["--window", "app.nim", "--scale:125", "-d:foo", "--theme:Dark",
                       "--size=420x840", "--opt:size"])
doAssert rest == @["app.nim", "-d:foo", "--opt:size"], $rest
doAssert getEnv("RETRO_WINDOW") == "1" and getEnv("RETRO_SCALE") == "125"
doAssert getEnv("RETRO_THEME") == "Dark" and getEnv("RETRO_SIZE") == "420x840"
doAssert not watching
discard runOptions(["--scale:900"])
doAssert getEnv("RETRO_SCALE") == "300", "the scale stays in 50..300"
delEnv("RETRO_WINDOW")
discard runOptions(["app.nim", "--watch"])
doAssert watching and getEnv("RETRO_WINDOW") == ""
watching = false
discard runOptions(["--live", "app.nim"])
doAssert watching and getEnv("RETRO_WINDOW") == "1", "--live is --window and --watch"

# ---- run --android: the package it follows, as retroapk names it ------------------------------

doAssert apkIdOf("examples/My App.nim", @[]) == "org.retro.myapp"
doAssert apkIdOf("2048.nim", @[]) == "org.retro.app2048"
doAssert apkIdOf("app.nim", @["--id:com.foxoman.notes"]) == "com.foxoman.notes"

# ---- what --watch watches -----------------------------------------------------------------------

let dir = getTempDir() / "retrokit-test-" & $getCurrentProcessId()
removeDir(dir)
for d in ["src/views", "src/views/deep", ".git", "nimcache", "assets"]: createDir(dir / d)
let elsewhere = getTempDir() / "retrokit-elsewhere-" & $getCurrentProcessId()
createDir(elsewhere)
writeFile(elsewhere / "far.nim", "")
createSymlink(elsewhere, dir / "linked")
for f in ["app.nim", "config.nims", "nim.cfg", "src/model.nim", "src/views/main.nim",
          "src/views/deep/too.nim", ".git/x.nim", "nimcache/c.nim", "assets/notes.txt"]:
  writeFile(dir / f, "")
var t = 1_700_000_000
proc touch(f: string) =
  inc t, 10
  setLastModificationTime(dir / f, fromUnix(t))
proc changes(f: string): bool =
  let before = sourcesStamp(dir)
  touch(f)
  sourcesStamp(dir) != before

for f in ["app.nim", "config.nims", "nim.cfg", "src/model.nim", "src/views/main.nim"]:
  doAssert changes(f), f & " is watched"
for f in ["src/views/deep/too.nim", ".git/x.nim", "nimcache/c.nim", "assets/notes.txt",
          "linked/far.nim"]:
  doAssert not changes(f), f & " is not watched"
let before = sourcesStamp(dir)
writeFile(dir / "src" / "new.nim", "")
doAssert sourcesStamp(dir) != before, "a new module is seen"

removeDir(dir)
removeDir(elsewhere)
echo "test_retrokit: ok"

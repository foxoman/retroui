#> build-only
import std/[os, strutils]
import retroui
import retroui/jobs

proc wordsIn(path: string): Job[int] =
  ## One job for one file: its closure takes `path` by value. (Made in a
  ## loop instead, every closure would see the loop's last `path`.)
  job(proc (c: JobCtl): int =
    let lines = readFile(path).splitLines   # only what was handed in: no globals, no UI
    for i, line in lines:
      if c.cancelled: return
      result += line.splitWhitespace.len
      if i mod 1000 == 0: c.progress(i / max(1, lines.len)))

var files = @[getCurrentDir() / "README.md", getCurrentDir() / "CHANGELOG.md"]
var counts: seq[Job[int]]

app "Words", 360, 160:
  if button("&Count the words", enabled = counts.len == 0):
    for f in files: counts.add wordsIn(f)
  for i, j in counts:
    label files[i].extractFilename & ": " &
          (if j.done: $j.value & " words" elif j.failed: j.error else: "counting...")

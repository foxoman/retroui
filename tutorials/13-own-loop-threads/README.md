# Lesson 13: Your own loop, and threads

**Level:** advanced · **Time:** 30 minutes · **You learn:** what `app` is made of, and what a worker thread may touch

## Your own loop

```nim
import retroui

# The five calls `app` is made of: your own loop, for a program that already
# has one (a game, an embedded tool) or wants to decide when frames run.
var count = 0
openApp("Own loop", 300, 100)
while beginFrame():                  # false once the window is closed
  if button("&Count"): inc count
  label "Counted " & $count
  endFrame()                         # draws the frame; waits for input when nothing moves
closeApp()
```

`app` is a macro around five calls: `openApp`, `beginFrame` (false once the window is closed), your frame, `endFrame`, `closeApp`. Write them yourself when your program already has a loop (a game, an emulator) or decides when frames run. Between frames `endFrame` waits for input (or a `wakeIn`): an app at rest takes next to no processor.

## Threads, safely

```nim
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
```

Nim's ORC counts a closure's references on one thread. The kit's jobs keep that true for you -- a job's closure is made and let go of on the screen's thread, and its value is moved out, never shared -- if the job's proc keeps two rules:

1. **It touches only what it was handed.** No control, no global of the app, nothing of `ui`. Copy what it needs into locals (or parameters) first; return what it made.
2. **A closure made in a loop shares the loop's variables.** Make each job in a proc of its own (`wordsIn(path)` here), so each has its own `path`.

`JobCtl` lets it report `progress` and see `cancelled`. The screen's thread is the only one that draws. For a thread of your own (`createThread`), hand data over with channels (`std/channels`) or copies, and wake the window with `wakeIn` from the screen's side.

## What you learned

- `openApp`, `beginFrame`, `endFrame`, `closeApp`.
- The two rules of a worker; `JobCtl`.

## Try it

Count the words of every `.nim` file in a folder (`walkDirRec` from `std/os`), with a progress bar for each.

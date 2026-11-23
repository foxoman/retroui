## `retroui/fetch`'s `downloadFile` against a server of the test's own (tests/dlmock.py), on
## every system: through WinHTTP on Windows (no program started: no window flashing up), curl
## or wget elsewhere. A file whole, a redirect, a 404, a download gone on with from its part, no
## server, `stopDownload`; and on the thread that draws, the busy box ticking while it waits and
## its Cancel ending it.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, osproc, streams, strutils, times, exitprocs]
import retroui/[fetch, busy]

let python = if findExe("python3").len > 0: "python3" else: "python"
let server = startProcess(python, args = [currentSourcePath().parentDir / "dlmock.py"], options = {poUsePath})
proc stopAtExit(p: Process) =
  addExitProc(proc () = p.terminate())
stopAtExit(server)
let base = "http://127.0.0.1:" & server.outputStream.readLine.strip

let dir = getTempDir() / "retro-downloads"
removeDir(dir)
createDir(dir)
var want = newString(3 * 1024 * 1024)
for i in 0 ..< want.len: want[i] = char((i * 7 + (i shr 8)) and 255)

var passed = 0
template check(cond: bool; what: string) =
  doAssert cond, what
  inc passed
  echo "  ok   ", what

var err = downloadFile(base & "/file.bin", dir / "a.bin")
check err == "" and readFile(dir / "a.bin") == want and not fileExists(dir / "a.bin.part"),
      "a file, whole: " & err
err = downloadFile(base & "/redirect", dir / "b.bin")
check err == "" and readFile(dir / "b.bin") == want, "a redirect followed: " & err
err = downloadFile(base & "/missing", dir / "c.bin")
check err.len > 0 and not fileExists(dir / "c.bin") and not fileExists(dir / "c.bin.part"),
      "a 404 said: " & err
writeFile(dir / "d.bin.part", want[0 ..< 1_000_000])
err = downloadFile(base & "/file.bin", dir / "d.bin", resume = true)
check err == "" and readFile(dir / "d.bin") == want, "gone on with from its part: " & err
err = downloadFile("http://127.0.0.1:9/nothing", dir / "e.bin", timeoutSec = 10)
check err.len > 0 and not fileExists(dir / "e.bin"), "no server: " & err

# `stopDownload` from another thread ends it, within a second or so
proc stopper() {.thread.} =
  sleep(1500)
  stopDownload(getTempDir() / "retro-downloads" / "f.bin")
var th: Thread[void]
var t0 = epochTime()
createThread(th, stopper)
err = downloadFile(base & "/slow", dir / "f.bin")
joinThread(th)
check err == "stopped" and epochTime() - t0 < 8, "stopped by stopDownload: " & err

# on the thread that draws: the busy box ticks as it waits (the window drawn, its events read),
# and its Cancel ends the download
markUiThread()
var ticks {.global.} = 0
busyHook = proc () {.nimcall.} =
  inc ticks
  if ticks == 30: busyCancelAsked = true       # (Cancel pressed)
t0 = epochTime()
beginBusy("Getting it", cancel = true)
err = downloadFile(base & "/slow", dir / "g.bin")
endBusy(cancel = true)
check err == "cancelled" and ticks >= 30 and epochTime() - t0 < 8 and not fileExists(dir / "g.bin.part"),
      "the busy box ticked, its Cancel ended it: " & err & " (" & $ticks & " ticks)"
busyHook = proc () {.nimcall.} = inc ticks
err = downloadFile(base & "/file.bin", dir / "h.bin")
check err == "" and readFile(dir / "h.bin") == want, "on the thread that draws, whole: " & err
busyHook = nil

removeDir(dir)
echo "downloads: ", passed, " checks passed"

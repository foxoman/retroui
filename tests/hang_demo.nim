## A window that waits on purpose, to try `retroui/hangwatch` by hand: it
## stops answering for eight seconds, then prints what the fault log got
## and ends. As a Windows program (under Wine too):
##
##   nim c -d:release -d:mingw --cpu:amd64 --app:console -o:hang_demo.exe tests/hang_demo.nim
##   python3 tools/winsym.py hang_demo.exe
##   wine hang_demo.exe
##
## It prints "the window did not answer for 5 seconds: its thread was in"
## and the procs, `waitOnPurpose` or `NimMainModule` among them.

import std/os
import retroui

proc waitOnPurpose() {.noinline.} =
  sleep(8000)

var frames = 0
app("Hang Demo", 320, 200):
  label "frame " & $frames
  inc frames
  wakeIn(50)
  if frames == 20: waitOnPurpose()
  if frames > 60:
    echo "FAULTS:\n", peekFaults()
    discard takeFaults()
    quitApp()

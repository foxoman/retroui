## The screen of a run that stopped: before the app's own code runs, the
## report of the last run's crash, with Copy and Start; once started, the
## app runs and the log is empty. Faults the app caught (`guarded`) and
## went on from do not stop it.

import std/[os, strutils]
import retroui
import retroui/uirelays/input
import harness

let home = getTempDir() / "retro-test-stopped"
removeDir(home)
createDir(home)
putEnv("XDG_DATA_HOME", home)
appIdent = "stopped-test"
let log = dataDir(appIdent) / "faults.log"
writeFile(log, "--- the app stopped\nSIGSEGV: memory that is not the program's (signal 11) at address 0x0\n" &
               "  #00 0x7f00001234 libmain.so+0x1234\n")
fakeDriver()
startApp("Stopped Test", W, H)
doAssert lastRunStopped(), "the last run's crash is seen"

var ran = 0
view = proc () =
  if not stoppedScreen(): inc ran
run(3)
doAssert ran == 0, "the app's own code waits while the report is shown"
doAssert not lastRunStopped(), "the report is taken from the log"
key(KeyC, {AltPressed})                   # &Copy
run()
when not defined(macosx):
  let copied = getClipboardText()
  doAssert "signal 11" in copied and "libmain.so+0x1234" in copied, copied
key(KeyS, {AltPressed})                   # &Start
when defined(macosx): key(KeyEnter)       # (no menu letters on a Mac: the default button)
run(2)
doAssert ran > 0, "Start: the app runs"
doAssert not startFresh()

# a fault the app caught and went on from: no screen, the problem box's
writeFile(log, "--- the color panel\nindex 4 not in 0 .. 2\n")
doAssert not lastRunStopped()
doAssert "the color panel" in peekFaults()
# an error nothing caught (Nim's own words) is a stop
writeFile(log, "Error: unhandled exception: index 4 not in 0 .. 2 [IndexDefect]\n")
doAssert lastRunStopped()
removeFile(log)
echo "stopped tests passed"

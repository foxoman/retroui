## How hard builds push the computer (retroui/buildjobs): the compilers at
## once follow the memory and stay at four in Termux, --jobs and
## $RETRO_JOBS win, and a build stopped half way is told the next time.

import std/[os, strutils, cpuinfo]
import retroui/buildjobs

let cores = max(1, countProcessors())
doAssert buildJobs(3) == 3, "--jobs wins"
putEnv("RETRO_JOBS", "2")
doAssert buildJobs() == 2, "$RETRO_JOBS"
delEnv("RETRO_JOBS")
let n = buildJobs()
doAssert n >= 1 and n <= cores, $n
let free = memAvailableMB()
when defined(linux):
  doAssert free > 0, "MemAvailable read"
  # (one compiler for each 320 MB above the Nim compiler's 600)
  doAssert n <= max(1, (free - 600) div 320)
  doAssert buildJobs(perJobMB = 1 shl 30) == 1, "little memory: one at a time"
putEnv("TERMUX_VERSION", "0.118")
doAssert inTermux()
doAssert buildJobs() <= 4, "at most four in Termux"
doAssert "signal 9" in cutNote(2) and "--jobs:1" in cutNote(2)
delEnv("TERMUX_VERSION")
when not defined(android):
  doAssert not inTermux()
  doAssert "signal 9" notin cutNote(2), "the Android advice only on Android"
doAssert jobsFlag(5) == "--parallelBuild:5"

let dir = getTempDir() / "retro-test-buildjobs"
removeDir(dir)
doAssert not lastBuildCut(dir)
buildStarted(dir)
doAssert lastBuildCut(dir), "a build that began and did not end"
buildEnded(dir)
doAssert not lastBuildCut(dir)
removeDir(dir)
echo "build jobs tests passed"

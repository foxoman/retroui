## How hard a build may push this computer: how many C compilers run at
## once, and whether the last build in a folder was stopped before it
## finished. The build tools (`retrokit`, `retroweb`, `retroapk`) use it.
##
## On a phone or tablet (Termux) a build that starts a compiler for every
## core can be stopped by Android itself: Android 12 and later stop an
## app's processes when there are too many of them, or when they use much
## of the processor while the app is in the background (the shell then
## ends with "signal 9"); with little memory the system stops them too.
## So the number of compilers follows the memory that is free, and in
## Termux at most four run at once.
##
## .. code-block:: nim
##   let n = buildJobs()                     # 1 .. cores
##   args.add "--parallelBuild:" & $n
##   if lastBuildCut(nimcache): echo cutNote(n)
##   buildStarted(nimcache)
##   ... the build ...
##   buildEnded(nimcache)
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, cpuinfo]

proc inTermux*(): bool =
  ## Running in Termux (Android's terminal), or another Android shell.
  defined(android) or existsEnv("TERMUX_VERSION") or getEnv("PREFIX").contains("com.termux")

proc memAvailableMB*(): int =
  ## The memory free for new programs, in MB (Linux and Android:
  ## /proc/meminfo's MemAvailable); -1 where it is not known.
  when defined(linux) or defined(android):
    try:
      for line in lines("/proc/meminfo"):
        if line.startsWith("MemAvailable:"):
          return parseInt(line.splitWhitespace()[1]) div 1024
    except CatchableError, Defect: discard
  -1

proc buildJobs*(asked = 0; perJobMB = 320): int =
  ## How many C compilers a build runs at once: `asked` when given (the
  ## `--jobs:N` option), else one per core while each has `perJobMB` of
  ## free memory (the Nim compiler itself keeps about 600 MB), and in
  ## Termux at most four.
  if asked > 0: return asked
  let env = getEnv("RETRO_JOBS")
  if env.len > 0:
    try: return max(1, parseInt(env))
    except ValueError: discard
  result = max(1, countProcessors())
  let free = memAvailableMB()
  if free > 0:
    result = min(result, max(1, (free - 600) div perJobMB))
  if inTermux(): result = min(result, 4)

proc jobsFlag*(asked = 0): string =
  ## The Nim compiler's option for it: "--parallelBuild:N".
  "--parallelBuild:" & $buildJobs(asked)

const markName = ".retro-building"

proc buildStarted*(dir: string) =
  ## A build in `dir` (its nimcache) begins: marked, so the next one can
  ## tell when it was stopped half way.
  try:
    createDir(dir)
    writeFile(dir / markName, $getCurrentProcessId())
  except CatchableError: discard

proc buildEnded*(dir: string) =
  ## The build in `dir` ended (well or not): the mark goes.
  try: removeFile(dir / markName)
  except CatchableError: discard

proc lastBuildCut*(dir: string): bool =
  ## The last build in `dir` was stopped before it ended (by the system,
  ## Ctrl+C, the window closed).
  fileExists(dir / markName)

proc cutNote*(jobs: int): string =
  ## What to say when the last build was stopped half way.
  result = "the last build here stopped before it finished; what it compiled is kept, so this one is quicker"
  if inTermux():
    result.add ". Android stops builds with many processes or much memory (\"signal 9\"): " &
               "this one runs " & $jobs & " compiler" & (if jobs == 1: "" else: "s") &
               " at once (--jobs:1 for fewer); keep Termux in front while it builds, or " &
               "turn the limit off (BUILDING.md, \"Building on a phone or tablet\")"

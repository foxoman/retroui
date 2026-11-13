## The kit measured: one scene of tools/bench.sh, run as an app ($RETRO_BENCH:
## rest, list, dashboard, document), its numbers written as a JSON line to
## $RETRO_BENCH_OUT (else stdout) and the app ended.
##
## - startup: the program started to its first frame shown (the kit's own
##   measure, `firstFrameMs`)
## - at rest: 5 seconds after the first frame with nothing happening -- the
##   memory (resident) and the processor's time
## - a scene: 600 frames, each asked for 16 ms after the last (as a 60 Hz
##   screen would), each changing what is shown -- the processor's time a
##   frame (all of the process's threads), the slowest frames (the 99th
##   percentile of the time between frames) and the most memory
##
##   rest       a number and three buttons
##   list       a grid of 100,000 rows of three texts, scrolled 8 pixels a frame
##   dashboard  600 cells, each its own color and a number that changes every frame
##   document   40 paragraphs (about 20,000 letters) wrapped again to a width
##              that changes every frame
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, times, monotimes, algorithm, json]
import retroui

let scene = getEnv("RETRO_BENCH", "rest")

proc memKb(field: string): int =
  ## (the process's memory: /proc's VmRSS or VmHWM, in KB; -1 elsewhere)
  try:
    for line in lines("/proc/self/status"):
      if line.startsWith(field & ":"):
        return parseInt(line.splitWhitespace()[1])
  except CatchableError: discard
  -1

proc cpuSeconds(): float = cpuTime()   # (the process's processor time, all its threads, on Linux)

var
  phase = 0                      # 0 starting, 1 at rest, 2 the scene, 3 done
  restFrom: MonoTime
  restCpu0: float
  sceneCpu0: float
  frameStarts: seq[MonoTime]
  res = %*{"scene": scene}
  count = 0
  gridSel = 0
  gridId: Id
  cols = @[Column(title: "Time", width: 110), Column(title: "Level", width: 70),
           Column(title: "Message", width: 400)]
  words: seq[string]

const SceneFrames = 600

for i in 0 ..< 40:
  var p = "Paragraph " & $(i + 1) & ". "
  while p.len < 500:
    p.add "The quick brown fox jumps over the lazy dog while the slow green turtle "
  words.add p

proc finish() =
  if phase == 3: return
  phase = 3
  var gaps: seq[float]
  for i in 1 ..< frameStarts.len:
    gaps.add (frameStarts[i] - frameStarts[i - 1]).inNanoseconds.float / 1e6
  gaps.sort()
  if gaps.len > 0:
    res["p99Ms"] = %gaps[min(gaps.high, int(gaps.len.float * 0.99))]
    let span = (frameStarts[^1] - frameStarts[0]).inNanoseconds.float / 1e9
    res["fps"] = %(gaps.len.float / max(1e-9, span))
  res["peakKb"] = %memKb("VmHWM")
  let line = $res
  let f = getEnv("RETRO_BENCH_OUT")
  if f.len > 0:
    let h = open(f, fmAppend)
    h.writeLine line
    h.close()
  else: echo line
  quit 0

app "Bench", 800, 600:
  inc count
  case phase
  of 0:
    wakeIn(16)                   # (until the first frame is on the screen)
    if framesShown() > 0 and count > 2:
      phase = 1
      res["startupMs"] = %firstFrameMs()
      restFrom = getMonoTime()
      restCpu0 = cpuSeconds()
      wakeIn(5000)
  of 1:
    let rested = (getMonoTime() - restFrom).inMilliseconds
    if rested < 5000: wakeIn(int(5000 - rested))
    else:
      res["restKb"] = %memKb("VmRSS")
      res["restCpuPct"] = %((cpuSeconds() - restCpu0) / 5.0 * 100)
      if scene == "rest": finish()
      phase = 2
      sceneCpu0 = cpuSeconds()
      wakeIn(16)
  of 2:
    frameStarts.add getMonoTime()
    if frameStarts.len > SceneFrames:
      res["cpuMsPerFrame"] = %((cpuSeconds() - sceneCpu0) * 1000 / SceneFrames.float)
      finish()
    wakeIn(16)
  else: discard

  let n = frameStarts.len
  case scene
  of "list":
    if phase == 2 and gridId != 0: state(gridId).scrollY += 8
    discard grid(cols, 100_000, proc (row, col: int): string =
      case col
      of 0: "12:" & align($(row div 60 mod 60), 2, '0') & ":" & align($(row mod 60), 2, '0')
      of 1: (if row mod 7 == 0: "WARN" else: "INFO")
      else: "Request " & $row & " served in " & $(row mod 97) & " ms", gridSel, height = -1)
    gridId = ui.lastId
  of "dashboard":
    let area = place(0, remainingH(), fill = true)
    let cw = area.w div 30
    let ch = area.h div 20
    for i in 0 ..< 600:
      let r = rect(area.x + (i mod 30) * cw, area.y + (i div 30) * ch, cw - 1, ch - 1)
      let v = (i * 7919 + n * 31) mod 1000
      fill(r, color(uint8(v mod 256), uint8((v * 3) mod 256), uint8(255 - v mod 256)))
      text(r.x + 2, r.y + 2, $v, ui.theme.text)
  of "document":
    let w = 300 + (n * 7) mod 400
    for p in words: paragraph(p, w = w)
  else:
    label $count, bold = true
    row:
      discard button("One")
      discard button("Two")
      discard button("Three")

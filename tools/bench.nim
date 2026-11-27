## The kit measured: one scene of tools/bench.sh, run as an app ($RETRO_BENCH:
## rest, list, dashboard, document, type), its numbers written as a JSON line to
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
##   type       24 lines of a type specimen, each in another of 48 sizes and
##              four faces every frame (the glyphs' caches full: the GPU's
##              atlas grown or emptied)
##   phone      a phone's settings page in the Gloss look -- bars, glossy tiles,
##              a switch, a slider, two groups of rows -- a pixel lower each frame
##
## RETRO_BENCH_PROFILE=1: the frame profiler (`retroui/frameprof`) on for the scene, its spans
## and counters over the last frames added to the numbers ("profile": each span's average and
## longest ms, each counter's average and most) -- where a frame's time goes.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, times, monotimes, algorithm, json]
import retroui
import retroui/frameprof

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

var phoneTab, phoneLevel = 0
var phoneOn = false

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
  if profOn:
    let s = summary(lastFrames())
    var spans = newJObject()
    for sp in s.spans: spans[sp.name] = %*{"avgMs": sp.avgMs, "maxMs": sp.maxMs, "frames": sp.frames}
    var counts = newJObject()
    for c in s.counters: counts[c.name] = %*{"avg": c.avg, "most": c.most}
    res["profile"] = %*{"spans": spans, "counters": counts}
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
      if getEnv("RETRO_BENCH_PROFILE") == "1": startTrace()
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
  of "phone":
    # (a phone's settings page in the Gloss look, its rows a pixel lower each frame: every
    # banded bar, glossy tile, switch and slider drawn again)
    if count == 1:
      uiLook = lookGloss
      ui.theme = GlossLight
    discard bottomNav([(nfHome, "Home"), (nfSearch, "Search"), (nfCog, "Settings")], phoneTab)
    discard navBar("Settings", back = "Home", action = "Edit")
    space(n mod 40)
    tableGroup "Network":
      if tableSwitch("Airplane Mode", phoneOn, glyph = nfWifi): discard
      for i in 0 ..< 6:
        discard tableRow("Row " & $i, "Detail", taChevron, glyph = nfCog, count = (if i == 2: "3" else: ""))
    discard slider(phoneLevel, 0, 100)
    tableGroup "More":
      for i in 0 ..< 8:
        discard tableRow("Item " & $i, "", taChevron, subtitle = "A line under it")
    phoneLevel = n mod 100
  of "type":
    let area = place(0, remainingH(), fill = true)
    for i in 0 ..< 24:
      let k = (n + i * 5) mod 192
      let st = TextStyle(size: 0.6 + float32(k mod 48) * 0.1, bold: (k div 48) mod 2 == 1,
                         serif: k div 96 == 1)
      text(area.x + 4, area.y + i * (area.h div 24), "Sphinx of black quartz, judge my vow 0123456789",
           ui.theme.text, st)
  else:
    label $count, bold = true
    row:
      discard button("One")
      discard button("Two")
      discard button("Three")

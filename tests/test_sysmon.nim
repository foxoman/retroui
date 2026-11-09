## What the computer is doing (retroui/sysmon): a sample's numbers in
## their ranges, this program among the processes (its identity: id and
## start time), the reading thread and the last good numbers, a process
## ended and given another priority, the startup programs turned off and on,
## the connections with a socket of its own, the history on disk; the
## scrolling graph (charts' liveGraph) drawn whole once, then moved.
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, strutils, times, net]
when not defined(windows):
  import std/osproc        # (a child to end: not on Windows here)
import retroui
import retroui/sysmon
import harness

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

echo "a sample"
discard takeSample()
sleep(300)
let s = takeSample()
check s.cpu == -1 or s.cpu in 0.0 .. 100.0, "the processor in percent: " & $s.cpu
check s.memTotal > 0 and s.memUsed in 0'i64 .. s.memTotal, "the memory: " & bytesText(s.memUsed) &
      " of " & bytesText(s.memTotal)
var me = ProcInfo(pid: -1)
for p in s.processes:
  if p.pid == getCurrentProcessId(): me = p
check me.pid > 0 and me.memory > 0, "this program among the processes (" & me.name & ")"
when not defined(windows):
  check me.started > 0 and abs(me.started - epochTime()) < 3600, "its start time"
check s.readMs >= 0 and s.readMs < 5000, "read in " & formatFloat(s.readMs, ffDecimal, 1) & " ms"
check bytesText(1536) == "1.5 KB" and bytesText(512) == "512 B" and rateText(0) == "0 KB/s",
      "sizes and rates as text"

echo "the reading thread"
startMonitor(100)
var got: Sample
for i in 0 .. 50:
  got = latestSample()
  if got != nil and monitorHistory().len >= 2: break
  sleep(50)
check got != nil and monitorHistory().len >= 2, "samples read on their own thread"
setMonitorInterval(5000)
check true, "slower when nobody looks"

echo "a process ended, another priority"
when not defined(windows):
  let child = startProcess("sleep", args = ["30"], options = {poUsePath})
  sleep(200)
  let s2 = takeSample()
  var kid = ProcInfo(pid: -1)
  for p in s2.processes:
    if p.pid == child.processID: kid = p
  check kid.pid > 0, "the child among them"
  check setPriority(kid, 10) == "", "a lower priority"
  let s3 = takeSample()
  for p in s3.processes:
    if p.pid == kid.pid: check p.nice == 10, "its priority read back: " & $p.nice
  var other = kid
  other.started = kid.started + 1000                 # (another process with the same id)
  check endProcess(other) != "", "an id that is another process's by now is left alone"
  check endProcess(kid) == "", "ended"
  check child.waitForExit(3000) != 0 or not child.running, "and gone"
  child.close()
stopMonitor()

echo "startup"
when defined(linux) and not defined(android):
  let cfg = getTempDir() / "retro-sysmon-" & $getCurrentProcessId()
  createDir(cfg / "autostart")
  putEnv("XDG_CONFIG_HOME", cfg)
  writeFile(cfg / "autostart" / "hello.desktop",
            "[Desktop Entry]\nType=Application\nName=Hello\nExec=hello --quiet\n")
  var items = startupItems()
  var hello = StartupItem()
  for it in items:
    if it.name == "Hello": hello = it
  check hello.enabled and hello.command == "hello --quiet" and hello.canChange, "an autostart entry"
  check setStartupEnabled(hello, false) == "", "turned off"
  for it in startupItems():
    if it.name == "Hello": check not it.enabled, "off (Hidden=true)"
  for it in startupItems():
    if it.name == "Hello": discard setStartupEnabled(it, true)
  for it in startupItems():
    if it.name == "Hello": check it.enabled, "on again"
  removeDir(cfg)

echo "connections"
when defined(linux) or defined(windows):
  let srv = newSocket()
  srv.setSockOpt(OptReuseAddr, true)
  srv.bindAddr(Port(0), "127.0.0.1")
  srv.listen()
  let port = int srv.getLocalAddr()[1]
  let (list, why) = connections()
  var mine = false
  for c in list:
    if c.local.endsWith(":" & $port) and c.state == "Listening": mine = true
  check mine or why.len > 0, "a socket of its own, listening (" & $list.len & " in all)"
  srv.close()

echo "the history"
let hf = getTempDir() / "retro-sysmon-history-" & $getCurrentProcessId()
removeFile(hf)
for i in 0 ..< 10:
  let p = Sample(at: epochTime() - float(10 - i) * 5, cpu: float(i * 10), memTotal: 1000,
                 memUsed: 500, battery: -1)
  appendHistory(hf, p)
let h = loadHistory(hf, epochTime() - 3600)
check h.len == 10 and abs(h[^1].cpu - 90) < 0.01, "kept and read back"
let h2 = loadHistory(hf, epochTime() - 3600, points = 5)
check h2.len == 5 and abs(h2[0].cpu - 5) < 0.01, "averaged into fewer points"
removeFile(hf)

echo "the graph that moves"
fakeDriver()
startApp("sysmon", W, H)
var vals: seq[float]
var version = 0
view = proc () =
  liveGraph("test", vals, version, w = 200, h = 80)
for i in 0 ..< 30:
  vals.add float(i mod 10) * 10
  inc version
  run()
let before = ui.frameNo
check before > 0, "drawn"
let t0 = epochTime()
for i in 0 ..< 200:
  vals.add 50
  if vals.len > 60: vals.delete(0)
  inc version
  run()
let ms = (epochTime() - t0) * 1000 / 200
check ms < 30, "a frame with a new value: " & formatFloat(ms, ffDecimal, 2) & " ms"

if failures > 0:
  echo failures, " failed"
  quit(1)
echo "sysmon tests passed"

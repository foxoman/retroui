## A model of yours run by `retroui/nnet`, against onnxruntime's answer for the same input
## (tools/netcheck.py writes it):
##
##   python3 tools/netcheck.py MODEL.onnx DIR [HEIGHT WIDTH]
##   nim r -d:release tools/netcheck.nim MODEL.onnx DIR [--times]
##
## Says, for each output, its largest value and how far the runner's is from onnxruntime's; how
## long each took; `--times`: the time each kind of operation took (`netProfile`).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[os, json, times, monotimes, strutils, tables, streams]
import retroui/nnet

proc readRaw(p: string; n: int): seq[float32] =
  result = newSeq[float32](n)
  let s = newFileStream(p, fmRead)
  if s == nil: quit "cannot read " & p
  if n > 0: discard s.readData(addr result[0], n * 4)
  s.close()

if paramCount() < 2: quit "netcheck MODEL.onnx DIR [--times]: DIR as tools/netcheck.py wrote it"
let net = loadNet(paramStr(1))
let dir = paramStr(2)
let meta = parseFile(dir / "meta.json")
var dims: seq[int]
for d in meta["dims"]: dims.add d.getInt
var x = floats(dims)
x.f = readRaw(dir / "in.raw", x.f.len)
netProfile = paramCount() >= 3 and paramStr(3) == "--times"
let t0 = getMonoTime()
let outs = net.run({meta["input"].getStr: x})
let ms = (getMonoTime() - t0).inMilliseconds
if netProfile:
  netTimes.sort()
  for k, v in netTimes: echo "  ", k, " ", v div 1000, " ms"
echo "ran in ", ms, " ms (onnxruntime ", formatFloat(meta["seconds"].getFloat * 1000, ffDecimal, 0), " ms)"
var worstAll = 0.0
for o in meta["outputs"]:
  let name = o["name"].getStr
  var od: seq[int]
  for d in o["dims"]: od.add d.getInt
  if name notin outs:
    echo "  ", name, ": not made"
    worstAll = Inf
    continue
  let got = outs[name]
  let want = readRaw(dir / o["file"].getStr, count(od))
  var worst, top = 0.0
  for v in want: top = max(top, abs(v.float))
  let vals = if got.isInt: (var f: seq[float32]; (for v in got.i: f.add float32(v)); f) else: got.f
  if vals.len != want.len:
    echo "  ", name, ": sizes ", got.dims, ", onnxruntime's ", od
    worstAll = Inf
    continue
  for i in 0 ..< want.len: worst = max(worst, abs(vals[i].float - want[i].float))
  worstAll = max(worstAll, worst / max(top, 1.0))
  echo "  ", name, " ", od, ": largest ", formatFloat(top, ffDecimal, 3), ", off by ",
       formatFloat(worst, ffScientific, 2), (if got.dims != od: " (sizes " & $got.dims & ")" else: "")
quit(if worstAll < 1e-3: 0 else: 1)

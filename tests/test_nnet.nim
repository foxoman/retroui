## Image models run here (`retroui/nnet`, `retroui/onnx`): three small ONNX graphs of random
## weights -- convolutions (grouped, strided, dilated, transposed), normalizations, attention,
## pools, resizing, the shape operations -- against onnxruntime's answers (tools/gennet.py).

import std/[json, os, strutils, tables]
import retroui/nnet

const data = currentSourcePath().parentDir / "data" / "nnet"

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

let expected = parseFile(data / "expected.json")
for name, e in expected.pairs:
  let net = loadNet(data / name & ".onnx")
  var ins: seq[(string, Tensor)]
  for k, v in e["inputs"].pairs:
    var dims: seq[int]
    for d in v["dims"]: dims.add d.getInt
    var t = floats(dims)
    for i, x in v["data"].getElems: t.f[i] = float32(x.getFloat)
    ins.add (k, t)
  let outs = net.run(ins)
  for k, v in e["outputs"].pairs:
    var dims: seq[int]
    for d in v["dims"]: dims.add d.getInt
    if k notin outs:
      check false, name & " " & k & ": not made"
      continue
    let o = outs[k]
    var worst = 0.0
    var top = 1.0
    for x in v["data"]: top = max(top, abs(x.getFloat))
    for i, x in v["data"].getElems:
      let got = if o.isInt: float(o.i[i]) else: float(o.f[i])
      worst = max(worst, abs(got - x.getFloat) / top)
    check o.dims == dims and worst < 1e-4, name & " " & k & " " & $dims & ": off by " &
          formatFloat(worst, ffScientific, 1) & (if o.dims != dims: " sizes " & $o.dims else: "")

if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_nnet: all passed"

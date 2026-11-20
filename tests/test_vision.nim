## Pictures understood by models (`retroui/vision`): the text detector's boxes (joined places,
## the smallest rectangle round them, grown as the detector was taught), a reader's answer as
## text (CTC), Arabic put in the order it is written, and the whole of `readText`, `subjectOf`
## and `depthOf` with stand-in models (tools/gennet.py: a "detector" that sees dark places, a
## "reader" whose answer is fixed) -- the real ones are tried by hand (BUILDING.md).

import std/[os, math]
import retroui/[nnet, vision]

const data = currentSourcePath().parentDir / "data" / "nnet"

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

proc near(a, b: float; by = 1.5): bool = abs(a - b) <= by

echo "the detector's boxes"
block boxes:
  # (a map of 60 x 40: two bars of "text", one turned a little)
  let (mw, mh) = (60, 40)
  var m = newSeq[float32](mw * mh)
  for y in 6 ..< 12:
    for x in 10 ..< 50: m[y * mw + x] = 0.9
  for x in 8 ..< 52:
    let y0 = 24 + (x - 8) div 11            # (a slope of 4 in 44)
    for y in y0 ..< y0 + 5: m[y * mw + x] = 0.8
  m[2 * mw + 2] = 0.95                      # (a speck: too small)
  let bs = textBoxes(m, mw, mh)
  check bs.len == 2, "two boxes (the speck left out): " & $bs.len
  if bs.len == 2:
    let (c, s) = bs[0]
    # (40 x 6 grown by 40 * 6 * 1.6 / 92 = 4.17 on every side)
    check near(c[0][0], 10 - 4.17) and near(c[0][1], 6 - 4.17) and near(c[2][0], 50 + 4.17) and
          near(c[2][1], 12 + 4.17), "  the first: its rectangle grown as DB grows it " & $c
    check near(s, 0.9, 0.01), "  its score: the map's mean inside"
    let (d, _) = bs[1]
    check d[0][0] < d[1][0] and d[0][1] < d[3][1] and d[1][1] > d[0][1], "  the second turned: its corners in reading order " & $d

echo "the reader's answer"
block ctc:
  # (6 steps, 4 classes: 0 nothing; "a a" read once, a gap, "b", "c")
  var p = newSeq[float32](6 * 4)
  for t, k in [1, 1, 0, 2, 2, 3]: p[t * 4 + k] = 0.9
  let (s, sure) = ctcText(p, 6, 4, ["a", "b", "c"])
  check s == "abc" and near(sure, 0.9, 1e-6), "repeats once, the gaps none: " & s
  var q = newSeq[float32](3 * 4)
  for t, k in [1, 0, 1]: q[t * 4 + k] = 0.9
  check ctcText(q, 3, 4, ["a", "b", "c"])[0] == "aa", "a letter twice, a gap between"
  check logicalOrder("مالس") == "سلام", "Arabic read left to right: put as it is written"
  check logicalOrder("abc") == "abc", "Latin alone: as it was"
  check logicalOrder("x1 بت") == "تب x1", "a Latin run kept whole, the Arabic letters turned round"
  check logicalOrder("2026 ابحرم") == "مرحبا 2026" and logicalOrder("hello world ابحرم") == "مرحبا hello world",
        "  the space between them kept between"
  check arabicChars.len == 161 and arabicChars[0] == "!" and arabicChars[^1] == "٩", "the Arabic reader's characters"

echo "text in a picture, with stand-in models"
block read:
  # (white, two dark bars: the "detector" finds them, the "reader" answers "abc" for each)
  let (w, h) = (200, 120)
  var px = newSeq[uint32](w * h)
  for i in 0 ..< px.len: px[i] = 0xFFFFFFFF'u32
  for y in 20 ..< 34:
    for x in 30 ..< 170: px[y * w + x] = 0xFF101010'u32
  for y in 70 ..< 80:
    for x in 60 ..< 140: px[y * w + x] = 0xFF202020'u32
  let det = loadNet(data / "vision-textdet.onnx")
  let rec = loadNet(data / "vision-textrec.onnx")
  check charsOf(rec, ["a", "b", "c"]) == @["a", "b", "c", " "], "a reader's characters: the dictionary and a space"
  let rec2 = loadNet(data / "vision-textrec2.onnx")
  check charsOf(rec2, ["a"]) == @["x", "y", "z", " "], "  those it carries itself first (RapidOCR's note)"
  let own = readText(det, rec2, px, w, h)
  check own.len == 2 and own[0].text == "xyz", "  read with them"
  let lines = readText(det, rec, px, w, h, chars = ["a", "b", "c"])
  check lines.len == 2, "two lines: " & $lines.len
  if lines.len == 2:
    check lines[0].text == "abc" and lines[1].text == "abc", "  each read: " & lines[0].text
    check lines[0].corners[0][1] < lines[1].corners[0][1], "  top to bottom"
    let c = lines[0].corners
    check c[0][0] < 30 and c[0][1] < 20 and c[2][0] > 170 and c[2][1] > 34 and c[2][0] < 185,
          "  the box round the first bar, in the picture's places " & $c
  let ar = readText(det, rec, px, w, h, chars = ["ب", "ت", "ث"], arabic = true)
  check ar.len == 2 and ar[0].text == "ثتب", "an Arabic reader's line put in its order: " & (if ar.len > 0: ar[0].text else: "")
  var stops = 0
  let none = readText(det, rec, px, w, h, chars = ["a"], stop = proc (): bool = (inc stops; true))
  check none.len == 0 and stops > 0, "stopped: nothing"

echo "the subject and the depth, with stand-in models"
block subject:
  # (a dark disc on white: the "subject" model sees brightness -- its mask the light places)
  let (w, h) = (100, 80)
  var px = newSeq[uint32](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      px[y * w + x] = if hypot(float(x - 50), float(y - 40)) < 20: 0xFF181818'u32 else: 0xFFF0F0F0'u32
  let m = subjectOf(loadNet(data / "vision-subject.onnx"), px, w, h)
  check m.len == w * h, "a mask as big as the picture (the model's own 32 x 32 made 100 x 80)"
  if m.len == w * h:
    check m[40 * w + 50] < 40 and m[5 * w + 5] > 215, "  0 .. 255, the model's least and most: " &
          $m[40 * w + 50] & " " & $m[5 * w + 5]
  let d = depthOf(loadNet(data / "vision-depth.onnx"), px, w, h, side = 56)
  check d.len == w * h, "a depth as big as the picture (seen at 56 a side, multiples of 14)"
  if d.len == w * h:
    var lo, hi = d[0]
    for v in d:
      lo = min(lo, v)
      hi = max(hi, v)
    check lo >= 0 and hi <= 1 and hi - lo > 0.9 and d[40 * w + 50] < d[5 * w + 5], "  0 .. 1, nearer where the model says"
  check subjectOf(loadNet(data / "vision-subject.onnx"), px, w, h, stop = proc (): bool = true).len == 0,
        "stopped: nothing"

if failures > 0:
  echo failures, " failed"
  quit 1
echo "test_vision: all passed"

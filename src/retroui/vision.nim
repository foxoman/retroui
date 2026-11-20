## Pictures understood by models the app runs itself (`retroui/nnet`): how near each place is
## (`depthOf`, Depth Anything's), which places are the picture's subject (`subjectOf`, U-2-Net's),
## the text in a picture (`readText`, PaddleOCR's detector and reader) -- each model downloaded
## from the model store (`retroui/modelstore`) when the user asks for it.
##
## .. code-block:: nim
##   let net = loadNet(modelPath(storeModel("depth-anything-v2-small")))
##   let near = depthOf(net, px, w, h)            # 0 .. 1 a pixel: 1 the nearest
##   let lines = readText(det, rec, px, w, h)     # each line's words and corners
##
## Pictures are ARGB, row by row (`photofx.Img`'s pixels). Each works for seconds on a phone: run
## it in a job (`retroui/jobs`); `stop`, asked between the model's steps, ends it early (empty
## then).
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/[math, algorithm, strutils, tables]
import std/unicode except strip
import nnet

type
  TextLine* = object
    ## A line of text found in a picture.
    text*: string                       ## its words, in reading order (Arabic too)
    corners*: array[4, (float, float)]  ## its box in the picture: top left, top right, bottom
                                        ## right, bottom left (as the text runs)
    score*: float                       ## how sure the reader is, 0 .. 1

  StopFn* = proc (): bool {.closure.}

# ---- pictures into tensors ---------------------------------------------------------------------------

proc sampled(px: openArray[uint32]; w, h: int; x, y: float): (float, float, float) =
  ## (the color at (x, y), between pixels: bilinear; outside: the edge's)
  let fx = clamp(x, 0.0, float(w - 1))
  let fy = clamp(y, 0.0, float(h - 1))
  let x0 = min(int(fx), w - 1)
  let y0 = min(int(fy), h - 1)
  let x1 = min(x0 + 1, w - 1)
  let y1 = min(y0 + 1, h - 1)
  let ax = fx - float(x0)
  let ay = fy - float(y0)
  var r, g, b = 0.0
  for (xx, yy, k) in [(x0, y0, (1 - ax) * (1 - ay)), (x1, y0, ax * (1 - ay)),
                      (x0, y1, (1 - ax) * ay), (x1, y1, ax * ay)]:
    let p = px[yy * w + xx]
    r += k * float((p shr 16) and 255)
    g += k * float((p shr 8) and 255)
    b += k * float(p and 255)
  (r, g, b)

proc pictureTensor(px: openArray[uint32]; w, h, tw, th: int; mean, std: array[3, float];
                   bgr = false; byMax = false): Tensor =
  ## (the picture resized to `tw` x `th`, as (1, 3, th, tw): each channel (value / 255 - mean) /
  ## std -- blue first when `bgr`; `byMax`: divided by the picture's largest value instead, as
  ## U-2-Net was taught)
  result = floats([1, 3, th, tw])
  var top = 255.0
  if byMax:
    top = 1.0
    for p in px: top = max(top, float(max(max((p shr 16) and 255, (p shr 8) and 255), p and 255)))
  let plane = tw * th
  let sx = float(w) / float(tw)
  let sy = float(h) / float(th)
  for y in 0 ..< th:
    for x in 0 ..< tw:
      let (r, g, b) = sampled(px, w, h, (float(x) + 0.5) * sx - 0.5, (float(y) + 0.5) * sy - 0.5)
      let c = if bgr: [b, g, r] else: [r, g, b]
      for k in 0 .. 2:
        result.f[k * plane + y * tw + x] = float32((c[k] / top - mean[k]) / std[k])

proc resizedMap(m: openArray[float32]; mw, mh, w, h: int): seq[float32] =
  ## (a map of `mw` x `mh` made `w` x `h`: bilinear)
  result = newSeq[float32](w * h)
  let sx = float(mw) / float(w)
  let sy = float(mh) / float(h)
  for y in 0 ..< h:
    let fy = clamp((float(y) + 0.5) * sy - 0.5, 0.0, float(mh - 1))
    let y0 = min(int(fy), mh - 1)
    let y1 = min(y0 + 1, mh - 1)
    let ay = float32(fy - float(y0))
    for x in 0 ..< w:
      let fx = clamp((float(x) + 0.5) * sx - 0.5, 0.0, float(mw - 1))
      let x0 = min(int(fx), mw - 1)
      let x1 = min(x0 + 1, mw - 1)
      let ax = float32(fx - float(x0))
      let top = m[y0 * mw + x0] * (1 - ax) + m[y0 * mw + x1] * ax
      let bot = m[y1 * mw + x0] * (1 - ax) + m[y1 * mw + x1] * ax
      result[y * w + x] = top * (1 - ay) + bot * ay

proc inputSize(net: Net; dflt: (int, int)): (int, int) =
  ## (the picture size the model takes: its first input's, when fixed -- (width, height))
  let ins = net.model.graph.inputs
  if ins.len > 0 and ins[0].dims.len == 4 and ins[0].dims[2] > 0 and ins[0].dims[3] > 0:
    return (ins[0].dims[3], ins[0].dims[2])
  dflt

const imagenetMean = [0.485, 0.456, 0.406]
const imagenetStd = [0.229, 0.224, 0.225]

proc spread(d: Tensor): seq[float32] =
  ## (a model's map made 0 .. 1: its least 0, its most 1)
  var lo = Inf.float32
  var hi = -Inf.float32
  for v in d.f:
    lo = min(lo, v)
    hi = max(hi, v)
  let span = max(hi - lo, 1e-6'f32)
  result = newSeq[float32](d.f.len)
  for i in 0 ..< result.len: result[i] = (d.f[i] - lo) / span

# ---- depth ---------------------------------------------------------------------------------------------

proc depthOf*(net: Net; px: openArray[uint32]; w, h: int; side = 518; stop: StopFn = nil): seq[float32] =
  ## How near each pixel is, 0 .. 1 (1 the nearest), by a Depth Anything model (`side`: the
  ## longer side it sees, a multiple of 14). Empty when stopped or the picture is empty.
  if w <= 0 or h <= 0 or px.len < w * h: return
  let k = float(side) / float(max(w, h))
  let tw = max(14, int(round(float(w) * k / 14)) * 14)
  let th = max(14, int(round(float(h) * k / 14)) * 14)
  let x = pictureTensor(px, w, h, tw, th, imagenetMean, imagenetStd)
  let outs = net.run({net.model.graph.inputs[0].name: x}, stop)
  if outs.len == 0: return
  let d = outs[net.model.graph.outputs[0].name]
  # (relative inverse depth: bigger is nearer)
  resizedMap(spread(d), d.dims[^1], d.dims[^2], w, h)

# ---- the subject ---------------------------------------------------------------------------------------

proc subjectOf*(net: Net; px: openArray[uint32]; w, h: int; stop: StopFn = nil): seq[uint8] =
  ## The picture's subject, 0 .. 255 a pixel (255: the subject), by a U-2-Net model (its first
  ## output, at the size it takes -- 320 x 320 -- made the picture's). Empty when stopped.
  if w <= 0 or h <= 0 or px.len < w * h: return
  let (tw, th) = net.inputSize((320, 320))
  let x = pictureTensor(px, w, h, tw, th, imagenetMean, imagenetStd, byMax = true)
  let outs = net.run({net.model.graph.inputs[0].name: x}, stop)
  if outs.len == 0: return
  let d = outs[net.model.graph.outputs[0].name]
  let big = resizedMap(spread(d), d.dims[^1], d.dims[^2], w, h)
  result = newSeq[uint8](w * h)
  for i in 0 ..< big.len: result[i] = uint8(clamp(big[i] * 255 + 0.5, 0, 255))

# ---- text: where it is (DB's map) ------------------------------------------------------------------------

type Pt = (float, float)

proc cross(o, a, b: Pt): float = (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

proc hull(pts: var seq[Pt]): seq[Pt] =
  ## (the convex hull, counterclockwise: Andrew's monotone chain)
  pts.sort(proc (a, b: Pt): int = (if a[0] != b[0]: cmp(a[0], b[0]) else: cmp(a[1], b[1])))
  if pts.len < 3: return pts
  for p in pts:
    while result.len >= 2 and cross(result[^2], result[^1], p) <= 0: discard result.pop()
    result.add p
  let lower = result.len + 1
  for i in countdown(pts.len - 2, 0):
    let p = pts[i]
    while result.len >= lower and cross(result[^2], result[^1], p) <= 0: discard result.pop()
    result.add p
  discard result.pop()

proc minRect(h: seq[Pt]): (array[4, Pt], float, float) =
  ## (the smallest rectangle round a convex hull -- one of its sides along an edge of it -- its
  ## corners, its two sides)
  var best = Inf
  var corners: array[4, Pt]
  var sides = (0.0, 0.0)
  if h.len == 0: return (corners, 0.0, 0.0)
  if h.len < 3:
    var x0, y0 = Inf
    var x1, y1 = -Inf
    for p in h:
      x0 = min(x0, p[0])
      x1 = max(x1, p[0])
      y0 = min(y0, p[1])
      y1 = max(y1, p[1])
    return ([(x0, y0), (x1, y0), (x1, y1), (x0, y1)], x1 - x0, y1 - y0)
  for i in 0 ..< h.len:
    let a = h[i]
    let b = h[(i + 1) mod h.len]
    let len = hypot(b[0] - a[0], b[1] - a[1])
    if len < 1e-9: continue
    let ux = (b[0] - a[0]) / len
    let uy = (b[1] - a[1]) / len
    var lo1, lo2 = Inf
    var hi1, hi2 = -Inf
    for p in h:
      let s = (p[0] - a[0]) * ux + (p[1] - a[1]) * uy
      let t = -(p[0] - a[0]) * uy + (p[1] - a[1]) * ux
      lo1 = min(lo1, s)
      hi1 = max(hi1, s)
      lo2 = min(lo2, t)
      hi2 = max(hi2, t)
    let area = (hi1 - lo1) * (hi2 - lo2)
    if area < best:
      best = area
      proc at(s, t: float): Pt = (a[0] + s * ux - t * uy, a[1] + s * uy + t * ux)
      corners = [at(lo1, lo2), at(hi1, lo2), at(hi1, hi2), at(lo1, hi2)]
      sides = (hi1 - lo1, hi2 - lo2)
  (corners, sides[0], sides[1])

proc ordered(c: array[4, Pt]): array[4, Pt] =
  ## (the corners as text runs: top left, top right, bottom right, bottom left -- as PaddleOCR
  ## orders them, by x, then each pair by y)
  var s = @c
  s.sort(proc (a, b: Pt): int = cmp(a[0], b[0]))
  let (l0, l1) = if s[0][1] <= s[1][1]: (s[0], s[1]) else: (s[1], s[0])
  let (r0, r1) = if s[2][1] <= s[3][1]: (s[2], s[3]) else: (s[3], s[2])
  [l0, r0, r1, l1]

proc textBoxes*(prob: openArray[float32]; mw, mh: int; thresh = 0.3; boxThresh = 0.5; unclip = 1.6;
                minSide = 3.0): seq[(array[4, (float, float)], float)] =
  ## The boxes of text in a detector's map (DB's: each place how likely it is text): the places
  ## past `thresh` joined, each group's smallest rectangle -- kept when the map's mean inside is
  ## past `boxThresh` -- grown by `unclip` (as the detector was taught: its map is of the text's
  ## shrunk middle), in the map's places. Each with its score.
  var label = newSeq[bool](mw * mh)
  var stack: seq[int]
  for start in 0 ..< mw * mh:
    if label[start] or prob[start] <= thresh: continue
    var pts: seq[Pt]
    var sum = 0.0
    var count = 0
    stack.setLen(0)
    stack.add start
    label[start] = true
    while stack.len > 0:
      let i = stack.pop()
      let x = i mod mw
      let y = i div mw
      sum += float(prob[i])
      inc count
      # (the pixel's corners: a box round pixels, not their middles)
      pts.add (float(x), float(y))
      pts.add (float(x + 1), float(y + 1))
      pts.add (float(x + 1), float(y))
      pts.add (float(x), float(y + 1))
      for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        let nx = x + dx
        let ny = y + dy
        if nx < 0 or ny < 0 or nx >= mw or ny >= mh: continue
        let j = ny * mw + nx
        if not label[j] and prob[j] > thresh:
          label[j] = true
          stack.add j
    if count < 4: continue
    let score = sum / float(count)
    if score < boxThresh: continue
    let (c, a, b) = minRect(hull(pts))
    if min(a, b) < minSide: continue
    # (grown as pyclipper grows it: by area x unclip / perimeter on every side)
    let d = a * b * unclip / max(1e-6, 2 * (a + b))
    let cx = (c[0][0] + c[2][0]) / 2
    let cy = (c[0][1] + c[2][1]) / 2
    let ua = ((c[1][0] - c[0][0]) / max(a, 1e-6), (c[1][1] - c[0][1]) / max(a, 1e-6))
    let ub = ((c[3][0] - c[0][0]) / max(b, 1e-6), (c[3][1] - c[0][1]) / max(b, 1e-6))
    let ha = a / 2 + d
    let hb = b / 2 + d
    let big = [(cx - ua[0] * ha - ub[0] * hb, cy - ua[1] * ha - ub[1] * hb),
               (cx + ua[0] * ha - ub[0] * hb, cy + ua[1] * ha - ub[1] * hb),
               (cx + ua[0] * ha + ub[0] * hb, cy + ua[1] * ha + ub[1] * hb),
               (cx - ua[0] * ha + ub[0] * hb, cy - ua[1] * ha + ub[1] * hb)]
    result.add (ordered(big), score)

const arabicChars* = [
  "!", "#", "$", "%", "&", "'", "(", "+", ",", "-", ".", "/", "0", "1", "2", "3", "4", "5", "6",
  "7", "8", "9", ":", "?", "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
  "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "_", "a", "b", "c", "d", "e",
  "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x",
  "y", "z", "É", "é", "ء", "آ", "أ", "ؤ", "إ", "ئ", "ا", "ب", "ة", "ت", "ث", "ج", "ح", "خ", "د",
  "ذ", "ر", "ز", "س", "ش", "ص", "ض", "ط", "ظ", "ع", "غ", "ف", "ق", "ك", "ل", "م", "ن", "ه", "و",
  "ى", "ي", "ً", "ٌ", "ٍ", "َ", "ُ", "ِ", "ّ", "ْ", "ٓ", "ٔ", "ٰ", "ٱ", "ٹ", "پ", "چ", "ڈ", "ڑ",
  "ژ", "ک", "ڭ", "گ", "ں", "ھ", "ۀ", "ہ", "ۂ", "ۃ", "ۆ", "ۇ", "ۈ", "ۋ", "ی", "ې", "ے", "ۓ", "ە",
  "١", "٢", "٣", "٤", "٥", "٦", "٧", "٨", "٩"
]
  ## The characters PaddleOCR's Arabic reader (PP-OCRv3's: Arabic, Persian, Urdu) writes, in its
  ## dictionary's order -- the reader does not carry them.

# ---- text: what it says (CTC) ----------------------------------------------------------------------------

proc ctcText*(probs: openArray[float32]; steps, classes: int; chars: openArray[string]): (string, float) =
  ## A reader's answer as text: each step's likeliest class -- 0 nothing, k the k-th of `chars` --
  ## a class repeated taken once; the mean of the chosen classes' likelihoods.
  var last = -1
  var sum = 0.0
  var n = 0
  var s = ""
  for t in 0 ..< steps:
    var best = 0
    var bp = probs[t * classes]
    for k in 1 ..< classes:
      if probs[t * classes + k] > bp:
        bp = probs[t * classes + k]
        best = k
    if best != 0 and best != last and best - 1 < chars.len:
      s.add chars[best - 1]
      sum += float(bp)
      inc n
    last = best
  (s, if n > 0: sum / float(n) else: 0.0)

proc logicalOrder*(visual: string): string =
  ## A line read left to right made the order Arabic is written in, as PaddleOCR does for its
  ## Arabic reader: runs of Latin letters, digits and their marks kept as they are (the spaces
  ## at their ends apart: between words of both), the rest a letter at a time, the whole turned
  ## round.
  var parts: seq[string]
  var run = ""
  proc close() =
    # (a run's own spaces at its ends: parts of their own)
    var a = 0
    var b = run.len
    while a < b and run[a] == ' ': inc a
    while b > a and run[b - 1] == ' ': dec b
    for i in 0 ..< a: parts.add " "
    if b > a: parts.add run[a ..< b]
    for i in b ..< run.len: parts.add " "
    run = ""
  for r in visual.runes:
    let c = $r
    if r.int < 128 and c[0] in {'a'..'z', 'A'..'Z', '0'..'9', ' ', ':', '*', '.', '/', '%', '+', '-'}:
      run.add c
    else:
      if run.len > 0: close()
      parts.add c
  if run.len > 0: close()
  for i in countdown(parts.high, 0): result.add parts[i]

proc charsOf*(rec: Net; given: openArray[string] = []): seq[string] =
  ## The characters a reader writes: those it carries itself (RapidOCR's keep them in the
  ## model's "character" note), else `given` (a dictionary's lines); a space after them, as
  ## PaddleOCR's readers were taught.
  let note = rec.model.metaOf("character")
  if note.len > 0: result = note.split('\n')
  else: result = @given
  while result.len > 0 and result[^1].len == 0: discard result.pop()
  result.add " "

proc cropLine(px: openArray[uint32]; w, h: int; c: array[4, (float, float)]; height: int;
              maxWidth: int): Tensor =
  ## (the box's pixels made upright, `height` high, as wide as keeps their shape -- at most
  ## `maxWidth` -- each channel (v / 255 - 0.5) / 0.5, blue first)
  let wide = max(hypot(c[1][0] - c[0][0], c[1][1] - c[0][1]), hypot(c[2][0] - c[3][0], c[2][1] - c[3][1]))
  let high = max(hypot(c[3][0] - c[0][0], c[3][1] - c[0][1]), hypot(c[2][0] - c[1][0], c[2][1] - c[1][1]))
  # (text standing up -- far taller than wide -- read turned)
  var cc = c
  var ww = wide
  var hh = high
  if high >= 1.5 * wide:
    cc = [c[3], c[0], c[1], c[2]]
    ww = high
    hh = wide
  let tw = clamp(int(ceil(float(height) * ww / max(hh, 1.0))), 8, maxWidth)
  result = floats([1, 3, height, tw])
  let plane = height * tw
  for y in 0 ..< height:
    let v = (float(y) + 0.5) / float(height)
    for x in 0 ..< tw:
      let u = (float(x) + 0.5) / float(tw)
      # (between the four corners: a box turned or slanted read straight)
      let top = (cc[0][0] + (cc[1][0] - cc[0][0]) * u, cc[0][1] + (cc[1][1] - cc[0][1]) * u)
      let bot = (cc[3][0] + (cc[2][0] - cc[3][0]) * u, cc[3][1] + (cc[2][1] - cc[3][1]) * u)
      let (r, g, b) = sampled(px, w, h, top[0] + (bot[0] - top[0]) * v - 0.5, top[1] + (bot[1] - top[1]) * v - 0.5)
      result.f[y * tw + x] = float32((b / 255 - 0.5) / 0.5)
      result.f[plane + y * tw + x] = float32((g / 255 - 0.5) / 0.5)
      result.f[2 * plane + y * tw + x] = float32((r / 255 - 0.5) / 0.5)

proc readText*(det, rec: Net; px: openArray[uint32]; w, h: int; chars: openArray[string] = [];
               arabic = false; side = 960; lineHeight = 48; stop: StopFn = nil): seq[TextLine] =
  ## The lines of text in the picture, top to bottom: PaddleOCR's detector (`det`) finds where
  ## each is, its reader (`rec`) what it says -- `chars` its dictionary, when the model does not
  ## carry one; `arabic`: a reader taught Arabic, its lines put in the order Arabic is written.
  ## `side`: the longer side the detector sees at most (a multiple of 32); `lineHeight`: the
  ## height the reader takes (48 for PP-OCRv3's). Empty when stopped.
  if w <= 0 or h <= 0 or px.len < w * h: return
  let k = min(1.0, float(side) / float(max(w, h)))
  let tw = max(32, int(round(float(w) * k / 32)) * 32)
  let th = max(32, int(round(float(h) * k / 32)) * 32)
  let x = pictureTensor(px, w, h, tw, th, imagenetMean, imagenetStd, bgr = true)
  let outs = det.run({det.model.graph.inputs[0].name: x}, stop)
  if outs.len == 0: return
  let m = outs[det.model.graph.outputs[0].name]
  let (mw, mh) = (m.dims[^1], m.dims[^2])
  let sx = float(w) / float(mw)
  let sy = float(h) / float(mh)
  let dict = charsOf(rec, chars)
  for (c, score) in textBoxes(m.f, mw, mh):
    if stop != nil and stop():
      result.setLen(0)
      return
    var corners: array[4, (float, float)]
    for i in 0 .. 3: corners[i] = (clamp(c[i][0] * sx, 0.0, float(w)), clamp(c[i][1] * sy, 0.0, float(h)))
    let crop = cropLine(px, w, h, corners, lineHeight, 32 * lineHeight)
    let ro = rec.run({rec.model.graph.inputs[0].name: crop}, stop)
    if ro.len == 0:
      result.setLen(0)
      return
    let p = ro[rec.model.graph.outputs[0].name]
    var (text, sure) = ctcText(p.f, p.dims[^2], p.dims[^1], dict)
    text = text.strip
    if text.len == 0: continue
    if arabic: text = logicalOrder(text)
    result.add TextLine(text: text, corners: corners, score: sure * score)
  # (top to bottom; lines side by side -- their middles within a quarter line -- left to right)
  result.sort(proc (a, b: TextLine): int =
    let ay = (a.corners[0][1] + a.corners[3][1]) / 2
    let by = (b.corners[0][1] + b.corners[3][1]) / 2
    let lh = max(4.0, (a.corners[3][1] - a.corners[0][1] + b.corners[3][1] - b.corners[0][1]) / 8)
    if abs(ay - by) > lh: cmp(ay, by) else: cmp(a.corners[0][0], b.corners[0][0]))

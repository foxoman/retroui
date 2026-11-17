## Flex Layout: frames that arrange themselves in a row or a column, as the layout program's
## Flex Layout and the web's flexbox -- the room between them kept, what is left shared out
## (`grow`) or taken back (`shrink`), wrapped onto more lines when they do not fit, aligned
## across, the box round them as big as they need (`hug`) or a size of its own. Change one
## (a text frame that grows with its text) and the others move.
##
## .. code-block:: nim
##   let box = FlexBox(dir: fdRow, gap: 12, padding: [10.0, 10, 10, 10], w: 600, h: 200,
##                     justify: fjBetween, align: faCenter)
##   let laid = flexArrange(box, [FlexItem(w: 100, h: 80), FlexItem(w: 200, h: 120, grow: 1)])
##   echo laid.rects            # where each goes, from the box's top left
##
## Developed by Sultan Al Isaiee @foxoman -- www.foxoman.net -- sultan@foxoman.net

import std/json

type
  FlexDir* = enum
    ## Which way the frames go.
    fdRow = "Row", fdColumn = "Column", fdRowReverse = "Row Reverse", fdColumnReverse = "Column Reverse"
  FlexJustify* = enum
    ## Where they stand along it.
    fjStart = "Start", fjCenter = "Center", fjEnd = "End", fjBetween = "Space Between",
    fjAround = "Space Around", fjEvenly = "Space Evenly"
  FlexAlign* = enum
    ## Where they stand across it.
    faStart = "Start", faCenter = "Center", faEnd = "End", faStretch = "Stretch"

  FlexItem* = object
    ## A frame in the box.
    w*, h*: float              ## its size
    grow*: float               ## a share of the room left along the line (0: none)
    shrink*: float             ## a share of the room lacking taken from it (0: none; it keeps its size)
    minW*, minH*: float        ## never smaller

  FlexBox* = object
    ## The box the frames are arranged in.
    dir*: FlexDir
    wrap*: bool                ## onto more lines when they do not fit (else one line)
    gap*: float                ## the room between frames
    lineGap*: float            ## ... between lines (wrapped; 0: `gap`)
    justify*: FlexJustify
    align*: FlexAlign
    padding*: array[4, float]  ## room inside it: top, right, bottom, left
    w*, h*: float              ## its size
    hugW*, hugH*: bool         ## as wide, as tall as the frames need (its size from them)

  FlexRect* = tuple[x, y, w, h: float]

proc flexArrange*(box: FlexBox; items: openArray[FlexItem]): tuple[rects: seq[FlexRect]; w, h: float] =
  ## Where each frame goes (from the box's top left) and how big the box is.
  let row = box.dir in {fdRow, fdRowReverse}
  let rev = box.dir in {fdRowReverse, fdColumnReverse}
  let pad = box.padding
  let (padM0, padM1, padC0, padC1) = if row: (pad[3], pad[1], pad[0], pad[2]) else: (pad[0], pad[2], pad[3], pad[1])
  let hugMain = if row: box.hugW else: box.hugH
  let hugCross = if row: box.hugH else: box.hugW
  let mainSize = (if row: box.w else: box.h) - padM0 - padM1
  let crossSize = (if row: box.h else: box.w) - padC0 - padC1
  let lineGap = if box.lineGap > 0: box.lineGap else: box.gap
  template mainOf(it: FlexItem): float = (if row: it.w else: it.h)
  template crossOf(it: FlexItem): float = (if row: it.h else: it.w)
  template minMain(it: FlexItem): float = (if row: it.minW else: it.minH)
  # the lines
  var lines: seq[seq[int]]
  var cur: seq[int]
  var used = 0.0
  for i, it in items:
    let m = max(0.0, it.mainOf)
    if box.wrap and not hugMain and cur.len > 0 and used + box.gap + m > mainSize + 1e-6:
      lines.add cur
      cur = @[]
      used = 0
    if cur.len > 0: used += box.gap
    used += m
    cur.add i
  if cur.len > 0: lines.add cur
  result.rects = newSeq[FlexRect](items.len)
  var mains = newSeq[float](items.len)
  var crossAt = padC0
  var widest = 0.0
  var lineCross: seq[float]
  for ln in lines:
    var c = 0.0
    for i in ln: c = max(c, max(0.0, items[i].crossOf))
    lineCross.add c
  # (one line, not hugging: as tall as the box across)
  if lines.len == 1 and not hugCross: lineCross[0] = max(lineCross[0], crossSize)
  for li, ln in lines:
    var total = 0.0
    var grows = 0.0
    var shrinks = 0.0
    for i in ln:
      mains[i] = max(0.0, items[i].mainOf)
      total += mains[i]
      grows += max(0.0, items[i].grow)
      shrinks += max(0.0, items[i].shrink) * mains[i]
    let gaps = box.gap * float(max(0, ln.len - 1))
    var free = if hugMain: 0.0 else: mainSize - total - gaps
    if free > 0 and grows > 0:
      for i in ln: mains[i] += free * max(0.0, items[i].grow) / grows
      free = 0
    elif free < 0 and shrinks > 0:
      for i in ln:
        let take = -free * max(0.0, items[i].shrink) * mains[i] / shrinks
        mains[i] = max(items[i].minMain, mains[i] - take)
      var t2 = 0.0
      for i in ln: t2 += mains[i]
      free = mainSize - t2 - gaps
    # where they start, and the room between them
    let n = ln.len
    var start = 0.0
    var between = box.gap
    let room = max(0.0, free)
    case box.justify
    of fjStart: discard
    of fjCenter: start = room / 2
    of fjEnd: start = room
    of fjBetween:
      if n > 1: between = box.gap + room / float(n - 1)
    of fjAround:
      start = room / float(2 * n)
      between = box.gap + room / float(n)
    of fjEvenly:
      start = room / float(n + 1)
      between = box.gap + room / float(n + 1)
    var at = padM0 + start
    let order = if rev: (block: (var o: seq[int]; for k in countdown(ln.high, 0): o.add ln[k]; o)) else: ln
    for i in order:
      let lc = lineCross[li]
      let c = max(0.0, items[i].crossOf)
      let (cs, co) = case box.align
                     of faStart: (c, 0.0)
                     of faCenter: (c, (lc - c) / 2)
                     of faEnd: (c, lc - c)
                     of faStretch: (lc, 0.0)
      result.rects[i] = if row: (at, crossAt + co, mains[i], cs) else: (crossAt + co, at, cs, mains[i])
      at += mains[i] + between
    widest = max(widest, at - between - padM0)
    crossAt += lineCross[li] + lineGap
  let crossUsed = max(0.0, crossAt - lineGap - padC0)
  let mainTotal = if hugMain: widest + padM0 + padM1 else: mainSize + padM0 + padM1
  let crossTotal = if hugCross: crossUsed + padC0 + padC1 else: crossSize + padC0 + padC1
  if row: (result.w, result.h) = (mainTotal, crossTotal)
  else: (result.w, result.h) = (crossTotal, mainTotal)

proc toJson*(b: FlexBox): JsonNode =
  ## The box's settings as JSON.
  %*{"dir": $b.dir, "wrap": b.wrap, "gap": b.gap, "lineGap": b.lineGap, "justify": $b.justify,
     "align": $b.align, "padding": b.padding, "w": b.w, "h": b.h, "hugW": b.hugW, "hugH": b.hugH}

proc flexBoxFrom*(j: JsonNode): FlexBox =
  ## (`toJson` read back)
  if j == nil or j.kind != JObject: return
  for d in FlexDir:
    if $d == j{"dir"}.getStr: result.dir = d
  for d in FlexJustify:
    if $d == j{"justify"}.getStr: result.justify = d
  for d in FlexAlign:
    if $d == j{"align"}.getStr: result.align = d
  result.wrap = j{"wrap"}.getBool
  result.gap = j{"gap"}.getFloat
  result.lineGap = j{"lineGap"}.getFloat
  let p = j{"padding"}.getElems
  if p.len == 4:
    for k in 0 .. 3: result.padding[k] = p[k].getFloat
  result.w = j{"w"}.getFloat
  result.h = j{"h"}.getFloat
  result.hugW = j{"hugW"}.getBool
  result.hugH = j{"hugH"}.getBool

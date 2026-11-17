## Tests of Flex Layout (retroui/flexlayout): frames in a row or a column, the room between
## them, grown and shrunk, justified and aligned, wrapped, the box hugging them.

import retroui/flexlayout

proc near(a, b: float): bool = abs(a - b) < 1e-6

block rowJustified:
  var box = FlexBox(dir: fdRow, gap: 10, padding: [5.0, 5, 5, 5], w: 330, h: 100)
  let items = [FlexItem(w: 100, h: 50), FlexItem(w: 100, h: 80)]
  var r = flexArrange(box, items)
  doAssert near(r.rects[0].x, 5) and near(r.rects[1].x, 115)
  box.justify = fjEnd
  r = flexArrange(box, items)
  doAssert near(r.rects[1].x + r.rects[1].w, 325)
  box.justify = fjBetween
  r = flexArrange(box, items)
  doAssert near(r.rects[0].x, 5) and near(r.rects[1].x + 100, 325)
  box.justify = fjCenter
  box.align = faCenter
  r = flexArrange(box, items)
  doAssert near(r.rects[0].x, 5 + 55) and near(r.rects[0].y, 5 + (90 - 50) / 2)
  box.align = faStretch
  r = flexArrange(box, items)
  doAssert near(r.rects[0].h, 90) and near(r.rects[1].h, 90)
  box.justify = fjEvenly
  r = flexArrange(box, items)
  doAssert near(r.rects[0].x - 5, (330 - 10 - 200 - 10) / 3)

block growShrink:
  let box = FlexBox(dir: fdRow, gap: 0, w: 400, h: 50)
  var r = flexArrange(box, [FlexItem(w: 100, h: 50), FlexItem(w: 100, h: 50, grow: 1),
                            FlexItem(w: 100, h: 50, grow: 3)])
  doAssert near(r.rects[1].w, 125) and near(r.rects[2].w, 175)
  r = flexArrange(FlexBox(dir: fdRow, w: 150, h: 50), [FlexItem(w: 100, h: 50, shrink: 1),
                                                     FlexItem(w: 100, h: 50, shrink: 1)])
  doAssert near(r.rects[0].w, 75) and near(r.rects[1].x, 75)

block wrappedAndColumns:
  let box = FlexBox(dir: fdRow, wrap: true, gap: 10, lineGap: 20, w: 250, h: 300)
  let r = flexArrange(box, [FlexItem(w: 100, h: 40), FlexItem(w: 100, h: 60), FlexItem(w: 100, h: 30)])
  doAssert near(r.rects[2].x, 0) and near(r.rects[2].y, 60 + 20)       # (the third on a line of its own)
  let c = flexArrange(FlexBox(dir: fdColumn, gap: 8, w: 200, h: 500, hugH: true),
                      [FlexItem(w: 80, h: 100), FlexItem(w: 120, h: 50)])
  doAssert near(c.rects[1].y, 108) and near(c.h, 158)                   # (as tall as they are)
  let rv = flexArrange(FlexBox(dir: fdRowReverse, w: 300, h: 50), [FlexItem(w: 100, h: 50), FlexItem(w: 50, h: 50)])
  doAssert near(rv.rects[1].x, 0) and near(rv.rects[0].x, 50)

block hugAndSaved:
  let box = FlexBox(dir: fdRow, gap: 6, padding: [4.0, 4, 4, 4], hugW: true, hugH: true)
  let r = flexArrange(box, [FlexItem(w: 30, h: 20), FlexItem(w: 40, h: 25)])
  doAssert near(r.w, 4 + 30 + 6 + 40 + 4) and near(r.h, 4 + 25 + 4)
  let back = flexBoxFrom(box.toJson)
  doAssert back == box

echo "flex layout ok"

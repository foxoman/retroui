## Tests of retroui/morecontrols and the buttons with a picture: driven
## headlessly (the fake driver of harness.nim).

import retroui/uirelays/input
import harness, retroui

fakeDriver()
startApp("t", W, H)

var
  lo = 20
  hi = 60
  tags = @["a", "b"]
  tagText = ""
  city = ""
  vol = 50
  open = 0
  clicked = ""
  picked = -1
  rangeRect, tagRect, autoRect, knobRect, saveRect, menuRect: Rect

view = proc () =
  rangeSlider(lo, hi, 0, 100, w = 200)
  rangeRect = ui.lastRect
  tagInput(tags, tagText, w = 300)
  tagRect = ui.lastRect
  autocomplete(city, ["Muscat", "Muttrah", "Sohar", "Salalah"], w = 200)
  autoRect = ui.lastRect
  knob(vol, 0, 100)
  knobRect = ui.lastRect
  row:
    if button("Save", pxSave, blTextBeside): clicked = "save"
    saveRect = ui.lastRect
    let m = menuButton("Export", ["PNG", "JPEG"])
    menuRect = ui.lastRect
    if m >= 0: picked = m
  for i, t in ["One", "Two"]:
    if accordionHeader(t, i, open): label "inside " & t
  led(true, "On")
  pill("Paid")
  timeline([("09:00", "Placed", ""), ("10:00", "Packed", "box 3")], current = 0)

run(2)

block range:
  # the right thumb dragged right: hi grows, lo stays
  let chanW = rangeRect.w - dp(11)
  let xHi = rangeRect.x + dp(11) div 2 + hi * chanW div 100
  let y = rangeRect.y + 5
  down(xHi, y); run()
  move(xHi + chanW div 5, y); run()
  up(xHi + chanW div 5, y); run()
  doAssert lo == 20 and hi > 70, $(lo, hi)
  # never crossing: the left thumb dragged past the right stops at it
  let xLo = rangeRect.x + dp(11) div 2 + lo * chanW div 100
  down(xLo, y); run()
  move(rangeRect.x + rangeRect.w - 2, y); run()
  up(rangeRect.x + rangeRect.w - 2, y); run()
  doAssert lo <= hi, $(lo, hi)

block tagsAdd:
  click(tagRect, dx = tagRect.w - 30)
  typeText("nim")
  run()
  key(KeyEnter)
  run(2)
  doAssert tags == @["a", "b", "nim"], $tags
  key(KeyBackspace)
  run(2)
  doAssert tags == @["a", "b"], $tags

block suggest:
  click(autoRect)
  typeText("so")
  run(2)
  key(KeyDown)       # (the first match is picked already; Down: the next)
  key(KeyUp)
  key(KeyEnter)
  run(2)
  doAssert city == "Sohar", city

block buttons:
  click(saveRect)
  doAssert clicked == "save"
  doAssert labeledSize(glyphPic(pxSave, 1.0), "Save", blTextBelow)[1] >
           labeledSize(glyphPic(pxSave, 1.0), "Save", blTextBeside)[1]
  doAssert labeledSize(glyphPic(pxSave, 1.0), "Save", blIconOnly)[0] <
           labeledSize(glyphPic(pxSave, 1.0), "Save", blTextBeside)[0]
  setToolbarLook(blTextBelow)
  doAssert toolbarLook == blTextBelow
  setToolbarLook(blDefault)
  doAssert toolbarLook == blIconOnly

block accordion:
  doAssert open == 0
  run(1)

echo "more controls tests passed"

## The Channels panel shown and used on images of every mode (it once
## brought the program down): its rows clicked, an alpha channel, Quick
## Mask, the composite again.

import std/[os]
import retroui/uirelays/input
import harness

const photoUnderTest = true
include ../examples/photo

let home = getTempDir() / "retro-photo-chantest"
removeDir(home)
createDir(home)
putEnv("HOME", home)
setCurrentDir(home)

fakeDriver()
setup()
startApp("photo", W, H)
view = photoFrame
run(3)

for (k, m) in [(2, cmRGB), (3, cmCMYK), (4, cmLab), (1, cmGray), (0, cmBitmap)]:
  docs.setLen(0)
  active = nil
  run(2)
  let d = newUntitled(120, 90, white, 72, newModeOf(k), "chan" & $k, 8)
  d.dpi = 300
  if m in {cmRGB, cmCMYK}:
    # (as the image the program came down on: Arabic type with a style)
    var t = newText("مرحبا", x = 20, y = 60)
    let L = d.addTextLayer(t)
    L.fx.fx[fxStroke].on = true
    L.fx.fx[fxDropShadow].on = true
    d.markAll()
  addDoc(d)
  run(2)
  showPanel("channels")
  run(3)
  doAssert panelShown("channels"), $m
  # each row clicked (the composite, each channel), as the panel does
  for i in 0 ..< d.channelNames.len:
    let ch = if d.channelNames.len == 1: -1 else: i - 1
    if ch < 0: d.showAllChannels() else: d.showChannel(ch)
    inc d.ver
    run(2)
  d.showAllChannels()
  inc d.ver
  # an alpha channel, then Quick Mask
  d.setSelection(d.rectMask(rect(10, 10, 40, 30)))
  discard d.saveSelection()
  inc d.ver
  run(2)
  d.quickMask = true
  inc d.ver
  run(2)
  d.quickMask = false
  inc d.ver
  run(2)
  # the panel clicked where its rows are (the mouse, as a finger would)
  let a = mdiAreaRect("ws")
  for y in countup(a.y + dp(40), a.y + a.h - dp(40), dp(15)):
    click(rect(a.x + a.w - dp(150), y, 4, 4))
    run(1)
  # Ctrl+3 .. (a channel by its keys) and Ctrl+2 (all)
  for k in [Key3, Key4, Key5, Key6, Key2, Key1]:
    key(k, {CtrlPressed})
    run(2)
  echo "ok ", m

block aPageShapedImage:
  # an image whose thumbnail, fitted, is a pixel shorter than asked (a book's page, 874 x 1240:
  # the panel once read past the small copy of it -- a fault each frame)
  docs.setLen(0)
  active = nil
  run(2)
  let d = newUntitled(874, 1240, white, 150, newModeOf(2), "page", 8)
  addDoc(d)
  showPanel("channels")
  ui.lastFault = ""
  run(3)
  for ch in [-1, 0, 1, 2]:
    doAssert channelThumb(d, ch, dp(24)).w > 0
  doAssert ui.lastFault == "", ui.lastFault
  echo "ok a page-shaped image"

echo "test_channelspanel: ok"

## Export for Screens (`retroui/screenexport`): an object picked written at 1x, 2x and 3x as
## PNG (its size times each, named with its suffix), as JPEG and WebP, once as SVG and PDF; a
## folder for each scale and format; artboards cut to their pages; the whole document; type
## drawn again at 2x, not stretched.

import std/[os, strutils]
import retroui/[gfx, imaging, photo, photoshapes, textengine, screenexport, photocc]

var failures = 0
template check(cond: bool; what: string) =
  if cond: echo "  ok   ", what
  else:
    echo "  FAIL ", what
    inc failures

let dir = getTempDir() / "retro-screens-test"
removeDir(dir)

let d = newDoc(400, 300, 0xFFFFFFFF'u32, name = "screens")
var s = ShapeData(kind: "Rectangle", fill: solidPaint(0xFF2266CC'u32))
s.path = rectPath(50, 40, 150, 90)
let B = d.addShapeLayer(s, "Button")
var t = newText("OK", CharStyle(size: 24, color: 0xFFFFFFFF'u32, hScale: 1, vScale: 1), 60, 50)
t.boxW = 80
t.boxH = 30
let T = d.addTextLayer(t)
T.name = "Label"

block assets:
  let items = d.assetItems(@[d.layers.find(B)])
  check items.len == 1 and items[0].box == rect(50, 40, 100, 50), "the button cut to its box: " & $items[0].box
  var o = defaultScreenExport()
  o.formats = {sfPng, sfJpeg, sfWebp, sfSvg, sfPdf}
  o.prefix = "ui_"
  let files = d.exportForScreens(items, o, dir)
  check files.len == 3 * 3 + 2, "three scales of three pictures, and SVG and PDF once (" & $files.len & ")"
  check fileExists(dir / "ui_Button.png") and fileExists(dir / "ui_Button@2x.png") and
        fileExists(dir / "ui_Button@3x.webp") and fileExists(dir / "ui_Button.svg") and fileExists(dir / "ui_Button.pdf"),
        "named with the prefix and each scale's suffix"
  let p1 = decodePng(readFile(dir / "ui_Button.png"))
  let p2 = decodePng(readFile(dir / "ui_Button@2x.png"))
  let p3 = decodePng(readFile(dir / "ui_Button@3x.png"))
  check (p1.w, p1.h) == (100, 50) and (p2.w, p2.h) == (200, 100) and (p3.w, p3.h) == (300, 150),
        "1x, 2x and 3x the size"
  check p2.px[50 * 200 + 100] == 0xFF2266CC'u32, "its color"
  check readFile(dir / "ui_Button.svg").contains("<svg") and readFile(dir / "ui_Button.pdf").startsWith("%PDF"),
        "SVG and PDF written"

block typeSharp:
  # (the button and its label together: the label set again at 2x -- its letters' edges as hard)
  let items = d.assetItems(@[d.layers.find(B), d.layers.find(T)])
  check items.len == 2, "two assets"
  let sd = d.itemDoc(ScreenItem(name: "both", layers: @[B, T], box: rect(50, 40, 100, 50)), 2)
  check sd.w == 200 and sd.h == 100 and sd.layers.len == 2 and sd.layers[1].isText and
        sd.layers[1].text.spans[0].style.size == 48, "type drawn again at twice its size"

block folders:
  var o = defaultScreenExport()
  o.formats = {sfPng, sfSvg}
  o.folderPerScale = true
  o.folderPerFormat = true
  let sub = dir / "folders"
  discard d.exportForScreens(@[d.documentItem], o, sub)
  check fileExists(sub / "1x" / "png" / "screens.png") and fileExists(sub / "2x" / "png" / "screens@2x.png") and
        fileExists(sub / "svg" / "screens.svg"), "a folder for each scale and format"
  check decodePng(readFile(sub / "1x" / "png" / "screens.png")).w == 400, "the whole document"

block artboards:
  let a = newDoc(600, 400, 0xFFFFFFFF'u32, name = "boards")
  var r = ShapeData(kind: "Rectangle", fill: solidPaint(0xFFCC3300'u32))
  r.path = rectPath(20, 20, 120, 120)
  let L = a.addShapeLayer(r, "Square")
  let k = a.addArtboard(rect(0, 0, 300, 400), "Phone", color = 0xFF00FF00'u32)
  let items = a.artboardItems()
  check items.len == 1 and items[0].box == a.boards[k].r and items[0].name == "Phone" and L in items[0].layers,
        "an artboard cut to its page, what is on it in it"
  let one = a.itemDoc(items[0])
  one.updateComposite()
  check one.w == 300 and one.h == 400, "its document as big as it"

removeDir(dir)
if failures > 0:
  echo "test_screenexport: ", failures, " failed"
  quit(1)
echo "test_screenexport: all passed"
